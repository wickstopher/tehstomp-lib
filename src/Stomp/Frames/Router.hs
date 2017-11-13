-- |The Router module implements an asynchronous notification system for events received on a
-- FrameHandle. Callers can request various types of events and receive those events on a 
-- dedicated communications channel.
module Stomp.Frames.Router (
    initFrameRouter,
    requestResponseEvents,
    requestSubscriptionEvents,
    RequestHandler
) where

import Control.Concurrent
import Control.Concurrent.TxEvent
import Data.HashMap.Strict as HM
import Stomp.Frames
import Stomp.Frames.IO

-- |The RequestHandler is used to request various types of notifications from the FrameRouter.
data RequestHandler = RequestHandler (SChan Update)

-- |Represents the types of updates that are processed by a FrameRouter. These are
-- internal representations and are not exported. Their usage is abstracted via
-- the RequestHandler datatype.
data Update         = ResponseRequest (SChan FrameEvt)  | 
                      SubscriptionRequest String (SChan FrameEvt) |
                      GotFrame Frame |
                      GotHeartbeat |
                      ServerDisconnected

-- |Represents a mapping of subscription IDs to the communications channels for interested callers.
-- This is an internal representation and is not exported.
data Subscriptions  = Subscriptions (HashMap String [SChan FrameEvt])

-- |The FrameRouter holds channels on which to receive updates, and also holds all of the communications
-- channels for event listeners. This is an internal representation and is not exported.
data FrameRouter    = FrameRouter (SChan Update) (SChan Update) [SChan FrameEvt] Subscriptions

-- |Given a FrameHandler on which FramesEvts are being received, initalize a FrameRouter and return a
-- RequestHandler for that FrameRouter to the caller.
initFrameRouter :: FrameHandler -> IO RequestHandler
initFrameRouter handler = do
    updateChannel  <- sync newSChan
    frameChannel   <- sync newSChan
    requestHandler <- return $ RequestHandler updateChannel
    subscriptions  <- return $ Subscriptions HM.empty
    frameRouter    <- return $ FrameRouter frameChannel updateChannel [] subscriptions
    forkIO $ frameLoop frameChannel handler
    forkIO $ routerLoop frameRouter
    return requestHandler

-- |Given a RequestHandler, request a new SChan on which to receive response events. Response events
-- are defined as any Frame received other than a MESSAGE Frame.
requestResponseEvents :: RequestHandler -> IO (SChan FrameEvt)
requestResponseEvents (RequestHandler chan) = do
    frameChannel <- sync newSChan
    sync $ sendEvt chan (ResponseRequest frameChannel)
    return frameChannel

-- |Given a RequestHandler, request a new SChan on which to receive subscription events for a given
-- subscription identifier. 
requestSubscriptionEvents :: RequestHandler -> String -> IO (SChan FrameEvt)
requestSubscriptionEvents (RequestHandler chan) subscriptionId = do
    frameChannel <- sync newSChan
    sync $ sendEvt chan (SubscriptionRequest subscriptionId frameChannel)
    return frameChannel

-- |This is initialized by the `initFrameRouter` function, and loops as new FrameEvts are received.
frameLoop :: SChan Update -> FrameHandler -> IO ()
frameLoop frameChannel handler = do
    f <- get handler
    case f of 
        NewFrame frame -> do
            sync $ sendEvt frameChannel (GotFrame frame)
            frameLoop frameChannel handler
        Heartbeat      -> do
            sync $ sendEvt frameChannel (GotHeartbeat)
        GotEof         -> do
            sync $ sendEvt frameChannel ServerDisconnected
            return ()

-- |This is initialized by the `initFrameRouter` function and loops as Updates are received. With
-- each iteration the router's state is updated if need be.
routerLoop :: FrameRouter -> IO ()
routerLoop router@(FrameRouter frameChannel updateChannel _ _) = do
    update      <- sync $ chooseEvt (recvEvt frameChannel) (recvEvt updateChannel)
    maybeRouter <- handleUpdate update router
    case maybeRouter of
        Just router' -> routerLoop router'
        Nothing      -> return ()

-- |Handle an Update and return an updated FrameRouter in the case that the Update necessitates
-- a change (e.g. SubscriptionRequest, ResponseRequest).
handleUpdate :: Update -> FrameRouter -> IO (Maybe FrameRouter)
handleUpdate update router@(FrameRouter _ _ responseChannels subscriptions) = 
    case update of
        GotFrame frame -> do
            handleFrame frame responseChannels subscriptions
            return $ Just router
        ResponseRequest responseChannel -> 
            return $ Just $ addResponseChannel router responseChannel
        SubscriptionRequest subId subChannel ->
            return $ Just $ addSubscriptionChannel router subId subChannel
        ServerDisconnected -> do
            handleDisconnect responseChannels subscriptions
            return Nothing

-- |Add a response channel to the FrameRouter
addResponseChannel :: FrameRouter -> (SChan FrameEvt) -> FrameRouter
addResponseChannel (FrameRouter f u r s) newChan =
    FrameRouter f u  (newChan:r) s

-- |Given a subscription identifier as a String, add a subscription channel to the FrameRouter.
addSubscriptionChannel :: FrameRouter -> String -> (SChan FrameEvt) -> FrameRouter
addSubscriptionChannel router@(FrameRouter f u r (Subscriptions subs)) subId newChan = 
    let sub = HM.lookup subId subs in
        case sub of 
            Just subscriptionChannels ->
                FrameRouter f u r (Subscriptions (HM.insert  subId (newChan:subscriptionChannels) subs))
            Nothing ->
                FrameRouter f u r (Subscriptions (HM.insert subId [newChan] subs))

-- |Given the response channels and subscription channels for a FrameRouter, handle notifications on
-- those channels for a given frame.
handleFrame :: Frame -> [SChan FrameEvt] -> Subscriptions -> IO ()
handleFrame frame responseChannels subscriptions = 
    let channels = selectChannels (getCommand frame) (getHeaders frame) responseChannels subscriptions in
        sendFrame frame channels

-- |Given a Command and Headers of a Frame, and the response and subscription channesl for a
-- FrameRouter, return the list of channels that need updates with respect to that Frame.
selectChannels :: Command -> Headers -> [SChan FrameEvt] -> Subscriptions -> [SChan FrameEvt]
selectChannels MESSAGE headers _ (Subscriptions subs) = case (getValueForHeader "subscription" headers) of
    Just subId -> case HM.lookup subId subs of
        Just channels -> channels
        Nothing       -> []  
    Nothing -> []
selectChannels _ _ responseChannels _ = responseChannels

-- |Send a NewFrame FrameEvt for the given Frame to the list of listener channels.
sendFrame :: Frame -> [SChan FrameEvt] -> IO ()
sendFrame frame []          = return ()
sendFrame frame (chan:rest) = do
    forkIO $ sync (sendEvt chan (NewFrame frame))
    sendFrame frame rest

-- |Send a GotEof Frame to all listeners in the given list of response channels and 
-- to all listeners for all subscriptions.
handleDisconnect :: [SChan FrameEvt] -> Subscriptions -> IO ()
handleDisconnect responseChannels (Subscriptions subs) = 
    let allListeners = responseChannels ++ (concat $ HM.elems subs) in
        sendDisconnect allListeners

-- |Send a GotEof Frame to all channels in the list of channels.
sendDisconnect :: [SChan FrameEvt] -> IO ()
sendDisconnect [] = return ()
sendDisconnect (chan:chans) = do
    forkIO $ sync (sendEvt chan GotEof)
    sendDisconnect chans
