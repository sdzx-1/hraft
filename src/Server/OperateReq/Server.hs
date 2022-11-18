{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.OperateReq.Server where

import Control.Concurrent.Class.MonadSTM
import Control.Effect.Labelled
import Control.Effect.Reader (Reader)
import qualified Control.Effect.Reader.Labelled as L
import Control.Monad.Class.MonadSay
import Network.TypedProtocol.Core hiding (Role)
import Raft.Type
import Server.OperateReq.Type

data ServerEnv s output n = ServerEnv
  { role :: TVar n Role
  , userLogQueue :: TQueue n (s, TMVar n (ApplyResult output))
  }

server
  :: ( MonadSay n
     , MonadSTM n
     , Show s
     , Show output
     , HasLabelledLift n sig m
     , HasLabelled ServerEnv (Reader (ServerEnv s output n)) sig m
     )
  => Peer (Operate s output) Server Idle m ()
server = effect $ do
  ServerEnv{role, userLogQueue} <- L.ask @ServerEnv
  pure $ await $ \case
    ClientTerminate -> done ()
    SendOp i -> effect $ do
      r <- lift $ readTVarIO role
      case r of
        Candidate -> pure $ yield (MasterChange Nothing) $ done ()
        Follower jid -> case jid of
          Nothing -> pure $ yield (MasterChange Nothing) $ done ()
          Just id' -> pure $ yield (MasterChange $ Just id') $ done ()
        Leader -> do
          tmv <- lift newEmptyTMVarIO
          lift $ atomically $ writeTQueue userLogQueue (i, tmv)
          resp <- lift $ atomically $ takeTMVar tmv
          case resp of
            Success resp' -> pure $ yield (SendResult resp') $ done ()
            LeaderChange id' -> pure $ yield (MasterChange id') $ done ()
    CSendOp i -> effect $ do
      r <- lift $ readTVarIO role
      case r of
        Candidate -> pure $ yield (CMasterChange Nothing) $ done ()
        Follower jid -> case jid of
          Nothing -> do
            pure $ yield (CMasterChange Nothing) $ done ()
          Just id' -> pure $ yield (CMasterChange $ Just id') $ done ()
        Leader -> do
          tmv <- lift newEmptyTMVarIO
          lift $ atomically $ writeTQueue userLogQueue (i, tmv)
          resp <- lift $ atomically $ takeTMVar tmv
          case resp of
            Success resp' -> pure $ yield (CSendResult resp') server
            LeaderChange id' -> pure $ yield (CMasterChange id') $ done ()
