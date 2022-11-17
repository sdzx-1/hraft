{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module ServerTest where

import Channel
import Codec.Serialise
import Control.Carrier.Random.Gen
import Control.Carrier.Reader
import Control.Carrier.State.Strict
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled hiding (send)
import qualified Control.Effect.Reader.Labelled as L
import qualified Control.Effect.State.Labelled as L
import Control.Monad
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (
  IOSim,
  runSimTrace,
  selectTraceEventsDynamic,
  selectTraceEventsSay,
  traceM,
 )
import Control.Tracer
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Lazy as LBS
import Data.List (
  delete,
  nub,
 )
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Data.Time (
  diffTimeToPicoseconds,
  picosecondsToDiffTime,
 )
import Deque.Strict (Deque)
import GHC.Exts (fromList)
import Network.TypedProtocol.Core (evalPeer, runPeer)
import Raft.Handler
import Raft.Process
import Raft.Type
import Raft.Utils
import qualified Server.OperateReq.Client as Mini
import qualified Server.OperateReq.Server as Mini
import Server.OperateReq.Type
import System.Random (mkStdGen)
import Test.QuickCheck
import Utils

data Env = Env
  { nodeIds :: [NodeId]
  , netDelayRange :: (DiffTime, DiffTime)
  , electionTimeRange :: (DiffTime, DiffTime)
  , heartbeatWaitTime :: DiffTime
  , appendEntriesRpcRetryWaitTime :: DiffTime
  , netPartitiongDurationRange :: (DiffTime, DiffTime)
  , nodeFaultsDurationRange :: (DiffTime, DiffTime)
  , faultsSeq :: [Faults]
  , randomI :: Int
  }
  deriving (Show)

data Faults
  = NetworkFaults (DiffTime, ([NodeId], [NodeId]), [(NodeId, NodeId)])
  | NodeFaults [NodeId] DiffTime

instance Show Faults where
  show (NetworkFaults ls) = "\n" ++ show ls
  show (NodeFaults a b) = "\n " ++ show a ++ " " ++ show b

chooseDiffTime :: (DiffTime, DiffTime) -> Gen DiffTime
chooseDiffTime (el, et) = picosecondsToDiffTime <$> choose r
  where
    r = (diffTimeToPicoseconds el, diffTimeToPicoseconds et)

instance Arbitrary Env where
  arbitrary = do
    nodeNums <- (\n -> n * 2 + 1) <$> choose (1 :: Int, 5)
    let nodeIds = [NodeId i | i <- [0 .. nodeNums - 1]]
        netDelayRange = (0.02, 0.04)
        electionTimeRange = (0.2, 0.4)
        heartbeatWaitTime = 0.1
        appendEntriesRpcRetryWaitTime = 1
        netPartitiongDurationRange = (2, 3)
        nodeFaultsDurationRange = (3, 5)
    randomI <- chooseAny
    ---
    seqLen <- choose (0 :: Int, 10)
    faultsSeq <- replicateM seqLen $ do
      ls <- shuffle nodeIds
      i <- choose (1 :: Int, length nodeIds `div` 2)
      let (va, vb) = splitAt i ls
      b <- choose (True, False)
      if b
        then do
          dt <- chooseDiffTime netPartitiongDurationRange
          pure $ NodeFaults va dt
        else do
          let newLs = getPart (va, vb)
          dt <- chooseDiffTime netPartitiongDurationRange
          pure $ NetworkFaults (dt, (va, vb), newLs)
    pure
      ( Env
          { nodeIds
          , netDelayRange
          , electionTimeRange
          , heartbeatWaitTime
          , appendEntriesRpcRetryWaitTime
          , netPartitiongDurationRange
          , nodeFaultsDurationRange
          , faultsSeq
          , randomI
          }
      )

  shrink env@Env{faultsSeq} =
    map
      (\s -> env{faultsSeq = s})
      (snps faultsSeq)
    where
      snps [] = []
      snps [_] = []
      snps nps = [take i nps | let len = length nps, i <- [len - 1 .. 1]]

data BaseState

data NodeInfo s = NodeInfo
  { persistent :: Persistent Int (IOSim s)
  , role :: TVar (IOSim s) Role
  , userLogQueue :: TQueue (IOSim s) (Int, TMVar (IOSim s) (ApplyResult Int))
  , commitIndexTVar :: CommitIndexTVar (IOSim s)
  , leaderAcceptReqList :: TVar (IOSim s) (Deque (Index, TMVar (IOSim s) (ApplyResult Int)))
  , needReplyOutputMap :: TVar (IOSim s) (Map Index (TMVar (IOSim s) (ApplyResult Int)))
  , lastAppliedTVar :: LastAppliedTVar (IOSim s)
  , peerChannels
      :: [ ( PeerNodeId
           , Channel (IOSim s) LBS.ByteString
           , TVar (IOSim s) ConnectedState
           )
         ]
  }

data NodeInfoMap

tClient
  :: forall s sig m
   . ( HasLabelledLift (IOSim s) sig m
     , Has Random sig m
     , Has (State NodeId) sig m
     , HasLabelled NodeInfoMap (Reader (Map NodeId (NodeInfo s))) sig m
     )
  => m ()
tClient = do
  let startServer nodeId = do
        nodeInfoMap <- L.ask @NodeInfoMap
        let NodeInfo{role, userLogQueue} = fromJust $ Map.lookup nodeId nodeInfoMap
        connStateTVar <- lift $ newTVarIO Connected
        (serverChannel, clientChannel) <-
          lift $
            createConnectedBufferedChannelsWithDelay @_ @LBS.ByteString
              connStateTVar
              0.01
              100
        -- start server
        _ <-
          lift
            . forkIO
            . void
            . runLabelledLift
            . runReader (Mini.ServerEnv role userLogQueue)
            . runLabelled @Mini.ServerEnv
            $ runPeer serverChannel 3
            $ evalPeer Mini.server
        pure clientChannel

  let go i = do
        nodeId <- get
        clchannel <- startServer nodeId
        (_, res) <-
          lift
            . runLabelledLift
            . runPeer clchannel 3
            . evalPeer
            $ Mini.client i
        case res of
          Left e -> do
            lift $ say $ "error happend: , " ++ show e ++ " retry"
            lift $ threadDelay 0.2
            go i
          Right Nothing -> do
            lift $ say "finish"
            pure ()
          Right (Just Nothing) -> do
            lift $ say "selecting leader "
            lift $ threadDelay 0.2
            go i
          Right (Just (Just id')) -> do
            lift $ say $ "connect to new leader " ++ show id'
            put (NodeId id')
            go i

  -- start client
  forM_ [1 .. 20] $ \i -> do
    go i
    lift $ threadDelay 0.1

data BaseEnv s = BaseEnv
  { connectMap
      :: Map
          (NodeId, NodeId)
          (Channel (IOSim s) LBS.ByteString, TVar (IOSim s) ConnectedState)
  , nodeInfos :: Map NodeId (NodeInfo s)
  , electionTimeRange :: (DiffTime, DiffTime)
  , appendEntriesRpcRetryWaitTime :: DiffTime
  , heartbeatWaitTime :: DiffTime
  }

killNode
  :: ( Has Random sig m
     , HasLabelledLift (IOSim s) sig m
     , HasLabelled BaseEnv (Reader (BaseEnv s)) sig m
     , HasLabelled BaseState (State (Map NodeId [ThreadId (IOSim s)])) sig m
     )
  => NodeId
  -> m ()
killNode nodeId = do
  thid <- fmap (fromJust . Map.lookup nodeId) $ L.get @BaseState
  NodeInfo{commitIndexTVar, lastAppliedTVar, peerChannels} <-
    fmap (fromJust . Map.lookup nodeId . nodeInfos) $ L.ask @BaseEnv
  lift $
    atomically $
      forM_ peerChannels $ \(_, _, tv) ->
        writeTVar tv Disconnectd
  lift $
    atomically $ do
      writeTVar commitIndexTVar 0
      writeTVar lastAppliedTVar 0
  mapM_ (lift . killThread) thid

restartFollower
  :: ( Has Random sig m
     , HasLabelledLift (IOSim s) sig m
     , HasLabelled BaseEnv (Reader (BaseEnv s)) sig m
     , HasLabelled BaseState (State (Map NodeId [ThreadId (IOSim s)])) sig m
     )
  => NodeId
  -> m ()
restartFollower nodeId = do
  pcs <-
    fmap (peerChannels . fromJust . Map.lookup nodeId . nodeInfos) $
      L.ask @BaseEnv
  lift $ atomically $ forM_ pcs $ \(_, _, tv) -> writeTVar tv Connected
  createFollower nodeId

createFollower
  :: ( Has Random sig m
     , HasLabelledLift (IOSim s) sig m
     , HasLabelled BaseEnv (Reader (BaseEnv s)) sig m
     , HasLabelled BaseState (State (Map NodeId [ThreadId (IOSim s)])) sig m
     )
  => NodeId
  -> m ()
createFollower nodeId = do
  BaseEnv
    { nodeInfos
    , electionTimeRange
    , appendEntriesRpcRetryWaitTime
    , heartbeatWaitTime
    } <-
    L.ask @BaseEnv
  let NodeInfo
        { persistent
        , commitIndexTVar
        , role
        , userLogQueue
        , leaderAcceptReqList
        , needReplyOutputMap
        , lastAppliedTVar
        , peerChannels
        } =
          fromJust $ Map.lookup nodeId nodeInfos
  let pf = createPersistentFun persistent
  newElectSize <- randomRDiffTime electionTimeRange
  newElectTimeout <- lift $ newTimeout newElectSize

  lift $
    atomically $ do
      writeTVar commitIndexTVar 0
      writeTVar lastAppliedTVar 0

  thid1 <-
    lift $
      forkIO $
        aProcess
          (readLogs pf)
          commitIndexTVar
          needReplyOutputMap
          lastAppliedTVar
          0
          (\i k -> pure (i + k, i + k))

  let tEncode = convertCborEncoder (encode @(Msg Int))
  tDecode <- lift $ convertCborDecoder (decode @(Msg Int))
  peersRecvQueue <- lift newTQueueIO
  peerInfoMaps' <- forM peerChannels $ \(peerNodeId, channel1, _) -> do
    thid2 <-
      lift . forkIO $
        rProcess
          ( Tracer
              ( traceM
                  . N1
                  . IdWrapper (unNodeId nodeId)
                  . IdWrapper
                    (unPeerNodeId peerNodeId)
              )
          )
          peerNodeId
          peersRecvQueue
          channel1
          tDecode
    pure (thid2, (peerNodeId, PeerInfo (send channel1 . tEncode)))
  let (thids, peerInfoMaps) = unzip peerInfoMaps'
      env =
        HEnv
          { nodeId = nodeId
          , role
          , userLogQueue
          , leaderAcceptReqList
          , needReplyOutputMap
          , peersRecvQueue
          , persistentFun = pf
          , peerInfos = Map.fromList peerInfoMaps
          , electionTimeRange
          , appendEntriesRpcRetryWaitTime
          , heartbeatWaitTime
          , commitIndexTVar = commitIndexTVar
          , lastAppliedTVar = lastAppliedTVar
          , tracer = Tracer (traceM . N2 . IdWrapper (unNodeId nodeId))
          }
      state' = HState newElectSize newElectTimeout
  randomI <- uniform
  thid <- lift $ forkIO $ void $ runFollower state' env (mkStdGen randomI)
  L.modify @BaseState (Map.insert nodeId (thid1 : thid : thids))

createAll :: (HasLabelledLift (IOSim s) sig m, Has Random sig m) => Env -> m ()
createAll
  Env
    { nodeIds
    , netDelayRange
    , electionTimeRange
    , heartbeatWaitTime
    , appendEntriesRpcRetryWaitTime
    , faultsSeq
    } =
    do
      connectMap <-
        fmap (Map.fromList . concat) $
          forM (ft nodeIds) $ \(na, nb) -> do
            dt <- randomRDiffTime netDelayRange
            connStateTVar <- lift $ newTVarIO Connected
            (ca, cb) <-
              lift $
                createConnectedBufferedChannelsWithDelay @_ @LBS.ByteString
                  connStateTVar
                  dt
                  100
            pure [((na, nb), (ca, connStateTVar)), ((nb, na), (cb, connStateTVar))]
      nodeInfos <- fmap Map.fromList . forM nodeIds $ \nodeId -> do
        let peerChannels =
              map
                ( \(NodeId i) ->
                    let (a, b) = fromJust $ Map.lookup (nodeId, NodeId i) connectMap
                     in (PeerNodeId i, a, b)
                )
                (delete nodeId nodeIds)
        persistent <- lift initPersisten
        commitIndexTVar <- lift $ newTVarIO 0
        lastAppliedTVar <- lift $ newTVarIO 0
        leaderAcceptReqList <- lift $ newTVarIO (fromList [])
        needReplyOutputMap <- lift $ newTVarIO Map.empty
        role <- lift $ newTVarIO (Follower Nothing)
        userLogQueue <- lift newTQueueIO
        pure
          ( nodeId
          , NodeInfo
              { persistent
              , commitIndexTVar
              , leaderAcceptReqList
              , needReplyOutputMap
              , lastAppliedTVar
              , peerChannels
              , role
              , userLogQueue
              }
          )
      let baseEnv =
            BaseEnv
              { connectMap
              , nodeInfos
              , electionTimeRange
              , appendEntriesRpcRetryWaitTime
              , heartbeatWaitTime
              }

      ---------------------------------
      randomI' <- uniform
      _ <-
        lift
          . forkIO
          . void
          . runLabelledLift
          . runRandom (mkStdGen randomI')
          . runReader nodeInfos
          . runLabelled @NodeInfoMap
          . runState (NodeId 0)
          $ do
            tClient
      ---------------------------------
      randomI'' <- uniform
      _ <-
        lift
          . forkIO
          . void
          . runLabelledLift
          . runRandom (mkStdGen randomI'')
          . runState @Index 0
          . forever
          $ do
            lastMaxCommitIndex <- get @Int

            let allCommitIndexTVar =
                  map (\NodeInfo{commitIndexTVar} -> commitIndexTVar) $
                    Map.elems nodeInfos
                checkMaxCommitChange = do
                  allVals <- mapM readTVar allCommitIndexTVar
                  let mv = maximum allVals
                  if mv > lastMaxCommitIndex then pure mv else retry

            newMaxCommitIndex <- lift $ atomically checkMaxCommitChange
            put newMaxCommitIndex

            n3 <-
              forM (Map.toList nodeInfos) $
                \(nodeId, NodeInfo{persistent, commitIndexTVar, lastAppliedTVar}) ->
                  do
                    let PersistentFun{getAllLogs} =
                          createPersistentFun persistent
                    commitIndex <- lift $ readTVarIO commitIndexTVar
                    lastApplied <- lift $ readTVarIO lastAppliedTVar
                    allLogs <- lift getAllLogs
                    pure (nodeId, commitIndex, lastApplied, allLogs)
            lift $ traceWith (Tracer (traceM . N3 @Int)) n3

      ---------------------------------
      randomI <- uniform
      lift
        . void
        . runLabelledLift
        . runRandom (mkStdGen randomI)
        . runReader baseEnv
        . runLabelled @BaseEnv
        . runState Map.empty
        . runLabelled @BaseState
        $ do
          forM_ nodeIds $ \nodeId -> do
            createFollower nodeId

          forM_ faultsSeq $ \fault -> do
            case fault of
              NodeFaults nis dt -> do
                ct <- lift getCurrentTime
                lift $
                  traceWith
                    (Tracer (traceM . N5 @Int))
                    (NodeRestart ct nis dt)
                mapM_ killNode nis
                lift $ threadDelay dt
                mapM_ restartFollower nis
              NetworkFaults (dt, tb, nps) -> do
                n3 <-
                  forM (Map.toList nodeInfos) $
                    \(nodeId, NodeInfo{persistent, commitIndexTVar}) -> do
                      let PersistentFun{getAllLogs, readCurrentTerm} =
                            createPersistentFun persistent
                      commitIndex <- lift $ readTVarIO commitIndexTVar
                      allLogs <- lift getAllLogs
                      term <- lift readCurrentTerm
                      pure (nodeId, term, commitIndex, allLogs)
                ct <- lift getCurrentTime
                lift $
                  traceWith
                    (Tracer (traceM . N4 @Int))
                    ( NetworkChange
                        ct
                        (bimap (map unNodeId) (map unNodeId) tb)
                        dt
                        n3
                    )

                lift $ do
                  atomically $
                    forM_ nps $ \(a, b) -> do
                      let tv10 = snd $ fromJust $ Map.lookup (a, b) connectMap
                      writeTVar tv10 Disconnectd

                  threadDelay dt

                  atomically $
                    forM_ nps $ \(a, b) -> do
                      let tv10 = snd $ fromJust $ Map.lookup (a, b) connectMap
                      writeTVar tv10 Connected
          lift $ threadDelay 5

runCreateAll :: Env -> [NTracer Int]
runCreateAll env@Env{randomI} =
  selectTraceEventsDynamic @_ @(NTracer Int) $
    runSimTrace $
      runLabelledLift $
        runRandom (mkStdGen randomI) $
          createAll env

selectN :: NTracer Int -> Bool
selectN (N3 _) = True
selectN _ = False
selectN1 :: NTracer Int -> Bool
selectN1 (N3 _) = True
selectN1 (N4 _) = True
selectN1 (N5 _) = True
selectN1 (N1 _) = False
selectN1 (N2 (IdWrapper _ (TimeWrapper _ CandidateElectionSuccess{}))) = True
selectN1 _ = False

writeToFile :: [NTracer Int] -> IO ()
writeToFile v1 = do
  let cns = unlines . map show . filter selectN1 $ v1
  writeFile "log" cns

-- runCreate :: Env -> [NTracer Int]
runCreate :: Env -> [String]
runCreate env@Env{randomI} =
  selectTraceEventsSay $
    runSimTrace $
      runLabelledLift $
        runRandom (mkStdGen randomI) $
          createAll env

generateLogFile :: IO ()
generateLogFile = do
  env <- generate (arbitrary :: Gen Env)
  -- let cns = unlines . map show . filter selectN $ runCreateAll env -- [10010]
  let cns = unlines $ runCreate env
  print env
  writeFile "log" cns

--------------------
