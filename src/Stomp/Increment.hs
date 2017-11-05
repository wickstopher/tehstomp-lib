module Stomp.Increment (
    Incrementer,
    newIncrementer,
    getNext
) where

import Control.Concurrent
import Control.Concurrent.TxEvent

data Incrementer = Incrementer (SChan Integer)

newIncrementer :: IO Incrementer
newIncrementer = do
    channel <- sync newSChan
    forkIO $ incrementLoop 0 channel
    return $ Incrementer channel

incrementLoop :: Integer -> SChan Integer -> IO ()
incrementLoop value channel = do
    sync $ sendEvt channel value
    incrementLoop (value + 1) channel

getNext :: Incrementer -> IO Integer
getNext (Incrementer channel) = sync $ recvEvt channel
