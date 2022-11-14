{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# HLINT ignore "Avoid lambda" #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Login.Type where

import Channel (convertCborDecoder, convertCborEncoder)
import qualified Codec.CBOR.Decoding as CBOR
import qualified Codec.CBOR.Encoding as CBOR
import Codec.Serialise (Serialise)
import qualified Codec.Serialise as CBOR
import Control.Monad.Class.MonadST (MonadST)
import Data.Text (Text)
import GHC.Generics (Generic)
import Network.TypedProtocol.Core

data Login req resp
  = UnLogin
  | Verify
  | VDone

instance Protocol (Login req resp) where
  data Message (Login req resp) from to where
    MsgLoginReq :: req -> Message (Login req resp) UnLogin Verify
    MsgLoginVerifyResult :: resp -> Message (Login req resp) Verify VDone

  data Sig (Login req resp) st where
    SigUnLogin :: Sig (Login req resp) UnLogin
    SigVerify :: Sig (Login req resp) Verify
    SigVDone :: Sig (Login req resp) VDone

  type ClientAgencyList (Login req resp) = '[ 'UnLogin]
  type ServerAgencyList (Login req resp) = '[ 'Verify]
  type NobodyAgencyList (Login req resp) = '[ 'VDone]

instance ToSig (Login req resp) UnLogin where
  toSig = SigUnLogin

instance ToSig (Login req resp) Verify where
  toSig = SigVerify

instance ToSig (Login req resp) VDone where
  toSig = SigVDone

encodeMsg ::
  ( CBOR.Serialise req,
    CBOR.Serialise resp
  ) =>
  Message (Login req resp) st st' ->
  CBOR.Encoding
encodeMsg x = case x of
  MsgLoginReq req ->
    CBOR.encodeListLen 2 <> CBOR.encodeWord 0 <> CBOR.encode req
  MsgLoginVerifyResult resp ->
    CBOR.encodeListLen 2 <> CBOR.encodeWord 1 <> CBOR.encode resp

decodeMsg ::
  ( CBOR.Serialise req,
    CBOR.Serialise resp
  ) =>
  Sig (Login req resp) st ->
  CBOR.Decoder s (SomeMessage st)
decodeMsg p = do
  _ <- CBOR.decodeListLen
  key <- CBOR.decodeWord
  case (p, key) of
    (SigUnLogin, 0) -> SomeMessage . MsgLoginReq <$> CBOR.decode
    (SigVerify, 1) -> SomeMessage . MsgLoginVerifyResult <$> CBOR.decode
    _ -> fail "codecLogin"

loginCodec ::
  forall m req resp.
  ( CBOR.Serialise req,
    CBOR.Serialise resp,
    MonadST m
  ) =>
  Codec (Login req resp) m
loginCodec =
  Codec
    { encode = convertCborEncoder encodeMsg,
      decode = \sig -> convertCborDecoder (decodeMsg sig)
    }

data LoginReq = LoginReq
  { clientId :: Text,
    password :: Text
  }
  deriving (Show, Generic, Serialise)
