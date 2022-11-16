{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.OperateReq.Client where
import           Control.Carrier.Random.Gen
import           Control.Effect.Labelled
import           Control.Monad.Class.MonadSay
import           Network.TypedProtocol.Core
import           Raft.Type
import           Server.OperateReq.Type


client
    :: (MonadSay n, Has Random sig m, HasLabelledLift n sig m)
    => Peer (Operate Int Int) Client Idle m (Maybe NodeId)
client = effect $ do
    ri <- uniformR (0, 100)
    if ri > 89
        then pure $ yield ClientTerminate $ done Nothing
        else pure $ yield (SendOp ri) $ await $ \case
            SendResult i -> effect $ do
                sendM $ say $ show i
                pure client
            MasterChange nid -> done (Just nid)
