{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module Handler where

import Channel
import Codec.Serialise
import Control.Carrier.Lift
import Control.Carrier.Random.Gen
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled hiding (send)
import Control.Monad
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (IOSim, runSimTrace, selectTraceEventsDynamic, traceM)
import Control.Tracer
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Lazy as LBS
import Data.List (delete, sort)
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Data.Time (diffTimeToPicoseconds, picosecondsToDiffTime)
import qualified MockLogStore as M
import Raft.Handler
import Raft.Process
import Raft.Type
import Raft.Utils
import System.Random (mkStdGen)
import Test.QuickCheck
import Utils

data Env = Env
  { nodeIds :: [NodeId],
    netDelayRange :: (DiffTime, DiffTime),
    simulationDuration :: DiffTime,
    electionTimeRange :: (DiffTime, DiffTime),
    heartbeatWaitTime :: DiffTime,
    appendEntriesRpcRetryWaitTime :: DiffTime,
    netPartitiongDurationRange :: (DiffTime, DiffTime),
    netPartitionSeq :: NetPartitionSeq,
    randomI :: Int
  }
  deriving (Show)

newtype NetPartitionSeq = NetPartitionSeq [(DiffTime, ([NodeId], [NodeId]), [(NodeId, NodeId)])]

instance Show NetPartitionSeq where
  show (NetPartitionSeq ls) = "\n" ++ unlines (map (\(a, b, _) -> show (a, b)) ls)

chooseDiffTime :: (DiffTime, DiffTime) -> Gen DiffTime
chooseDiffTime (el, et) = picosecondsToDiffTime <$> choose r
  where
    r =
      ( diffTimeToPicoseconds el,
        diffTimeToPicoseconds et
      )

instance Arbitrary Env where
  arbitrary = do
    nodeNums <- (\n -> n * 2 + 1) <$> choose (1 :: Int, 3)
    let nodeIds = [NodeId i | i <- [0 .. nodeNums -1]]
        netDelayRange = (0.02, 0.04)
        simulationDuration = 10
        electionTimeRange = (0.2, 0.4)
        heartbeatWaitTime = 0.1
        appendEntriesRpcRetryWaitTime = 1
        netPartitiongDurationRange = (2, 3)
    randomI <- chooseAny
    ---
    seqLen <- choose (0 :: Int, 10)
    netPartitionSeq <- fmap NetPartitionSeq $
      replicateM seqLen $ do
        ls <- shuffle nodeIds
        i <- choose (1 :: Int, length nodeIds `div` 2)
        let (va, vb) = splitAt i ls
            newLs = getPart (va, vb)
        dt <- chooseDiffTime netPartitiongDurationRange
        pure (dt, (va, vb), newLs)
    pure
      ( Env
          { nodeIds,
            netDelayRange,
            simulationDuration,
            electionTimeRange,
            heartbeatWaitTime,
            appendEntriesRpcRetryWaitTime,
            netPartitiongDurationRange,
            netPartitionSeq,
            randomI
          }
      )

  shrink
    env@Env
      { netPartitionSeq = NetPartitionSeq nps'
      } = map (\s -> env {netPartitionSeq = NetPartitionSeq s}) (snps nps')
      where
        snps [] = []
        snps [_] = []
        snps nps = [take i nps | let len = length nps, i <- [len -1 .. 1]]

createFollower ::
  ( Has Random sig m,
    HasLabelledLift (IOSim s) sig m
  ) =>
  Int ->
  (DiffTime, DiffTime) ->
  DiffTime ->
  DiffTime ->
  TQueue (IOSim s) Int ->
  NodeId ->
  [(PeerNodeId, Channel (IOSim s) LBS.ByteString)] ->
  m (HEnv Int (IOSim s))
createFollower
  randomI
  electionTimeRange
  appendEntriesRpcRetryWaitTime
  heartbeatWaitTime
  userLogQueue
  nodeId
  peerChannels =
    do
      a <- lift $ newTVarIO 0
      b <- lift $ newTVarIO Nothing
      c <- lift $ newTVarIO M.emptyLogStore
      let pf = createPersistentFun $ Persistent a b c
      newElectSize <- randomRDiffTime electionTimeRange
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
                electionTimeRange,
                appendEntriesRpcRetryWaitTime,
                heartbeatWaitTime,
                commitIndexTVar = ctv,
                lastAppliedTVar = latv,
                tracer = Tracer (traceM . N2 . IdWrapper (unNodeId nodeId))
              }
          state' = HState newElectSize newElectTimeout
      void $ lift $ forkIO $ void $ runFollow state' env (mkStdGen randomI)
      pure env

createAll :: (HasLabelledLift (IOSim s) sig m, Has Random sig m) => Env -> m ()
createAll
  Env
    { nodeIds,
      netDelayRange,
      simulationDuration,
      electionTimeRange,
      heartbeatWaitTime,
      appendEntriesRpcRetryWaitTime,
      netPartitionSeq = NetPartitionSeq nsq
    } = do
    ccs <- forM (ft nodeIds) $ \(na, nb) -> do
      -- create connected Channel
      dt <- randomRDiffTime netDelayRange
      connStateTVar <- lift $ newTVarIO Connected
      (ca, cb) <-
        lift $ createConnectedBufferedChannelsWithDelay @_ @LBS.ByteString connStateTVar dt 100

      pure
        [ ((na, nb), (ca, connStateTVar)),
          ((nb, na), (cb, connStateTVar))
        ]

    let ccm = Map.fromList $ concat ccs

    userLogQueue <- lift $ newTQueueIO @_ @Int

    randomI <- uniform

    -- client append log thread
    _ <- lift
      . forkIO
      . void
      . runLabelledLift
      . runRandom (mkStdGen randomI)
      $ do
        forM_ [1 ..] $ \i -> do
          lift $ atomically $ writeTQueue userLogQueue i
          dt <- randomRDiffTime (0.1, 0.5)
          lift $ threadDelay dt

    nsls <- forM nodeIds $ \nodeId -> do
      let ncs =
            map
              (\(NodeId i) -> (PeerNodeId i, fst $ fromJust $ Map.lookup (nodeId, NodeId i) ccm))
              (delete nodeId nodeIds)

      randomI' <- uniform

      -- create all follower
      createFollower
        randomI'
        electionTimeRange
        appendEntriesRpcRetryWaitTime
        heartbeatWaitTime
        userLogQueue
        nodeId
        ncs

    -- Cut off the network thread
    _ <- lift $
      forkIO
        . void
        . runLabelledLift
        $ do
          forM_ nsq $ \(ta, tb, newLs) -> do
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
            ct <- lift getCurrentTime
            lift $
              traceWith
                (Tracer (traceM . N4 @Int))
                ( NetworkChange
                    ct
                    (bimap (map unNodeId) (map unNodeId) tb)
                    ta
                    kls
                )

            lift $ do
              atomically $
                forM_ newLs $ \(a, b) -> do
                  let tv10 = snd $ fromJust $ Map.lookup (a, b) ccm
                  writeTVar tv10 Disconnectd

              threadDelay ta

              atomically $
                forM_ newLs $ \(a, b) -> do
                  let tv10 = snd $ fromJust $ Map.lookup (a, b) ccm
                  writeTVar tv10 Connected

    -- check store log consistency
    _ <- lift $
      forkIO
        . void
        . runLabelledLift
        . forever
        $ do
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
          lift $ threadDelay 0.3

    lift $ threadDelay simulationDuration

runCreateAll :: Env -> [NTracer Int]
runCreateAll env@Env {randomI} =
  selectTraceEventsDynamic @_ @(NTracer Int) $
    runSimTrace $
      runLabelledLift $
        runRandom (mkStdGen randomI) $
          createAll env

selectN3 :: NTracer s -> Bool
selectN3 (N3 _) = True
selectN3 _ = False

verifyStoreLog :: NTracer a -> Bool
verifyStoreLog (N3 xs) =
  let bs = map (\(_, b, _, _) -> b) xs
      minB = reverse (sort bs) !! (length bs `div` 2)
      ds = concatMap (\(_, b, _, d) -> [take minB d | b >= minB]) xs
   in all (== head ds) ds
verifyStoreLog _ = False

prop_store_log :: Env -> Bool
prop_store_log = all verifyStoreLog . filter selectN3 . runCreateAll

seletElectionSuccess :: NTracer s -> [HandleTracer' s]
seletElectionSuccess (N2 (IdWrapper _ (TimeWrapper _ h@(CandidateElectionSuccess _ _)))) = [h]
seletElectionSuccess _ = []

prop_election_success :: Env -> Bool
prop_election_success env = prop res
  where
    res = concatMap seletElectionSuccess $ runCreateAll env
    prop [CandidateElectionSuccess _ t] = t > 0
    prop (CandidateElectionSuccess _ t : xs@(CandidateElectionSuccess _ t1 : _)) = t < t1 && prop xs

selectN :: NTracer s -> Bool
-- selectN (N3 _) = True
selectN (N4 _) = True
selectN (N2 (IdWrapper _ (TimeWrapper _ h@(CandidateElectionSuccess _ _)))) = True
selectN _ = False

generateLogFile :: IO ()
generateLogFile = do
  env <- generate (arbitrary :: Gen Env)
  let res = unlines $ map show $ filter selectN $ runCreateAll env
  writeFile "log" res

seletE :: NTracer s -> [(NodeId, Index, Index, [TermWarpper Int])]
seletE (N3 v) = v
seletE _ = []

prop_commit_log_never_change :: Env -> Bool
prop_commit_log_never_change env@Env {nodeIds} = all (cs . fun res) nodeIds
  where
    res = concatMap seletE $ runCreateAll env

    fun :: [(NodeId, Index, Index, [TermWarpper Int])] -> NodeId -> [[TermWarpper Int]]
    fun xs nodeId =
      map (\(_, i, _, d) -> take i d) $
        filter (\(a, _, _, _) -> a == nodeId) xs

    compareLog :: [TermWarpper Int] -> [TermWarpper Int] -> Bool
    compareLog [] _ = True
    compareLog (x : xs) (y : ys) = (x == y) && compareLog xs ys

    cs :: [[TermWarpper Int]] -> Bool
    cs xs = and $ zipWith compareLog xs (tail xs)
