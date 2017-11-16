-- |The Increment module provides a stateful incrementer.
module Stomp.Increment (
    Incrementer,
    newIncrementer,
    getNext,
    getNextEvt
) where

import Control.Concurrent
import Control.Concurrent.TxEvent

-- |An Incrementer maintains the state of an Integer that increases by one with each access.
data Incrementer = Incrementer (SChan Integer)

-- |Initialize a new incrementer and return it in an IO context. The first value retrieved will be 0.
newIncrementer :: IO Incrementer
newIncrementer = do
    channel <- sync newSChan
    forkIO $ incrementLoop 0 channel
    return $ Incrementer channel

-- |Get the next sequential Integer and return it in an IO context.
getNext :: Incrementer -> IO Integer
getNext incrementer = sync $ getNextEvt incrementer

-- |Get the next sequential Integer and return it in an Evt context.
getNextEvt :: Incrementer -> Evt Integer
getNextEvt (Incrementer channel) = recvEvt channel

-- |State management for the Incrementer; blocks until it receives a corresponding recvEvt on the Integer
-- channel, send its current value, and then increments its value.
incrementLoop :: Integer -> SChan Integer -> IO ()
incrementLoop value channel = do
    sync $ sendEvt channel value
    incrementLoop (value + 1) channel
