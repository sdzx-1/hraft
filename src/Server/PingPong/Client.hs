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
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}

module Server.PingPong.Client where

import Channel (socketAsChannel)
import qualified Codec.CBOR.Read as CBOR
import Control.Carrier.Error.Either (runError)
import Control.Carrier.State.Strict
import Control.Effect.Labelled
import qualified Control.Exception as E
import Control.Monad (void)
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Network.Socket
import Network.TypedProtocol.Core
import Server.PingPong.Type

ppClient ::
  forall n sig m.
  ( Monad n,
    MonadTime n,
    MonadSay n,
    HasLabelledLift n sig m,
    Has (State Int) sig m,
    MonadDelay n
  ) =>
  SPeer PingPong Client StIdle m ()
ppClient = yield (MsgPing 1) $
  await $ \case
    MsgPong i -> SEffect $ do
      sendM $ say $ "c MsgPong " ++ show i
      if i > 3
        then do
          sendM $ say "client done"
          pure $ yield MsgDone (done ())
        else pure ppClient

main :: IO ()
main = runTCPClient "127.0.0.1" "3000" $ \sc -> do
  void
    . runLabelledLift
    . runState @Int 0
    . runError @CBOR.DeserialiseFailure
    $ runPeerWithDriver (driverSimple pingPongCodec (socketAsChannel sc)) ppClient Nothing

runTCPClient :: HostName -> ServiceName -> (Socket -> IO a) -> IO a
runTCPClient host port client = withSocketsDo $ do
  addr <- resolve
  E.bracket (open addr) close client
  where
    resolve = do
      let hints = defaultHints {addrSocketType = Stream}
      head <$> getAddrInfo (Just hints) (Just host) (Just port)
    open addr = E.bracketOnError (openSocket addr) close $ \sock -> do
      connect sock $ addrAddress addr
      return sock
