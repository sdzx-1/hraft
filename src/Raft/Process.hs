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
import Raft.Type

cProcess
  :: MonadSTM m
  => PersistentFun log m
  -> CmdQueue m
  -> CommitIndexTVar m
  -> [MatchIndexTVar m]
  -> Index
  -> m ()
cProcess persisFun@PersistentFun{readCurrentTerm, readLog} cmdQueue commitTVar matchTVars index =
  do
    val <-
      atomically $ (Left <$> readTQueue cmdQueue) <|> (Right <$> getNewCommit)
    case val of
      Left Terminate -> pure ()
      Right minMatch -> do
        currentTerm <- readCurrentTerm
        TermWarpper term _ <- readLog minMatch
        when (term == currentTerm) $ atomically $ writeTVar commitTVar minMatch
        cProcess persisFun cmdQueue commitTVar matchTVars minMatch
  where
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
  -> LastAppliedTVar m
  -> state
  -> ApplyFun state operate output m
  -> m ()
aProcess logReader commitTVar lastAppTVar state'' applyFun = do
  (start, end) <- atomically $ do
    lastApp <- readTVar lastAppTVar
    commit <- readTVar commitTVar
    if commit > lastApp then pure (lastApp + 1, commit) else retry

  operates <- logReader start end
  let go state' [] = pure state'
      go state' (TermWarpper _ x : xs) = do
        (newState, _) <- applyFun state' x
        go newState xs
  newState <- go state'' operates
  atomically $ writeTVar lastAppTVar end
  aProcess logReader commitTVar lastAppTVar newState applyFun

timeTracerWith :: MonadTime m => Tracer m (TimeWrapper a) -> a -> m ()
timeTracerWith tracer a = do
  ct <- getCurrentTime
  traceWith tracer (TimeWrapper ct a)
