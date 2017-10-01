module Stomp.Frames.IO (
    parseFrame
) where

import Data.ByteString as BS
import Data.ByteString.UTF8
import Data.List.Split
import Data.Word
import Stomp.Frames
import Stomp.Util
import System.IO

parseFrame :: Handle -> IO Frame
parseFrame handle = do
    command <- parseCommand handle
    headers <- parseHeaders handle EndOfHeaders
    body    <- parseBody handle (getContentLength headers)
    return $ Frame command headers body

parseCommand :: Handle -> IO Command
parseCommand handle = do
    commandLine <- BS.hGetLine handle
    return $ stringToCommand (toString commandLine)

parseHeaders :: Handle -> Headers -> IO Headers
parseHeaders handle headers = do
    line <- stringFromHandle handle
    if line == "" then
        return headers
    else
        parseHeaders handle (addHeaderEnd (headerFromLine line) headers)

parseBody :: Handle -> Maybe Int -> IO Body
parseBody handle (Just n) = do
    bytes <- hGet handle n
    nullByte <- hGet handle 1
    return (Body bytes)
parseBody handle Nothing  = do 
    bytes <- hGet handle 1
    if bytes == (fromString "\NUL") then
        return EmptyBody
    else do
        body <- parseBodyNoContentLengthHeader handle [BS.head bytes]
        return $ Body body

parseBodyNoContentLengthHeader :: Handle -> [Word8] -> IO ByteString
parseBodyNoContentLengthHeader handle bytes = do
    byte <- hGet handle 1
    if byte == (fromString "\NUL") then
        return (BS.pack $ Prelude.reverse bytes)
    else
        parseBodyNoContentLengthHeader handle ((BS.head byte) : bytes)

headerFromLine :: String -> Header
headerFromLine line = let tokens = tokenize ":" line in
    Header (Prelude.head tokens) (Prelude.last tokens)

stringFromHandle :: Handle -> IO String
stringFromHandle handle = do
    line <- BS.hGetLine handle
    return $ toString line
