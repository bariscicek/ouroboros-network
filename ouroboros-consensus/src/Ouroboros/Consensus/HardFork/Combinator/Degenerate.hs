{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE EmptyCase                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

module Ouroboros.Consensus.HardFork.Combinator.Degenerate (
    DegenFork(..)
    -- * Type families
  , Header(..)
  , BlockConfig(..)
  , LedgerState(..)
  , GenTx(..)
  , TxId(..)
  , CodecConfig(..)
    -- * Test support
  , projCfg
  ) where

import           Cardano.Prelude (NoUnexpectedThunks (..))
import           Control.Monad.Except
import           Data.FingerTree.Strict (Measured (..))
import           Data.Proxy
import           Data.Type.Equality
import           Data.Void

import           Ouroboros.Network.Block
import           Ouroboros.Network.Protocol.LocalStateQuery.Codec (Some (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Config.SupportsNode
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.SupportsMempool
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Node.Run
import qualified Ouroboros.Consensus.Storage.ChainDB.Init as InitChainDB

import           Ouroboros.Consensus.HardFork.Abstract
import           Ouroboros.Consensus.HardFork.Combinator.Abstract
import           Ouroboros.Consensus.HardFork.Combinator.AcrossEras
import           Ouroboros.Consensus.HardFork.Combinator.Basics
import           Ouroboros.Consensus.HardFork.Combinator.Block
import           Ouroboros.Consensus.HardFork.Combinator.Ledger ()
import           Ouroboros.Consensus.HardFork.Combinator.Ledger.Query ()
import           Ouroboros.Consensus.HardFork.Combinator.Mempool
import           Ouroboros.Consensus.HardFork.Combinator.Node ()
import           Ouroboros.Consensus.HardFork.Combinator.Protocol ()
import           Ouroboros.Consensus.HardFork.Combinator.Unary

-- | Degenerate hard fork with a single era
--
-- NOTE: It is important to realize that in general
--
-- > HardForkBlock '[b]
--
-- and
--
-- > DegenFork b
--
-- may behave differently. Crucially, they might have
--
-- * different serialization formats, where the former uses a serialization
--   format that is forward-compatible with hard fork transitions, whereas
--   the latter may well not be
-- * related to the previous point, it will have its own network protocol
--   versioning
--
-- The main use of 'DegenFork' is for testing, and as evidence that all
-- type class instances that are required for the hard fork are present.
newtype DegenFork b = DBlk {
      unDBlk :: HardForkBlock '[b]
    }
  deriving (Eq, Show)

type instance BlockProtocol (DegenFork b) = BlockProtocol (HardForkBlock '[b])

{-------------------------------------------------------------------------------
  Data family instances
-------------------------------------------------------------------------------}

instance SingleEraBlock b => GetHeader (DegenFork b) where
  newtype Header (DegenFork b) = DHdr {
        unDHdr :: Header (HardForkBlock '[b])
      }
    deriving (Show, NoUnexpectedThunks)

  getHeader (DBlk b) = DHdr (getHeader b)

  blockMatchesHeader (DHdr hdr) (DBlk blk) =
      blockMatchesHeader (projHeader hdr) (projBlock blk)

  headerIsEBB (DHdr hdr) = headerIsEBB (projHeader hdr)

newtype instance BlockConfig (DegenFork b) = DBCfg {
      unDBCfg :: BlockConfig (HardForkBlock '[b])
    }
  deriving (NoUnexpectedThunks)

instance HasCodecConfig b => HasCodecConfig (DegenFork b) where
  newtype CodecConfig (DegenFork b) = DCCfg {
        unDCCfg :: CodecConfig (HardForkBlock '[b])
      }

  getCodecConfig = DCCfg . getCodecConfig . unDBCfg

newtype instance LedgerState (DegenFork b) = DLgr {
      unDLgr :: LedgerState (HardForkBlock '[b])
    }
  deriving (Eq, Show, NoUnexpectedThunks)

instance ConfigSupportsNode b => ConfigSupportsNode (DegenFork b) where
  getSystemStart     = getSystemStart     . unDBCfg
  getNetworkMagic    = getNetworkMagic    . unDBCfg
  getProtocolMagicId = getProtocolMagicId . unDBCfg

{-------------------------------------------------------------------------------
  Forward HasHeader instances
-------------------------------------------------------------------------------}

type instance HeaderHash (DegenFork b) = HeaderHash (HardForkBlock '[b])

instance SingleEraBlock b => StandardHash (DegenFork b)

instance SingleEraBlock b => Measured BlockMeasure (DegenFork b) where
  measure = blockMeasure

instance SingleEraBlock b => HasHeader (DegenFork b) where
    blockHash      =            blockHash     . unDBlk
    blockPrevHash  = castHash . blockPrevHash . unDBlk
    blockSlot      =            blockSlot     . unDBlk
    blockNo        =            blockNo       . unDBlk

    blockInvariant = const True

instance SingleEraBlock b => HasHeader (Header (DegenFork b)) where
  blockHash      =            blockHash     . unDHdr
  blockPrevHash  = castHash . blockPrevHash . unDHdr
  blockSlot      =            blockSlot     . unDHdr
  blockNo        =            blockNo       . unDHdr
  blockInvariant = const True

{-------------------------------------------------------------------------------
  Forward 'HardForkBlock' instances
-------------------------------------------------------------------------------}

type instance LedgerCfg (LedgerState (DegenFork b)) = LedgerCfg (LedgerState (HardForkBlock '[b]))

instance SingleEraBlock b => IsLedger (LedgerState (DegenFork b)) where
  type LedgerErr (LedgerState (DegenFork b)) = LedgerErr (LedgerState (HardForkBlock '[b]))

  applyChainTick cfg slot (DLgr lgr) = DLgr <$> applyChainTick cfg slot lgr

instance SingleEraBlock b => ApplyBlock (LedgerState (DegenFork b)) (DegenFork b) where
  applyLedgerBlock cfg (DBlk b) (Ticked slot (DLgr lgr)) =
    DLgr <$> applyLedgerBlock cfg b (Ticked slot lgr)
  reapplyLedgerBlock cfg (DBlk b) (Ticked slot (DLgr lgr)) =
    DLgr $ reapplyLedgerBlock cfg b (Ticked slot lgr)
  ledgerTipPoint (DLgr l) =
    (castPoint :: Point (HardForkBlock '[b]) -> Point (DegenFork b)) $ ledgerTipPoint l

instance SingleEraBlock b => UpdateLedger (DegenFork b)

instance SingleEraBlock b => HasHardForkHistory (DegenFork b) where
  type HardForkIndices (DegenFork b) = '[b]

  hardForkSummary cfg (DLgr lgr) = hardForkSummary cfg lgr

instance SingleEraBlock b => HasAnnTip (DegenFork b) where
  type TipInfo (DegenFork b) = TipInfo (HardForkBlock '[b])

  tipInfoHash _ = tipInfoHash (Proxy @(HardForkBlock '[b]))
  getTipInfo (DHdr hdr) = getTipInfo hdr

instance SingleEraBlock b => BasicEnvelopeValidation (DegenFork b) where
  expectedFirstBlockNo  _ = expectedFirstBlockNo  (Proxy @(HardForkBlock '[b]))
  minimumPossibleSlotNo _ = minimumPossibleSlotNo (Proxy @(HardForkBlock '[b]))
  expectedNextBlockNo   _ = expectedNextBlockNo   (Proxy @(HardForkBlock '[b]))
  minimumNextSlotNo     _ = minimumNextSlotNo     (Proxy @(HardForkBlock '[b]))

instance SingleEraBlock b => ValidateEnvelope (DegenFork b) where
  type OtherHeaderEnvelopeError (DegenFork b) = OtherHeaderEnvelopeError (HardForkBlock '[b])

  additionalEnvelopeChecks cfg view (DHdr hdr) =
      withExcept injEnvelopeErr $
        additionalEnvelopeChecks
          (projCfg cfg)
          (projLedgerView (Proxy @b) <$> view)
          (projHeader hdr)

instance SingleEraBlock b => BlockSupportsProtocol (DegenFork b) where
  validateView (DBCfg cfg) (DHdr hdr) = validateView cfg hdr
  selectView   (DBCfg cfg) (DHdr hdr) = selectView   cfg hdr

instance SingleEraBlock b => LedgerSupportsProtocol (DegenFork b) where
  protocolLedgerView   cfg (DLgr lgr) = protocolLedgerView   cfg lgr
  ledgerViewForecastAt cfg (DLgr lgr) = ledgerViewForecastAt cfg lgr

instance SingleEraBlock b => LedgerSupportsMempool (DegenFork b) where
  newtype GenTx (DegenFork b) = DTx {
        unDTx :: GenTx (HardForkBlock '[b])
      }
    deriving (Show, NoUnexpectedThunks)

  type ApplyTxErr (DegenFork b) = ApplyTxErr (HardForkBlock '[b])

  txInvariant = txInvariant . unDTx

  applyTx cfg (DTx tx) (Ticked slot (DLgr lgr)) =
    fmap DLgr <$> applyTx cfg tx (Ticked slot lgr)
  reapplyTx cfg (DTx tx) (Ticked slot (DLgr lgr)) =
    fmap DLgr <$> reapplyTx cfg tx (Ticked slot lgr)

  maxTxCapacity (Ticked slot (DLgr lgr)) =
    maxTxCapacity (Ticked slot (projLedgerState lgr))

  maxTxSize (DLgr lgr) = maxTxSize (projLedgerState lgr)

  txInBlockSize (DTx tx) = txInBlockSize (projGenTx tx)


instance SingleEraBlock b => HasTxId (GenTx (DegenFork b)) where
  newtype TxId (GenTx (DegenFork b)) = DTxId {
        unDTxId :: TxId (GenTx (HardForkBlock '[b]))
      }
    deriving (Show, Eq, Ord, NoUnexpectedThunks)

  txId (DTx tx) = DTxId (txId tx)

instance SingleEraBlock b => ShowQuery (Query (DegenFork b)) where
  showResult (DQry qry) = showResult qry

instance SingleEraBlock b => QueryLedger (DegenFork b) where
  newtype Query (DegenFork b) result = DQry {
        unDQry :: Query (HardForkBlock '[b]) result
      }
    deriving (Show)

  answerQuery cfg (DQry qry) (DLgr lgr) = answerQuery cfg qry lgr
  eqQuery (DQry qry1) (DQry qry2) = eqQuery qry1 qry2

instance SingleEraBlock b => CanForge (DegenFork b) where
  type ForgeState (DegenFork b) = ForgeState (HardForkBlock '[b])

  forgeBlock cfg upd block (Ticked slot (DLgr lgr)) txs proof =
      (DBlk . injBlock) <$>
        forgeBlock
          (projCfg cfg)
          (projForgeState (Proxy @b) upd)
          block
          (Ticked slot (projLedgerState lgr))
          (map (projGenTx . unDTx) txs)
          (projIsLeader proof)

instance HasTxs b => HasTxs (DegenFork b) where
  extractTxs = map DTx . extractTxs . unDBlk

instance SingleEraBlock b => ConvertRawHash (DegenFork b) where
  toRawHash   _ = toRawHash   (Proxy @(HardForkBlock '[b]))
  fromRawHash _ = fromRawHash (Proxy @(HardForkBlock '[b]))
  hashSize    _ = hashSize    (Proxy @(HardForkBlock '[b]))

{-------------------------------------------------------------------------------
  RunNode instance

  As discussed in the module header, for this we delegate to @b@, rather than
  to @HardForkBlock '[b]@
-------------------------------------------------------------------------------}

projCfg :: SingleEraBlock b => TopLevelConfig (DegenFork b) -> TopLevelConfig b
projCfg = projTopLevelConfig . castTopLevelConfig

instance HasNetworkProtocolVersion b => HasNetworkProtocolVersion (DegenFork b) where
  type NodeToNodeVersion   (DegenFork b) = NodeToNodeVersion   b
  type NodeToClientVersion (DegenFork b) = NodeToClientVersion b

  -- | Enumerate all supported node-to-node versions
  supportedNodeToNodeVersions   _ = supportedNodeToNodeVersions   (Proxy @b)
  supportedNodeToClientVersions _ = supportedNodeToClientVersions (Proxy @b)
  mostRecentNodeToNodeVersion   _ = mostRecentNodeToNodeVersion   (Proxy @b)
  mostRecentNodeToClientVersion _ = mostRecentNodeToClientVersion (Proxy @b)
  nodeToNodeProtocolVersion     _ = nodeToNodeProtocolVersion     (Proxy @b)
  nodeToClientProtocolVersion   _ = nodeToClientProtocolVersion   (Proxy @b)

instance (SingleEraBlock b, RunNode b) => RunNode (DegenFork b) where
  nodeBlockFetchSize     (DHdr hdr)            = nodeBlockFetchSize     (projHeader hdr)

  nodeImmDbChunkInfo  cfg = nodeImmDbChunkInfo (projCfg cfg)

  nodeAddHeaderEnvelope _ = nodeAddHeaderEnvelope (Proxy @b)
  nodeExceptionIsFatal  _ = nodeExceptionIsFatal  (Proxy @b)

  nodeInitChainDB cfg initDB =
      nodeInitChainDB
        (projCfg cfg)
        (projInitChainDB (InitChainDB.cast initDB))

  nodeCheckIntegrity cfg (DBlk blk) = nodeCheckIntegrity (projCfg cfg) (projBlock blk)

  -- Encoders

  nodeEncodeBlockWithInfo (DCCfg cfg) (DBlk blk) =
      nodeEncodeBlockWithInfo (projCodecConfig cfg) (projBlock blk)
  nodeEncodeBlock (DCCfg cfg) (DBlk blk) =
      nodeEncodeBlock (projCodecConfig cfg) (projBlock blk)
  nodeEncodeHeader (DCCfg cfg) version (DHdr hdr) =
      nodeEncodeHeader (projCodecConfig cfg) (castSerialisationVersion version) (projHeader hdr)
  nodeEncodeWrappedHeader (DCCfg cfg) version (Serialised hdr) =
      nodeEncodeWrappedHeader (projCodecConfig cfg) (castSerialisationAcrossNetwork version) (Serialised hdr)
  nodeEncodeGenTx (DCCfg cfg) (DTx tx) =
      nodeEncodeGenTx (projCodecConfig cfg) (projGenTx tx)
  nodeEncodeGenTxId (DCCfg cfg) (DTxId tid) =
      nodeEncodeGenTxId (projCodecConfig cfg) (projGenTxId tid)
  nodeEncodeHeaderHash (DCCfg cfg) hash =
      nodeEncodeHeaderHash (projCodecConfig cfg) (projHeaderHash hash)
  nodeEncodeLedgerState (DCCfg cfg) (DLgr lgr) =
      nodeEncodeLedgerState (projCodecConfig cfg) (projLedgerState lgr)
  nodeEncodeConsensusState (DCCfg cfg) st =
      nodeEncodeConsensusState (projCodecConfig cfg) (projConsensusState st)
  nodeEncodeApplyTxError (DCCfg cfg) err =
      nodeEncodeApplyTxError (projCodecConfig cfg) (projApplyTxErr err)
  nodeEncodeAnnTip (DCCfg cfg) tip =
      nodeEncodeAnnTip (projCodecConfig cfg) (projAnnTip (castAnnTip tip))
  nodeEncodeQuery (DCCfg cfg) (DQry qry) =
      projQuery qry $ \_pf qry' -> nodeEncodeQuery (projCodecConfig cfg) qry'
  nodeEncodeResult (DCCfg cfg) (DQry qry) mResult =
      projQuery qry $ \Refl qry' ->
        case mResult of
          Right result -> nodeEncodeResult (projCodecConfig cfg) qry' result
          Left  err    -> absurd $ mismatchOneEra err

  -- Decoders

  nodeDecodeBlock (DCCfg cfg) =
      (\f -> DBlk . injBlock . f) <$>
        nodeDecodeBlock (projCodecConfig cfg)
  nodeDecodeHeader (DCCfg cfg) version =
      (\f -> DHdr . injHeader . f) <$>
        nodeDecodeHeader (projCodecConfig cfg) (castSerialisationVersion version)
  nodeDecodeWrappedHeader (DCCfg cfg) version =
      (\(Serialised hdr) -> Serialised hdr) <$>
        nodeDecodeWrappedHeader (projCodecConfig cfg) (castSerialisationAcrossNetwork version)
  nodeDecodeGenTx (DCCfg cfg) =
      (DTx . injGenTx) <$>
        nodeDecodeGenTx (projCodecConfig cfg)
  nodeDecodeGenTxId (DCCfg cfg) =
      (DTxId . injGenTxId) <$>
        nodeDecodeGenTxId (projCodecConfig cfg)
  nodeDecodeHeaderHash (DCCfg cfg) =
      injHeaderHash <$>
        nodeDecodeHeaderHash (projCodecConfig cfg)
  nodeDecodeLedgerState (DCCfg cfg) =
      (DLgr . injLedgerState) <$> nodeDecodeLedgerState (projCodecConfig cfg)
  nodeDecodeConsensusState (DCCfg cfg) =
      injConsensusState <$> nodeDecodeConsensusState (projCodecConfig cfg)
  nodeDecodeApplyTxError (DCCfg cfg) =
      injApplyTxErr <$>
        nodeDecodeApplyTxError (projCodecConfig cfg)
  nodeDecodeAnnTip (DCCfg cfg) =
      (castAnnTip . injAnnTip) <$>
        nodeDecodeAnnTip (projCodecConfig cfg)
  nodeDecodeQuery (DCCfg cfg) =
      (\(Some qry) -> Some (DQry $ injQuery qry)) <$>
        nodeDecodeQuery (projCodecConfig cfg)
  nodeDecodeResult (DCCfg cfg) (DQry qry) =
      projQuery qry $ \Refl qry' ->
        Right <$> nodeDecodeResult (projCodecConfig cfg) qry'