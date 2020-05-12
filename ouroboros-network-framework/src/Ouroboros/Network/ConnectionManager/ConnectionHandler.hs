{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE KindSignatures            #-}
{-# LANGUAGE NamedFieldPuns            #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}

-- | Implementation of 'ConnectionHandler'
--
module Ouroboros.Network.ConnectionManager.ConnectionHandler
  ( MuxPromise (..)
  , MuxConnectionHandler
  , makeConnectionHandler
  , MuxConnectionManager
  -- * tracing
  , ConnectionTrace (..)
  ) where

import           Control.Monad (when)
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Tracer (Tracer, contramap, traceWith)

import           Data.ByteString.Lazy (ByteString)
import           Data.Functor (void)
import           Data.Foldable (traverse_)

import           Network.Mux hiding (miniProtocolNum)

import           Ouroboros.Network.Mux
import           Ouroboros.Network.Protocol.Handshake
import           Ouroboros.Network.Channel (fromChannel)
import           Ouroboros.Network.ConnectionId (ConnectionId)
import           Ouroboros.Network.ConnectionManager.Types


-- | States of the connection handler thread.
--
-- * 'MuxRunning'      - sucessful Handshake, mux started
-- * 'MuxStopped'      - either mux was gracefully stopped (using 'Mux' or by
--                     'killThread'; the latter is done by
--                     'Ouoroboros.Network.ConnectinoManager.withConnectionManager')
-- * 'MuxPromiseHandshakeClientError'
--                     - the connection handler thread was running client side
--                     of the handshake negotiation, which failed with
--                     'HandshakeException'
-- * 'MuxPromiseHandshakeServerError'
--                     - the conneciton hndler thread was running server side
--                     of the handshake protocol, which faile with
--                     'HandshakeException'
-- * 'MuxPromiseError' - the multiplexer thrown 'MuxError'.
--
data MuxPromise muxMode verionNumber bytes m where
    MuxRunning
      :: forall muxMode versionNumber bytes m a b.
         !(Mux muxMode m)
      -> ![MiniProtocol muxMode bytes m a b]
      -> !(StrictTVar m RunOrStop)
      -> MuxPromise muxMode versionNumber bytes m

    MuxStopped
      :: MuxPromise muxMode versionNumber bytes m

    MuxPromiseHandshakeClientError
     :: HasInitiator muxMode ~ True
     => !(HandshakeException (HandshakeClientProtocolError versionNumber))
     -> MuxPromise muxMode versionNumber bytes m

    MuxPromiseHandshakeServerError
      :: HasResponder muxMode ~ True
      => !(HandshakeException (RefuseReason versionNumber))
      -> MuxPromise muxMode versionNumber bytes m

    MuxPromiseError
     :: !SomeException
     -> MuxPromise muxMode versionNumber bytes m


-- | A predicate which returns 'True' if connection handler thread has stopped running.
--
isConnectionHandlerRunning :: MuxPromise muxMode verionNumber bytes m -> Bool
isConnectionHandlerRunning muxPromise =
    case muxPromise of
      MuxRunning{}                     -> True
      MuxPromiseHandshakeClientError{} -> False
      MuxPromiseHandshakeServerError{} -> False
      MuxPromiseError{}                -> False
      MuxStopped                       -> False


-- | Type of 'ConnectionHandler' implemented in this module.
--
type MuxConnectionHandler muxMode peerAddr versionNumber bytes m =
    ConnectionHandler muxMode
                      (ConnectionTrace versionNumber)
                      peerAddr
                      (MuxPromise muxMode versionNumber bytes m)
                      m

-- | Type alias for 'ConnectionManager' using 'MuxPromise'.
--
type MuxConnectionManager muxMode socket peerAddr versionNumber bytes m =
    ConnectionManager muxMode socket peerAddr (MuxPromise muxMode versionNumber bytes m) m

-- | To be used as `makeConnectionHandler` field of 'ConnectionManagerArguments'.
--
-- Note: We need to pass `MiniProtocolBundle` what forces us to have two
-- different `ConnectionManager`s: one for `node-to-client` and another for
-- `node-to-node` connections.  But this is ok, as these resources are
-- independent.
--
makeConnectionHandler
    :: forall peerAddr muxMode versionNumber extra m a b.
       ( MonadAsync m
       , MonadCatch m
       , MonadFork  m
       , MonadThrow (STM m)
       , MonadTime  m
       , MonadTimer m
       , MonadMask  m
       , Ord versionNumber
       )
    => Tracer m (WithMuxBearer (ConnectionId peerAddr) MuxTrace)
    -> SingInitiatorResponderMode muxMode
    -- ^ describe whether this is outbound or inbound connection, and bring
    -- evidence that we can use mux with it.
    -> MiniProtocolBundle muxMode
    -> HandshakeArguments (ConnectionId peerAddr) versionNumber extra m
                          (OuroborosApplication muxMode peerAddr ByteString m a b)
    -> MuxConnectionHandler muxMode peerAddr versionNumber ByteString m
makeConnectionHandler muxTracer singMuxMode miniProtocolBundle handshakeArguments =
    ConnectionHandler $
      case singMuxMode of
        SInitiatorMode          -> WithInitiatorMode          outboundConnectionHandler
        SResponderMode          -> WithResponderMode          inboundConnectionHandler
        SInitiatorResponderMode -> WithInitiatorResponderMode outboundConnectionHandler
                                                              inboundConnectionHandler
  where
    outboundConnectionHandler
      :: HasInitiator muxMode ~ True
      => ConnectionHandlerFn (ConnectionTrace versionNumber)
                             peerAddr
                             (MuxPromise muxMode versionNumber ByteString m)
                             m
    outboundConnectionHandler muxPromiseVar tracer connectionId muxBearer =
      exceptionHandling muxPromiseVar tracer $ do
        traceWith tracer ConnectionStart
        hsResult <- runHandshakeClient muxBearer
                                       connectionId
                                       handshakeArguments
        case hsResult of
          Left !err -> do
            atomically $ writeTVar muxPromiseVar (Promised (MuxPromiseHandshakeClientError err))
            traceWith tracer (ConnectionTraceHandshakeClientError err)
          Right app -> do
            traceWith tracer ConnectionTraceHandshakeSuccess
            scheduleStopVar <- newTVarM Run
            let !ptcls = ouroborosProtocols connectionId (readTVar scheduleStopVar) app
            !mux <- newMux miniProtocolBundle
            atomically $ writeTVar muxPromiseVar
                          (Promised
                            (MuxRunning mux
                                        ptcls
                                        scheduleStopVar))

            -- For outbound connections we need to on demand start receivers.
            -- This is, in a sense, a no man land: the server will not act, as
            -- it's only reacting to inbound connections, and it also does not
            -- belong to initiator (peer-2-peer governor).
            case singMuxMode of
              SInitiatorResponderMode -> do
                -- TODO: #2221 restart responders
                traverse_ (runResponder mux) ptcls

              _ -> pure ()

            runMux (WithMuxBearer connectionId `contramap` muxTracer)
                   mux muxBearer
                

    inboundConnectionHandler
      :: HasResponder muxMode ~ True
      => ConnectionHandlerFn (ConnectionTrace versionNumber)
                             peerAddr
                             (MuxPromise muxMode versionNumber ByteString m)
                             m
    inboundConnectionHandler muxPromiseVar tracer connectionId muxBearer =
      exceptionHandling muxPromiseVar tracer $ do
        traceWith tracer ConnectionStart
        hsResult <- runHandshakeServer muxBearer
                                       connectionId
                                       (\_ _ _ -> Accept) -- we accept all connections
                                       handshakeArguments
        case hsResult of
          Left !err -> do
            atomically $ writeTVar muxPromiseVar (Promised (MuxPromiseHandshakeServerError err))
            traceWith tracer (ConnectionTraceHandshakeServerError err)
          Right app -> do
            traceWith tracer ConnectionTraceHandshakeSuccess
            scheduleStopVar <- newTVarM Run
            let !ptcls = ouroborosProtocols connectionId (readTVar scheduleStopVar) app
            !mux <- newMux miniProtocolBundle
            atomically $ writeTVar muxPromiseVar (Promised (MuxRunning mux ptcls scheduleStopVar))
            runMux (WithMuxBearer connectionId `contramap` muxTracer)
                       mux muxBearer

    -- minimal error handling, just to make adequate changes to
    -- `muxPromiseVar`; Classification of errors is done by
    -- 'withConnectionManager' when the connection handler thread is started..
    exceptionHandling :: forall x.
                         StrictTVar m
                           (Promise
                             (MuxPromise muxMode versionNumber ByteString m))
                      -> Tracer m (ConnectionTrace versionNumber)
                      -> m x -> m x
    exceptionHandling muxPromiseVar tracer io =
      io
      -- the default for normal exit and unhandled error is to write
      -- `MusStopped`, but we don't want to override handshake errors.
      `finally` do
        atomically $ do
          st <- readTVar muxPromiseVar
          when (case st of
                  Promised muxPromise -> isConnectionHandlerRunning muxPromise
                  Empty -> True)
            $ writeTVar muxPromiseVar (Promised MuxStopped)
        traceWith tracer ConnectionStopped

      -- if 'MuxError' was thrown by the conneciton handler, let the other side
      -- know.
      `catch` \(e :: SomeException) -> do
        atomically (writeTVar muxPromiseVar (Promised (MuxPromiseError e)))
        throwM e


    runResponder :: Mux InitiatorResponderMode m
                 -> MiniProtocol InitiatorResponderMode ByteString m a b -> m ()
    runResponder mux MiniProtocol {
                        miniProtocolNum,
                        miniProtocolRun
                      } =
        case miniProtocolRun of
          InitiatorAndResponderProtocol _ responder ->
            void $
              runMiniProtocol
                mux miniProtocolNum
                ResponderDirection
                StartOnDemand
                (runMuxPeer responder . fromChannel)


--
-- Tracing
--


-- | 'ConnectionTrace' is embedded into 'ConnectionManagerTrace' with
-- 'Ouroboros.Network.ConnectionMamanger.Types.ConnectionTrace' constructor.
--
-- TODO: when 'Handshake' will get it's own tracer, independent of 'Mux', it
-- should be embedded into 'ConnectionTrace'.
--
data ConnectionTrace versionNumber =
      ConnectionStart
    | ConnectionTraceHandshakeSuccess
    | ConnectionTraceHandshakeClientError
        !(HandshakeException (HandshakeClientProtocolError versionNumber))
    | ConnectionTraceHandshakeServerError
        !(HandshakeException (RefuseReason versionNumber))
    | ConnectionStopped
  deriving Show
