-- |The Increment module provides a stateful incrementer.
module Stomp.Increment (
    Incrementer,
    newIncrementer,
    getNext,
    getNextEvt,
    getLast,
    getLastEvt
) where

import Control.Concurrent
import Control.Concurrent.TxEvent

-- |An Incrementer maintains the state of an Integer that increases by one with each access.
data Incrementer = Incrementer (SChan Integer) (SChan Request)

data Request     = NextValue | CurrentValue

-- |Initialize a new incrementer and return it in an IO context. The first value retrieved will be 0.
newIncrementer :: IO Incrementer
newIncrementer = do
    intChan <- sync newSChan
    reqChan <- sync newSChan
    forkIO $ incrementLoop 0 intChan reqChan 
    return $ Incrementer intChan reqChan

-- |Get the next sequential Integer and return it in an IO context.
getNext :: Incrementer -> IO Integer
getNext incrementer = sync $ getNextEvt incrementer

-- |Get the next sequential Integer and return it in an Evt context.
getNextEvt :: Incrementer -> Evt Integer
getNextEvt (Incrementer intChan reqChan) = do
    sendEvt reqChan NextValue
    recvEvt intChan

-- |Get the most recent value returned by the Incrementer and return it in an IO context.
getLast :: Incrementer -> IO Integer
getLast incrementer = sync $ getLastEvt incrementer

-- |Get the most recent value returned by Incrementer and return it in an Evt context.
getLastEvt :: Incrementer -> Evt Integer
getLastEvt (Incrementer intChan reqChan) = do
    sendEvt reqChan CurrentValue
    recvEvt intChan

-- |State management for the Incrementer; blocks until it receives a corresponding recvEvt on the Integer
-- channel, send its current value, and then increments its value.
incrementLoop :: Integer -> SChan Integer -> SChan Request -> IO ()
incrementLoop value intChan reqChan = do
    value' <- sync $ incrementEvt value intChan reqChan
    incrementLoop value' intChan reqChan

-- |Looping event to handle multiple consecutive requests in the same synchronization.
incrementEvt :: Integer -> SChan Integer -> SChan Request -> Evt Integer
incrementEvt value intChan reqChan = do
    request <- recvEvt reqChan
    let value' = case request of
            NextValue    -> (value + 1)
            CurrentValue -> value
        in do
            sendEvt intChan value'
            (alwaysEvt value') `chooseEvt` (incrementEvt value' intChan reqChan)
