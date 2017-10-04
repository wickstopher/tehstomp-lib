module Stomp.TLogger where

import System.IO
import Control.Concurrent
import Control.Concurrent.TxEvent

data Logger = Logger Handle (SChan String) ThreadId

initLogger :: Handle -> IO Logger
initLogger handle = do
    logChannel <- sync newSChan
    tid <- forkIO $ logLoop handle logChannel
    return $ Logger handle logChannel tid

log :: Logger -> String -> IO ()
log (Logger handle logChannel _) message = do
    sync $ sendEvt logChannel $ message ++ "\n"

prompt :: Logger -> String -> IO ()
prompt (Logger handle logChannel _) message = do
    sync $ sendEvt logChannel message

logLoop :: Handle -> (SChan String) -> IO ()
logLoop handle logChannel = do
    message <- sync $ recvEvt logChannel
    hPutStr handle message
    logLoop handle logChannel
