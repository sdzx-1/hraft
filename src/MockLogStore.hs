{-# LANGUAGE NamedFieldPuns #-}

module MockLogStore where

import Data.List (foldl')
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import Data.Vector (Vector, generate, (!), (//))
import GHC.Stack (HasCallStack)

type Index = Int

type RowIndex = Int

type ColumIndex = Int

data LogStore log = LogStore
  { vectorSize :: Int,
    currentIndex :: !Index,
    store :: Map RowIndex (Vector log)
  }
  deriving (Show)

class Def a where
  def :: a

emptyLogStore :: LogStore a
emptyLogStore = LogStore 20 (-1) Map.empty

appendLog :: Def log => log -> LogStore log -> LogStore log
appendLog log' logStore@LogStore {vectorSize, currentIndex, store} =
  let newIndex = currentIndex + 1
      (row, column) = newIndex `divMod` vectorSize
   in case Map.lookup row store of
        Nothing ->
          let vec = generate vectorSize (const def)
              newVec = vec // [(column, log')]
              newStore = Map.insert row newVec store
           in logStore {currentIndex = newIndex, store = newStore}
        Just v ->
          let newVec = v // [(column, log')]
              newStore = Map.insert row newVec store
           in logStore {currentIndex = newIndex, store = newStore}

data W
  = OneRow RowIndex ColumIndex ColumIndex
  | MultRow (RowIndex, ColumIndex) [RowIndex] (RowIndex, ColumIndex)

readLogs :: (HasCallStack, Show log) => Index -> Index -> LogStore log -> [log]
readLogs start end LogStore {vectorSize, currentIndex, store}
  | start > currentIndex || end > currentIndex || start > end = []
  | otherwise =
    let (startRow, startCol) = start `divMod` vectorSize
        (endRow, endCol) = end `divMod` vectorSize
        w =
          if startRow == endRow
            then OneRow startRow startCol endCol
            else MultRow (startRow, startCol) [startRow + 1 .. endRow - 1] (endRow, endCol)
        getRow row indexs =
          map
            ( fromMaybe
                ( error $
                    "undefined behave, "
                      ++ show ((start, end), (row, indexs), currentIndex, store)
                )
                (Map.lookup row store)
                !
            )
            indexs
     in case w of
          OneRow r s e -> getRow r [s .. e]
          MultRow (sRow, sCol) cx (eRow, eCol) ->
            let sRowLogs = getRow sRow [sCol .. vectorSize - 1]
                cxRowLogs = concatMap (\r -> getRow r [0 .. vectorSize -1]) cx
                eRowLogs = getRow eRow [0 .. eCol]
             in concat [sRowLogs, cxRowLogs, eRowLogs]

removeLogs :: Index -> LogStore log -> LogStore log
removeLogs index logStore@LogStore {vectorSize, currentIndex, store}
  | index > currentIndex || index < 0 = logStore
  | otherwise =
    let indexRow = index `div` vectorSize
        currRow = currentIndex `div` vectorSize
     in if indexRow == currRow
          then logStore {currentIndex = index - 1}
          else
            let rows = [indexRow + 1 .. currRow]
                newStore = foldl' (flip Map.delete) store rows
             in logStore {currentIndex = index - 1, store = newStore}

instance Def Int where
  def = -1
