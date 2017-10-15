-- |The TLogger module implements a transactional logger. It is a convenient way
-- to write output to a handle in a multi-threaded context in which it is necessary to
-- provide sequential locking access to the handle. Examples of situations in which this might
-- be used is in a logfile or a command-prompt in a multi-threaded application.
module Stomp.TLogger (
    initLogger,
    dateTimeLogger,
    log,
    prompt,
    addTransform,
    Logger
) where

import Control.Concurrent
import Control.Concurrent.TxEvent
import Data.Time
import Prelude hiding (log)
import System.IO

-- |A Logger can be used to send output to its Handle. It is guaranteed to be thread-safe.
data Logger = Logger Handle (SChan String) ThreadId (IO String -> IO String)

-- |Initialize and return a logger for the given Handle.
initLogger :: Handle -> IO Logger
initLogger handle = do
    logChannel <- sync newSChan
    tid <- forkIO $ logLoop handle logChannel
    return $ Logger handle logChannel tid id -- the base transformation is the identity function

-- |Initialize and return a logger that automatically timestamps all of its messages with the 
-- current UTC time.
dateTimeLogger :: Handle -> IO Logger
dateTimeLogger handle = do
    logger <- initLogger handle
    return $ addTransform timeStampTransform logger

-- |Send a line of output to the Logger's Handle.
log :: Logger -> String -> IO ()
log (Logger handle logChannel _ f) message = do
    message' <- f (return message)
    sync $ sendEvt logChannel $ message' ++ "\n"

-- |Send output to the Logger's handle, but do not append a newline.
prompt :: Logger -> String -> IO ()
prompt (Logger handle logChannel _ f) message = do
    message' <- f (return message)
    sync $ sendEvt logChannel $ message'

-- |Get a new Logger for the same Handle as the original Logger, but with some additional String
-- transformation applied.
addTransform :: (IO String -> IO String) -> Logger -> Logger
addTransform f' (Logger h c t f) = Logger h c t (f . f')

--------------------------
-- Unexported Functions --
--------------------------

-- |This function blocks waiting for messages on the log channel. When a client calls the `log` or
-- `prompt` function, it sends an event on the channel and puts the message in the channel.
logLoop :: Handle -> SChan String -> IO ()
logLoop handle logChannel = do
    message <- sync $ recvEvt logChannel
    hPutStr handle message
    logLoop handle logChannel

-- |Transformation function to prepend a UTC timestamp to log messages.
timeStampTransform :: IO String -> IO String
timeStampTransform s = do
    time <- getCurrentTime
    s' <- s
    return $ "[" ++ (show time) ++ "] " ++ s'
