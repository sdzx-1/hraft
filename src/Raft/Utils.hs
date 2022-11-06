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

module Raft.Utils where

import Control.Algebra
import Control.Carrier.Random.Gen
import Control.Carrier.Reader
import Control.Carrier.State.Strict
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled
import qualified Control.Effect.Reader.Labelled as R
import qualified Control.Effect.State.Labelled as S
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Tracer
import qualified Data.Map as Map
import Data.Maybe
import Data.Time
  ( diffTimeToPicoseconds,
    picosecondsToDiffTime,
  )
import Raft.Type

timeTracerWith ::
  ( HasLabelled HEnv (Reader (HEnv s n)) sig m,
    HasLabelledLift n sig m,
    MonadTime n
  ) =>
  HandleTracer' s ->
  m ()
timeTracerWith a = do
  HEnv {tracer} <- R.ask @HEnv
  ct <- lift getCurrentTime
  lift $ traceWith tracer (TimeWrapper ct a)

waitTimeout :: (MonadTimer n, MonadSTM n) => Timeout n -> STM n ()
waitTimeout timeout' = do
  tv <- readTimeout timeout'
  case tv of
    TimeoutFired -> pure ()
    _ -> retry

updateTimeout' ::
  ( MonadTimer n,
    HasLabelledLift n sig m,
    HasLabelled HState (State (HState s n)) sig m
  ) =>
  m ()
updateTimeout' = do
  HState {electionSize, electionTimeout} <- S.get @HState
  lift $ updateTimeout electionTimeout electionSize

newTimeout' ::
  ( MonadTimer n,
    HasLabelledLift n sig m,
    HasLabelled HState (State (HState s n)) sig m
  ) =>
  m ()
newTimeout' = do
  HState {electionSize} <- S.get @HState
  to <- lift $ newTimeout electionSize
  S.put @HState (HState {electionSize, electionTimeout = to})

randomRDiffTime :: Has Random sig m => (DiffTime, DiffTime) -> m DiffTime
randomRDiffTime (el, et) = picosecondsToDiffTime <$> uniformR (a, b)
  where
    (a, b) =
      ( diffTimeToPicoseconds el,
        diffTimeToPicoseconds et
      )

getPeerSendFun ::
  ( MonadTimer n,
    HasLabelledLift n sig m,
    HasLabelled HEnv (Reader (HEnv s n)) sig m
  ) =>
  PeerNodeId ->
  m (Msg s -> m ())
getPeerSendFun peerNodeId = do
  HEnv {peerInfos} <- R.ask @HEnv
  let send' = peerSendFun $ fromJust $ Map.lookup peerNodeId peerInfos
  pure (lift . send')
