module Stomp.Util where

import Data.List.Split

tokenize :: String -> String -> [String]
tokenize delimiter = filter (not . null) . splitOn delimiter