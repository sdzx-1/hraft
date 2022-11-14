{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Login.Server where

import Network.TypedProtocol.Core
import Server.Login.Type

ppServer :: SPeer (Login req resp) Server UnLogin m ()
ppServer = await $ \case
  MsgLoginReq res -> undefined
