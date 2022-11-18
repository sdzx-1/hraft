{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}

module FaultsTest where

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
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (
  IOSim,
  runSimTrace,
  selectTraceEventsDynamic,
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
import Raft.Handler
import Raft.Process
import Raft.Type
import Raft.Utils
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

data BaseEnv s = BaseEnv
  { connectMap
      :: Map
          (NodeId, NodeId)
          (Channel (IOSim s) LBS.ByteString, TVar (IOSim s) ConnectedState)
  , userLogQueue :: TQueue (IOSim s) (Int, TMVar (IOSim s) (ApplyResult Int))
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
    , userLogQueue
    , electionTimeRange
    , appendEntriesRpcRetryWaitTime
    , heartbeatWaitTime
    } <-
    L.ask @BaseEnv
  let NodeInfo
        { persistent
        , commitIndexTVar
        , role
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
      userLogQueue <- lift newTQueueIO
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
              }
          )
      let baseEnv =
            BaseEnv
              { connectMap
              , userLogQueue
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
          $ do
            forM_ [1 ..] $ \i -> do
              tmvar <- lift newEmptyTMVarIO
              lift $ atomically $ writeTQueue userLogQueue (i, tmvar)
              dt <- randomRDiffTime (0.1, 0.5)
              lift $ threadDelay dt
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
                ct <- lift getMonotonicTime
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

verifyStoreLog :: [NodeId] -> NTracer a -> Bool
verifyStoreLog nodeIds (N3 xs) =
  let bs = map (\(_, b, _, _) -> b) xs
      maxCommit = maximum bs
      (_, _, _, tmpLogs) = head $ filter (\(_, b, _, _) -> b == maxCommit) xs
      allLogs = map (\(_, _, _, l) -> take maxCommit l) xs
      res = filter (== take maxCommit tmpLogs) allLogs
   in length res > (length nodeIds `div` 2)
verifyStoreLog _ _ = False

-- commit log must replicate more than half of the servers
prop_commit_log_replicate :: Env -> Bool
prop_commit_log_replicate env@Env{nodeIds} =
  all (verifyStoreLog nodeIds) . filter selectN $ runCreateAll env

seletElectionSuccess :: NTracer s -> [HandleTracer' s]
seletElectionSuccess (N2 (IdWrapper _ (TimeWrapper _ h@(CandidateElectionSuccess _ _)))) =
  [h]
seletElectionSuccess _ = []

-- election term doesn't come up more than once
prop_election_success_term :: Env -> Bool
prop_election_success_term env = length terms == length (nub terms)
  where
    res = concatMap seletElectionSuccess $ runCreateAll env
    terms = map (\(CandidateElectionSuccess _ t) -> t) res

getCommitLog :: NTracer a -> [TermWarpper Int]
getCommitLog (N3 xs) =
  let bs = map (\(_, b, _, _) -> b) xs
      maxCommit = maximum bs
      (_, _, _, tmpLogs) = head $ filter (\(_, b, _, _) -> b == maxCommit) xs
   in take maxCommit tmpLogs
getCommitLog _ = error "undefined behave"

-- commit log never chage
prop_commit_log_never_change :: Env -> Bool
prop_commit_log_never_change env =
  let res = map getCommitLog $ filter selectN $ runCreateAll env
      compareLog :: [TermWarpper Int] -> [TermWarpper Int] -> Bool
      compareLog [] _ = True
      compareLog (x : xs) (y : ys) = (x == y) && compareLog xs ys
   in and $ zipWith compareLog res (tail res)

--------------------
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

generateLogFile :: IO ()
generateLogFile = do
  env <- generate (arbitrary :: Gen Env)
  let cns = unlines . map show . filter selectN $ runCreateAll env -- [10010]
  writeFile "log" cns

--------------------
