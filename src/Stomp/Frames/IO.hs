module Stomp.Frames.IO (
    FrameHandler,
    FrameEvt(..),
    initFrameHandler,
    put,
    get,
    close
) where

import Data.ByteString as BS
import Data.ByteString.UTF8
import Control.Concurrent
import Control.Concurrent.TxEvent
import Data.List.Split
import Data.Word
import Stomp.Frames hiding (addHeaders)
import Stomp.Util
import System.IO

-- |A FrameHandler encapsulates the work of sending and receiving frames on a Handle (e.g.) a
-- Handle to a TCP socket connection to a STOMP client or broker).
data FrameHandler = FrameHandler Handle (SChan Frame) (SChan FrameEvt) ThreadId ThreadId

-- |A FrameEvt is a type of event that can be received from a FrameHandler. It is either a NewFrame,
-- representing that a Frame was successfully read from the Channel
data FrameEvt = NewFrame Frame |
                ParseError String |
                GotEof


-- |Given a resource Handle to which STOMP frames will be read from and written to, initializes a FrameHandler 
-- and returns it to the caller.
initFrameHandler :: Handle -> IO FrameHandler
initFrameHandler handle = do
    writeChannel <- sync newSChan
    readChannel  <- sync newSChan
    wTid <- forkIO $ frameWriterLoop handle writeChannel
    rTid <- forkIO $ frameReaderLoop handle readChannel
    return $ FrameHandler handle writeChannel readChannel wTid rTid

-- |Puts the given Frame into the given FrameHandler. This function will block until the Frame has been processed.
put :: FrameHandler -> Frame -> IO ()
put (FrameHandler _ writeChannel _ _ _) frame = do
    sync $ sendEvt writeChannel frame

-- |Get a FrameEvt from the given FrameHandler. This function will block until a Frame is available, or until some error
-- has occurred.
get :: FrameHandler -> IO FrameEvt
get (FrameHandler _ _ readChannel _ _) = do
    frame <- sync $ recvEvt readChannel
    return frame

-- |Closes tha handle and kills all threads associated with the FrameHandler.
close :: FrameHandler -> IO ()
close (FrameHandler handle _ _ wTid rTid) = do
    hClose handle
    killThread wTid
    killThread rTid

frameWriterLoop :: Handle -> SChan Frame -> IO ()
frameWriterLoop handle writeChannel = do
    frame <- sync $ recvEvt writeChannel
    hPut handle $ frameToBytes frame
    frameWriterLoop handle writeChannel

frameReaderLoop :: Handle -> SChan FrameEvt -> IO ()
frameReaderLoop handle readChannel = do
    evt <- parseFrame handle
    sync $ sendEvt readChannel evt
    case evt of 
        NewFrame _ -> frameReaderLoop handle readChannel
        otherwise  -> return ()

parseFrame :: Handle -> IO FrameEvt
parseFrame handle = do
    command <- parseCommand handle
    case command of
        Left c    -> addHeaders handle c
        Right evt -> return evt

parseCommand :: Handle -> IO (Either Command FrameEvt)
parseCommand handle = do
    eof <- hIsEOF handle
    if eof then
        return $ Right GotEof
    else do
        commandLine <- BS.hGetLine handle
        return $ stringToCommand (toString commandLine)

addHeaders :: Handle -> Command -> IO FrameEvt
addHeaders handle command = do
    headers <- parseHeaders handle EndOfHeaders
    case headers of
        Left h    -> addBody handle command h
        Right evt -> return evt

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

addBody :: Handle -> Command -> Headers -> IO FrameEvt
addBody handle command headers = do
    body <- parseBody handle (getContentLength headers)
    case body of
        Left b    -> return (NewFrame $ Frame command headers b)
        Right evt -> return evt

parseBody :: Handle -> Maybe Int -> IO (Either Body FrameEvt)
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

parseBodyNoContentLengthHeader :: Handle -> [Word8] -> IO (Either ByteString FrameEvt)
parseBodyNoContentLengthHeader handle bytes = do
    eof <- hIsEOF handle
    if eof then
        return $ Right GotEof
    else do
        byte <- hGet handle 1
        if byte == (fromString "\NUL") then
            return $ Left (BS.pack $ Prelude.reverse bytes)
        else
            parseBodyNoContentLengthHeader handle ((BS.head byte) : bytes)

headerFromLine :: String -> Either Header FrameEvt
headerFromLine line = let tokens = tokenize ":" line in
    if (Prelude.length tokens) == 2 then
        Left $ Header (Prelude.head tokens) (Prelude.last tokens)
    else
        Right $ ParseError $ "Malformed header: " ++ line

stringFromHandle :: Handle -> IO String
stringFromHandle handle = do
    line <- BS.hGetLine handle
    return $ toString line

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
stringToCommand s             = Right $ ParseError $ "Malformed command: " ++ s
