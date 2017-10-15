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

data FrameHandler = FrameHandler Handle (SChan Frame) (SChan FrameEvt) ThreadId ThreadId

data FrameEvt = NewFrame Frame | GotEof

initFrameHandler :: Handle -> IO FrameHandler
initFrameHandler handle = do
    writeChannel <- sync newSChan
    readChannel  <- sync newSChan
    wTid <- forkIO $ frameWriterLoop handle writeChannel
    rTid <- forkIO $ frameReaderLoop handle readChannel
    return $ FrameHandler handle writeChannel readChannel wTid rTid

put :: FrameHandler -> Frame -> IO ()
put (FrameHandler _ writeChannel _ _ _) frame = do
    sync $ sendEvt writeChannel frame

get :: FrameHandler -> IO FrameEvt
get (FrameHandler _ _ readChannel _ _) = do
    frame <- sync $ recvEvt readChannel
    return frame

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
    frame <- parseFrame handle
    case frame of 
        Just f  -> do
            sync $ sendEvt readChannel (NewFrame f)
            frameReaderLoop handle readChannel
        Nothing -> do
            sync $ sendEvt readChannel GotEof
            return ()

parseFrame :: Handle -> IO (Maybe Frame)
parseFrame handle = do
    command <- parseCommand handle
    case command of
        Just c  -> addHeaders handle c
        Nothing -> return Nothing

addHeaders :: Handle -> Command -> IO (Maybe Frame)
addHeaders handle command = do
    headers <- parseHeaders handle EndOfHeaders
    case headers of
        Just h  -> addBody handle command h
        Nothing -> return Nothing

addBody :: Handle -> Command -> Headers -> IO (Maybe Frame)
addBody handle command headers = do
    body <- parseBody handle (getContentLength headers)
    case body of
        Just b  -> return $ Just (Frame command headers b)
        Nothing -> return Nothing

parseCommand :: Handle -> IO (Maybe Command)
parseCommand handle = do
    eof <- hIsEOF handle
    if eof then
        return Nothing
    else do
        commandLine <- BS.hGetLine handle
        return $ stringToCommand (toString commandLine)

parseHeaders :: Handle -> Headers -> IO (Maybe Headers)
parseHeaders handle headers = do
    eof <- hIsEOF handle
    if eof then
        return Nothing
    else do
        line <- stringFromHandle handle
        if line == "" then
            return $ Just headers
        else
            parseHeaders handle (addHeaderEnd (headerFromLine line) headers)

parseBody :: Handle -> Maybe Int -> IO (Maybe Body)
parseBody handle (Just n) = do
    eof <- hIsEOF handle
    if eof then
        return Nothing
    else do 
        bytes <- hGet handle n
        nullByte <- hGet handle 1
        return $ Just (Body bytes)
parseBody handle Nothing  = do 
    eof <- hIsEOF handle
    if eof then
        return Nothing
    else do
        bytes <- hGet handle 1
        if bytes == (fromString "\NUL") then
            return $ Just EmptyBody
        else do
            body <- parseBodyNoContentLengthHeader handle [BS.head bytes]
            case body of
                Just body -> return $ Just (Body body)
                Nothing   -> return Nothing

parseBodyNoContentLengthHeader :: Handle -> [Word8] -> IO (Maybe ByteString)
parseBodyNoContentLengthHeader handle bytes = do
    eof <- hIsEOF handle
    if eof then
        return Nothing
    else do
        byte <- hGet handle 1
        if byte == (fromString "\NUL") then
            return $ Just (BS.pack $ Prelude.reverse bytes)
        else
            parseBodyNoContentLengthHeader handle ((BS.head byte) : bytes)

headerFromLine :: String -> Header
headerFromLine line = let tokens = tokenize ":" line in
    Header (Prelude.head tokens) (Prelude.last tokens)

stringFromHandle :: Handle -> IO String
stringFromHandle handle = do
    line <- BS.hGetLine handle
    return $ toString line
