{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Login.Client where

import           Data.Text                      ( Text )
import           Network.TypedProtocol.Core
import           Server.Login.Type

ppClient :: Text -> Text -> Peer (Login LoginReq Bool) Client UnLogin m Bool
ppClient userId pw = yield (MsgLoginReq $ LoginReq userId pw) $ await $ \case
  MsgLoginVerifyResult b -> done b
