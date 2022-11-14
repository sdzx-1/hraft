{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Network.TypedProtocol.Core where

import Channel
import qualified Codec.CBOR.Read as CBOR
import Control.Effect.Error
import Control.Effect.Labelled hiding (send)
import qualified Data.ByteString.Lazy as LBS
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
    recvMessage :: forall (st :: ps). Sig ps st -> dstate -> m (Either CBOR.DeserialiseFailure (SomeMessage st, dstate)),
    startDState :: dstate
  }

data Codec ps m = Codec
  { encode ::
      forall (st :: ps) (st' :: ps).
      Message ps st st' ->
      LBS.ByteString,
    decode ::
      forall (st :: ps).
      Sig ps st ->
      m (DecodeStep LBS.ByteString CBOR.DeserialiseFailure m (SomeMessage st))
  }

driverSimple ::
  forall ps m.
  Monad m =>
  Codec ps m ->
  Channel m LBS.ByteString ->
  SDriver ps (Maybe LBS.ByteString) m
driverSimple Codec {encode, decode} channel@Channel {send} =
  SDriver {sendMessage, recvMessage, startDState = Nothing}
  where
    sendMessage ::
      forall (st :: ps) (st' :: ps).
      Message ps st st' ->
      m ()
    sendMessage msg = do
      send (encode msg)

    recvMessage ::
      forall (st :: ps).
      Sig ps st ->
      Maybe LBS.ByteString ->
      m (Either CBOR.DeserialiseFailure (SomeMessage st, Maybe LBS.ByteString))
    recvMessage stok trailing = do
      decoder <- decode stok
      runDecoderWithChannel channel trailing decoder

runPeerWithDriver ::
  forall ps (st :: ps) (r :: Role) dstate m n sig a.
  ( Functor n,
    ToSig ps st,
    Has (Error CBOR.DeserialiseFailure) sig m,
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
      res <- sendM $ recvMessage toSig dstate
      case res of
        Left df -> throwError df
        Right (SomeMessage msg, dstate') -> go dstate' (k msg)
