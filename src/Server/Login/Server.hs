{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Login.Server where

import Control.Carrier.Reader (Reader, ask)
import Control.Effect.Labelled
import Control.Monad.Class.MonadSay
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import Network.TypedProtocol.Core
import Server.Login.Type

type User = Map Text Text

ppServer ::
  (Has (Reader User) sig m, HasLabelledLift n sig m, MonadSay n) =>
  SPeer (Login LoginReq Bool) Server UnLogin m (Maybe Text)
ppServer = await $ \case
  MsgLoginReq LoginReq {clientId, password} -> SEffect $ do
    sendM $ say $ "clientId " ++ show clientId ++ " password: " ++ show password
    userMap <- ask @User
    case Map.lookup clientId userMap of
      Nothing -> pure $ yield (MsgLoginVerifyResult False) (done Nothing)
      Just txt ->
        if txt == password
          then pure $ yield (MsgLoginVerifyResult True) (done (Just clientId))
          else pure $ yield (MsgLoginVerifyResult False) (done Nothing)
