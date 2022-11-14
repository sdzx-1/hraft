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

import Channel (socketAsChannel)
import qualified Codec.CBOR.Read as CBOR
import Control.Carrier.Error.Either (runError)
import Control.Carrier.State.Strict
import Control.Concurrent (forkFinally)
import Control.Effect.Labelled
import qualified Control.Exception as E
import Control.Monad (forever, void)
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Network.Socket
import Network.TypedProtocol.Core
import Server.PingPong.Type

ppServer ::
  forall m n sig.
  ( Monad n,
    MonadSay n,
    MonadTime n,
    Has (State Int) sig m,
    HasLabelledLift n sig m
  ) =>
  SPeer PingPong Server StIdle m ()
ppServer = await $ \case
  MsgPing i -> SEffect $ do
    modify (+ i)
    sendM $ say $ "s MsgPing " ++ show i
    i' <- get @Int
    pure $
      yield (MsgPong i') ppServer
  MsgDone -> SEffect $ do
    sendM $ say "server done"
    pure $ done ()

main :: IO ()
main = runTCPServer Nothing "3000" foo
  where
    foo sc =
      void
        . runLabelledLift
        . runState @Int 0
        . runError @CBOR.DeserialiseFailure
        $ runPeerWithDriver (driverSimple pingPongCodec (socketAsChannel sc)) ppServer Nothing

runTCPServer :: Maybe HostName -> ServiceName -> (Socket -> IO a) -> IO a
runTCPServer mhost port server = withSocketsDo $ do
  addr <- resolve
  E.bracket (open addr) close loop
  where
    resolve = do
      let hints =
            defaultHints
              { addrFlags = [AI_PASSIVE],
                addrSocketType = Stream
              }
      head <$> getAddrInfo (Just hints) mhost (Just port)
    open addr = E.bracketOnError (openSocket addr) close $ \sock -> do
      setSocketOption sock ReuseAddr 1
      withFdSocket sock setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      listen sock 1024
      return sock
    loop sock = forever $
      E.bracketOnError (accept sock) (close . fst) $
        \(conn, _peer) ->
          void $
            forkFinally (server conn) (const $ gracefulClose conn 5000)
