{-# LANGUAGE TypeApplications #-}

module Server.PingPong.SimExample where

import           Channel                        ( createConnectedBufferedChannels
                                                )
import qualified Codec.CBOR.Read               as CBOR
import           Control.Carrier.Error.Either
import           Control.Carrier.State.Strict
import           Control.Effect.Labelled
import           Control.Monad                  ( void )
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadTimer
import           Control.Monad.IOSim            ( runSimTrace
                                                , selectTraceEventsSay
                                                )
import           Network.TypedProtocol.Core     ( runPeerWithDriver )
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
    . runError @CBOR.DeserialiseFailure
    $ runPeerWithDriver sc ppServer Nothing

  void
    . forkIO
    . void
    . runLabelledLift
    . runState @Int 0
    . runError @CBOR.DeserialiseFailure
    $ runPeerWithDriver cc ppClient Nothing
  threadDelay 10
