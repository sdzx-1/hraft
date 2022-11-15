{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# HLINT ignore "Avoid lambda" #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Login.Type where

import qualified Codec.CBOR.Decoding           as CBOR
import qualified Codec.CBOR.Encoding           as CBOR
import           Codec.Serialise                ( Serialise )
import qualified Codec.Serialise               as CBOR
import           Data.Text                      ( Text )
import           GHC.Generics                   ( Generic )
import           Network.TypedProtocol.Core

data Login req resp
  = UnLogin
  | Verify
  | VDone

instance (Serialise req, Serialise resp) => Protocol (Login req resp) where
  data Message (Login req resp) from to where
    MsgLoginReq ::req -> Message (Login req resp) UnLogin Verify
    MsgLoginVerifyResult ::resp -> Message (Login req resp) Verify VDone
  
  data Sig (Login req resp) st where
    SigUnLogin ::Sig (Login req resp) UnLogin
    SigVerify ::Sig (Login req resp) Verify
    SigVDone ::Sig (Login req resp) VDone

  type ClientAgencyList (Login req resp) = '[ 'UnLogin]
  type ServerAgencyList (Login req resp) = '[ 'Verify]
  type NobodyAgencyList (Login req resp) = '[ 'VDone]

  encode = \case
    MsgLoginReq req ->
      CBOR.encodeListLen 2 <> CBOR.encodeWord 0 <> CBOR.encode req
    MsgLoginVerifyResult resp ->
      CBOR.encodeListLen 2 <> CBOR.encodeWord 1 <> CBOR.encode resp

  decode p = do
    _   <- CBOR.decodeListLen
    key <- CBOR.decodeWord
    case (p, key) of
      (SigUnLogin, 0) -> SomeMessage . MsgLoginReq <$> CBOR.decode
      (SigVerify , 1) -> SomeMessage . MsgLoginVerifyResult <$> CBOR.decode
      _               -> fail "codecLogin"

instance ToSig (Login req resp) UnLogin where
  toSig = SigUnLogin

instance ToSig (Login req resp) Verify where
  toSig = SigVerify

instance ToSig (Login req resp) VDone where
  toSig = SigVDone

data LoginReq = LoginReq
  { clientId :: Text
  , password :: Text
  }
  deriving (Show, Generic, Serialise)
