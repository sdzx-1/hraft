
{-# LANGUAGE TypeApplications #-}

module Server.OperateReq.Sim where

import           Channel                        ( createConnectedBufferedChannels
                                                )
import           Control.Carrier.Random.Gen     ( runRandom )
import           Control.Carrier.State.Strict
import           Control.Effect.Labelled
import           Control.Monad                  ( void )
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadTimer
import           Control.Monad.IOSim            ( runSimTrace
                                                , selectTraceEventsSay
                                                )
import           Control.Monad.Random           ( mkStdGen )
import           Network.TypedProtocol.Core     ( evalPeer
                                                , runPeer
                                                )
import           Server.OperateReq.Client       ( client )
import           Server.OperateReq.Server       ( server )

-- >>> foo
-- ["recv 46","47","recv 21","22","recv 83","84","recv 12","13","recv 15","16","recv 44","45","recv 21","22","recv 6","7","recv 82","83","recv 14","15"]
foo :: [String]
foo = selectTraceEventsSay $ runSimTrace $ do
    (cc, sc) <- createConnectedBufferedChannels 100

    void
        . forkIO
        . void
        . runLabelledLift
        . runState @Int 0
        . runPeer sc 3
        $ evalPeer server

    void
        . forkIO
        . void
        . runLabelledLift
        . runRandom (mkStdGen 10)
        . runPeer cc 3
        $ evalPeer client
    threadDelay 10
