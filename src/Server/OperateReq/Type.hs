{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.OperateReq.Type where

import qualified Codec.CBOR.Decoding           as CBOR
import qualified Codec.CBOR.Encoding           as CBOR
import           Codec.Serialise                ( Serialise )
import qualified Codec.Serialise               as CBOR
import           Network.TypedProtocol.Core
import           Raft.Type

data Operate req resp
  = Idle
  | Busy
  | CDone
  | SDone

instance (Serialise req, Serialise resp) => Protocol (Operate req resp) where
    data Message (Operate req resp) from to where
        SendOp ::req -> Message (Operate req resp) Idle Busy
        SendResult ::resp -> Message (Operate req resp) Busy Idle
        MasterChange ::NodeId -> Message (Operate req resp) Busy SDone
        ClientTerminate ::Message (Operate req resp) Idle CDone
    
    data Sig (Operate req resp) st where
        SigIdle ::Sig (Operate req resp) Idle
        SigBusy ::Sig (Operate req resp) Busy
        SigCDone ::Sig (Operate req resp) CDone
        SigSDone ::Sig (Operate req resp) SDone

    type ClientAgencyList (Operate req resp) = '[Idle]
    type ServerAgencyList (Operate req resp) = '[Busy]
    type NobodyAgencyList (Operate req resp) = '[CDone , SDone]

    encode = \case
        SendOp req ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 0 <> CBOR.encode req
        SendResult resp ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 1 <> CBOR.encode resp
        MasterChange nid ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 2 <> CBOR.encode nid
        ClientTerminate -> CBOR.encodeListLen 1 <> CBOR.encodeWord 3

    decode p = do
        _   <- CBOR.decodeListLen
        key <- CBOR.decodeWord
        case (p, key) of
            (SigIdle, 0) -> SomeMessage . SendOp <$> CBOR.decode
            (SigBusy, 1) -> SomeMessage . SendResult <$> CBOR.decode
            (SigBusy, 2) -> SomeMessage . MasterChange <$> CBOR.decode
            (SigIdle, 3) -> pure $ SomeMessage ClientTerminate
            _            -> fail "codecLogin"

instance ToSig (Operate req resp) Idle where
    toSig = SigIdle

instance ToSig (Operate req resp) Busy where
    toSig = SigBusy

instance ToSig (Operate req resp) CDone where
    toSig = SigCDone

instance ToSig (Operate req resp) SDone where
    toSig = SigSDone


