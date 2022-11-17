{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Utils where

import Control.Concurrent.Class.MonadSTM
import Control.Monad.Class.MonadTime
import Control.Parallel.Strategies
import Data.Time (
  defaultTimeLocale,
  formatTime,
 )
import GHC.Generics
import GHC.Stack (HasCallStack)
import MockLogStore (LogStore)
import qualified MockLogStore as M
import Raft.Type

data Persistent log m = Persistent
  { currentTermTVar :: TVar m Term
  , votedForTVar :: TVar m (Maybe Id)
  , logStore :: TVar m (LogStore (TermWarpper log))
  }

initPersisten :: MonadSTM m => m (Persistent log m)
initPersisten = do
  a <- newTVarIO 0
  b <- newTVarIO Nothing
  c <- newTVarIO M.emptyLogStore
  pure (Persistent a b c)

instance M.Def a => M.Def (TermWarpper a) where
  def = TermWarpper (-1) M.def

getPart :: ([a], [a]) -> [(a, a)]
getPart (xs, ys) = [(x, y) | x <- xs, y <- ys]

createPersistentFun
  :: (MonadSTM m, M.Def log, Show log, HasCallStack)
  => Persistent log m
  -> PersistentFun log m
createPersistentFun Persistent{currentTermTVar, votedForTVar, logStore} =
  PersistentFun
    { readCurrentTerm = readTVarIO currentTermTVar
    , writeCurrentTermAndVotedFor = \a b -> atomically $ do
        writeTVar currentTermTVar a
        writeTVar votedForTVar b
    , ---------
      readVotedFor = readTVarIO votedForTVar
    , -- writeVotedFor = atomically . writeTVar votedForTVar,
      ---------
      appendLog = \tlog -> atomically $ do
        oldLS <- readTVar logStore
        writeTVar logStore (M.appendLog tlog oldLS)
        pure (M.currentIndex oldLS + 2)
    , removeLogs = \index -> atomically $ do
        oldLS <- readTVar logStore
        writeTVar logStore (M.removeLogs (index - 1) oldLS)
    , ---------
      readLog = \index -> do
        oldLS <- readTVarIO logStore
        let [v] = M.readLogs (index - 1) (index - 1) oldLS
        pure $ if index == 0 then TermWarpper 0 undefined else v
    , readLogs = \startIndex endIndex -> do
        oldLS <- readTVarIO logStore
        let vs = zip [startIndex .. endIndex] $ M.readLogs (startIndex - 1) (endIndex - 1) oldLS
        pure vs
    , persisLastLogIndexAndTerm = do
        oldLS <- readTVarIO logStore
        let index = M.currentIndex oldLS
            [TermWarpper term _] = M.readLogs index index oldLS
        pure (index + 1, if index == (-1) then 0 else term)
    , getAllLogs = do
        oldLS <- readTVarIO logStore
        let index = M.currentIndex oldLS
        case index of
          -1 -> pure []
          _ -> pure $ M.readLogs 0 index oldLS
    , ---------
      checkAppendentries = \index term -> do
        if index == 0 && term == 0
          then pure True
          else do
            oldLS <- readTVarIO logStore
            case M.readLogs (index - 1) (index - 1) oldLS of
              [] -> pure False
              [TermWarpper pterm _] ->
                pure (term == pterm)
              _ -> error "undefined behave"
    , checkEntry = \index term -> do
        oldLS <- readTVarIO logStore
        let currentIndex = M.currentIndex oldLS
        if (index - 1) > currentIndex
          then pure Null
          else do
            let [TermWarpper pterm _] =
                  M.readLogs (index - 1) (index - 1) oldLS
            if pterm == term then pure Exis else pure Diff
    }

data IdWrapper a = IdWrapper Id a
  deriving (Eq, Generic, NFData)

instance Show a => Show (IdWrapper a) where
  show (IdWrapper nid a) = show nid ++ ": " ++ show a

ft' :: [(a, a)] -> [a] -> [(a, a)]
ft' rs [] = rs
ft' rs (a : xs) = ft' (rs ++ [(a, b) | b <- xs]) xs

ft :: [a] -> [(a, a)]
ft = ft' []

data NetworkChange
  = NetworkChange
      UTCTime
      ([Int], [Int])
      DiffTime
      [(NodeId, Term, Index, [TermWarpper Int])]
  deriving (Eq, Generic, NFData)

renderUTCTime :: UTCTime -> String
renderUTCTime ct = s'
  where
    s = formatTime defaultTimeLocale "%S%Q" ct
    len = length s
    s' = if len < 7 then s ++ replicate (7 - len) ' ' else take 7 s

instance Show NetworkChange where
  show (NetworkChange ct (a, b) dt c) =
    "====================================================\n"
      ++ unlines (map (\v -> "|| " ++ show v) c)
      ++ "== "
      ++ renderUTCTime ct
      ++ " NECONFIG_CHNAGE "
      ++ show (a, b)
      ++ " "
      ++ show dt
      ++ "\n"

data NodeRestart = NodeRestart UTCTime [NodeId] DiffTime
  deriving (Eq, Generic, NFData)

instance Show NodeRestart where
  show (NodeRestart ct ids dt) =
    "   " ++ renderUTCTime ct ++ " NodeRestart " ++ show ids ++ " " ++ show dt

type CommitIndex = Int

type LastAppliedIndex = Int

data NTracer a
  = N1 (IdWrapper (IdWrapper (RecvTracer a)))
  | N2 (IdWrapper (HandleTracer a))
  | N3 [(NodeId, CommitIndex, LastAppliedIndex, [TermWarpper Int])]
  | N4 NetworkChange
  | N5 NodeRestart
  deriving (Eq, Generic, NFData)

instance Show a => Show (NTracer a) where
  show (N1 (IdWrapper i1 (IdWrapper i2 rt))) =
    show i1 ++ " <- " ++ show i2 ++ ": " ++ show rt
  show (N2 (IdWrapper i1 ht)) = show i1 ++ ": " ++ show ht
  show (N3 rs) =
    concatMap
      ( \(nid, commitIndex, lastApplied, logStore) ->
          concat
            [ show nid
            , ", "
            , show commitIndex
            , ","
            , show lastApplied
            , ","
            , show logStore
            ]
            ++ "\n"
      )
      rs
  show (N4 v) = show v
  show (N5 v) = show v
