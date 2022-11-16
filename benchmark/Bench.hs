{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}

module Main where

import           Channel
import           Codec.Serialise
import           Control.Carrier.Random.Gen
import           Control.Concurrent.Class.MonadSTM
import           Control.DeepSeq
import           Control.Effect.Labelled hiding ( send )
import           Control.Monad
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Monad.IOSim            ( IOSim
                                                , runSimTrace
                                                , selectTraceEventsDynamic
                                                , traceM
                                                )
import           Control.Monad.Random           ( runRand )
import           Control.Tracer
import qualified Data.ByteString.Lazy          as LBS
import           Data.List                      ( delete
                                                , sort
                                                )
import           Data.Map                       ( Map )
import qualified Data.Map                      as Map
import           Data.Maybe                     ( fromJust )
import           Data.Time               hiding ( getCurrentTime )
import           GHC.Generics
import           GHC.Stack                      ( HasCallStack )
import           MockLogStore                   ( LogStore )
import qualified MockLogStore                  as M
import           Raft.Handler
import           Raft.Process
import           Raft.Type
import           Raft.Utils
import           System.Random                  ( mkStdGen )
import           System.Random.Shuffle          ( shuffleM )
import           Test.Tasty.Bench

data Persistent log m = Persistent
  { currentTermTVar :: TVar m Term
  , votedForTVar    :: TVar m (Maybe Id)
  , logStore        :: TVar m (LogStore (TermWarpper log))
  }

instance M.Def a => M.Def (TermWarpper a) where
  def = TermWarpper (-1) M.def

getPart :: ([Int], [Int]) -> [(Int, Int)]
getPart (xs, ys) = [ (x, y) | x <- xs, y <- ys ]

createPersistentFun
  :: (MonadSTM m, M.Def log, Show log, HasCallStack)
  => Persistent log m
  -> PersistentFun log m
createPersistentFun Persistent { currentTermTVar, votedForTVar, logStore } =
  PersistentFun
    { readCurrentTerm             = readTVarIO currentTermTVar
    , writeCurrentTermAndVotedFor = \a b -> atomically $ do
                                      writeTVar currentTermTVar a
                                      writeTVar votedForTVar    b
    , readVotedFor                = readTVarIO votedForTVar
    , appendLog                   = \tlog -> atomically $ do
                                      oldLS <- readTVar logStore
                                      writeTVar logStore (M.appendLog tlog oldLS)
                                      pure (M.currentIndex oldLS + 2)
    , removeLogs                  = \index -> atomically $ do
                                      oldLS <- readTVar logStore
                                      writeTVar logStore (M.removeLogs (index - 1) oldLS)
    , readLog                     = \index -> do
                                      oldLS <- readTVarIO logStore
                                      let [v] = M.readLogs (index - 1) (index - 1) oldLS
                                      pure $ if index == 0 then TermWarpper 0 undefined else v
    , readLogs                    = \startIndex endIndex -> do
                                      oldLS <- readTVarIO logStore
                                      let vs = M.readLogs (startIndex - 1) (endIndex - 1) oldLS
                                      pure vs
    , persisLastLogIndexAndTerm   = do
      oldLS <- readTVarIO logStore
      let index                = M.currentIndex oldLS
          [TermWarpper term _] = M.readLogs index index oldLS
      pure (index + 1, if index == (-1) then 0 else term)
    , getAllLogs                  = do
                                      oldLS <- readTVarIO logStore
                                      let index = M.currentIndex oldLS
                                      case index of
                                        -1 -> pure []
                                        _  -> pure $ M.readLogs 0 index oldLS
    , checkAppendentries          = \index term -> do
                                      if index == 0 && term == 0
                                        then pure True
                                        else do
                                          oldLS <- readTVarIO logStore
                                          case
                                              M.readLogs (index - 1) (index - 1) oldLS
                                            of
                                              [] -> pure False
                                              [TermWarpper pterm _] ->
                                                pure (term == pterm)
                                              _ -> error "undefined behave"
    , checkEntry                  = \index term -> do
                                      oldLS <- readTVarIO logStore
                                      let currentIndex = M.currentIndex oldLS
                                      if (index - 1) > currentIndex
                                        then pure Null
                                        else do
                                          let [TermWarpper pterm _] =
                                                M.readLogs (index - 1) (index - 1) oldLS
                                          if pterm == term then pure Exis else pure Diff
    }

data IdWrapper a = IdWrapper Id a
  deriving (Eq, Generic, NFData)

instance Show a => Show (IdWrapper a) where
  show (IdWrapper nid a) = show nid ++ ": " ++ show a

ft' :: [(Int, Int)] -> [Int] -> [(Int, Int)]
ft' rs []       = rs
ft' rs (a : xs) = ft' (rs ++ [ (a, b) | b <- xs ]) xs

ft :: [Int] -> [(Int, Int)]
ft = ft' []

selectN3 :: NTracer s -> Bool
selectN3 (N3 _) = True
selectN3 _      = False

ntId :: NTracer a -> Int -> Bool
ntId (N2 (IdWrapper i _)) j = i == j
ntId (N3 _              ) _ = True
ntId (N4 _              ) _ = True
ntId _                    _ = False

data NetworkChange = NetworkChange UTCTime
                                   ([Int], [Int])
                                   DiffTime
                                   [(NodeId, Term, Index, [TermWarpper Int])]
  deriving (Eq, Generic, NFData)

data NTracer a
  = N1 (IdWrapper (IdWrapper (RecvTracer a)))
  | N2 (IdWrapper (HandleTracer a))
  | N3 [(NodeId, Index, Index, [TermWarpper Int])]
  | N4 NetworkChange
  deriving (Eq, Generic, NFData)

instance Show NetworkChange where
  show (NetworkChange ct (a, b) dt c) =
    "\n"
      ++ unlines (map show c)
      ++ "\n---"
      ++ s'
      ++ " NECONFIG_CHNAGE "
      ++ show (a, b)
      ++ " "
      ++ show dt
   where
    s   = formatTime defaultTimeLocale "%S%Q" ct
    len = length s
    s'  = if len < 7 then s ++ replicate (7 - len) ' ' else take 7 s

instance Show a => Show (NTracer a) where
  show (N1 (IdWrapper i1 (IdWrapper i2 rt))) =
    show i1 ++ " <- " ++ show i2 ++ ": " ++ show rt
  show (N2 (IdWrapper i1 ht)) = show i1 ++ ": " ++ show ht
  show (N3 rs               ) = concatMap
    (\(nid, commitIndex, lastApplied, logStore) ->
      concat
          [ show nid
          , ", "
          , show commitIndex
          , ","
          , show lastApplied
          , ","
          , show logStore
          ]
        ++ "\n"
    )
    rs
  show (N4 v) = show v

createFollower
  :: (Has Random sig m, HasLabelledLift (IOSim s) sig m)
  => TQueue (IOSim s) Int
  -> NodeId
  -> [(PeerNodeId, Channel (IOSim s) LBS.ByteString)]
  -> m (HEnv Int (IOSim s))
createFollower userLogQueue nodeId peerChannels = do
  a <- lift $ newTVarIO 0
  b <- lift $ newTVarIO Nothing
  c <- lift $ newTVarIO M.emptyLogStore
  let pf            = createPersistentFun $ Persistent a b c
      elecTimeRange = (0.2, 0.4)
  newElectSize    <- randomRDiffTime elecTimeRange
  newElectTimeout <- lift $ newTimeout newElectSize

  ctv             <- lift $ newTVarIO 0
  latv            <- lift $ newTVarIO 0
  _ <- lift $ forkIO $ aProcess (readLogs pf) ctv latv 0 (\i k -> pure (i + k, i + k))

  let tEncode = convertCborEncoder (encode @(Msg Int))
  tDecode        <- lift $ convertCborDecoder (decode @(Msg Int))
  peersRecvQueue <- lift newTQueueIO
  peerInfoMaps   <- forM peerChannels $ \(peerNodeId, channel1) -> do
    void . lift . forkIO $ rProcess
      (Tracer
        (traceM . N1 . IdWrapper (unNodeId nodeId) . IdWrapper
          (unPeerNodeId peerNodeId)
        )
      )
      peerNodeId
      peersRecvQueue
      channel1
      tDecode
    pure (peerNodeId, PeerInfo (send channel1 . tEncode))
  let env = HEnv { nodeId                        = nodeId
                 , userLogQueue
                 , peersRecvQueue
                 , persistentFun                 = pf
                 , peerInfos                     = Map.fromList peerInfoMaps
                 , electionTimeRange             = elecTimeRange
                 , appendEntriesRpcRetryWaitTime = 1
                 , heartbeatWaitTime             = 0.1
                 , commitIndexTVar               = ctv
                 , lastAppliedTVar               = latv
                 , tracer = Tracer (traceM . N2 . IdWrapper (unNodeId nodeId))
                 }
      state = HState newElectSize newElectTimeout
  ri <- uniform
  void $ lift $ forkIO $ void $ runFollow state env (mkStdGen ri)
  pure env

networkPartition
  :: (HasLabelledLift (IOSim s) sig m, Has Random sig m)
  => [Int]
  -> [HEnv Int (IOSim s)]
  -> Map
       (Int, Int)
       ( Channel (IOSim s) LBS.ByteString
       , TVar (IOSim s) ConnectedState
       )
  -> m ()
networkPartition nodeIds nsls ccm = forever $ do
  ri <- uniform @Int
  let ls = fst $ runRand (shuffleM nodeIds) (mkStdGen ri)
  i  <- uniformR (1 :: Int, length nodeIds `div` 2)
  ta <- randomRDiffTime (2, 4)
  let (va, vb) = splitAt i ls
      newLs    = getPart (va, vb)
  kls <-
    forM nsls
      $ \HEnv { nodeId, commitIndexTVar, persistentFun = PersistentFun { getAllLogs, readCurrentTerm } } ->
          lift $ do
            commitIndex <- readTVarIO commitIndexTVar
            atls        <- getAllLogs
            term        <- readCurrentTerm
            pure (nodeId, term, commitIndex, atls)
  t <- lift getCurrentTime
  lift
    $ traceWith (Tracer (traceM . N4 @Int)) (NetworkChange t (va, vb) ta kls)

  forM_ newLs $ \(a, b) -> lift $ atomically $ do
    let tv10 = snd $ fromJust $ Map.lookup (a, b) ccm
    writeTVar tv10 Disconnectd

  lift $ threadDelay ta

  forM_ newLs $ \(a, b) -> lift $ atomically $ do
    let tv10 = snd $ fromJust $ Map.lookup (a, b) ccm
    writeTVar tv10 Connected

createAll :: (Has Random sig m, HasLabelledLift (IOSim s) sig m) => m ()
createAll = do
  nds <- (* 2) <$> uniformR (1, 10)
  let nodeIds = [0 .. nds]
  ccs <- forM (ft nodeIds) $ \(na, nb) -> do
    dt            <- randomRDiffTime (0.01, 0.03)
    connStateTVar <- lift $ newTVarIO Connected
    (ca, cb)      <-
      lift $ createConnectedBufferedChannelsWithDelay @_ @LBS.ByteString
        connStateTVar
        dt
        100
    pure [((na, nb), (ca, connStateTVar)), ((nb, na), (cb, connStateTVar))]
  let ccm = Map.fromList $ concat ccs
  userLogQueue <- lift newTQueueIO
  _            <- lift $ forkIO $ do
    forM_ [1 ..] $ \i -> do
      atomically $ writeTQueue userLogQueue i
      threadDelay 0.5
  nsls <- forM nodeIds $ \nodeId -> do
    let ncs = map
          (\i -> (PeerNodeId i, fst $ fromJust $ Map.lookup (nodeId, i) ccm))
          (delete nodeId nodeIds)
    createFollower userLogQueue (NodeId nodeId) ncs

  ri <- uniform
  _  <-
    lift
    . forkIO
    . void
    . runLabelledLift
    . runRandom (mkStdGen ri)
    $ networkPartition nodeIds nsls ccm
  dt <- randomRDiffTime (10, 30)
  lift $ threadDelay dt

  kls <-
    forM nsls
      $ \HEnv { nodeId, commitIndexTVar, lastAppliedTVar, persistentFun } ->
          lift $ do
            commitIndex <- readTVarIO commitIndexTVar
            lastApplied <- readTVarIO lastAppliedTVar
            atls        <- getAllLogs persistentFun
            pure (nodeId, commitIndex, lastApplied, atls)
  lift $ traceWith (Tracer (traceM . N3 @Int)) kls

verifyResult :: NTracer a -> Bool
verifyResult (N3 xs) =
  let bs   = map (\(_, b, _, _) -> b) xs
      minB = reverse (sort bs) !! (length bs `div` 2)
      ds   = concatMap (\(_, b, _, d) -> [ take minB d | b >= minB ]) xs
  in  all (== head ds) ds
verifyResult _ = False

runCreateAll :: Int -> Bool
runCreateAll i =
  verifyResult
    . head
    . filter selectN3
    . selectTraceEventsDynamic @_ @(NTracer Int)
    $ runSimTrace
    $ runLabelledLift
    . runRandom (mkStdGen i)
    $ createAll

main :: IO ()
main = defaultMain [bench "raft" $ nf runCreateAll 1000]
