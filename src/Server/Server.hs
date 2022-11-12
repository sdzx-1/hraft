{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.Server where

import Control.Carrier.State.Strict
import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled
import Control.Effect.Reader (Reader)
import Control.Effect.Reader.Labelled (ask)
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Network.TypedProtocol.Core

data PingPong
  = StIdle
  | StBusy
  | StDone
  | TB

instance Protocol PingPong where
  data Message PingPong from to where
    MsgPing :: Int -> Message PingPong StIdle StBusy
    MsgPong :: Int -> UTCTime -> Message PingPong StBusy StIdle
    MsgDone :: Message PingPong StIdle StDone
    MsgTBStart :: Message PingPong StIdle TB
    MsgTB :: Int -> Message PingPong TB TB
    MsgTBEnd :: Message PingPong TB StIdle

  data ClientHasAgency st where
    TokIdle :: ClientHasAgency StIdle
    TokTB :: ClientHasAgency TB

  data ServerHasAgency st where
    TokBusy :: ServerHasAgency StBusy

  data NobodyHasAgency st where
    TokDone :: NobodyHasAgency StDone

  exclusionLemma_ClientAndServerHaveAgency TokIdle tok = case tok of
  exclusionLemma_NobodyAndClientHaveAgency TokDone tok = case tok of
  exclusionLemma_NobodyAndServerHaveAgency TokDone tok = case tok of

deriving instance Show (Message PingPong from to)

instance Show (ClientHasAgency (st :: PingPong)) where
  show TokIdle = "TokIdle"

instance Show (ServerHasAgency (st :: PingPong)) where
  show TokBusy = "TokBusy"

pingPongServer ::
  forall sig m n.
  ( Has (State Int) sig m,
    Has (State [Int]) sig m,
    HasLabelledLift n sig m,
    MonadTime n
  ) =>
  Peer PingPong AsServer StIdle m ()
pingPongServer =
  Await (ClientAgency TokIdle) $ \case
    MsgDone -> Done TokDone ()
    MsgTBStart ->
      let go = Await (ClientAgency TokTB) $ \case
            MsgTB i -> Effect @m $ do
              modify (i :)
              pure go
            MsgTBEnd -> pingPongServer
       in go
    MsgPing i -> Effect $ do
      modify @Int (+ i)
      ct <- sendM getCurrentTime
      ri <- get @Int
      pure $ Yield (ServerAgency TokBusy) (MsgPong ri ct) pingPongServer

newtype RQueue n = RQueue (TQueue n Int)

pingPongClient ::
  forall n sig m.
  ( HasLabelled RQueue (Reader (RQueue n)) sig m,
    Has (State [Int]) sig m,
    HasLabelledLift n sig m,
    MonadSay n,
    MonadSTM n
  ) =>
  Peer PingPong AsClient StIdle m ()
pingPongClient =
  Effect $ do
    RQueue tq <- ask @RQueue
    i <- sendM $ atomically $ readTQueue tq
    pure $
      Yield (ClientAgency TokIdle) (MsgPing i) $
        Await (ServerAgency TokBusy) $ \(MsgPong ri ct) ->
          Effect $ do
            sendM $ say $ show (i, ct)
            if ri > 10
              then do
                sendM $ say "connect terminate"
                pure $ Yield (ClientAgency TokIdle) MsgDone (Done TokDone ())
              else
                pure $
                  Yield (ClientAgency TokIdle) MsgTBStart $
                    let go f = Effect @m $ do
                          ls <- get @[Int]
                          case ls of
                            [] -> pure $ Yield (ClientAgency TokTB) MsgTBEnd f
                            (x : xs) -> do
                              put xs
                              sendM $ say $ "client batch sync " ++ show x
                              pure $ Yield (ClientAgency TokTB) (MsgTB x) (go f)
                     in go pingPongClient
