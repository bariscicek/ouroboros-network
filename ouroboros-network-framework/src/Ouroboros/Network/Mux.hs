{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}

module Ouroboros.Network.Mux
  ( MuxMode (..)
  , OuroborosApplication (..)
  , MuxProtocolBundle
  , AppKind (..)
  , TokAppKind (..)
  , WithAppKind (..)
  , withoutAppKind
  , Bundle (..)
  , projectBundle
  , OuroborosBundle
  , MuxBundle
  , MiniProtocol (..)
  , MiniProtocolNum (..)
  , MiniProtocolLimits (..)
  , RunMiniProtocol (..)
  , MuxPeer (..)
  , runMuxPeer
  , toApplication
  , mkMuxApplicationBundle
  , ControlMessage (..)
  , ControlMessageSTM
  , continueForever

    -- * Re-exports
    -- | from "Network.Mux"
  , MuxError(..)
  , MuxErrorType(..)
  , HasInitiator
  , HasResponder
  ) where

import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadSTM
import           Control.Monad.Class.MonadThrow
import           Control.Exception (Exception)
import           Control.Tracer (Tracer)

import           Data.Void (Void)
import qualified Data.ByteString.Lazy as LBS

import           Network.TypedProtocol.Core
import           Network.TypedProtocol.Pipelined

import qualified Network.Mux.Compat as Mux
import           Network.Mux
                   ( MuxMode(..), HasInitiator, HasResponder
                   , MiniProtocolNum, MiniProtocolLimits(..)
                   , MuxError(..), MuxErrorType(..) )

import           Ouroboros.Network.Channel
import           Ouroboros.Network.ConnectionId
import           Ouroboros.Network.Codec
import           Ouroboros.Network.Driver


-- | Control signal sent to a mini-protocol.  expected to exit, on 'Continue' it
-- should continue its operation
--
data ControlMessage =
    -- | Continue operation.
      Continue

    -- | Hold on, e.g. do not sent messages until resumed.  This is not used for
    -- any hot protocol.
    --
    | Quiesce

    -- | The client is expected to terminate as soon as possible.
    --
    | Terminate
  deriving (Eq, Show)

-- |  'ControlMessageSTM' should depend on `muxMode` (we only need to shedule
-- stop for intiator side).  This is not done only because this would break
-- tests, but once the old api is removed it should be possible.
--
type ControlMessageSTM m = STM m ControlMessage

continueForever :: Applicative (STM m)
          => proxy m
          -> ControlMessageSTM m
continueForever _ = pure Continue

-- |  Like 'MuxApplication' but using a 'MuxPeer' rather than a raw
-- @Channel -> m a@ action.
--
newtype OuroborosApplication (mode :: MuxMode) addr bytes m a b =
        OuroborosApplication
          (ConnectionId addr -> ControlMessageSTM m -> [MiniProtocol mode bytes m a b])


-- |  There are three kinds of applications: warm, hot and established (ones
-- that run in for both warm and hot peers).
--
data AppKind = HotApp | WarmApp | EstablishedApp


-- | Singletons for 'AppKind'
--
data TokAppKind (appKind :: AppKind) where
    TokHotApp         :: TokAppKind HotApp
    TokWarmApp        :: TokAppKind WarmApp
    TokEstablishedApp :: TokAppKind EstablishedApp


-- | We keep hot and warm application (or their context) distinct.  It's only
-- needed for a handly 'projectBundle' map.
--
data WithAppKind (appKind :: AppKind) a where
    WithHot         :: !a -> WithAppKind HotApp  a
    WithWarm        :: !a -> WithAppKind WarmApp a
    WithEstablished :: !a -> WithAppKind EstablishedApp a

deriving instance Eq a => Eq (WithAppKind appKind a)
deriving instance Show a => Show (WithAppKind appKind a)
deriving instance (Functor (WithAppKind appKind))

instance Semigroup a => Semigroup (WithAppKind appKind a) where
    WithHot a <> WithHot b = WithHot (a <> b)
    WithWarm a <> WithWarm b = WithWarm (a <> b)
    WithEstablished a <> WithEstablished b = WithEstablished (a <> b)

instance Monoid a => Monoid (WithAppKind HotApp a) where
    mempty = WithHot mempty

instance Monoid a => Monoid (WithAppKind WarmApp a) where
    mempty = WithWarm mempty

instance Monoid a => Monoid (WithAppKind EstablishedApp a) where
    mempty = WithEstablished mempty


withoutAppKind :: WithAppKind appKind a -> a
withoutAppKind (WithHot a)         = a
withoutAppKind (WithWarm a)        = a
withoutAppKind (WithEstablished a) = a


-- | A bundle of 'HotApp', 'WarmApp' and 'EstablishedApp'.
--
data Bundle a =
      Bundle {
          -- | hot mini-protocols
          --
          withHot
            :: !(WithAppKind HotApp a),

          -- | warm mini-protocols
          --
          withWarm
            :: !(WithAppKind WarmApp a),

          -- | established mini-protocols
          --
          withEstablished
            :: !(WithAppKind EstablishedApp a)
        }
  deriving (Eq, Show, Functor)

instance Semigroup a => Semigroup (Bundle a) where
    Bundle hot warm established <> Bundle hot' warm' established' =
      Bundle (hot <> hot')
             (warm <> warm')
             (established <> established')

instance Monoid a => Monoid (Bundle a) where
    mempty = Bundle mempty mempty mempty

projectBundle :: TokAppKind appKind -> Bundle a -> a
projectBundle TokHotApp         = withoutAppKind . withHot
projectBundle TokWarmApp        = withoutAppKind . withWarm
projectBundle TokEstablishedApp = withoutAppKind . withEstablished


instance Applicative Bundle where
    pure a = Bundle (WithHot a) (WithWarm a) (WithEstablished a)
    Bundle (WithHot hotFn)
           (WithWarm warmFn)
           (WithEstablished establishedFn)
      <*> Bundle (WithHot hot)
                 (WithWarm warm)
                 (WithEstablished established) =
        Bundle (WithHot $ hotFn hot)
               (WithWarm $ warmFn warm)
               (WithEstablished $ establishedFn established)

--
-- Useful type synonyms
--

type MuxProtocolBundle (mode :: MuxMode) addr bytes m a b
       = ConnectionId addr
      -> ControlMessageSTM m
      -> [MiniProtocol mode bytes m a b]

type OuroborosBundle (mode :: MuxMode) addr bytes m a b =
    Bundle (MuxProtocolBundle mode addr bytes m a b)

data MiniProtocol (mode :: MuxMode) bytes m a b =
     MiniProtocol {
       miniProtocolNum    :: !MiniProtocolNum,
       miniProtocolLimits :: !MiniProtocolLimits,
       miniProtocolRun    :: !(RunMiniProtocol mode bytes m a b)
     }

type MuxBundle (mode :: MuxMode) bytes m a b =
    Bundle [MiniProtocol mode bytes m a b]


data RunMiniProtocol (mode :: MuxMode) bytes m a b where
     InitiatorProtocolOnly
       :: MuxPeer bytes m a
       -> RunMiniProtocol InitiatorMode bytes m a Void

     ResponderProtocolOnly
       :: MuxPeer bytes m b
       -> RunMiniProtocol ResponderMode bytes m Void b

     InitiatorAndResponderProtocol
       :: MuxPeer bytes m a
       -> MuxPeer bytes m b
       -> RunMiniProtocol InitiatorResponderMode bytes m a b


data MuxPeer bytes m a where
    MuxPeer :: Exception failure
            => Tracer m (TraceSendRecv ps)
            -> Codec ps failure m bytes
            -> Peer ps pr st m a
            -> MuxPeer bytes m a

    MuxPeerPipelined
            :: Exception failure
            => Tracer m (TraceSendRecv ps)
            -> Codec ps failure m bytes
            -> PeerPipelined ps pr st m a
            -> MuxPeer bytes m a

    MuxPeerRaw
           :: (Channel m bytes -> m (a, Maybe bytes))
           -> MuxPeer bytes m a

toApplication :: (MonadCatch m, MonadAsync m)
              => ConnectionId addr
              -> ControlMessageSTM m
              -> OuroborosApplication mode addr LBS.ByteString m a b
              -> Mux.MuxApplication mode m a b
toApplication connectionId controlMessageSTM (OuroborosApplication ptcls) =
  Mux.MuxApplication
    [ Mux.MuxMiniProtocol {
        Mux.miniProtocolNum    = miniProtocolNum ptcl,
        Mux.miniProtocolLimits = miniProtocolLimits ptcl,
        Mux.miniProtocolRun    = toMuxRunMiniProtocol (miniProtocolRun ptcl)
      }
    | ptcl <- ptcls connectionId controlMessageSTM ]


mkMuxApplicationBundle
    :: forall mode addr bytes m a b.
       ConnectionId addr
    -> Bundle (ControlMessageSTM m)
    -> OuroborosBundle mode addr bytes m a b
    -> MuxBundle       mode      bytes m a b
mkMuxApplicationBundle connectionId
                       (Bundle
                         hotControlMessageSTM
                         warmControlMessageSTM
                         establishedControlMessageSTM)
                       (Bundle
                           hotApp
                           warmApp
                           establishedApp) =
    Bundle {
        withHot =
          mkApplication hotControlMessageSTM hotApp,

        withWarm =
          mkApplication warmControlMessageSTM warmApp,

        withEstablished =
          mkApplication establishedControlMessageSTM establishedApp
    }
  where
    mkApplication :: WithAppKind appKind (ControlMessageSTM m)
                  -> WithAppKind appKind (MuxProtocolBundle mode addr bytes m a b)
                  -> WithAppKind appKind [MiniProtocol mode bytes m a b]
    mkApplication (WithHot scheduleStop) (WithHot app) =
      WithHot $ app connectionId scheduleStop

    mkApplication (WithWarm scheduleStop) (WithWarm app) =
      WithWarm $ app connectionId scheduleStop

    mkApplication (WithEstablished scheduleStop) (WithEstablished app) =
      WithEstablished $ app connectionId scheduleStop


toMuxRunMiniProtocol :: forall mode m a b.
                        (MonadCatch m, MonadAsync m)
                     => RunMiniProtocol mode LBS.ByteString m a b
                     -> Mux.RunMiniProtocol mode m a b
toMuxRunMiniProtocol (InitiatorProtocolOnly i) =
  Mux.InitiatorProtocolOnly (runMuxPeer i . fromChannel)
toMuxRunMiniProtocol (ResponderProtocolOnly r) =
  Mux.ResponderProtocolOnly (runMuxPeer r . fromChannel)
toMuxRunMiniProtocol (InitiatorAndResponderProtocol i r) =
  Mux.InitiatorAndResponderProtocol (runMuxPeer i . fromChannel)
                                    (runMuxPeer r . fromChannel)

-- |
-- Run a @'MuxPeer'@ using either @'runPeer'@ or @'runPipelinedPeer'@.
--
runMuxPeer
  :: ( MonadCatch m
     , MonadAsync m
     )
  => MuxPeer bytes m a
  -> Channel m bytes
  -> m (a, Maybe bytes)
runMuxPeer (MuxPeer tracer codec peer) channel =
    runPeer tracer codec channel peer

runMuxPeer (MuxPeerPipelined tracer codec peer) channel =
    runPipelinedPeer tracer codec channel peer

runMuxPeer (MuxPeerRaw action) channel =
    action channel
