{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.PingPong.Type where

import qualified Codec.CBOR.Decoding           as CBOR
import qualified Codec.CBOR.Encoding           as CBOR
import qualified Codec.Serialise               as CBOR
import           Network.TypedProtocol.Core

data PingPong
  = StIdle
  | StBusy
  | StDone

instance Protocol PingPong where
  data Message PingPong from to where
    MsgPing ::Int -> Message PingPong StIdle StBusy
    MsgPong ::Int -> Message PingPong StBusy StIdle
    MsgDone ::Message PingPong StIdle StDone
  
  data Sig PingPong st where
    SigStIdle ::Sig PingPong StIdle
    SigStBusy ::Sig PingPong StBusy
    SigStDone ::Sig PingPong StDone

  type ClientAgencyList PingPong = '[ 'StIdle]
  type ServerAgencyList PingPong = '[ 'StBusy]
  type NobodyAgencyList PingPong = '[ 'StDone]

  encode x = case x of
    MsgPing i -> CBOR.encodeListLen 2 <> CBOR.encodeWord 0 <> CBOR.encode i
    MsgPong i -> CBOR.encodeListLen 2 <> CBOR.encodeWord 1 <> CBOR.encode i
    MsgDone   -> CBOR.encodeListLen 1 <> CBOR.encodeWord 2

  decode p = do
    _   <- CBOR.decodeListLen
    key <- CBOR.decodeWord
    case (p, key) of
      (SigStIdle, 0) -> SomeMessage . MsgPing <$> CBOR.decode
      (SigStBusy, 1) -> SomeMessage . MsgPong <$> CBOR.decode
      (SigStIdle, 2) -> pure (SomeMessage MsgDone)
      _              -> fail "codecPingPong error"

instance ToSig PingPong StIdle where
  toSig = SigStIdle

instance ToSig PingPong StBusy where
  toSig = SigStBusy

instance ToSig PingPong StDone where
  toSig = SigStDone
