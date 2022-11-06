{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module NetworkPartition where

import Channel
import Codec.Serialise (Serialise (encode), decode)
import Control.Algebra hiding (send)
import Control.Carrier.Random.Gen
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled hiding (send)
import Control.Monad (forM, forM_)
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (IOSim, runSimTrace, selectTraceEventsDynamic, traceM)
import Control.Monad.Random (forever, mkStdGen, runRand, void)
import Control.Tracer
import qualified Data.ByteString.Lazy as LBS
import Data.List (delete, sort)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import qualified MockLogStore as M
import Raft.Handler
import Raft.Process hiding (timeTracerWith)
import Raft.Type
import Raft.Utils
import System.Random.Shuffle (shuffleM)
import Utils

createFollower ::
  ( Has Random sig m,
    HasLabelledLift (IOSim s) sig m
  ) =>
  TQueue (IOSim s) Int ->
  NodeId ->
  [(PeerNodeId, Channel (IOSim s) LBS.ByteString)] ->
  m (HEnv Int (IOSim s))
createFollower
  userLogQueue
  nodeId
  peerChannels =
    do
      a <- lift $ newTVarIO 0
      b <- lift $ newTVarIO Nothing
      c <- lift $ newTVarIO M.emptyLogStore
      let pf = createPersistentFun $ Persistent a b c
          elecTimeRange = (0.2, 0.4)
      newElectSize <- randomRDiffTime elecTimeRange
      newElectTimeout <- lift $ newTimeout newElectSize

      ctv <- lift $ newTVarIO 0
      latv <- lift $ newTVarIO 0
      _ <- lift $ forkIO $ aProcess (readLogs pf) ctv latv 0 (\i k -> pure (i + k))

      let tEncode = convertCborEncoder (encode @(Msg Int))
      tDecode <- lift $ convertCborDecoder (decode @(Msg Int))
      peersRecvQueue <- lift newTQueueIO
      peerInfoMaps <- forM peerChannels $ \(peerNodeId, channel1) -> do
        void . lift . forkIO $
          rProcess (Tracer (traceM . N1 . IdWrapper (unNodeId nodeId) . IdWrapper (unPeerNodeId peerNodeId))) peerNodeId peersRecvQueue channel1 tDecode
        pure (peerNodeId, PeerInfo (send channel1 . tEncode))
      let env =
            HEnv
              { nodeId = nodeId,
                userLogQueue,
                peersRecvQueue,
                persistentFun = pf,
                peerInfos = Map.fromList peerInfoMaps,
                electionTimeRange = elecTimeRange,
                appendEntriesRpcRetryWaitTime = 1,
                heartbeatWaitTime = 0.1,
                commitIndexTVar = ctv,
                lastAppliedTVar = latv,
                tracer = Tracer (traceM . N2 . IdWrapper (unNodeId nodeId))
              }
          state = HState newElectSize newElectTimeout
      ri <- uniform
      void $ lift $ forkIO $ void $ runFollow state env (mkStdGen ri)
      pure env

networkPartition ::
  ( HasLabelledLift (IOSim s) sig m,
    Has Random sig m
  ) =>
  [Int] ->
  [HEnv Int (IOSim s)] ->
  Map (Int, Int) (Channel (IOSim s) LBS.ByteString, TVar (IOSim s) ConnectedState) ->
  m ()
networkPartition nodeIds nsls ccm = forever $ do
  ri <- uniform @Int
  let ls = fst $ runRand (shuffleM nodeIds) (mkStdGen ri)
  i <- uniformR (1 :: Int, length nodeIds `div` 2)
  ta <- randomRDiffTime (2, 4)
  let (va, vb) = splitAt i ls
      newLs = getPart (va, vb)
  kls <-
    forM nsls $
      \HEnv
         { nodeId,
           commitIndexTVar,
           persistentFun = PersistentFun {getAllLogs, readCurrentTerm}
         } -> lift $ do
          commitIndex <- readTVarIO commitIndexTVar
          atls <- getAllLogs
          term <- readCurrentTerm
          pure (nodeId, term, commitIndex, atls)
  t <- lift getCurrentTime
  lift $ traceWith (Tracer (traceM . N4 @Int)) (NetworkChange t (va, vb) ta kls)

  forM_ newLs $ \(a, b) -> lift $
    atomically $ do
      let tv10 = snd $ fromJust $ Map.lookup (a, b) ccm
      writeTVar tv10 Disconnectd

  lift $ threadDelay ta

  forM_ newLs $ \(a, b) -> lift $
    atomically $ do
      let tv10 = snd $ fromJust $ Map.lookup (a, b) ccm
      writeTVar tv10 Connected

createAll ::
  ( Has Random sig m,
    HasLabelledLift (IOSim s) sig m
  ) =>
  m ()
createAll = do
  nds <- (* 2) <$> uniformR (1, 10)
  let nodeIds = [0 .. nds]
  ccs <- forM (ft nodeIds) $ \(na, nb) -> do
    dt <- randomRDiffTime (0.01, 0.03)
    connStateTVar <- lift $ newTVarIO Connected
    (ca, cb) <-
      lift $ createConnectedBufferedChannelsWithDelay @_ @LBS.ByteString connStateTVar dt 100
    pure
      [ ((na, nb), (ca, connStateTVar)),
        ((nb, na), (cb, connStateTVar))
      ]
  let ccm = Map.fromList $ concat ccs
  userLogQueue <- lift newTQueueIO
  _ <- lift $
    forkIO $ do
      forM_ [1 ..] $ \i -> do
        atomically $ writeTQueue userLogQueue i
        threadDelay 0.5
  nsls <- forM nodeIds $ \nodeId -> do
    let ncs =
          map
            (\i -> (PeerNodeId i, fst $ fromJust $ Map.lookup (nodeId, i) ccm))
            (delete nodeId nodeIds)
    createFollower userLogQueue (NodeId nodeId) ncs

  ri <- uniform
  _ <-
    lift
      . forkIO
      . void
      . runLabelledLift
      . runRandom (mkStdGen ri)
      $ networkPartition nodeIds nsls ccm
  dt <- randomRDiffTime (10, 30)
  lift $ threadDelay dt

  kls <-
    forM nsls $
      \HEnv
         { nodeId,
           commitIndexTVar,
           lastAppliedTVar,
           persistentFun
         } -> lift $ do
          commitIndex <- readTVarIO commitIndexTVar
          lastApplied <- readTVarIO lastAppliedTVar
          atls <- getAllLogs persistentFun
          pure (nodeId, commitIndex, lastApplied, atls)
  lift $ traceWith (Tracer (traceM . N3 @Int)) kls

verifyResult :: NTracer a -> Bool
verifyResult (N3 xs) =
  let bs = map (\(_, b, _, _) -> b) xs
      minB = reverse (sort bs) !! (length bs `div` 2)
      ds = concatMap (\(_, b, _, d) -> [take minB d | b >= minB]) xs
   in all (== head ds) ds
verifyResult _ = False

runCreateAll :: Int -> Bool
runCreateAll i =
  verifyResult
    . head
    . filter selectN3
    . selectTraceEventsDynamic @_ @(NTracer Int)
    $ runSimTrace $
      runLabelledLift
        . runRandom (mkStdGen i)
        $ createAll
