{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
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

module Server.Client where

import Channel (socketAsChannel)
import qualified Codec.CBOR.Read as CBOR
import Control.Carrier.Error.Either (runError, throwError)
import Control.Effect.Labelled
import qualified Control.Exception as E
import Control.Monad (unless, void)
import qualified Data.Text as T
import Network.Socket
import Network.TypedProtocol.Core
import qualified Server.Login.Client as Login
import Server.Login.Type
import qualified Server.PingPong.Client as PingPong
import Server.PingPong.Type

main :: IO ()
main = runTCPClient "127.0.0.1" "3000" $ \sc -> do
  void
    . runLabelledLift
    . runError @CBOR.DeserialiseFailure
    . runError @()
    $ do
      let loginDriver = driverSimple loginCodec (socketAsChannel sc)
      userId <- sendM $ do
        putStrLn "input userId"
        T.pack <$> getLine
      pw <- sendM $ do
        putStrLn "input password"
        T.pack <$> getLine
      (b, st) <- runPeerWithDriver loginDriver (Login.ppClient userId pw) Nothing
      unless b $ throwError ()
      let pingPongDriver = driverSimple pingPongCodec (socketAsChannel sc)
      runPeerWithDriver pingPongDriver PingPong.ppClient st

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