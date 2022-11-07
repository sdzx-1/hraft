{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Handler
import Test.Tasty
import Test.Tasty.QuickCheck

main :: IO ()
main = do
  defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Test Group"
    [ testProperty "verify store log consistency" prop_store_log,
      testProperty "verify election success term inc" prop_election_success,
      testProperty "commit log never change" prop_commit_log_never_change
    ]
