module Animate.Type where

import Data.Time hiding (getCurrentTime)
import Graphics.Gloss
import Control.Monad.Class.MonadTime

main :: IO ()
main =
  animate
    (InWindow "Nice Window" (800, 800) (10, 10))
    white
    pc

pc :: Float -> Picture
pc t =
  pictures
    [ translate (sin (2 * t) * 60) (cos (2 * t) * 60) (circle 10)
    , translate (sin (2 * t) * 60) (cos (2 * t) * 60) (text "a")
    , text (show t)
    , circle 10
    ]

-- >>> show startUTCTime
-- "1970-01-01 00:00:00 UTC"
startUTCTime :: UTCTime
startUTCTime = UTCTime (ModifiedJulianDay 40587) 0

-- >>> f
-- 1668779903.476206972s
f :: IO NominalDiffTime
f = do 
    ct <- getCurrentTime
    pure $ diffUTCTime ct startUTCTime
