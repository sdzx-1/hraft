{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.OperateReq.Client where

import Control.Effect.Labelled
import Control.Monad.Class.MonadSay
import Network.TypedProtocol.Core
import Raft.Type
import Server.OperateReq.Type

client
  :: ( MonadSay n
     , HasLabelledLift n sig m
     )
  => Int
  -> Peer (Operate Int (Int, Int)) Client Idle m (Either (Maybe Id) (Int, Int))
client reqI = yield (SendOp reqI) $
  await $ \case
    SendResult i -> effect $ do
      lift $ say $ "client recv " ++ show i
      lift $ say "client done"
      pure (done (Right i))
    MasterChange nid -> done (Left nid)
