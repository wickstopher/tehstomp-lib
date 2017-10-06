module Stomp.TLogger where

import Control.Concurrent
import Control.Concurrent.TxEvent
import Data.Time
import System.IO

data Logger = Logger Handle (SChan String) ThreadId (IO String -> IO String)

initLogger :: Handle -> IO Logger
initLogger handle = do
    logChannel <- sync newSChan
    tid <- forkIO $ logLoop handle logChannel
    return $ Logger handle logChannel tid id

dateTimeLogger :: Handle -> IO Logger
dateTimeLogger handle = do
    logger <- initLogger handle
    return $ addTransform timeStampTransform logger

log :: Logger -> String -> IO ()
log (Logger handle logChannel _ f) message = do
    message' <- f (return message)
    sync $ sendEvt logChannel $ message' ++ "\n"

prompt :: Logger -> String -> IO ()
prompt (Logger handle logChannel _ f) message = do
    message' <- f (return message)
    sync $ sendEvt logChannel $ message'

logLoop :: Handle -> SChan String -> IO ()
logLoop handle logChannel = do
    message <- sync $ recvEvt logChannel
    hPutStr handle message
    logLoop handle logChannel

addTransform :: (IO String -> IO String) -> Logger -> Logger
addTransform f' (Logger h c t f) = Logger h c t (f . f')

timeStampTransform :: IO String -> IO String
timeStampTransform s = do
    time <- getCurrentTime
    s' <- s
    return $ "[" ++ (show time) ++ "] " ++ s'
