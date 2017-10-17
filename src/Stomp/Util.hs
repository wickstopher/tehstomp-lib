-- |The Util module exports convenience functions from the Stomp library.
module Stomp.Util (
    tokenize
)
where

import Data.List.Split

-- |Given a delimiter and a String, return a list of the tokens in the String given
-- by splitting on that delimiter.
tokenize :: String -> String -> [String]
tokenize delimiter = filter (not . null) . splitOn delimiter