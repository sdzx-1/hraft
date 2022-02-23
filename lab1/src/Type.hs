{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Type where

import Process.HasServer
import Process.Metric
import Process.TH
import Process.Type
import Process.Util

--- coordinator
--- worker -- mapWork  reduceWork

data AskWork where
  MapWork :: ((FilePath, String) -> IO ()) -> RespVal () %1 -> AskWork
  ReduceWork :: ((String, [String]) -> IO ()) -> RespVal () %1 -> AskWork

mkSigAndClass
  "SigCoord"
  [ ''AskWork
  ]
