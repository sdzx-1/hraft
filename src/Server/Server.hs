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

import Control.Carrier.State.Strict
import Control.Effect.Labelled
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Network.TypedProtocol.Core
import Server.Type

ppServer ::
  forall m n sig.
  ( Monad n,
    MonadSay n,
    MonadTime n,
    Has (State Int) sig m,
    HasLabelledLift n sig m
  ) =>
  SPeer PingPong Server StIdle m ()
ppServer = await $ \case
  MsgPing i -> SEffect $ do
    modify (+ i)
    sendM $ say $ "s MsgPing " ++ show i
    i' <- get @Int
    pure $
      yield (MsgPong i') ppServer
  MsgDone -> SEffect $ do
    sendM $ say "server done"
    pure $ done ()

-- >>> foo
-- ["s MsgPing 1","c MsgPong 1","s MsgPing 1","c MsgPong 2","s MsgPing 1","c MsgPong 3","s MsgPing 1","c MsgPong 4","client done","server done"]
-- foo :: [String]
-- foo = selectTraceEventsSay $
--   runSimTrace $ do
--     (cc, sc) <- createConnectedBufferedChannels 100
--     let cD = driverSimple pingPongCodec cc
--         sD = driverSimple pingPongCodec sc

--     void
--       . forkIO
--       . void
--       . runLabelledLift
--       . runState @Int 0
--       . runError @CBOR.DeserialiseFailure
--       $ runPeerWithDriver sD ppServer Nothing

--     void
--       . forkIO
--       . void
--       . runLabelledLift
--       . runState @Int 0
--       . runError @CBOR.DeserialiseFailure
--       $ runPeerWithDriver cD ppClient Nothing
--     threadDelay 10
