{-# LANGUAGE TypeApplications #-}

module Server.PingPong.SimExample where

import           Channel                        ( createConnectedBufferedChannels
                                                )
import           Control.Carrier.Error.Either
import           Control.Carrier.State.Strict
import           Control.Effect.Labelled
import           Control.Monad                  ( void )
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadTimer
import           Control.Monad.IOSim            ( runSimTrace
                                                , selectTraceEventsSay
                                                )
import           Network.TypedProtocol.Core     ( PeerError
                                                , runPeerWithDriver
                                                )
import           Server.PingPong.Client         ( ppClient )
import           Server.PingPong.Server         ( ppServer )

-- >>> foo
-- ["s MsgPing 1","c MsgPong 1","s MsgPing 1","c MsgPong 2","s MsgPing 1","c MsgPong 3","s MsgPing 1","c MsgPong 4","client done","server done"]
foo :: [String]
foo = selectTraceEventsSay $ runSimTrace $ do
  (cc, sc) <- createConnectedBufferedChannels 100

  void
    . forkIO
    . void
    . runLabelledLift
    . runState @Int 0
    . runError @PeerError
    $ runPeerWithDriver sc ppServer Nothing

  void
    . forkIO
    . void
    . runLabelledLift
    . runState @Int 0
    . runError @PeerError
    $ runPeerWithDriver cc ppClient Nothing
  threadDelay 10
