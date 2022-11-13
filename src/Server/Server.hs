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
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled
import Control.Monad (void)
import Control.Monad.Class.MonadFork hiding (yield)
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (runSimTrace, selectTraceEventsSay)
import Network.TypedProtocol.Core

-------------------------- ping pong example
data PingPong
  = StIdle
  | StBusy
  | StDone
  | TB

instance Protocol PingPong where
  data Message PingPong from to where
    MsgPing :: Message PingPong StIdle StBusy
    MsgPong :: Message PingPong StBusy StIdle
    MsgDone :: Message PingPong StIdle StDone
    MsgTBStart :: Message PingPong StIdle TB
    MsgTB :: Message PingPong TB TB
    MsgTBEnd :: Message PingPong TB StIdle
    MsgHeartbeat :: Message PingPong StIdle StIdle

  data Sig PingPong st where
    SigStIdle :: Sig PingPong StIdle
    SigStBusy :: Sig PingPong StBusy
    SigStDone :: Sig PingPong StDone
    SigTB :: Sig PingPong TB

  type ClientAgencyList PingPong = '[ 'StIdle, 'TB]
  type ServerAgencyList PingPong = '[ 'StBusy]
  type NobodyAgencyList PingPong = '[ 'StDone]

instance ToSig PingPong StIdle where
  toSig = SigStIdle

instance ToSig PingPong StBusy where
  toSig = SigStBusy

instance ToSig PingPong StDone where
  toSig = SigStDone

instance ToSig PingPong TB where
  toSig = SigTB

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
ppClient =
  yield MsgHeartbeat $
    yield MsgTBStart $
      let go = SEffect @m $ do
            modify @Int (+ 1)
            v <- get @Int
            if v > 2
              then pure $
                yield MsgTBEnd $
                  SEffect $ do
                    sendM $ say "client done"
                    pure $ yield MsgDone (done ())
              else do
                sendM $ threadDelay 1
                sendM $ say $ show ("send", "MsgTB")
                pure $ yield MsgTB go
       in go

ppServer ::
  forall m n sig.
  ( Monad n,
    MonadSay n,
    MonadTime n,
    HasLabelledLift n sig m
  ) =>
  SPeer PingPong Server StIdle m ()
ppServer = await $ \case
  MsgHeartbeat -> SEffect $ do
    sendM $ say $ show ("recv", "MsgHeartbeat")
    pure ppServer
  MsgPing -> SEffect $ do
    pure $
      yield MsgPong ppServer
  MsgDone -> SEffect $ do
    sendM $ say "server done"
    pure $ done ()
  MsgTBStart ->
    let go = await @_ @_ @_ @m $ \case
          MsgTB -> SEffect $ do
            sendM $ say $ show ("recv", "MsgTB")
            pure go
          MsgTBEnd -> ppServer
     in go

encodeMessagePingPong :: Message PingPong st st' -> String
encodeMessagePingPong = \case
  MsgPing -> "ping"
  MsgPong -> "pong"
  MsgDone -> "done"
  MsgTBStart -> "start"
  MsgTB -> "tb"
  MsgTBEnd -> "end"
  MsgHeartbeat -> "heartBeat"

decodeMessagePingPong :: Sig PingPong st -> String -> SomeMessage st
decodeMessagePingPong p s = case (p, s) of
  (SigStIdle, "ping") -> SomeMessage MsgPing
  (SigStBusy, "pong") -> SomeMessage MsgPong
  (SigStIdle, "done") -> SomeMessage MsgDone
  (SigStIdle, "start") -> SomeMessage MsgTBStart
  (SigTB, "tb") -> SomeMessage MsgTB
  (SigTB, "end") -> SomeMessage MsgTBEnd
  (SigStIdle, "heartBeat") -> SomeMessage MsgHeartbeat
  _ -> undefined

csDriver ::
  (MonadSTM n) =>
  (TQueue n String, TQueue n String) ->
  (SDriver PingPong Int n, SDriver PingPong Int n)
csDriver (a, b) =
  let f x y =
        SDriver
          { sendMessage = atomically . writeTQueue x . encodeMessagePingPong,
            recvMessage = \sig _ -> do
              st <- atomically $ readTQueue y
              let res = decodeMessagePingPong sig st
              pure (res, 0),
            startDState = 0
          }
   in (f a b, f b a)

-- >>> foo
-- ["(\"recv\",\"MsgHeartbeat\")","(\"send\",\"MsgTB\")","(\"recv\",\"MsgTB\")","(\"send\",\"MsgTB\")","(\"recv\",\"MsgTB\")","client done","server done"]
foo :: [String]
foo = selectTraceEventsSay $
  runSimTrace $ do
    tq1 <- newTQueueIO
    tq2 <- newTQueueIO
    let (cD, sD) = csDriver (tq1, tq2)
    void $ forkIO $ void $ runLabelledLift $ runState @Int 0 $ runPeerWithDriver sD ppServer 0
    void $ forkIO $ void $ runLabelledLift $ runState @Int 0 $ runPeerWithDriver cD ppClient 0
    threadDelay 10
