{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main
  ( main
  ) where

import           FaultsTest
import           Test.Tasty
import           Test.Tasty.QuickCheck

main :: IO ()
main = do
  defaultMain tests

tests :: TestTree
tests = testGroup
  "verify faults"
  [ testProperty "commit log must replicate more than half of the servers"
                 prop_commit_log_replicate
  , testProperty "election term doesn't come up more than once"
                 prop_election_success_term
  , testProperty "commit log never change" prop_commit_log_never_change
  ]
