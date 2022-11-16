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
  | CBusy
  | CDone
  | SDone

instance (Serialise req, Serialise resp) => Protocol (Operate req resp) where
    data Message (Operate req resp) from to where
        SendOp ::req -> Message (Operate req resp) Idle Busy
        SendResult ::resp -> Message (Operate req resp) Busy CDone
        MasterChange ::NodeId -> Message (Operate req resp) Busy SDone
        CSendOp ::req -> Message (Operate req resp) Idle CBusy
        CSendResult ::resp -> Message (Operate req resp) CBusy Idle
        CMasterChange ::NodeId -> Message (Operate req resp) CBusy SDone
    
    data Sig (Operate req resp) st where
        SigIdle ::Sig (Operate req resp) Idle
        SigBusy ::Sig (Operate req resp) Busy
        SigCBusy ::Sig (Operate req resp) CBusy
        SigCDone ::Sig (Operate req resp) CDone
        SigSDone ::Sig (Operate req resp) SDone

    type ClientAgencyList (Operate req resp) = '[Idle]
    type ServerAgencyList (Operate req resp) = '[Busy, CBusy]
    type NobodyAgencyList (Operate req resp) = '[CDone , SDone]

    encode = \case
        SendOp req ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 0 <> CBOR.encode req
        SendResult resp ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 1 <> CBOR.encode resp
        MasterChange nid ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 2 <> CBOR.encode nid
        CSendOp req ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 3 <> CBOR.encode req
        CSendResult resp ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 4 <> CBOR.encode resp
        CMasterChange nid ->
            CBOR.encodeListLen 2 <> CBOR.encodeWord 5 <> CBOR.encode nid

    decode p = do
        _   <- CBOR.decodeListLen
        key <- CBOR.decodeWord
        case (p, key) of
            (SigIdle , 0) -> SomeMessage . SendOp <$> CBOR.decode
            (SigBusy , 1) -> SomeMessage . SendResult <$> CBOR.decode
            (SigBusy , 2) -> SomeMessage . MasterChange <$> CBOR.decode
            (SigIdle , 3) -> SomeMessage . CSendOp <$> CBOR.decode
            (SigCBusy, 4) -> SomeMessage . CSendResult <$> CBOR.decode
            (SigCBusy, 5) -> SomeMessage . CMasterChange <$> CBOR.decode
            _             -> fail "codecLogin"

instance ToSig (Operate req resp) Idle where
    toSig = SigIdle

instance ToSig (Operate req resp) Busy where
    toSig = SigBusy

instance ToSig (Operate req resp) CBusy where
    toSig = SigCBusy

instance ToSig (Operate req resp) CDone where
    toSig = SigCDone

instance ToSig (Operate req resp) SDone where
    toSig = SigSDone


