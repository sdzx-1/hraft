{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

{-# HLINT ignore "Avoid lambda" #-}

module Server.PingPong.Type where

import Channel
import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.Serialise as CBOR
import Control.Monad.Class.MonadST (MonadST)
import Network.TypedProtocol.Core

data PingPong
  = StIdle
  | StBusy
  | StDone

instance Protocol PingPong where
  data Message PingPong from to where
    MsgPing :: Int -> Message PingPong StIdle StBusy
    MsgPong :: Int -> Message PingPong StBusy StIdle
    MsgDone :: Message PingPong StIdle StDone

  data Sig PingPong st where
    SigStIdle :: Sig PingPong StIdle
    SigStBusy :: Sig PingPong StBusy
    SigStDone :: Sig PingPong StDone

  type ClientAgencyList PingPong = '[ 'StIdle]
  type ServerAgencyList PingPong = '[ 'StBusy]
  type NobodyAgencyList PingPong = '[ 'StDone]

instance ToSig PingPong StIdle where
  toSig = SigStIdle

instance ToSig PingPong StBusy where
  toSig = SigStBusy

instance ToSig PingPong StDone where
  toSig = SigStDone

encodeMsg :: Message PingPong st st' -> CBOR.Encoding
encodeMsg x = case x of
  MsgPing i ->
    CBOR.encodeListLen 2 <> CBOR.encodeWord 0 <> CBOR.encode i
  MsgPong i ->
    CBOR.encodeListLen 2 <> CBOR.encodeWord 1 <> CBOR.encode i
  MsgDone ->
    CBOR.encodeListLen 1 <> CBOR.encodeWord 2

decodeMsg :: Sig PingPong st -> CBOR.Decoder s (SomeMessage st)
decodeMsg p = do
  _ <- CBOR.decodeListLen
  key <- CBOR.decodeWord
  case (p, key) of
    (SigStIdle, 0) -> SomeMessage . MsgPing <$> CBOR.decode
    (SigStBusy, 1) -> SomeMessage . MsgPong <$> CBOR.decode
    (SigStIdle, 2) -> pure (SomeMessage MsgDone)
    _ -> fail "codecPingPong error"

pingPongCodec :: forall m. MonadST m => Codec PingPong m
pingPongCodec =
  Codec
    { encode = convertCborEncoder encodeMsg,
      decode = \sig -> convertCborDecoder (decodeMsg sig)
    }
