{-# language DuplicateRecordFields #-}
{-# language LambdaCase            #-}
{-# language OverloadedStrings     #-}
{-# language ScopedTypeVariables   #-}
{-# language ViewPatterns          #-}

import Concurrency (atomically, race_)
import Data.Aeson
import Environment (getArgs)
import Exit (exitFailure)
import File (stderr)
import File.Text (hPutStrLn)
import IORef (modifyIORef', newIORef, readIORef)
import MonadFail (fail)
import Network.HTTP.Types (status400, status500)
import Network.Wai (Request, remoteHost, responseLBS, responseRaw)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets
  (getRequestHead, isWebSocketsReq, runWebSockets)
import Network.WebSockets
  (Connection, PendingConnection, acceptRequest, defaultConnectionOptions,
    receiveData, sendTextData)
import Read (readMaybe)
import Socket (SockAddr)
import String (String)
import TChan

import qualified HashSet

data Message
  = SubscribeMsg SubscribeMessage
  | PayloadMsg PayloadMessage

instance FromJSON Message where
  parseJSON =
    withObject "message" $ \o ->
      (o .: "type") >>= \case
        "subscribe" ->
          SubscribeMsg
            <$> (SubscribeMessage
                  <$> o .: "topic")
        "message" ->
          PayloadMsg
            <$> (PayloadMessage
                  <$> o .: "topic"
                  <*> o .: "payload")
        s ->
          fail ("Unexpected message type: " <> s)

data SubscribeMessage = SubscribeMessage
  { subscribeMsgTopic :: !Text
  }

data PayloadMessage = PayloadMessage
  { payloadMsgTopic :: !Text
  , payloadMsgPayload :: !Value
  }

data MalformedMessage
  = MalformedMessage !SockAddr !ByteString
  deriving (Show)

instance Exception MalformedMessage

main :: IO ()
main = do
  port :: Int <-
    parseArgs =<< getArgs

  chan :: TChan (SockAddr, PayloadMessage) <-
    newBroadcastTChanIO

  run port $ \req resp ->
    if isWebSocketsReq req
      then
        resp
          (responseRaw
            (runWebSockets
              defaultConnectionOptions
              (getRequestHead req)
              (wsApp chan req))
            (responseLBS status500 [] ""))
      else
        resp (responseLBS status400 [] "")
 where
  parseArgs :: [String] -> IO Int
  parseArgs = \case
    [readMaybe -> Just port] ->
      pure port
    _ -> do
      hPutStrLn stderr "Usage: generic-websocket-server PORT"
      exitFailure

wsApp
  :: TChan (SockAddr, PayloadMessage)
  -> Request
  -> PendingConnection
  -> IO ()
wsApp chan request pconn = do
  conn :: Connection <-
    acceptRequest pconn

  chan' :: TChan (SockAddr, PayloadMessage) <-
    atomically (dupTChan chan)

  subscribedRef :: IORef (HashSet Text) <-
    newIORef mempty

  let recvThread :: IO ()
      recvThread =
        forever $ do
          (sender, PayloadMessage topic payload) :: (SockAddr, PayloadMessage) <-
            atomically (readTChan chan')

          subscribed :: HashSet Text <-
            readIORef subscribedRef

          when (sender /= remoteHost request &&
                  topic `elem` subscribed)
            (sendTextData conn (encode payload))

  let sendThread :: IO ()
      sendThread =
        forever $ do
          bytes :: ByteString <-
            receiveData conn
          case decodeStrict' bytes of
            Nothing ->
              throwIO (MalformedMessage (remoteHost request) bytes)
            Just message ->
              case message of
                SubscribeMsg (SubscribeMessage s) ->
                  modifyIORef' subscribedRef (HashSet.insert s)
                PayloadMsg message' ->
                  atomically
                    (writeTChan chan (remoteHost request, message'))

  race_ recvThread sendThread
