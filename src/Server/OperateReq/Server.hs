{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.OperateReq.Server where
import           Control.Effect.Labelled
import           Control.Monad.Class.MonadSay
import           Network.TypedProtocol.Core
import           Raft.Type
import           Server.OperateReq.Type

server
    :: (MonadSay n, HasLabelledLift n sig m)
    => Peer (Operate Int Int) Server Idle m ()
server = await $ \case
    SendOp i -> effect $ do
        sendM $ say $ "server recv " ++ show i
        let changeMaster = False
        if changeMaster
            then pure $ yield (MasterChange (NodeId 1)) $ done ()
            else do
                sendM $ say $ "server resp " ++ show (i + 1)
                pure $ yield (SendResult (i + 1)) $ effect $ do
                    sendM $ say "server done"
                    pure $ done ()
