{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Raft.Handler where

import Control.Algebra
import Control.Applicative ((<|>))
import Control.Arrow (second)
import Control.Carrier.Lift (runM)
import Control.Carrier.Random.Gen
import Control.Carrier.Reader
import Control.Carrier.State.Strict
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled
import qualified Control.Effect.Reader.Labelled as R
import qualified Control.Effect.State.Labelled as S
import Control.Monad
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.Random (StdGen, mkStdGen)
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Set as Set
import Raft.Process (cProcess)
import Raft.Type
import Raft.Utils

runFollow ::
  forall s n.
  ( Monad n,
    MonadTime n,
    MonadTimer n,
    MonadFork n
  ) =>
  HState s n ->
  HEnv s n ->
  StdGen ->
  n (HState s n, (StdGen, ()))
runFollow s e g =
  runLabelledLift
    . runState @(HState s n) s
    . runLabelled @HState
    . runReader @(HEnv s n) e
    . runLabelled @HEnv
    . runRandom g
    $ follower

follower ::
  ( HasLabelled HEnv (Reader (HEnv s n)) sig m,
    HasLabelled HState (State (HState s n)) sig m,
    Has Random sig m,
    HasLabelledLift n sig m,
    MonadTime n,
    MonadTimer n,
    MonadSTM n,
    MonadFork n
  ) =>
  m ()
follower = do
  HEnv
    { persistentFun =
        PersistentFun
          { readCurrentTerm,
            writeCurrentTermAndVotedFor
          },
      peersRecvQueue
    } <-
    R.ask @HEnv
  HState {electionTimeout} <- S.get @HState
  val <-
    sendM $ atomically $ (Left <$> waitTimeout electionTimeout) <|> (Right <$> readTQueue peersRecvQueue)
  case val of
    Left () -> do
      timeTracerWith FollowerTimeoutToCandidate
      candidate
    Right (peerNodeId, msg) -> do
      timeTracerWith (FollowerRecvMsg (peerNodeId, msg))
      send' <- getPeerSendFun peerNodeId
      currentTerm <- sendM readCurrentTerm
      case msg of
        MsgAppendEntries ranNum appEnt@AppendEntries {term} -> do
          case compare term currentTerm of
            LT -> send' (MsgAppendEntriesResult ranNum (AppendEntriesResult currentTerm False))
            EQ -> do
              updateTimeout'
              appendAction ranNum peerNodeId appEnt
            GT -> do
              updateTimeout'
              sendM $ writeCurrentTermAndVotedFor term Nothing
              appendAction ranNum peerNodeId appEnt
          follower
        MsgRequestVote reqVote@RequestVote {term} -> do
          case compare term currentTerm of
            LT -> send' (MsgRequestVoteResult (RequestVoteResult currentTerm False))
            EQ -> voteAction peerNodeId reqVote
            GT -> do
              sendM $ writeCurrentTermAndVotedFor term Nothing
              voteAction peerNodeId reqVote
          follower
        MsgAppendEntriesResult _ _ -> follower
        MsgRequestVoteResult _ -> follower

candidate ::
  ( HasLabelled HEnv (Reader (HEnv s n)) sig m,
    HasLabelled HState (State (HState s n)) sig m,
    HasLabelledLift n sig m,
    Has Random sig m,
    MonadTime n,
    MonadTimer n,
    MonadSTM n,
    MonadFork n
  ) =>
  m ()
candidate = do
  HEnv
    { persistentFun =
        PersistentFun
          { readCurrentTerm,
            writeCurrentTermAndVotedFor,
            persisLastLogIndexAndTerm
          },
      nodeId,
      peerInfos,
      electionTimeRange
    } <-
    R.ask @HEnv
  oldTerm <- sendM readCurrentTerm
  sendM $ writeCurrentTermAndVotedFor (oldTerm + 1) (Just $ unNodeId nodeId)
  timeTracerWith (CandidateNewElectionStart (oldTerm + 1))
  timeTracerWith (VotedForNode (unNodeId nodeId) (oldTerm + 1))
  randomElectionSize <- randomRDiffTime electionTimeRange
  newTimeo <- sendM $ newTimeout randomElectionSize
  S.put @HState (HState {electionSize = randomElectionSize, electionTimeout = newTimeo})
  timeTracerWith (CandidateSetNewElectionSzie randomElectionSize)
  allSend <- mapM getPeerSendFun (Map.keys peerInfos)
  currentTerm <- sendM readCurrentTerm
  (persisLastLogIndexVal, persisLastLogTermVal) <- sendM persisLastLogIndexAndTerm
  timeTracerWith (CandidateSendVotoForMsgToAll (Map.keys peerInfos))
  forM_ allSend $ \send' -> do
    send'
      ( MsgRequestVote
          ( RequestVote
              currentTerm
              (unNodeId nodeId)
              persisLastLogIndexVal
              persisLastLogTermVal
          )
      )
  go Set.empty Set.empty
  where
    go voteTrueSet voteFalseSet = do
      HState {electionTimeout} <- S.get @HState
      HEnv
        { persistentFun =
            PersistentFun
              { readCurrentTerm,
                writeCurrentTermAndVotedFor
              },
          peersRecvQueue,
          peerInfos
        } <-
        R.ask @HEnv
      val <- sendM $ atomically $ (Left <$> waitTimeout electionTimeout) <|> (Right <$> readTQueue peersRecvQueue)
      case val of
        Left () -> do
          timeTracerWith CandidateElectionTimeout
          candidate
        Right (peerNodeId, msg) -> do
          timeTracerWith (CandidateRecvMsg (peerNodeId, msg))
          currentTerm <- sendM readCurrentTerm
          send' <- getPeerSendFun peerNodeId
          case msg of
            MsgAppendEntries ranNum appEnt@AppendEntries {term} -> do
              case compare term currentTerm of
                LT -> do
                  send' (MsgAppendEntriesResult ranNum (AppendEntriesResult currentTerm False))
                  go voteTrueSet voteFalseSet
                EQ -> do
                  appendAction ranNum peerNodeId appEnt
                  updateTimeout'
                  follower
                GT -> do
                  sendM $ writeCurrentTermAndVotedFor term Nothing
                  appendAction ranNum peerNodeId appEnt
                  updateTimeout'
                  follower
            MsgRequestVote reqVote@RequestVote {term} -> do
              case compare term currentTerm of
                LT -> do
                  send' (MsgRequestVoteResult (RequestVoteResult currentTerm False))
                  go voteTrueSet voteFalseSet
                EQ -> do
                  send' (MsgRequestVoteResult (RequestVoteResult currentTerm False))
                  go voteTrueSet voteFalseSet
                GT -> do
                  sendM $ writeCurrentTermAndVotedFor term Nothing
                  voteAction peerNodeId reqVote
                  updateTimeout'
                  follower
            MsgRequestVoteResult RequestVoteResult {term, voteGranted} ->
              do
                case compare term currentTerm of
                  LT -> go voteTrueSet voteFalseSet
                  EQ -> do
                    if voteGranted
                      then do
                        let newVoteTrueSet = Set.insert peerNodeId voteTrueSet
                        if Set.size newVoteTrueSet >= (Map.size peerInfos `div` 2)
                          then do
                            timeTracerWith (CandidateElectionSuccess (Set.toList newVoteTrueSet) currentTerm)
                            leader
                          else go newVoteTrueSet voteFalseSet
                      else do
                        let newVoteFalseSet = Set.insert peerNodeId voteFalseSet
                        if Set.size newVoteFalseSet >= (Map.size peerInfos `div` 2 + 1)
                          then do
                            timeTracerWith (CandidateElectionFailed (Set.toList newVoteFalseSet) currentTerm)
                            updateTimeout'
                            follower
                          else go voteTrueSet newVoteFalseSet
                  GT -> do
                    sendM $ writeCurrentTermAndVotedFor term Nothing
                    updateTimeout'
                    follower
            MsgAppendEntriesResult _ _ -> go voteTrueSet voteFalseSet

sendMsgAppEnt ::
  ( HasLabelled SEnv (Reader (SEnv s n)) sig m,
    Has (State RandomNumber) sig m,
    Has Random sig m,
    HasLabelledLift n sig m,
    Monad n
  ) =>
  AppendEntries s ->
  m ()
sendMsgAppEnt appEnt = do
  SEnv {sendFun} <- R.ask @SEnv
  ranNum <- uniform
  put ranNum
  sendM $ sendFun (MsgAppendEntries ranNum appEnt)

sync ::
  ( HasLabelled SEnv (Reader (SEnv s n)) sig m,
    Has (State SState) sig m,
    Has (State RandomNumber) sig m,
    Has Random sig m,
    HasLabelledLift n sig m,
    MonadSTM n,
    MonadTimer n,
    MonadTime n
  ) =>
  AppendEntries s ->
  m ()
sync appEnt = do
  SState {syncingPrevLogIndex, syncingLogLength} <- get
  SEnv
    { nodeId,
      currentTerm,
      persistentFun,
      appendEntriesRpcRetryWaitTime,
      heartbeatWaitTime,
      appendEntriesResultQueue,
      matchIndexTVar,
      lastLogIndexTVar,
      commitIndexTVar
    } <-
    R.ask @SEnv
  timeout' <- sendM $ newTimeout appendEntriesRpcRetryWaitTime
  res <- sendM $ atomically $ (Left <$> readTQueue appendEntriesResultQueue) <|> (Right <$> waitTimeout timeout')
  case res of
    Right _ -> do
      sendMsgAppEnt appEnt
      sync appEnt
    Left (Left Terminate) -> pure ()
    Left (Right (respRanNum, AppendEntriesResult {success})) -> do
      lastRanNum <- get @RandomNumber
      if respRanNum /= lastRanNum
        then sync appEnt
        else do
          if success
            then do
              sendM $
                atomically $ writeTVar matchIndexTVar (syncingPrevLogIndex + syncingLogLength)
              let check' = do
                    lastLogIndex <- readTVar lastLogIndexTVar
                    if lastLogIndex > syncingPrevLogIndex + syncingLogLength
                      then pure LastLogIndexGTSyncingParams
                      else retry
              timeout'' <- sendM $ newTimeout heartbeatWaitTime
              res' <- sendM $ atomically $ (Left <$> check') <|> (Right <$> waitTimeout timeout'')
              case res' of
                Right _ -> do
                  (pi', pt) <- sendM $ persisLastLogIndexAndTerm persistentFun
                  commitIndex <- sendM $ readTVarIO commitIndexTVar
                  let appEnt' = AppendEntries currentTerm (unNodeId nodeId) pi' pt [] commitIndex
                  sendMsgAppEnt appEnt'
                  put (SState {syncingPrevLogIndex = pi', syncingLogLength = 0})
                  sync appEnt'
                Left LastLogIndexGTSyncingParams -> do
                  let newPreIndex = syncingPrevLogIndex + syncingLogLength
                  put (SState {syncingPrevLogIndex = newPreIndex, syncingLogLength = 1})
                  TermWarpper newPreTerm _ <- sendM $ readLog persistentFun newPreIndex
                  log' <- sendM $ readLog persistentFun (newPreIndex + 1)
                  commitIndex <- sendM $ readTVarIO commitIndexTVar
                  let appEnt' = AppendEntries currentTerm (unNodeId nodeId) newPreIndex newPreTerm [log'] commitIndex
                  sendMsgAppEnt appEnt'
                  sync appEnt'
            else do
              let newPreIndex = syncingPrevLogIndex - 1
              put (SState {syncingPrevLogIndex = newPreIndex, syncingLogLength = 0})
              TermWarpper newPreTerm _ <- sendM $ readLog persistentFun newPreIndex
              commitIndex <- sendM $ readTVarIO commitIndexTVar
              let appEnt' = AppendEntries currentTerm (unNodeId nodeId) newPreIndex newPreTerm [] commitIndex
              sendMsgAppEnt appEnt'
              sync appEnt'

leader ::
  ( HasLabelled HEnv (Reader (HEnv s n)) sig m,
    HasLabelled HState (State (HState s n)) sig m,
    HasLabelledLift n sig m,
    Has Random sig m,
    MonadSTM n,
    MonadTime n,
    MonadFork n,
    MonadTimer n
  ) =>
  m ()
leader = do
  HEnv
    { nodeId,
      peerInfos,
      persistentFun =
        ps@PersistentFun
          { readCurrentTerm,
            persisLastLogIndexAndTerm,
            appendLog,
            writeCurrentTermAndVotedFor
          },
      peersRecvQueue,
      commitIndexTVar,
      userLogQueue,
      appendEntriesRpcRetryWaitTime,
      heartbeatWaitTime,
      tracer
    } <-
    R.ask @HEnv
  currentTerm <- sendM readCurrentTerm
  (pi', pt) <- sendM persisLastLogIndexAndTerm
  commitIndex <- sendM $ readTVarIO commitIndexTVar
  timeTracerWith (LeaderSendEmptyAppendEntries (Map.keys peerInfos))
  ranNum <- uniform
  let appEnt = AppendEntries currentTerm (unNodeId nodeId) pi' pt [] commitIndex
      msg = MsgAppendEntries ranNum appEnt
  mapM_ (getPeerSendFun >=> ($ msg)) $ Map.keys peerInfos
  lastLogIndexTVar <- sendM $ newTVarIO pi'
  pns <- forM (Map.toList peerInfos) $ \(peerNodeId, peerInfo) -> do
    matchIndexTVar <- sendM $ newTVarIO 0
    appendEntriesResultQueue <- sendM newTQueueIO
    let sState = SState {syncingPrevLogIndex = pi', syncingLogLength = 0}
        sEnv =
          SEnv
            { nodeId,
              peerNodeId,
              sendFun = peerSendFun peerInfo,
              currentTerm,
              persistentFun = ps,
              appendEntriesResultQueue,
              matchIndexTVar,
              lastLogIndexTVar,
              commitIndexTVar,
              appendEntriesRpcRetryWaitTime,
              heartbeatWaitTime,
              tracer
            }
    ri <- uniform
    void
      . sendM
      . forkIO
      . void
      . runLabelledLift
      . runReader sEnv
      . runLabelled @SEnv
      . runState sState
      . runRandom (mkStdGen ri)
      . runState @RandomNumber ranNum
      $ sync appEnt
    pure (peerNodeId, (appendEntriesResultQueue, matchIndexTVar))

  let miTVars = map (snd . snd) pns
      tmpPeersResultQueue = Map.fromList $ map (second fst) pns

  cmdQueue <- sendM newTQueueIO
  _ <- sendM $ forkIO $ cProcess ps cmdQueue commitIndexTVar miTVars 0

  let stopDependProcess = do
        sendM $ atomically $ writeTQueue cmdQueue Terminate
        forM_ (Map.elems tmpPeersResultQueue) $ \tq -> sendM $ atomically (writeTQueue tq (Left Terminate))

      go = do
        mMsg <- sendM $ atomically $ (Left <$> readTQueue peersRecvQueue) <|> (Right <$> readTQueue userLogQueue)
        case mMsg of
          Right log' -> do
            index <- sendM $ appendLog (TermWarpper currentTerm log')
            sendM $ atomically $ writeTVar lastLogIndexTVar index
            go
          Left (peerNodeId, msg') -> do
            timeTracerWith (LeaderRecvMsg (peerNodeId, msg'))
            case msg' of
              MsgAppendEntries ranNum' appEnt'@AppendEntries {term} -> do
                send' <- getPeerSendFun peerNodeId
                case compare term currentTerm of
                  LT -> do
                    timeTracerWith (LeaderRecvPastAppendEntries appEnt')
                    send' (MsgAppendEntriesResult ranNum' (AppendEntriesResult currentTerm False))
                    go
                  EQ -> error "undefined behave"
                  GT -> do
                    stopDependProcess
                    sendM $ writeCurrentTermAndVotedFor term Nothing
                    appendAction ranNum' peerNodeId appEnt'
                    newTimeout'
                    timeTracerWith LeaderToFollowerAtAP
                    follower
              MsgRequestVote
                reqVote@RequestVote
                  { term
                  } -> do
                  send' <- getPeerSendFun peerNodeId
                  case compare term currentTerm of
                    LT -> do
                      timeTracerWith (LeaderRecvPastRequestVote reqVote)
                      send' (MsgRequestVoteResult (RequestVoteResult currentTerm False))
                      go
                    EQ -> do
                      timeTracerWith (LeaderRecvPastRequestVote reqVote)
                      send' (MsgRequestVoteResult (RequestVoteResult currentTerm False))
                      go
                    GT -> do
                      stopDependProcess
                      sendM $ writeCurrentTermAndVotedFor term Nothing
                      voteAction peerNodeId reqVote
                      newTimeout'
                      timeTracerWith LeaderToFollowerAtRV
                      follower
              MsgAppendEntriesResult ranNum' apr@AppendEntriesResult {term} -> do
                let tq = fromJust $ Map.lookup peerNodeId tmpPeersResultQueue
                case compare term currentTerm of
                  LT -> go
                  EQ -> do
                    sendM $ atomically $ writeTQueue tq (Right (ranNum', apr))
                    go
                  GT -> do
                    stopDependProcess
                    sendM $ writeCurrentTermAndVotedFor term Nothing
                    newTimeout'
                    follower
              MsgRequestVoteResult _ -> go

  go

appendAction ::
  ( HasLabelled HEnv (Reader (HEnv s n)) sig m,
    HasLabelledLift n sig m,
    MonadTime n,
    MonadTimer n,
    MonadSTM n
  ) =>
  RandomNumber ->
  PeerNodeId ->
  AppendEntries s ->
  m ()
appendAction
  ranNum
  peerNodeId
  AppendEntries
    { prevLogIndex,
      prevLogTerm,
      entries,
      leaderCommit
    } =
    do
      HEnv
        { persistentFun =
            PersistentFun
              { readCurrentTerm,
                checkAppendentries,
                checkEntry,
                appendLog,
                removeLogs
              },
          commitIndexTVar
        } <-
        R.ask @HEnv
      send' <- getPeerSendFun peerNodeId
      currentTerm <- sendM readCurrentTerm
      prevCheck <- sendM $ checkAppendentries prevLogIndex prevLogTerm
      timeTracerWith (FollowerCheckPrevLog prevCheck)
      if not prevCheck
        then send' (MsgAppendEntriesResult ranNum (AppendEntriesResult currentTerm False))
        else do
          let go [] = pure ()
              go k@((i, _) : es) = do
                checkEntryResult <- sendM $ checkEntry (prevLogIndex + i) currentTerm
                case checkEntryResult of
                  Exis -> go es
                  Null -> do
                    mapM_ (sendM . appendLog) (snd <$> k)
                  Diff -> sendM $ do
                    removeLogs (prevLogIndex + i)
                    mapM_ appendLog (snd <$> k)
          go (zip [1 ..] entries)
          commitIndex <- sendM $ readTVarIO commitIndexTVar
          if leaderCommit > commitIndex
            then do
              let persisLastLogIndexVal = prevLogIndex + length entries
              sendM $ atomically $ writeTVar commitIndexTVar (min leaderCommit persisLastLogIndexVal)
              timeTracerWith (FollowerUpdateCommitIndex leaderCommit persisLastLogIndexVal (min leaderCommit persisLastLogIndexVal))
            else pure ()
          send' (MsgAppendEntriesResult ranNum (AppendEntriesResult currentTerm True))

voteAction ::
  ( HasLabelled HEnv (Reader (HEnv s n)) sig m,
    HasLabelledLift n sig m,
    MonadTime n,
    MonadTimer n,
    MonadSTM n
  ) =>
  PeerNodeId ->
  RequestVote ->
  m ()
voteAction
  peerNodeId
  RequestVote
    { candidateId,
      lastLogIndex,
      lastLogTerm
    } =
    do
      HEnv
        { persistentFun =
            PersistentFun
              { readCurrentTerm,
                readVotedFor,
                writeCurrentTermAndVotedFor,
                persisLastLogIndexAndTerm
              }
        } <-
        R.ask @HEnv
      send' <- getPeerSendFun peerNodeId
      currentTerm <- sendM readCurrentTerm
      (persisLastLogIndexVal, persisLastLogTermVal) <- sendM persisLastLogIndexAndTerm
      let isCandidateLogNewst =
            lastLogTerm > persisLastLogTermVal
              || (lastLogTerm == persisLastLogTermVal && lastLogIndex >= persisLastLogIndexVal)
      if not isCandidateLogNewst
        then send' (MsgRequestVoteResult (RequestVoteResult currentTerm False))
        else do
          voteFor <- sendM readVotedFor
          case voteFor of
            Nothing -> do
              sendM $ writeCurrentTermAndVotedFor currentTerm (Just candidateId)
              timeTracerWith (VotedForNode candidateId currentTerm)
              send' (MsgRequestVoteResult (RequestVoteResult currentTerm True))
            Just canid -> do
              if canid == candidateId
                then do
                  timeTracerWith (VotedForNode candidateId currentTerm)
                  send' (MsgRequestVoteResult (RequestVoteResult currentTerm True))
                else send' (MsgRequestVoteResult (RequestVoteResult currentTerm False))

-- type S s n = RandomC StdGen (Labelled HEnv (ReaderC (HEnv s n)) (Labelled HState (StateC (HState s n)) (LabelledLift Lift (Lift n) (LiftC n)))) ()
--
-- {-# SPECIALIZE follower :: S s IO #-}
-- {-# SPECIALIZE follower :: S s (IOSim n) #-}
-- {-# SPECIALIZE candidate :: S s IO #-}
-- {-# SPECIALIZE candidate :: S s (IOSim n) #-}
-- {-# SPECIALIZE leader :: S s IO #-}
-- {-# SPECIALIZE leader :: S s (IOSim n) #-}
-- {-# SPECIALIZE appendAction :: PeerNodeId -> AppendEntries s -> S s IO #-}
-- {-# SPECIALIZE appendAction :: PeerNodeId -> AppendEntries s -> S s (IOSim n) #-}
-- {-# SPECIALIZE voteAction :: PeerNodeId -> RequestVote -> S s IO #-}
-- {-# SPECIALIZE voteAction :: PeerNodeId -> RequestVote -> S s (IOSim n) #-}
-- {-# SPECIALIZE runFollow :: HState s IO -> HEnv s IO -> StdGen -> IO (HState s IO, (StdGen, ())) #-}
-- {-# SPECIALIZE runFollow :: HState s (IOSim n) -> HEnv s (IOSim n) -> StdGen -> IOSim n (HState s (IOSim n), (StdGen, ())) #-}
