{-# LANGUAGE GADTs               #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Ouroboros.Network.KeepAlive
  ( KeepAliveInterval (..)
  , keepAliveClient
  , keepAliveServer

  , TraceKeepAliveClient
  ) where

import           Control.Exception (assert)
import qualified Control.Monad.Class.MonadSTM as Lazy
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Tracer (Tracer, traceWith)
import qualified Data.Map.Strict as M

import           Ouroboros.Network.Mux (RunOrStop (..))
import           Ouroboros.Network.DeltaQ
import           Ouroboros.Network.Protocol.KeepAlive.Client
import           Ouroboros.Network.Protocol.KeepAlive.Server


newtype KeepAliveInterval = KeepAliveInterval { keepAliveInterval :: DiffTime }

data TraceKeepAliveClient peer =
    AddSample peer DiffTime

instance Show peer => Show (TraceKeepAliveClient peer) where
    show (AddSample peer rtt) = "AddSample " ++ show peer ++ show rtt

keepAliveClient
    :: forall m peer.
       ( MonadSTM   m
       , MonadMonotonicTime m
       , MonadTimer m
       , Ord peer
       )
    => Tracer m (TraceKeepAliveClient peer)
    -> peer
    -> (StrictTVar m (M.Map peer PeerGSV))
    -> KeepAliveInterval
    -> StrictTVar m (Maybe Time)
    -> KeepAliveClient m ()
keepAliveClient tracer peer dqCtx KeepAliveInterval { keepAliveInterval } startTimeV =
    SendMsgKeepAlive go
  where
    payloadSize = 2

    decisionSTM :: Lazy.TVar m Bool
                -> STM  m RunOrStop
    decisionSTM delayVar = Lazy.readTVar delayVar >>= fmap (const Run) . check

    go :: m (KeepAliveClient m ())
    go = do
      endTime <- getMonotonicTime
      startTime_m <- atomically $ readTVar startTimeV
      case startTime_m of
           Just startTime -> do
               traceWith tracer $ AddSample peer $ diffTime endTime startTime
               let sample = fromSample startTime endTime payloadSize
               atomically $ modifyTVar dqCtx $ \m ->
                   assert (peer `M.member` m) $
                   M.adjust (\a -> a <> sample) peer m
           Nothing        -> return ()

      delayVar <- registerDelay keepAliveInterval
      decision <- atomically (decisionSTM delayVar)
      now <- getMonotonicTime
      atomically $ writeTVar startTimeV $ Just now
      case decision of
        Run  -> pure (SendMsgKeepAlive go)
        Stop -> pure (SendMsgDone (pure ()))


keepAliveServer
  :: forall m.  Applicative m
  => KeepAliveServer m ()
keepAliveServer = KeepAliveServer {
    recvMsgKeepAlive = pure keepAliveServer,
    recvMsgDone      = pure ()
  }
