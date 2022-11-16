{-# LANGUAGE AllowAmbiguousTypes #-}
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

module Server.Server where

import           Channel                        ( socketAsChannel )
import           Control.Carrier.Error.Either   ( runError
                                                , throwError
                                                )
import           Control.Carrier.Reader         ( runReader )
import           Control.Carrier.State.Strict
import           Control.Concurrent             ( forkFinally )
import           Control.Effect.Labelled
import qualified Control.Exception             as E
import           Control.Monad                  ( forever
                                                , void
                                                )
import           Data.Map                       ( Map )
import qualified Data.Map                      as Map
import           Data.Text                      ( Text )
import           Network.Socket
import           Network.TypedProtocol.Core
import qualified Server.Login.Server           as Login
import qualified Server.PingPong.Server        as PingPong


main :: IO ()
main = runTCPServer Nothing "3000" foo
  where
    foo sc =
        void
            . runLabelledLift
            . runReader @(Map Text Text) (Map.fromList [("sdzx", "1")])
            . runState @Int 0
            . runPeer (socketAsChannel sc) 3
            . runError @()
            $ do
                  m_userId <- evalPeer Login.ppServer
                  case m_userId of
                      Nothing -> do
                          lift $ putStrLn "login failed, terminate connect."
                          throwError ()
                      Just _userId -> do
                          evalPeer PingPong.ppServer

runTCPServer :: Maybe HostName -> ServiceName -> (Socket -> IO a) -> IO a
runTCPServer mhost port server = withSocketsDo $ do
    addr <- resolve
    E.bracket (open addr) close loop
  where
    resolve = do
        let
            hints = defaultHints { addrFlags      = [AI_PASSIVE]
                                 , addrSocketType = Stream
                                 }
        head <$> getAddrInfo (Just hints) mhost (Just port)
    open addr = E.bracketOnError (openSocket addr) close $ \sock -> do
        setSocketOption sock ReuseAddr 1
        withFdSocket sock setCloseOnExecIfNeeded
        bind sock $ addrAddress addr
        listen sock 1024
        return sock
    loop sock =
        forever
            $ E.bracketOnError (accept sock) (close . fst)
            $ \(conn, _peer) -> void $ forkFinally
                  (server conn)
                  (const $ gracefulClose conn 5000)
