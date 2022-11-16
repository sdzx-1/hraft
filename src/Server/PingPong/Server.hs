{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.PingPong.Server where

import Control.Carrier.State.Strict
import Control.Effect.Labelled
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Network.TypedProtocol.Core
import Server.PingPong.Type

ppServer
  :: forall m n sig
   . ( Monad n
     , MonadSay n
     , MonadTime n
     , Has (State Int) sig m
     , HasLabelledLift n sig m
     )
  => Peer PingPong Server StIdle m ()
ppServer = await $ \case
  MsgPing i -> effect $ do
    modify (+ i)
    lift $ say $ "s MsgPing " ++ show i
    i' <- get @Int
    pure $ yield (MsgPong i') ppServer
  MsgDone -> Effect $ do
    lift $ say "server done"
    pure $ done ()
