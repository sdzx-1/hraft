{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Server where

import Channel (createConnectedBufferedChannels)
import Control.Carrier.State.Strict
import Control.Effect.Labelled
import Control.Monad (void)
import Control.Monad.Class.MonadFork hiding (yield)
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (runSimTrace, selectTraceEventsSay)
import Network.TypedProtocol.Core
import Server.Type

ppClient ::
  forall n sig m.
  ( Monad n,
    MonadTime n,
    MonadSay n,
    HasLabelledLift n sig m,
    Has (State Int) sig m,
    MonadDelay n
  ) =>
  SPeer PingPong Client StIdle m ()
ppClient = yield MsgPing $
  await $ \case
    MsgPong -> SEffect $ do
      sendM $ say "client recv MsgPong"
      pure $ yield MsgDone (done ())

ppServer ::
  forall m n sig.
  ( Monad n,
    MonadSay n,
    MonadTime n,
    HasLabelledLift n sig m
  ) =>
  SPeer PingPong Server StIdle m ()
ppServer = await $ \case
  MsgPing -> SEffect $ do
    sendM $ say "server recv MsgPing"
    pure $
      yield MsgPong ppServer
  MsgDone -> SEffect $ do
    sendM $ say "server done"
    pure $ done ()

-- >>> foo
-- ["server recv MsgPing","client recv MsgPong","server done"]
foo :: [String]
foo = selectTraceEventsSay $
  runSimTrace $ do
    (cc, sc) <- createConnectedBufferedChannels 100
    let cD = driverSimple pingPongCodec cc
        sD = driverSimple pingPongCodec sc

    void
      . forkIO
      . void
      . runLabelledLift
      . runState @Int 0
      $ runPeerWithDriver sD ppServer Nothing

    void
      . forkIO
      . void
      . runLabelledLift
      . runState @Int 0
      $ runPeerWithDriver cD ppClient Nothing
    threadDelay 10
