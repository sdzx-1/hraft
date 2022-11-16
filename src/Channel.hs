{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Channel where

import qualified Codec.CBOR.Decoding as CBOR (
  Decoder,
 )
import qualified Codec.CBOR.Encoding as CBOR (
  Encoding,
 )
import qualified Codec.CBOR.Read as CBOR
import qualified Codec.CBOR.Write as CBOR
import Control.Concurrent.Class.MonadSTM
import Control.Monad (
  forever,
  mfilter,
 )
import Control.Monad.Class.MonadFork
import Control.Monad.Class.MonadST
import Control.Monad.Class.MonadSay
import Control.Monad.Class.MonadTime
import Control.Monad.Class.MonadTimer
import Control.Monad.ST
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Builder.Extra as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Internal as LBS (
  smallChunkSize,
 )
import Data.Text.Internal.Lazy (smallChunkSize)
import GHC.Natural
import Network.Socket (Socket)
import qualified Network.Socket.ByteString.Lazy as Socket

data Channel m a = Channel
  { send :: a -> m ()
  , recv :: m (Maybe a)
  }

{- | Transform a channel to add an extra action before /every/ send and after
 /every/ receive.
-}
channelEffect
  :: forall m a
   . Monad m
  => (a -> m ())
  -- ^ Action before 'send'
  -> (Maybe a -> m ())
  -- ^ Action after 'recv'
  -> Channel m a
  -> Channel m a
channelEffect beforeSend afterRecv Channel{send, recv} =
  Channel
    { send = \x -> do
        beforeSend x
        send x
    , recv = do
        mx <- recv
        afterRecv mx
        return mx
    }

{- | Delay a channel on the receiver end.

 This is intended for testing, as a crude approximation of network delays.
 More accurate models along these lines are of course possible.
-}
delayChannel :: MonadTimer m => DiffTime -> Channel m a -> Channel m a
delayChannel delay = channelEffect (\_ -> return ()) (\_ -> threadDelay delay)

-- | Channel which logs sent and received messages.
loggingChannel
  :: (MonadSay m, Show id, Show a) => id -> Channel m a -> Channel m a
loggingChannel ident Channel{send, recv} =
  Channel
    { send = loggingSend
    , recv = loggingRecv
    }
  where
    loggingSend a = do
      say (show ident ++ ":send:" ++ show a)
      send a

    loggingRecv = do
      msg <- recv
      case msg of
        Nothing -> return ()
        Just a -> say (show ident ++ ":recv:" ++ show a)
      return msg

socketAsChannel :: Socket -> Channel IO LBS.ByteString
socketAsChannel sock = Channel{..}
  where
    send :: LBS.ByteString -> IO ()
    send = Socket.sendAll sock

    recv :: IO (Maybe LBS.ByteString)
    recv =
      mfilter (not . LBS.null) . pure
        <$> Socket.recv
          sock
          (fromIntegral smallChunkSize)

createConnectedBufferedChannels
  :: MonadSTM m => Natural -> m (Channel m a, Channel m a)
createConnectedBufferedChannels sz = do
  -- Create two TBQueues to act as the channel buffers (one for each
  -- direction) and use them to make both ends of a bidirectional channel
  bufferA <- atomically $ newTBQueue sz
  bufferB <- atomically $ newTBQueue sz

  return (queuesAsChannel bufferB bufferA, queuesAsChannel bufferA bufferB)
  where
    queuesAsChannel bufferRead bufferWrite = Channel{send, recv}
      where
        send x = atomically (writeTBQueue bufferWrite x)
        recv = atomically (Just <$> readTBQueue bufferRead)

data ConnectedState
  = Disconnectd
  | Connected
  deriving (Show)

createConnectedBufferedChannelsWithDelay
  :: (MonadSTM m, MonadFork m, MonadDelay m, Monoid a)
  => TVar m ConnectedState
  -> DiffTime
  -> Natural
  -> m (Channel m a, Channel m a)
createConnectedBufferedChannelsWithDelay connStateTVar dt sz = do
  -- Create two TBQueues to act as the channel buffers (one for each
  -- direction) and use them to make both ends of a bidirectional channel
  bufferA <- atomically $ newTBQueue sz
  bufferA' <- atomically newTQueue

  bufferB <- atomically $ newTBQueue sz
  bufferB' <- atomically newTQueue

  _ <- forkIO $ syncQueueThread bufferA bufferA'
  _ <- forkIO $ syncQueueThread bufferB bufferB'

  return (queuesAsChannel bufferB' bufferA, queuesAsChannel bufferA' bufferB)
  where
    queuesAsChannel bufferRead bufferWrite = Channel{send, recv}
      where
        send x = atomically (writeTBQueue bufferWrite x)
        recv = atomically (Just <$> readTQueue bufferRead)

    syncQueueThread tbq tq = forever $ do
      oneVal <- atomically $ readTBQueue tbq
      threadDelay dt
      rs <- go tbq
      let newRs = mconcat (oneVal : rs)
      res <- readTVarIO connStateTVar
      case res of
        Disconnectd -> pure ()
        Connected -> atomically $ writeTQueue tq newRs
      where
        go tbq' = do
          t <- atomically $ isEmptyTBQueue tbq'
          if t
            then pure []
            else do
              v <- atomically $ readTBQueue tbq'
              vs <- go tbq'
              pure (v : vs)

data DecodeStep bytes failure m a
  = DecodePartial
      ( Maybe bytes
        -> m (DecodeStep bytes failure m a)
      )
  | DecodeDone a (Maybe bytes)
  | DecodeFail failure

runDecoderWithChannel
  :: Monad m
  => Channel m bytes
  -> Maybe bytes
  -> DecodeStep bytes failure m a
  -> m (Either failure (a, Maybe bytes))
runDecoderWithChannel Channel{recv} = go
  where
    go _ (DecodeDone x trailing) = return (Right (x, trailing))
    go _ (DecodeFail failure) = return (Left failure)
    go Nothing (DecodePartial k) = recv >>= k >>= go Nothing
    go (Just trailing) (DecodePartial k) = k (Just trailing) >>= go Nothing

{-# NOINLINE toLazyByteString #-}
toLazyByteString :: BS.Builder -> LBS.ByteString
toLazyByteString = BS.toLazyByteStringWith strategy LBS.empty
  where
    strategy = BS.untrimmedStrategy 800 LBS.smallChunkSize

convertCborDecoderLBS
  :: forall s m a
   . Monad m
  => CBOR.Decoder s a
  -> (forall b. ST s b -> m b)
  -> m (DecodeStep LBS.ByteString CBOR.DeserialiseFailure m a)
convertCborDecoderLBS cborDecode sendMST =
  go []
    =<< sendMST (CBOR.deserialiseIncremental cborDecode)
  where
    go
      :: [BS.ByteString]
      -> CBOR.IDecode s a
      -> m (DecodeStep LBS.ByteString CBOR.DeserialiseFailure m a)
    go [] (CBOR.Done trailing _ x)
      | BS.null trailing = return (DecodeDone x Nothing)
      | otherwise = return (DecodeDone x (Just trailing'))
      where
        trailing' = LBS.fromStrict trailing
    go cs (CBOR.Done trailing _ x) = return (DecodeDone x (Just trailing'))
      where
        trailing' = LBS.fromChunks (trailing : cs)
    go _ (CBOR.Fail _ _ e) = return (DecodeFail e)
    go (c : cs) (CBOR.Partial k) = go cs =<< sendMST (k (Just c))
    go [] (CBOR.Partial k) = return $
      DecodePartial $ \case
        Nothing -> go [] =<< sendMST (k Nothing)
        Just bs -> go cs (CBOR.Partial k) where cs = LBS.toChunks bs

convertCborEncoder :: (a -> CBOR.Encoding) -> a -> LBS.ByteString
convertCborEncoder cborEncode = toLazyByteString . CBOR.toBuilder . cborEncode

convertCborDecoder
  :: MonadST m
  => (forall s. CBOR.Decoder s a)
  -> m (DecodeStep LBS.ByteString CBOR.DeserialiseFailure m a)
convertCborDecoder cborDecode = withLiftST (convertCborDecoderLBS cborDecode)
