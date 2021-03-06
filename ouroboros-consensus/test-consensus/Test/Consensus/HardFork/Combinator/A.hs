{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE EmptyCase                  #-}
{-# LANGUAGE EmptyDataDeriving          #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Test.Consensus.HardFork.Combinator.A (
    ProtocolA
  , BlockA(..)
  , binaryBlockInfoA
  , safeFromTipA
  , stabilityWindowA
    -- * Additional types
  , PartialLedgerConfigA(..)
  , TxPayloadA(..)
    -- * Type family instances
  , BlockConfig(..)
  , CodecConfig(..)
  , ConsensusConfig(..)
  , GenTx(..)
  , Header(..)
  , LedgerState(..)
  , NestedCtxt_(..)
  , TxId(..)
  ) where

import           Codec.Serialise
import           Control.Monad.Except
import qualified Data.Binary as B
import           Data.ByteString as Strict
import qualified Data.ByteString.Lazy as Lazy
import           Data.FingerTree.Strict (Measured (..))
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Void
import           Data.Word
import           GHC.Generics (Generic)

import           Cardano.Crypto.ProtocolMagic
import           Cardano.Prelude (NoUnexpectedThunks, OnlyCheckIsWHNF (..))
import           Cardano.Slotting.EpochInfo

import           Test.Util.Time (dawnOfTime)

import           Ouroboros.Network.Block (Serialised, unwrapCBORinCBOR,
                     wrapCBORinCBOR)
import           Ouroboros.Network.Magic

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Config.SupportsNode
import           Ouroboros.Consensus.Forecast
import           Ouroboros.Consensus.HardFork.Combinator
import           Ouroboros.Consensus.HardFork.Combinator.Condense
import           Ouroboros.Consensus.HardFork.Combinator.Serialisation.Common
import           Ouroboros.Consensus.HardFork.History (Bound (..),
                     EraParams (..))
import qualified Ouroboros.Consensus.HardFork.History as History
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.CommonProtocolParams
import           Ouroboros.Consensus.Ledger.SupportsMempool
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Node.Run
import           Ouroboros.Consensus.Node.Serialisation
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Storage.ChainDB.Serialisation
import           Ouroboros.Consensus.Storage.Common
import           Ouroboros.Consensus.Ticked
import           Ouroboros.Consensus.Util (repeatedlyM)
import           Ouroboros.Consensus.Util.Condense
import           Ouroboros.Consensus.Util.Orphans ()

{-------------------------------------------------------------------------------
  BlockA
-------------------------------------------------------------------------------}

data ProtocolA

data instance ConsensusConfig ProtocolA = CfgA {
      cfgA_k           :: SecurityParam
    , cfgA_leadInSlots :: Set SlotNo
    }
  deriving NoUnexpectedThunks via OnlyCheckIsWHNF "CfgA" (ConsensusConfig ProtocolA)

instance ChainSelection ProtocolA where
  -- Use defaults

instance HasChainIndepState ProtocolA where
  -- Use defaults

instance ConsensusProtocol ProtocolA where
  type ChainDepState ProtocolA = ()
  type LedgerView    ProtocolA = ()
  type IsLeader      ProtocolA = ()
  type CanBeLeader   ProtocolA = ()
  type CannotLead    ProtocolA = Void
  type ValidateView  ProtocolA = ()
  type ValidationErr ProtocolA = Void

  checkIsLeader CfgA{..} () _ (Ticked slot _) _ =
      return $ if slot `Set.member` cfgA_leadInSlots
                 then IsLeader ()
                 else NotLeader

  protocolSecurityParam = cfgA_k

  tickChainDepState = \_ (Ticked slot _lv) -> Ticked slot

  updateChainDepState = \_ _ _ _ -> return ()
  rewindChainDepState = \_ _ _ _ -> Just ()

data BlockA = BlkA {
      blkA_header :: Header BlockA
    , blkA_body   :: [GenTx BlockA]
    }
  deriving stock    (Show, Eq, Generic)
  deriving anyclass (Serialise)
  deriving NoUnexpectedThunks via OnlyCheckIsWHNF "BlkA" BlockA

-- Standard cborg generic serialisation is:
--
-- > [number of fields in the product]
-- >   [tag of the constructor]
-- >   field1
-- >   ..
-- >   fieldN
binaryBlockInfoA :: BlockA -> BinaryBlockInfo
binaryBlockInfoA BlkA{..} = BinaryBlockInfo {
      headerOffset = 2
    , headerSize   = fromIntegral $ Lazy.length (serialise blkA_header)
    }

instance GetHeader BlockA where
  data Header BlockA = HdrA {
        hdrA_fields :: HeaderFields BlockA
      , hdrA_prev   :: ChainHash BlockA
      }
    deriving stock    (Show, Eq, Generic)
    deriving anyclass (Serialise)
    deriving NoUnexpectedThunks via OnlyCheckIsWHNF "HdrA" (Header BlockA)

  getHeader          = blkA_header
  blockMatchesHeader = \_ _ -> True -- We are not interested in integrity here
  headerIsEBB        = const Nothing

data instance BlockConfig BlockA = BCfgA
  deriving (Generic, NoUnexpectedThunks)

type instance BlockProtocol BlockA = ProtocolA
type instance HeaderHash    BlockA = Strict.ByteString

data instance CodecConfig BlockA = CCfgA
  deriving (Generic, NoUnexpectedThunks)

instance ConfigSupportsNode BlockA where
  getSystemStart     _ = SystemStart dawnOfTime
  getNetworkMagic    _ = NetworkMagic 0
  getProtocolMagicId _ = ProtocolMagicId 0

instance StandardHash BlockA

instance Measured BlockMeasure BlockA where
  measure = blockMeasure

instance HasHeader BlockA where
  getHeaderFields = getBlockHeaderFields

instance HasHeader (Header BlockA) where
  getHeaderFields = castHeaderFields . hdrA_fields

instance GetPrevHash BlockA where
  headerPrevHash _cfg = hdrA_prev

instance HasAnnTip BlockA where

instance BasicEnvelopeValidation BlockA where
  -- Use defaults

instance ValidateEnvelope BlockA where

data instance LedgerState BlockA = LgrA {
      lgrA_tip :: Point BlockA

      -- | The 'SlotNo' of the block containing the 'InitiateAtoB' transaction
    , lgrA_transition :: Maybe SlotNo
    }
  deriving (Show, Eq, Generic, Serialise)
  deriving NoUnexpectedThunks via OnlyCheckIsWHNF "LgrA" (LedgerState BlockA)

data PartialLedgerConfigA = LCfgA {
      lcfgA_k           :: SecurityParam
    , lcfgA_systemStart :: SystemStart
    , lcfgA_forgeTxs    :: Map SlotNo [GenTx BlockA]
    }
  deriving NoUnexpectedThunks via OnlyCheckIsWHNF "LCfgA" PartialLedgerConfigA

type instance LedgerCfg (LedgerState BlockA) =
    (EpochInfo Identity, PartialLedgerConfigA)

instance IsLedger (LedgerState BlockA) where
  type LedgerErr (LedgerState BlockA) = Void
  applyChainTick _ = Ticked
  ledgerTipPoint   = castPoint . lgrA_tip

instance ApplyBlock (LedgerState BlockA) BlockA where
  applyLedgerBlock cfg blk =
        fmap setTip
      . repeatedlyM (applyTx (blockConfigLedger cfg)) (blkA_body blk)
    where
      setTip :: TickedLedgerState BlockA -> LedgerState BlockA
      setTip (Ticked _ st) = st { lgrA_tip = blockPoint blk }

  reapplyLedgerBlock cfg blk st =
      case runExcept $ applyLedgerBlock cfg blk st of
        Left  _   -> error "reapplyLedgerBlock: impossible"
        Right st' -> st'

instance UpdateLedger BlockA

instance CommonProtocolParams BlockA where
  maxHeaderSize _ = maxBound
  maxTxSize     _ = maxBound

instance CanForge BlockA where
  forgeBlock tlc _ bno (Ticked sno st) _txs _ = BlkA {
        blkA_header = HdrA {
            hdrA_fields = HeaderFields {
                headerFieldHash    = Lazy.toStrict . B.encode $ unSlotNo sno
              , headerFieldSlot    = sno
              , headerFieldBlockNo = bno
              }
          , hdrA_prev = ledgerTipHash st
          }
      , blkA_body = Map.findWithDefault [] sno (lcfgA_forgeTxs ledgerConfig)
      }
    where
      ledgerConfig :: PartialLedgerConfig BlockA
      ledgerConfig = snd $ configLedger tlc

instance BlockSupportsProtocol BlockA where
  validateView _ _ = ()

instance LedgerSupportsProtocol BlockA where
  protocolLedgerView   _ _ = ()
  ledgerViewForecastAt _ _ = Just . trivialForecast

instance HasPartialConsensusConfig ProtocolA

instance HasPartialLedgerConfig BlockA where
  type PartialLedgerConfig BlockA = PartialLedgerConfigA

  completeLedgerConfig _ = (,)

data TxPayloadA = InitiateAtoB
  deriving (Show, Eq, Generic, NoUnexpectedThunks, Serialise)

-- | See 'Ouroboros.Consensus.HardFork.History.EraParams.safeFromTip'
safeFromTipA :: SecurityParam -> Word64
safeFromTipA (SecurityParam k) = k

-- | This mock ledger assumes that every node is honest and online, every slot
-- has a single leader, and ever message arrives before the next slot. So a run
-- of @k@ slots is guaranteed to extend the chain by @k@ blocks.
stabilityWindowA :: SecurityParam -> Word64
stabilityWindowA (SecurityParam k) = k

instance LedgerSupportsMempool BlockA where
  data GenTx BlockA = TxA {
         txA_id      :: TxId (GenTx BlockA)
       , txA_payload :: TxPayloadA
       }
    deriving (Show, Eq, Generic, Serialise)
    deriving NoUnexpectedThunks via OnlyCheckIsWHNF "TxA" (GenTx BlockA)

  type ApplyTxErr BlockA = Void

  applyTx _ (TxA _ tx) (Ticked sno st) =
      case tx of
        InitiateAtoB -> do
          return $ Ticked sno $ st { lgrA_transition = Just sno }

  reapplyTx = applyTx

  maxTxCapacity _ = maxBound
  txInBlockSize _ = 0

instance HasTxId (GenTx BlockA) where
  newtype TxId (GenTx BlockA) = TxIdA Int
    deriving stock   (Show, Eq, Ord, Generic)
    deriving newtype (NoUnexpectedThunks, Serialise)

  txId = txA_id

instance ShowQuery (Query BlockA) where
  showResult qry = case qry of {}

instance QueryLedger BlockA where
  data Query BlockA result
    deriving (Show)

  answerQuery _ qry = case qry of {}
  eqQuery qry _qry' = case qry of {}

instance ConvertRawHash BlockA where
  toRawHash   _ = id
  fromRawHash _ = id
  hashSize    _ = 8 -- We use the SlotNo as the hash, which is Word64

data instance NestedCtxt_ BlockA f a where
  CtxtA :: NestedCtxt_ BlockA f (f BlockA)

deriving instance Show (NestedCtxt_ BlockA f a)
instance SameDepIndex (NestedCtxt_ BlockA f)

instance TrivialDependency (NestedCtxt_ BlockA f) where
  type TrivialIndex (NestedCtxt_ BlockA f) = f BlockA
  hasSingleIndex CtxtA CtxtA = Refl
  indexIsTrivial = CtxtA

instance EncodeDisk BlockA (Header BlockA)
instance DecodeDisk BlockA (Lazy.ByteString -> Header BlockA) where
  decodeDisk _ = const <$> decode

instance EncodeDiskDepIx (NestedCtxt Header) BlockA
instance EncodeDiskDep   (NestedCtxt Header) BlockA

instance DecodeDiskDepIx (NestedCtxt Header) BlockA
instance DecodeDiskDep   (NestedCtxt Header) BlockA

instance HasNestedContent Header BlockA where
  -- Use defaults

instance ReconstructNestedCtxt Header BlockA
  -- Use defaults

instance SingleEraBlock BlockA where
  singleEraInfo _ = SingleEraInfo "A"

  singleEraTransition cfg EraParams{..} eraStart st = do
      confirmedInSlot <- lgrA_transition st

      -- The ledger must report the scheduled transition to the next era as soon
      -- as the block containing this transaction is immutable (that is, at
      -- least @k@ blocks have come after) -- this happens elsewhere in the
      -- corresponding 'SingleEraBlock' instance. It must not report it sooner
      -- than that because the consensus layer requires that conversions about
      -- time (when successful) must not be subject to rollback.
      let confirmationDepth =
            case ledgerTipSlot st of
              Origin      -> error "impossible"
              NotOrigin s -> if s < confirmedInSlot
                               then error "impossible"
                               else History.countSlots s confirmedInSlot
      guard $ confirmationDepth >= stabilityWindowA (lcfgA_k cfg)

      -- Consensus /also/ insists that as long as the transition to the next era
      -- is not yet known (ie not yet determined by an immutable block), there
      -- is a safe zone that extends past the tip of the ledger in which we
      -- guarantee the next era will not begin. This means that we must have an
      -- additional @safeFromTipA k@ blocks /after/ reporting the transition and
      -- /before/ the start of the next era.
      --
      -- Thus, we schedule the next era to begin with the first upcoming epoch
      -- that starts /after/ we're guaranteed to see both the aforementioned @k@
      -- additional blocks and also a further @safeFromTipA k@ slots after the
      -- last of those.

      let -- The last slot that must be in the current era
          firstPossibleLastSlotThisEra =
            History.addSlots
              (stabilityWindowA k + safeFromTipA k)
              confirmedInSlot

          -- The 'EpochNo' corresponding to 'firstPossibleLastSlotThisEra'
          lastEpochThisEra = slotToEpoch firstPossibleLastSlotThisEra

          -- The first epoch that may be in the next era
          -- (recall: eras are epoch-aligned)
          firstEpochNextEra = succ lastEpochThisEra

      return firstEpochNextEra
   where
      k = lcfgA_k cfg

      -- Slot conversion (valid for slots in this era only)
      slotToEpoch :: SlotNo -> EpochNo
      slotToEpoch s =
          History.addEpochs
            (History.countSlots s (boundSlot eraStart) `div` unEpochSize eraEpochSize)
            (boundEpoch eraStart)

instance HasTxs BlockA where
  extractTxs = blkA_body

{-------------------------------------------------------------------------------
  Condense
-------------------------------------------------------------------------------}

instance CondenseConstraints BlockA

instance Condense BlockA                where condense = show
instance Condense (Header BlockA)       where condense = show
instance Condense (GenTx BlockA)        where condense = show
instance Condense (TxId (GenTx BlockA)) where condense = show

{-------------------------------------------------------------------------------
  Top-level serialisation constraints
-------------------------------------------------------------------------------}

instance SerialiseConstraintsHFC          BlockA
instance ImmDbSerialiseConstraints        BlockA
instance VolDbSerialiseConstraints        BlockA
instance LgrDbSerialiseConstraints        BlockA
instance SerialiseDiskConstraints         BlockA
instance SerialiseNodeToNodeConstraints   BlockA
instance SerialiseNodeToClientConstraints BlockA

{-------------------------------------------------------------------------------
  SerialiseDiskConstraints
-------------------------------------------------------------------------------}

deriving instance Serialise (AnnTip BlockA)

instance EncodeDisk BlockA (LedgerState BlockA)
instance DecodeDisk BlockA (LedgerState BlockA)

instance EncodeDisk BlockA BlockA
instance DecodeDisk BlockA (Lazy.ByteString -> BlockA) where
  decodeDisk _ = const <$> decode

instance EncodeDisk BlockA (AnnTip BlockA)
instance DecodeDisk BlockA (AnnTip BlockA)

instance EncodeDisk BlockA ()
instance DecodeDisk BlockA ()

instance HasNetworkProtocolVersion BlockA

{-------------------------------------------------------------------------------
  SerialiseNodeToNode
-------------------------------------------------------------------------------}

instance SerialiseNodeToNode BlockA BlockA
instance SerialiseNodeToNode BlockA Strict.ByteString
instance SerialiseNodeToNode BlockA (Serialised BlockA)
instance SerialiseNodeToNode BlockA (SerialisedHeader BlockA)
instance SerialiseNodeToNode BlockA (GenTx BlockA)
instance SerialiseNodeToNode BlockA (GenTxId BlockA)

-- Must be compatible with @(SerialisedHeader BlockA)@, which uses
-- the @Serialise (SerialisedHeader BlockA)@ instance below
instance SerialiseNodeToNode BlockA (Header BlockA) where
  encodeNodeToNode _ _ = wrapCBORinCBOR   encode
  decodeNodeToNode _ _ = unwrapCBORinCBOR (const <$> decode)

instance Serialise (SerialisedHeader BlockA) where
  encode = encodeTrivialSerialisedHeader
  decode = decodeTrivialSerialisedHeader

{-------------------------------------------------------------------------------
  SerialiseNodeToClient
-------------------------------------------------------------------------------}

instance SerialiseNodeToClient BlockA BlockA
instance SerialiseNodeToClient BlockA (Serialised BlockA)
instance SerialiseNodeToClient BlockA (GenTx BlockA)

instance SerialiseNodeToClient BlockA Void where
  encodeNodeToClient _ _ = absurd
  decodeNodeToClient _ _ = fail "no ApplyTxErr to be decoded"

instance SerialiseNodeToClient BlockA (SomeBlock Query BlockA) where
  encodeNodeToClient _ _ (SomeBlock q) = case q of {}
  decodeNodeToClient _ _ = fail "there are no queries to be decoded"

instance SerialiseResult BlockA (Query BlockA) where
  encodeResult _ _ = \case {}
  decodeResult _ _ = \case {}
