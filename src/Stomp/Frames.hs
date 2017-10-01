module Stomp.Frames where

import Data.ByteString as BS
import Data.ByteString.Char8 as Char8
import Data.ByteString.UTF8 as UTF
import Stomp.Util

data Header         =   Header HeaderName HeaderValue
data Headers        =   Some Header Headers | EndOfHeaders
type HeaderName     =   String
type HeaderValue    =   String

data Body           =   EmptyBody | Body ByteString

data Command        =   SEND |
                        SUBSCRIBE |
                        UNSUBSCRIBE |
                        BEGIN |
                        COMMIT |
                        ABORT |
                        ACK |
                        NACK |
                        DISCONNECT |
                        CONNECT |
                        STOMP |
                        CONNECTED |
                        MESSAGE |
                        RECEIPT |
                        ERROR deriving Show

data Frame          =   Frame Command Headers Body

instance Show Header where
    show (Header headerName headerValue) = headerName ++ ":" ++ headerValue

instance Show Headers where
    show EndOfHeaders = "\n"
    show (Some header headers) = show header ++ "\n" ++ show headers

instance Show Body where
    show EmptyBody = ""
    show (Body s)  = show s

bodyToBytes :: Body -> ByteString
bodyToBytes EmptyBody = UTF.fromString ""
bodyToBytes (Body bs) = bs

instance Show Frame where
    show (Frame c h b) = show c ++ "\n" ++ show h ++ show b ++ "\NUL"

frameToBytes :: Frame -> ByteString
frameToBytes (Frame c h b) = 
    BS.append (Char8.snoc (UTF.fromString $ show c) '\n')
        (Char8.snoc (append (UTF.fromString $ show h) (bodyToBytes b)) '\NUL')

stringToCommand :: String -> Command
stringToCommand "SEND"        = SEND
stringToCommand "SUBSCRIBE"   = SUBSCRIBE
stringToCommand "UNSUBSCRIBE" = UNSUBSCRIBE
stringToCommand "BEGIN"       = BEGIN
stringToCommand "COMMIT"      = COMMIT
stringToCommand "ABORT"       = ABORT
stringToCommand "ACK"         = ACK
stringToCommand "NACK"        = NACK
stringToCommand "DISCONNECT"  = DISCONNECT
stringToCommand "CONNECT"     = CONNECT
stringToCommand "MESSAGE"     = MESSAGE
stringToCommand "RECEIPT"     = RECEIPT
stringToCommand "ERROR"       = ERROR

-- Header utility functions

makeHeaders :: [Header] -> Headers
makeHeaders []     = EndOfHeaders
makeHeaders (x:xs) = Some x (makeHeaders xs)

addHeaderEnd :: Header -> Headers -> Headers
addHeaderEnd newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderEnd newHeader (Some h hs)  = Some h (addHeaderEnd newHeader hs)

addHeaderFront :: Header -> Headers -> Headers
addHeaderFront newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderFront newHeader (Some h hs)  = Some newHeader (addHeaderFront h hs)

addHeaderAfter :: HeaderName -> Header -> Headers -> Headers
addHeaderAfter name newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderAfter n1 newHeader (Some h@(Header n2 _) hs)
    | n1 == n2   = Some h (addHeaderFront newHeader hs)
    | otherwise  = Some h (addHeaderAfter n1 newHeader hs)

addFrameHeaderEnd :: Header -> Frame -> Frame
addFrameHeaderEnd header (Frame c h b) = Frame c (addHeaderEnd header h) b

addFrameHeaderFront :: Header -> Frame -> Frame
addFrameHeaderFront header (Frame c h b) = Frame c (addHeaderFront header h) b

addFrameHeaderAfter :: HeaderName -> Header -> Frame -> Frame
addFrameHeaderAfter name header (Frame c h b) = Frame c (addHeaderAfter name header h) b

addHeaders :: Headers -> Headers -> Headers
addHeaders headers EndOfHeaders = headers
addHeaders headers (Some h hs)  = (Some h (addHeaders headers hs))

addFrameHeaders :: Headers -> Frame -> Frame
addFrameHeaders h1 (Frame c h2 b) = Frame c (addHeaders h2 h1) b

getContentLength :: Headers -> Maybe Int
getContentLength EndOfHeaders                         = Nothing
getContentLength (Some (Header "content-length" n) _) = Just (read n)
getContentLength (Some _ headers)                     = getContentLength headers

getSupportedVersions :: Frame -> Maybe [String]
getSupportedVersions (Frame _ h _) = getVersionsFromHeaders h

getVersionsFromHeaders :: Headers -> Maybe [String]
getVersionsFromHeaders EndOfHeaders                                = Nothing
getVersionsFromHeaders (Some (Header "accept-version" versions) _) = Just (tokenize "," versions)
getVersionsFromHeaders (Some _ headers)                            = getVersionsFromHeaders headers

-- Frame utility functions

textFrame :: String -> Command -> Frame
textFrame message command = let encoding = (UTF.fromString message) in
    Frame command 
          (makeHeaders [plainTextContentHeader, contentLengthHeader encoding])
          (Body encoding)


-- Convenience functions to create various concrete headers

stompHeaders ::  String -> Headers
stompHeaders host = makeHeaders [Header "accept-version" "1.2", Header "host" host]

versionHeader :: Header
versionHeader = Header "version" "1.2"

plainTextContentHeader :: Header
plainTextContentHeader = Header "content-type" "text/plain"

contentLengthHeader :: ByteString -> Header
contentLengthHeader s = Header "content-length" (show $ UTF.length s)

destinationHeader :: String -> Header
destinationHeader s = Header "destination" s

idHeader :: String -> Header
idHeader s = Header "id" s

ackHeader :: String -> Header
ackHeader s = Header "ack" s

txHeader :: String -> Header
txHeader tx = Header "transaction" tx

receiptHeader :: String -> Header
receiptHeader receipt = Header "receipt" receipt

receiptIdHeader :: String -> Header
receiptIdHeader id = Header "receipt-id" id

subscriptionHeader :: String -> Header
subscriptionHeader id = Header "subscription" id

messageIdHeader :: String -> Header
messageIdHeader id = Header "message-id" id


-- Client frames

stomp :: String -> Frame
stomp host = Frame STOMP (stompHeaders host) EmptyBody

connect :: String -> Frame
connect host = Frame CONNECT (stompHeaders host) EmptyBody

sendText :: String -> String -> Frame
sendText message dest = 
    addFrameHeaderFront (destinationHeader dest) (textFrame message SEND)

subscribe :: String -> String -> String -> Frame
subscribe id dest ack = Frame 
    SUBSCRIBE 
    (makeHeaders [idHeader id, destinationHeader dest, ackHeader ack])
    EmptyBody

unsubscribe :: String -> Frame
unsubscribe id = Frame UNSUBSCRIBE (makeHeaders [idHeader id]) EmptyBody

ack :: String -> Frame
ack id = Frame ACK (makeHeaders [idHeader id]) EmptyBody

nack :: String -> Frame
nack id = Frame NACK (makeHeaders [idHeader id]) EmptyBody

begin :: String -> Frame
begin tx = Frame BEGIN (makeHeaders [txHeader tx]) EmptyBody

commit :: String -> Frame
commit tx = Frame COMMIT (makeHeaders [txHeader tx]) EmptyBody

abort :: String -> Frame
abort tx = Frame ABORT (makeHeaders [txHeader tx]) EmptyBody

disconnect :: String -> Frame
disconnect receipt = Frame DISCONNECT (makeHeaders [receiptHeader receipt]) EmptyBody


-- Server frames

connected :: Frame
connected = Frame CONNECTED (makeHeaders [versionHeader]) EmptyBody

errorFrame :: String -> Frame
errorFrame message = textFrame message ERROR

textMessage :: String -> String -> String -> String -> Frame
textMessage subscription id dest message = 
    let 
      headers = makeHeaders [subscriptionHeader subscription, messageIdHeader id, destinationHeader dest] 
    in
      addFrameHeaders headers (textFrame message MESSAGE)

receipt :: String -> Frame
receipt id = Frame RECEIPT (makeHeaders [receiptIdHeader id]) EmptyBody
