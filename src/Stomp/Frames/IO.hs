-- |The IO module of the Frames package encapsulates error-handling IO operations on 
-- Handles that are expected to be receiving STOMP frames.
module Stomp.Frames.IO (
    FrameHandler,
    FrameEvt(..),
    initFrameHandler,
    put,
    putEvt,
    get,
    getEvt,
    getEvtWithTimeOut,
    close,
    frameToBytes,
    updateHeartbeat
) where

import Control.Concurrent
import Control.Concurrent.TxEvent
import Control.Exception
import Data.ByteString as BS
import Data.ByteString.Char8 as Char8
import Data.ByteString.UTF8 as UTF
import Data.List.Split
import Data.Word
import Stomp.Frames hiding (addHeaders)
import Stomp.Util
import System.IO

-- |A FrameHandler encapsulates the work of sending and receiving frames on a Handle. In most cases,
-- this will be a Handle to a TCP socket connection in a STOMP client or broker.
data FrameHandler = FrameHandler Handle (SChan SendEvt) (SChan FrameEvt) ThreadId ThreadId

-- |A FrameEvt is a type of event that can be received from a FrameHandler (see the get function). 
data FrameEvt = NewFrame Frame |
                ParseError String |
                Heartbeat |
                GotEof |
                TimedOut deriving Show

-- |A SendEvt is a type of event that can be sent to a FrameHandler. This datatype is used internally
-- to the module only.
data SendEvt  = SendFrame Frame |
                UpdateHeartbeat Int |
                DoHeartbeat


-- |Given a resource Handle to which STOMP frames will be read from and written to, initializes a FrameHandler 
-- and returns it to the caller.
initFrameHandler :: Handle -> IO FrameHandler
initFrameHandler handle = do
    writeChannel <- sync newSChan
    readChannel  <- sync newSChan
    wTid <- forkIO $ frameWriterLoop handle 0 writeChannel
    rTid <- forkIO $ frameReaderLoop handle readChannel
    return $ FrameHandler handle writeChannel readChannel wTid rTid

-- |Puts the given Frame into the given FrameHandler in an IO context.
-- This function will block until the Frame has been processed.
put :: FrameHandler -> Frame -> IO ()
put frameHandler frame = do
    sync $ putEvt frame frameHandler

-- |Puts the given Frame into the FrameHandler in an Evt context.
putEvt :: Frame -> FrameHandler -> Evt ()
putEvt frame (FrameHandler _ writeChannel _ _ _) = sendEvt writeChannel $ SendFrame frame

-- |Update the rate at which this FrameHandler sends heart-beats. A rate of 0 or less means that 
-- no heart-beats will be transmitted. Otherwise, we will send one heart-beat every n microseconds.
updateHeartbeat :: FrameHandler -> Int -> IO ()
updateHeartbeat (FrameHandler _ writeChannel _ _ _) n = sync $ sendEvt writeChannel (UpdateHeartbeat n)

-- |Get the next FrameEvt from the given FrameHandler and return it in an IO context. 
-- This function will block until a FrameEvt is available.
get :: FrameHandler -> IO FrameEvt
get frameHandler = do
    sync $ getEvt frameHandler

-- |Get the next FrameEvt from the given FrameHandler and return it in an Evt context.
getEvt :: FrameHandler -> Evt FrameEvt
getEvt (FrameHandler _ _ readChannel _ _) = recvEvt readChannel

-- |Get the next FrameEvt from the given FrameHandler and return it an Evt context. If the given
-- timeout (in microseconds) is exceeded prior to receiving activity on the channel, this will
-- return TimedOut.
getEvtWithTimeOut :: FrameHandler -> Int -> Evt FrameEvt
getEvtWithTimeOut (FrameHandler _ _ readChannel _ _) timeOut = 
    if timeOut < 1 then
        recvEvt readChannel
    else
        (recvEvt readChannel) `chooseEvt` (timeOutEvt timeOut `thenEvt` (\_ -> alwaysEvt TimedOut))

-- |Kills all threads associated with the FrameHandler.
close :: FrameHandler -> IO ()
close (FrameHandler _ _ _ wTid rTid) = do
    killThread wTid
    killThread rTid

-- |Convert a Frame to a STOMP protocol adherent ByteString suitable for transmission over a handle.
frameToBytes :: Frame -> ByteString
frameToBytes (Frame c h b) = 
    BS.append (Char8.snoc (UTF.fromString $ show c) '\n')
        (Char8.snoc (append (UTF.fromString $ show h) (bodyToBytes b)) '\NUL')

-- |Loops waiting for Frames to write out to the Handle. The `put` function in this module sends Frames on
-- the SChan, and we use event synchronization to ensure that no more than one Frame at a time is sent
-- to the Handle. If there is value for the heartbeat greater than 0, a heart-beat will be sent every n
-- microseconds that pass without any activity.
frameWriterLoop :: Handle -> Int -> SChan SendEvt -> IO ()
frameWriterLoop handle heartbeat writeChannel = do
    update <- if heartbeat < 1 
        then sync $ recvEvt writeChannel
        else sync $ (recvEvt writeChannel) `chooseEvt` (timeOutEvt heartbeat `thenEvt` (\_ -> alwaysEvt DoHeartbeat))
    case update of
        SendFrame frame -> do
            hPut handle $ frameToBytes frame
            frameWriterLoop handle heartbeat writeChannel
        UpdateHeartbeat n -> do
            hPut handle $ UTF.fromString "\n"
            frameWriterLoop handle n writeChannel
        DoHeartbeat       -> do
            hPut handle $ UTF.fromString "\n"
            frameWriterLoop handle heartbeat writeChannel


-- |Loops as data is received from the handle and parses out frames. The loop blocks until a frame is read from the
-- FrameHandler using the `get` functions. If there is an error (e.g. an EOF received or an issue in parsing) the loop 
-- is terminated.
frameReaderLoop :: Handle -> SChan FrameEvt -> IO ()
frameReaderLoop handle readChannel = do
    evt <- parseFrameWithExceptionHandling handle
    sync $ sendEvt readChannel evt
    case evt of 
        NewFrame _ -> frameReaderLoop handle readChannel
        Heartbeat  -> frameReaderLoop handle readChannel
        otherwise  -> return ()

parseFrameWithExceptionHandling :: Handle -> IO FrameEvt
parseFrameWithExceptionHandling handle = do
    result <- try (parseFrame handle) :: IO (Either SomeException FrameEvt)
    case result of
        Left exception -> return GotEof
        Right frameEvt -> return frameEvt

-- |Parse a frame out of a Handle and return a FrameEvt to the caller.
parseFrame :: Handle -> IO FrameEvt
parseFrame handle = do
    command <- parseCommand handle
    case command of
        Left c    -> addHeaders handle c
        Right evt -> return evt

-- |Parse the Command portion of a Frame out of a Handle. If no errors are encountered while the
-- Command is being parsed, we return a Left Either containing the Command. A Right Either containing
-- a FrameEvt indicates that either a heartbeat was received from the client or that an error occurred.
parseCommand :: Handle -> IO (Either Command FrameEvt)
parseCommand handle = do
    eof <- hIsEOF handle
    if eof then
        return $ Right GotEof
    else do
        commandLine <- BS.hGetLine handle
        return $ stringToCommand (toString commandLine)

-- |Given a Handle and a Command that has been parsed, parse and add the Headers from the Handle.
addHeaders :: Handle -> Command -> IO FrameEvt
addHeaders handle command = do
    headers <- parseHeaders handle EndOfHeaders
    case headers of
        Left h    -> addBody handle command h
        Right evt -> return evt

-- |Parse the Headers portion of a Frame out of a Handle. If no errors are encountered while the
-- Headers are being parsed, we return a Left Either containing the Headers. A Right Either containing
-- a FrameEvt indicates an error.
parseHeaders :: Handle -> Headers -> IO (Either Headers FrameEvt)
parseHeaders handle headers = do
    eof <- hIsEOF handle
    if eof then
        return $ Right GotEof
    else do
        line <- stringFromHandle handle
        if line == "" then
            return $ Left headers
        else case headerFromLine line of
            Left h -> parseHeaders handle (addHeaderEnd h headers)
            Right evt -> return $ Right evt

-- |Given a Handle, a Command, and a set of Headers that have been parsed, parse and add the Body from
-- the Handle. This function constructs the new Frame object and returns the NewFrame FrameEvt in the
-- success case, or returns the appropriate FrameEvt in the error case.
addBody :: Handle -> Command -> Headers -> IO FrameEvt
addBody handle command headers = do
    body <- parseBody handle (getContentLength headers)
    case body of
        Left b    -> return (NewFrame $ Frame command headers b)
        Right evt -> return evt

-- |Parse the Body porition of a Frame out of a Handle. If no errors are encountered while the
-- Body is being parsed, we return a Left Either containig a Body. A Right Either containing a
-- FrameEvt indicates an error.
parseBody :: Handle -> Maybe Int -> IO (Either Body FrameEvt)
-- This is the case in which we know the length of the body content
parseBody handle (Just n) = do
    eof <- hIsEOF handle
    if eof then
        return $ Right GotEof
    else do 
        bytes <- hGet handle n
        nullByte <- hGet handle 1
        if nullByte /= (fromString "\NUL") then
            return $ Right $ ParseError $ "Read " ++ (show n) ++ " bytes, and the subsequent byte was not NUL"
        else
            return $ Left (Body bytes)
parseBody handle Nothing  = do 
-- This is the case in which we do not know the length of the body
    eof <- hIsEOF handle
    if eof then
        return $ Right GotEof
    else do
        bytes <- hGet handle 1
        if bytes == (fromString "\NUL") then
            return $ Left EmptyBody
        else do
            bodyBytes <- parseBodyNoContentLengthHeader handle [BS.head bytes]
            case bodyBytes of
                Left byteString -> return $ Left (Body byteString)
                Right evt       -> return $ Right evt

-- |Parse the Body portion of a Frame out of a Handle. This function reads the body byte-by-byte
-- and is to be used in the absenece of a content-length header. It should be initialized with a
-- singleton Word8 list containing the first (non-NUL) byte read from the Handle after the 
-- Headers have been read. It is then called recursively until a NUL byte is received. If no 
-- errors are encountered while the Body is read, we return a Left Either containing a ByteString.
-- A Right Either containing a FrameEvt indicates an error.
parseBodyNoContentLengthHeader :: Handle -> [Word8] -> IO (Either ByteString FrameEvt)
parseBodyNoContentLengthHeader handle bytes = do
    eof <- hIsEOF handle
    if eof then
        return $ Right GotEof
    else do
        byte <- hGet handle 1
        if byte == (fromString "\NUL") then
            -- This is an efficiency hack; note that when the list is constructed we use the "cons" (:)
            -- operator to append to the list to avoid an O(n) operation for each append. As such, the list
            -- needs to be reversed once we have finished constructing it.
            return $ Left (BS.pack $ Prelude.reverse bytes)
        else
            parseBodyNoContentLengthHeader handle ((BS.head byte) : bytes)

-- |Parse a Header from a String. If the no errors are encountered while the Header is parsed, we
-- return a Left Either containing a Header. A Right Either containing a FrameEvt indicates an error.
headerFromLine :: String -> Either Header FrameEvt
headerFromLine line = let tokens = tokenize ":" line in
    if (Prelude.length tokens) == 2 then
        Left $ Header (Prelude.head tokens) (Prelude.last tokens)
    else
        Right $ ParseError $ "Malformed header: " ++ line

-- |Read a line of Bytes from the given handle, and return it as a String.
stringFromHandle :: Handle -> IO String
stringFromHandle handle = do
    line <- BS.hGetLine handle
    return $ toString line

-- |Parse a Command from a String. If no errors are encountered while the Command is parsed, we
-- return a Left Either containint a Command. A Right Either containing a FrameEvt indicates either
-- a heartbeat was received instead of a frame, or an error occurred.
stringToCommand :: String -> Either Command FrameEvt
stringToCommand "SEND"        = Left SEND
stringToCommand "SUBSCRIBE"   = Left SUBSCRIBE
stringToCommand "UNSUBSCRIBE" = Left UNSUBSCRIBE
stringToCommand "BEGIN"       = Left BEGIN
stringToCommand "COMMIT"      = Left COMMIT
stringToCommand "ABORT"       = Left ABORT
stringToCommand "ACK"         = Left ACK
stringToCommand "NACK"        = Left NACK
stringToCommand "DISCONNECT"  = Left DISCONNECT
stringToCommand "CONNECT"     = Left CONNECT
stringToCommand "CONNECTED"   = Left CONNECTED
stringToCommand "MESSAGE"     = Left MESSAGE
stringToCommand "RECEIPT"     = Left RECEIPT
stringToCommand "ERROR"       = Left ERROR
stringToCommand ""            = Right Heartbeat
stringToCommand s             = Right $ ParseError $ "Malformed command: " ++ s

-- |Convert a Body to bytes. Helper function for `frameToBytes`
bodyToBytes :: Body -> ByteString
bodyToBytes EmptyBody = UTF.fromString ""
bodyToBytes (Body bs) = bs
