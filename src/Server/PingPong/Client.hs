{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.PingPong.Client where

import           Control.Effect.Labelled
import           Control.Monad.Class.MonadSay
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Network.TypedProtocol.Core
import           Server.PingPong.Type

ppClient
  :: forall n sig m
   . (MonadTime n, MonadSay n, HasLabelledLift n sig m, MonadDelay n)
  => Peer PingPong Client StIdle m ()
ppClient = yield (MsgPing 1) $ await $ \case
  MsgPong i -> effect $ do
    sendM $ say $ "c MsgPong " ++ show i
    if i > 3
      then do
        sendM $ say "client done"
        pure $ yield MsgDone (done ())
      else pure ppClient
