-- |The Frames module provides abstract data types for representing STOMP Frames, and convenience functions
-- for working with those data types.
module Stomp.Frames (
    Header(..),
    Headers(..),
    Body(..),
    Command(..),
    Frame(..),
    AckType(..),
    abort,
    ack,
    ackHeader,
    addFrameHeaderFront,
    addFrameHeaderEnd,
    addHeaderEnd,
    addHeaderFront,
    addReceiptHeader,
    begin,
    commit,
    connect,
    connected,
    disconnect,
    errorFrame,
    getAckType,
    getBody,
    getCommand,
    getContentLength,
    getDestination,
    getHeaders,
    getId,
    getReceipt,
    getReceiptId,
    getSupportedVersions,
    getTransaction,
    getValueForHeader,
    idHeader,
    makeHeaders,
    messageIdHeader,
    nack,
    receipt,
    sendText,
    subscribe,
    subscriptionHeader,
    txHeader,
    unsubscribe,
    _getDestination,
    _getAck,
    _getId
) where

import Data.ByteString as BS
import Data.ByteString.UTF8 as UTF
import Stomp.Util
import Text.Read

-- |A HeaderName is a type synonym for String, and is one component of a Header
type HeaderName     =   String

-- |A HeaderValue is a type synonym for String, and is one component of a Header
type HeaderValue    =   String

-- |A Header contains a name and a value for a STOMP header
data Header         =   Header HeaderName HeaderValue

-- |A Headers is a recursive, list-like data structure representing the set of Headers 
-- for a given STOMP frame
data Headers        =   Some Header Headers | EndOfHeaders

-- |A Body represents the body of a STOMP frame. It is either empty or consists of a single
-- ByteString.
data Body           =   EmptyBody | Body ByteString

-- |A Command represents the command portion of a STOMP Frame.
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

-- |An abstract data type representing a STOMP Frame. It consists of a Command, Headers, and Body.
data Frame          =   Frame Command Headers Body

-- |Data type representing the possible acknowledgement types for a subscription to a STOMP broker.
data AckType        =   Auto | Client | ClientIndividual

instance Show Header where
    show (Header headerName headerValue) = headerName ++ ":" ++ headerValue

instance Show Headers where
    show EndOfHeaders = "\n"
    show (Some header headers) = show header ++ "\n" ++ show headers

instance Show Body where
    show EmptyBody = ""
    show (Body s)  = show s

instance Show Frame where
    show (Frame c h b) = show c ++ "\n" ++ show h ++ show b ++ "\NUL"

instance Show AckType where
    show Auto             = "auto"
    show Client           = "client"
    show ClientIndividual = "client-individual"

-----------------------------
-- Frame utility functions --
-----------------------------

-- |Convenience function for retrieiving the Command portion of a Frame.
getCommand :: Frame -> Command
getCommand (Frame c h b) = c

-- |Convenience function for retrieving the Body portion of a Frame.
getBody :: Frame -> Body
getBody (Frame c h b) = b


-- |Construct a Frame with a UTF-8 text content-type given a String and a Command. This function automatically
-- generates content-length and content-type headers and adds them to the Frame.
textFrame :: String -> Command -> Frame
textFrame message command = let encoding = (UTF.fromString message) in
    Frame command 
          (makeHeaders [plainTextContentHeader, contentLengthHeader encoding])
          (Body encoding)

-- |Add a receipt Header to the Frame.
addReceiptHeader :: String -> Frame -> Frame
addReceiptHeader receiptId = addFrameHeaderEnd (receiptHeader receiptId)



------------------------------
-- Header utility functions --
------------------------------

-- |Convenience function for retrieving the Headers portion of a Frame.
getHeaders :: Frame -> Headers
getHeaders (Frame c h b) = h

-- |Given a list of Header datatypes, return a Headers datatype.
makeHeaders :: [Header] -> Headers
makeHeaders []     = EndOfHeaders
makeHeaders (x:xs) = Some x (makeHeaders xs)

-- |Add a Header to the end of the Headers
addHeaderEnd :: Header -> Headers -> Headers
addHeaderEnd newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderEnd newHeader (Some h hs)  = Some h (addHeaderEnd newHeader hs)

-- |Add a Header to the front of the Headers
addHeaderFront :: Header -> Headers -> Headers
addHeaderFront newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderFront newHeader (Some h hs)  = Some newHeader (addHeaderFront h hs)

-- |Add a Header after the first occurence of the Header with the given name. If no such Header 
-- exists in the Headers, it will be added as the last Header.
addHeaderAfter :: HeaderName -> Header -> Headers -> Headers
addHeaderAfter name newHeader EndOfHeaders = Some newHeader EndOfHeaders
addHeaderAfter n1 newHeader (Some h@(Header n2 _) hs)
    | n1 == n2   = Some h (addHeaderFront newHeader hs)
    | otherwise  = Some h (addHeaderAfter n1 newHeader hs)

-- |Given a Frame, add a Header to the end of its Headers.
addFrameHeaderEnd :: Header -> Frame -> Frame
addFrameHeaderEnd header (Frame c h b) = Frame c (addHeaderEnd header h) b

-- |Given a Frame, add a Header to the front of its Headers.
addFrameHeaderFront :: Header -> Frame -> Frame
addFrameHeaderFront header (Frame c h b) = Frame c (addHeaderFront header h) b

-- |Given a Frame, add a Header after the first occurence of the Header with the given name
-- to its Headers. If no such Header exists in the Headers, it will be added as the last Header.
addFrameHeaderAfter :: HeaderName -> Header -> Frame -> Frame
addFrameHeaderAfter name header (Frame c h b) = Frame c (addHeaderAfter name header h) b

-- |Add two Headers together.
addHeaders :: Headers -> Headers -> Headers
addHeaders headers EndOfHeaders = headers
addHeaders headers (Some h hs)  = (Some h (addHeaders headers hs))

-- |Add the Headers to the end of the Frame's Headers.
addFrameHeaders :: Headers -> Frame -> Frame
addFrameHeaders h1 (Frame c h2 b) = Frame c (addHeaders h2 h1) b

-- |Given Headers, get the value of the content-length Header if it is present.
getContentLength :: Headers -> Maybe Int
getContentLength EndOfHeaders                         = Nothing
getContentLength (Some (Header "content-length" n) _) = readMaybe n
getContentLength (Some _ headers)                     = getContentLength headers

-- |Given a Frame, get a list of supported STOMP versions, provided that the accept-version Header
-- is present and well-formed.
getSupportedVersions :: Frame -> Maybe [String]
getSupportedVersions (Frame _ h _) = getVersionsFromHeaders h

getVersionsFromHeaders :: Headers -> Maybe [String]
getVersionsFromHeaders EndOfHeaders                                = Nothing
getVersionsFromHeaders (Some (Header "accept-version" versions) _) = Just (tokenize "," versions)
getVersionsFromHeaders (Some _ headers)                            = getVersionsFromHeaders headers

getTransaction :: Frame -> Maybe String
getTransaction (Frame _ h _) = getValueForHeader "transaction" h

-- |Given a Frame, get the value of the receipt header if it is present.
getReceipt :: Frame -> Maybe String
getReceipt (Frame _ h _) = getValueForHeader "receipt" h

-- |Given a Frame, get the value of the receipt-id header if it is present.
getReceiptId :: Frame -> Maybe String
getReceiptId (Frame _ h _) = getValueForHeader "receipt-id" h

-- |Given a Frame, get the value of the destination header if it is present.
getDestination :: Frame -> Maybe String
getDestination (Frame _ h _) = getValueForHeader "destination" h

-- |Given a Frame, get the value of the destination header. If it is not present, throw an error.
_getDestination :: Frame -> String
_getDestination frame = case getDestination frame of
    Just s  -> s
    Nothing -> error "No destination header present"

-- |Given a Frame, get the value of the ack header if it is present.
getAck :: Frame -> Maybe String
getAck (Frame _ h _) = getValueForHeader "ack" h

_getAck :: Frame -> String
_getAck frame = case getAck frame of
    Just s  -> s
    Nothing -> error "No ack header present"

-- |Given a Frame, get the AckType if it is present
getAckType :: Frame -> Maybe AckType
getAckType (Frame _ h _) = case getValueForHeader "ack" h of
    Just ack -> stringToAckType ack
    Nothing  -> Nothing

stringToAckType :: String -> Maybe AckType
stringToAckType "auto"              = Just Auto
stringToAckType "client"            = Just Client
stringToAckType "client-individual" = Just ClientIndividual
stringToAckType _                   = Nothing

-- |Given a Frame, get the value of the id header if it is present.
getId :: Frame -> Maybe String
getId (Frame _ h _) = getValueForHeader "id" h

_getId :: Frame -> String
_getId frame = case getId frame of
    Just s  -> s
    Nothing -> error "No id header present"

-- |Given a Frame, get the value of the subscription header if it is present.
getSubscription :: Frame -> Maybe String
getSubscription (Frame _ h _) = getValueForHeader "subscription" h

-- |Given a header name and a Frame, get the value for that header if it is present.
getValueForHeader :: String -> Headers -> Maybe String
getValueForHeader _ EndOfHeaders = Nothing
getValueForHeader s (Some (Header s' v) headers) 
    | s == s'   = Just v
    | otherwise = getValueForHeader s headers

-- |Given a host identifier as a String, create the appropriate headers for the CONNECT/STOMP Frame.
stompHeaders ::  String -> Headers
stompHeaders host = makeHeaders [Header "accept-version" "1.2", Header "host" host]

-- |Given a version as a String, create a version Header
versionHeader :: String -> Header
versionHeader version = Header "version" version

-- |Create content-type Header with of text/plain
plainTextContentHeader :: Header
plainTextContentHeader = Header "content-type" "text/plain"

-- |Given a ByteString, generate the content-length Header from the length of the ByteString.
contentLengthHeader :: ByteString -> Header
contentLengthHeader s = Header "content-length" (show $ UTF.length s)

-- |Given a destination as a String, create a destination Header.
destinationHeader :: String -> Header
destinationHeader s = Header "destination" s

-- |Given an ID as a String, create an id Header.
idHeader :: String -> Header
idHeader s = Header "id" s

-- |Given a String, generate an ack header.
ackHeader :: String -> Header
ackHeader value = Header "ack" value

-- |Given a transaction identifier as a String, generate a transaction Header.
txHeader :: String -> Header
txHeader tx = Header "transaction" tx

-- |Given a receipt identifier as a String, generate a receipt Header.
receiptHeader :: String -> Header
receiptHeader receipt = Header "receipt" receipt

-- |Given a receipt identifier as a String, generate a receipt-id Header.
receiptIdHeader :: String -> Header
receiptIdHeader id = Header "receipt-id" id

-- |Given a subscription identifier as a String, generate a subscription Header.
subscriptionHeader :: String -> Header
subscriptionHeader id = Header "subscription" id

-- |Given a message identifier as a String, generate a message-id Header.
messageIdHeader :: String -> Header
messageIdHeader id = Header "message-id" id

-----------------------------------------
-- Functions to generate client frames --
-----------------------------------------

-- |Generate a STOMP Frame given a host identifier as a String.
stomp :: String -> Frame
stomp host = Frame STOMP (stompHeaders host) EmptyBody

-- |Generate a CONNECT Frame given a host identifier as a String.
connect :: String -> Frame
connect host = Frame CONNECT (stompHeaders host) EmptyBody

-- |Generate a plain text SEND Frame given a message as a String and a destination as a String.
sendText :: String -> String -> Frame
sendText message dest = 
    addFrameHeaderFront (destinationHeader dest) (textFrame message SEND)

-- |Generate a SUBSCRIBE Frame given a subscription identifer and destination as Strings, an 
subscribe :: String -> String -> AckType -> Frame
subscribe id dest ackType = Frame 
    SUBSCRIBE 
    (makeHeaders [idHeader id, destinationHeader dest, ackHeader (show ackType)])
    EmptyBody

-- |Generate an UNSUBSCRIBE Frame given a subscription identifier.
unsubscribe :: String -> Frame
unsubscribe id = Frame UNSUBSCRIBE (makeHeaders [idHeader id]) EmptyBody

-- |Generate an ACK Frame given a message identifier as a String.
ack :: String -> Frame
ack id = Frame ACK (makeHeaders [idHeader id]) EmptyBody

-- |Generate a NACK Frame given a message identifier as a String.
nack :: String -> Frame
nack id = Frame NACK (makeHeaders [idHeader id]) EmptyBody

-- |Generate a BEGIN Frame given a transaction identifier as a String.
begin :: String -> Frame
begin tx = Frame BEGIN (makeHeaders [txHeader tx]) EmptyBody

-- |Generate a COMMIT Frame given a transaction identifier as a String.
commit :: String -> Frame
commit tx = Frame COMMIT (makeHeaders [txHeader tx]) EmptyBody

-- |Generate an ABORT Frame given a transaction identifier as a String.
abort :: String -> Frame
abort tx = Frame ABORT (makeHeaders [txHeader tx]) EmptyBody

-- |Generate a DISCONNECT Frame given a receipt identifier as a String.
disconnect :: String -> Frame
disconnect receipt = Frame DISCONNECT (makeHeaders [receiptHeader receipt]) EmptyBody

-----------------------------------------
-- Functions to generate server frames --
-----------------------------------------

-- |Generate a CONNECTED Frame given a version identifier as a String.
connected :: String -> Frame
connected version = Frame CONNECTED (makeHeaders [versionHeader version]) EmptyBody

-- |Generate an ERROR Frame given an error message as a String.
errorFrame :: String -> Frame
errorFrame message = textFrame message ERROR

-- |Generate a MESSAGE Frame given a subscription identifier, message identifier, destination,
-- and message as Strings.
textMessage :: String -> String -> String -> String -> Frame
textMessage subscription id dest message = 
    let 
      headers = makeHeaders [subscriptionHeader subscription, messageIdHeader id, destinationHeader dest] 
    in
      addFrameHeaders headers (textFrame message MESSAGE)

-- |Generate a RECEIPT Frame given a receipt identifier as a String.
receipt :: String -> Frame
receipt id = Frame RECEIPT (makeHeaders [receiptIdHeader id]) EmptyBody
