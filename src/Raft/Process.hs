{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}

module Raft.Process where

import Channel
import qualified Codec.CBOR.Read as CBOR
import Codec.Serialise (Serialise)
import Control.Applicative
import Control.Concurrent.Class.MonadSTM
import Control.Monad (when)
import Control.Monad.Class.MonadTime
import Control.Tracer
import qualified Data.ByteString.Lazy as LBS
import Data.List (sort)
import Data.Map (Map)
import qualified Data.Map as Map
import Deque.Strict (Deque)
import qualified Deque.Strict as D
import GHC.Exts (toList)
import Raft.Type

cProcess
  :: MonadSTM m
  => PersistentFun log m
  -> CmdQueue m
  -> CommitIndexTVar m
  -> TVar m (Deque (Index, TMVar m (ApplyResult output)))
  -> TVar m (Map Index (TMVar m (ApplyResult output)))
  -> [MatchIndexTVar m]
  -> Index
  -> m ()
cProcess
  persisFun@PersistentFun
    { readCurrentTerm
    , readLog
    }
  cmdQueue
  commitTVar
  leaderAcceptReqList
  needReplyOutputMap
  matchTVars
  index =
    do
      val <-
        atomically $ (Left <$> readTQueue cmdQueue) <|> (Right <$> getNewCommit)
      case val of
        Left Terminate -> pure ()
        Right minMatch -> do
          currentTerm <- readCurrentTerm
          TermWarpper term _ <- readLog minMatch
          when (term == currentTerm) $ atomically $ do
            dq <- readTVar leaderAcceptReqList
            oldMap <- readTVar needReplyOutputMap
            let (newMap, ndq) = updateNeedReplyMapAndDQ minMatch dq oldMap
            writeTVar leaderAcceptReqList ndq
            writeTVar needReplyOutputMap newMap
            writeTVar commitTVar minMatch

          cProcess
            persisFun
            cmdQueue
            commitTVar
            leaderAcceptReqList
            needReplyOutputMap
            matchTVars
            minMatch
    where
      updateNeedReplyMapAndDQ comIndex dq oldMap = (newMap, gs)
        where
          (ls, gs) = D.span (\(i, _) -> i <= comIndex) dq
          newMap = foldr (uncurry Map.insert) oldMap (toList ls)

      medianValue xs = sort xs !! lmid
        where
          len = length xs
          lmid = len `div` 2

      getNewCommit = do
        matchs <- mapM readTVar matchTVars
        let minMatch = medianValue matchs
        if minMatch > index then pure minMatch else retry

rProcess
  :: ( MonadSTM m
     , Serialise s
     , MonadTime m
     )
  => Tracer m (RecvTracer s)
  -> PeerNodeId
  -> RecvQueue s m
  -> Channel m LBS.ByteString
  -> DecodeStep LBS.ByteString CBOR.DeserialiseFailure m (Msg s)
  -> m ()
rProcess recvTracer peerNodeId recvQueue channel dstep = go Nothing
  where
    go mb = do
      r <- runDecoderWithChannel channel mb dstep
      case r of
        Left e -> error (show e)
        Right (msg, rbs) -> do
          timeTracerWith recvTracer msg
          atomically $ writeTQueue recvQueue (peerNodeId, msg)
          go rbs

aProcess
  :: (MonadSTM m)
  => LogReader m operate
  -> CommitIndexTVar m
  -> TVar m (Map Index (TMVar m (ApplyResult output)))
  -> LastAppliedTVar m
  -> state
  -> ApplyFun state operate output m
  -> m ()
aProcess
  logReader
  commitTVar
  needReplyOutputMap
  lastAppTVar
  state''
  applyFun = do
    (start, end) <- atomically $ do
      lastApp <- readTVar lastAppTVar
      commit <- readTVar commitTVar
      if commit > lastApp then pure (lastApp + 1, commit) else retry

    operates <- logReader start end
    let go state' [] = pure state'
        go state' ((index, TermWarpper _ x) : xs) = do
          (newState, output) <- applyFun state' x
          nom <- readTVarIO needReplyOutputMap
          case Map.lookup index nom of
            Nothing -> pure ()
            Just tv -> atomically $ do
              modifyTVar' needReplyOutputMap (Map.delete index)
              putTMVar tv (Success output)
          go newState xs
    newState <- go state'' operates
    atomically $ writeTVar lastAppTVar end
    aProcess
      logReader
      commitTVar
      needReplyOutputMap
      lastAppTVar
      newState
      applyFun

timeTracerWith :: MonadTime m => Tracer m (TimeWrapper a) -> a -> m ()
timeTracerWith tracer a = do
  ct <- getCurrentTime
  traceWith tracer (TimeWrapper ct a)
