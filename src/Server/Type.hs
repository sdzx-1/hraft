{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Type where

import Control.Carrier.State.Strict
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled
import Control.Monad (void)
import Control.Monad.Class.MonadFork hiding (yield)
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.IOSim (runSimTrace, selectTraceEventsSay)
import Data.Kind
import GHC.TypeLits (ErrorMessage (..), TypeError)

class Protocol ps where
  data Message ps (st :: ps) (st' :: ps)
  data Sig ps (st :: ps)
  type NobodyAgencyList ps :: [ps]
  type ClientAgencyList ps :: [ps]
  type ServerAgencyList ps :: [ps]

class Protocol ps => ToSig ps (st :: ps) where
  toSig :: Sig ps st

type family Elem t ts :: Constraint where
  Elem t '[] = TypeError (Text "method error")
  Elem t (t ': ts) = ()
  Elem t (_ ': ts) = Elem t ts

data Role = Client | Server

type family YieldList (r :: Role) ps where
  YieldList Client ps = (ClientAgencyList ps)
  YieldList Server ps = (ServerAgencyList ps)

type family AwaitList (r :: Role) ps where
  AwaitList Client ps = (ServerAgencyList ps)
  AwaitList Server ps = (ClientAgencyList ps)

data SPeer ps (r :: Role) (st :: ps) m a where
  SEffect ::
    m (SPeer ps r st m a) ->
    SPeer ps r st m a
  SDone ::
    (Elem st (NobodyAgencyList ps)) =>
    a ->
    SPeer ps r st m a
  SYield ::
    ( Elem st (YieldList r ps),
      ToSig ps st,
      ToSig ps st'
    ) =>
    Message ps st st' ->
    SPeer ps r st' m a ->
    SPeer ps r st m a
  SAwait ::
    (Elem st (AwaitList r ps)) =>
    (forall st'. Message ps st st' -> SPeer ps r st' m a) ->
    SPeer ps r st m a

deriving instance Functor m => Functor (SPeer ps r (st :: ps) m)

data SomeMessage (st :: ps) where
  SomeMessage :: (ToSig ps st') => Message ps st st' -> SomeMessage st

done ::
  Elem st (NobodyAgencyList ps) =>
  a ->
  SPeer ps r st m a
done = SDone

yield ::
  ( Elem st (YieldList r ps),
    ToSig ps st,
    ToSig ps st'
  ) =>
  Message ps st st' ->
  SPeer ps r (st' :: ps) m a ->
  SPeer ps r (st :: ps) m a
yield = SYield

await ::
  Elem st (AwaitList r ps) =>
  (forall st'. Message ps st st' -> SPeer ps r (st' :: ps) m a) ->
  SPeer ps r (st :: ps) m a
await = SAwait

data SDriver ps dstate m = SDriver
  { sendMessage :: forall (st :: ps) (st' :: ps). Message ps st st' -> m (),
    recvMessage :: forall (st :: ps). Sig ps st -> dstate -> m (SomeMessage st, dstate),
    startDState :: dstate
  }

runPeerWithDriver ::
  forall ps (st :: ps) (r :: Role) dstate m n sig a.
  ( Functor n,
    ToSig ps st,
    HasLabelledLift n sig m
  ) =>
  SDriver ps dstate n ->
  SPeer ps r st m a ->
  dstate ->
  m (a, dstate)
runPeerWithDriver SDriver {sendMessage, recvMessage} =
  flip go
  where
    go :: forall st'. (ToSig ps st') => dstate -> SPeer ps r st' m a -> m (a, dstate)
    go dstate (SEffect k) = k >>= go dstate
    go dstate (SDone x) = return (x, dstate)
    go dstate (SYield msg k) = do
      sendM $ sendMessage msg
      go dstate k
    go dstate (SAwait k) = do
      (SomeMessage msg, dstate') <- sendM $ recvMessage toSig dstate
      go dstate' (k msg)

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
  MsgPing -> SEffect $ do
    pure $
      yield MsgPong ppServer
  MsgDone -> SEffect $ do
    sendM $ say "server done"
    pure $ done ()
  MsgTBStart ->
    let go = await @_ @_ @_ @m $ \case
          MsgTB -> SEffect $ do
            ct <- sendM getCurrentTime
            sendM $ say $ show (ct, "msgTB")
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

decodeMessagePingPong :: Sig PingPong st -> String -> SomeMessage st
decodeMessagePingPong p s = case (p, s) of
  (SigStIdle, "ping") -> SomeMessage MsgPing
  (SigStBusy, "pong") -> SomeMessage MsgPong
  (SigStIdle, "done") -> SomeMessage MsgDone
  (SigStIdle, "start") -> SomeMessage MsgTBStart
  (SigTB, "tb") -> SomeMessage MsgTB
  (SigTB, "end") -> SomeMessage MsgTBEnd
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
-- ["(1970-01-01 00:00:01 UTC,\"msgTB\")","(1970-01-01 00:00:02 UTC,\"msgTB\")","client done","server done"]
foo :: [String]
foo = selectTraceEventsSay $
  runSimTrace $ do
    tq1 <- newTQueueIO
    tq2 <- newTQueueIO
    let (cD, sD) = csDriver (tq1, tq2)
    void $ forkIO $ void $ runLabelledLift $ runState @Int 0 $ runPeerWithDriver sD ppServer 0
    void $ forkIO $ void $ runLabelledLift $ runState @Int 0 $ runPeerWithDriver cD ppClient 0
    threadDelay 10
