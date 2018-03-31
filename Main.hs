{-# language LambdaCase          #-}
{-# language OverloadedStrings   #-}
{-# language ScopedTypeVariables #-}
{-# language ViewPatterns        #-}

import Control.Monad (forever)
import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
import Data.Text (Text)
import Network.HTTP.Types (status400, status500)
import Network.Socket (SockAddr)
import Network.Wai (Request, remoteHost, responseLBS, responseRaw)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets
  (getRequestHead, isWebSocketsReq, runWebSockets)
import Network.WebSockets hiding (Request)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

main :: IO ()
main = do
  port :: Int <-
    parseArgs =<< getArgs

  chan :: TChan (SockAddr, Text) <-
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

parseArgs :: [String] -> IO Int
parseArgs = \case
  [readMaybe -> Just port] ->
    pure port
  _ -> do
    hPutStrLn stderr "Usage: generic-websocket-server PORT"
    exitFailure

wsApp :: TChan (SockAddr, Text) -> Request -> PendingConnection -> IO ()
wsApp chan request pconn = do
  conn :: Connection <-
    acceptRequest pconn

  chan' :: TChan (SockAddr, Text) <-
    atomically (dupTChan chan)

  let recvBus :: IO Text
      recvBus = do
        (addr, msg) <-
          atomically (readTChan chan')
        if addr == remoteHost request
          then
            recvBus
          else
            pure msg

  let sendBus :: Text -> IO ()
      sendBus msg =
        atomically (writeTChan chan (remoteHost request, msg))

  theApp recvBus sendBus conn

theApp :: IO Text -> (Text -> IO ()) -> Connection -> IO ()
theApp recvBus sendBus conn = do
  race_
    (forever (recvBus >>= sendTextData conn))
    (forever (receiveData conn >>= sendBus))
