{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import NetworkPartition
import Test.Tasty
import Test.Tasty.QuickCheck

main :: IO ()
main = do
  -- mapM_ print (runCreateAll (-96))
  defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Test Group"
    [ testProperty "verify network" runCreateAll
    ]
