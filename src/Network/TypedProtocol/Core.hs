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
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

{-# HLINT ignore "Avoid lambda" #-}

module Network.TypedProtocol.Core where

import           Channel
import qualified Codec.CBOR.Decoding           as CBOR
import qualified Codec.CBOR.Encoding           as CBOR
import qualified Codec.CBOR.Read               as CBOR
import           Control.Carrier.Error.Either   ( ErrorC
                                                , runError
                                                )
import           Control.Carrier.Reader         ( ReaderC
                                                , runReader
                                                )
import           Control.Carrier.State.Strict   ( StateC
                                                , runState
                                                )
import           Control.Effect.Error
import           Control.Effect.Labelled hiding ( send )
import           Control.Effect.Reader          ( Reader )
import qualified Control.Effect.Reader.Labelled
                                               as L
import           Control.Effect.State           ( State
                                                , get
                                                , put
                                                )
import           Control.Monad.Class.MonadST    ( MonadST )
import           Control.Monad.Class.MonadThrow
import qualified Data.ByteString.Lazy          as LBS
import           Data.Kind
import           GHC.TypeLits                   ( ErrorMessage(..)
                                                , TypeError
                                                )

class Protocol ps where
  data Message ps (st :: ps) (st' :: ps)
  data Sig ps (st :: ps)
  type NobodyAgencyList ps :: [ps]
  type ClientAgencyList ps :: [ps]
  type ServerAgencyList ps :: [ps]
  encode :: Message ps (st :: ps) (st' :: ps) -> CBOR.Encoding
  decode :: Sig ps (st :: ps) -> CBOR.Decoder s (SomeMessage st)

class ToSig ps (st :: ps) where
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

data Peer ps (r :: Role) (st :: ps) m a where
  Effect ::m (Peer ps r st m a) -> Peer ps r st m a
  Done ::(Elem st (NobodyAgencyList ps)) => a -> Peer ps r st m a
  Yield ::(Elem st (YieldList r ps), ToSig ps st, ToSig ps st') => Message ps st st' -> Peer ps r st' m a -> Peer ps r st m a
  Await ::(Elem st (AwaitList r ps)) => (forall st'. Message ps st st' -> Peer ps r st' m a) -> Peer ps r st m a

deriving instance Functor m => Functor (Peer ps r (st :: ps) m)

data SomeMessage (st :: ps) where
  SomeMessage ::(ToSig ps st') => Message ps st st' -> SomeMessage st

effect :: m (Peer ps r st m a) -> Peer ps r st m a
effect = Effect

done :: Elem st (NobodyAgencyList ps) => a -> Peer ps r st m a
done = Done

yield
  :: (Elem st (YieldList r ps), ToSig ps st, ToSig ps st')
  => Message ps st st'
  -> Peer ps r (st' :: ps) m a
  -> Peer ps r (st :: ps) m a
yield = Yield

await
  :: Elem st (AwaitList r ps)
  => (forall st' . Message ps st st' -> Peer ps r (st' :: ps) m a)
  -> Peer ps r (st :: ps) m a
await = Await

data PeerError = SerialiseError CBOR.DeserialiseFailure
               | ConnectedError IOError
               deriving (Show)

data Driver ps dstate m = Driver
  { sendMessage :: forall (st :: ps) (st' :: ps) . Message ps st st' -> m ()
  , recvMessage
      :: forall (st :: ps)
       . Sig ps st
      -> dstate
      -> m (Either CBOR.DeserialiseFailure (SomeMessage st, dstate))
  }

driverSimple
  :: forall ps m
   . (Protocol ps, Monad m, MonadST m)
  => Channel m LBS.ByteString
  -> Driver ps (Maybe LBS.ByteString) m
driverSimple channel@Channel { send } = Driver { sendMessage, recvMessage }
 where
  encode' = convertCborEncoder encode
  decode' = \sig -> convertCborDecoder (decode sig)

  sendMessage :: forall (st :: ps) (st' :: ps) . Message ps st st' -> m ()
  sendMessage msg = do
    send (encode' msg)

  recvMessage
    :: forall (st :: ps)
     . Sig ps st
    -> Maybe LBS.ByteString
    -> m
         ( Either
             CBOR.DeserialiseFailure
             (SomeMessage st, Maybe LBS.ByteString)
         )
  recvMessage stok trailing = do
    decoder <- decode' stok
    runDecoderWithChannel channel trailing decoder

newtype PeerEnv n = PeerEnv {peerChannel :: Channel n LBS.ByteString}
newtype PeerState = PeerState {unUsedByteString :: Maybe LBS.ByteString} deriving (Show)


runPeer
  :: Channel n LBS.ByteString
  -> ErrorC
       PeerError
       (StateC PeerState (Labelled PeerEnv (ReaderC (PeerEnv n)) m))
       a
  -> m (PeerState, Either PeerError a)
runPeer a =
  runReader (PeerEnv a)
    . runLabelled @PeerEnv
    . runState (PeerState Nothing)
    . runError @PeerError

evalPeer
  :: forall ps (st :: ps) (r :: Role) m n sig a
   . ( ToSig ps st
     , Protocol ps
     , Monad n
     , MonadST n
     , MonadCatch n
     , HasLabelledLift n sig m
     , Has (Error PeerError) sig m
     , Has (State PeerState) sig m
     , HasLabelled PeerEnv (Reader (PeerEnv n)) sig m
     )
  => Peer ps r st m a
  -> m a
evalPeer peer = do
  PeerEnv { peerChannel } <- L.ask @PeerEnv
  let Driver { sendMessage, recvMessage } = driverSimple @ps @n peerChannel
      go
        :: forall st'
         . (ToSig ps st')
        => Maybe LBS.ByteString
        -> Peer ps r st' m a
        -> m (a, Maybe LBS.ByteString)
      go dstate (Effect k   ) = k >>= go dstate
      go dstate (Done   x   ) = return (x, dstate)
      go dstate (Yield msg k) = do
        sr <- sendM $ try @_ @IOError $ sendMessage msg
        case sr of
          Left  ie -> throwError (ConnectedError ie)
          Right _  -> pure ()
        go dstate k
      go dstate (Await k) = do
        res <- sendM $ try @_ @IOError $ recvMessage toSig dstate
        case res of
          Left  ie -> throwError (ConnectedError ie)
          Right (Left df) -> throwError (SerialiseError df)
          Right (Right (SomeMessage msg, dstate')) -> go dstate' (k msg)
  PeerState { unUsedByteString } <- get @PeerState
  (res, newUnUsedByteString)     <- go unUsedByteString peer
  put (PeerState newUnUsedByteString)
  pure res
