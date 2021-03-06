{-# LANGUAGE NamedFieldPuns   #-}
{-# LANGUAGE TypeApplications #-}

module Test.ThreadNet.RealTPraos (tests) where

import           Control.Monad (replicateM)
import           Data.List ((!!))
import           Data.Proxy (Proxy (..))
import           Data.Word (Word64)

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.QuickCheck

import           Cardano.Crypto.Hash (ShortHash)
import qualified Cardano.Crypto.KES.Class as KES

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config.SecurityParam
import           Ouroboros.Consensus.Ledger.SupportsMempool (extractTxs)
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Node.ProtocolInfo
import           Ouroboros.Consensus.NodeId

import           Test.ThreadNet.General
import           Test.ThreadNet.Infra.Shelley

import           Test.Util.HardFork.Future (singleEraFuture)
import           Test.Util.Orphans.Arbitrary ()
import           Test.Util.Random

import qualified Shelley.Spec.Ledger.BaseTypes as SL
import qualified Shelley.Spec.Ledger.OCert as SL
import qualified Shelley.Spec.Ledger.PParams as SL

import           Ouroboros.Consensus.Shelley.Ledger (ShelleyBlock)
import           Ouroboros.Consensus.Shelley.Node
import           Ouroboros.Consensus.Shelley.Protocol.Crypto (KES)

import           Test.Consensus.Shelley.MockCrypto (TPraosMockCrypto)
import           Test.ThreadNet.TxGen.Shelley
import           Test.ThreadNet.Util.NodeJoinPlan (trivialNodeJoinPlan)
import           Test.ThreadNet.Util.NodeRestarts (noRestarts)
import           Test.ThreadNet.Util.NodeToNodeVersion (genVersion)

type Crypto = TPraosMockCrypto ShortHash

data TestSetup = TestSetup
  { setupD          :: Double
    -- ^ decentralization parameter
  , setupK          :: SecurityParam
  , setupTestConfig :: TestConfig
  , setupVersion    :: (NodeToNodeVersion, BlockNodeToNodeVersion (ShelleyBlock Crypto))
  }
  deriving (Show)

instance Arbitrary TestSetup where
  arbitrary = do
    setupD <- (/10)         <$> choose   (1, 10)
    setupK <- SecurityParam <$> elements [5, 10]

    setupTestConfig <- arbitrary

    setupVersion   <- genVersion (Proxy @(ShelleyBlock Crypto))

    pure TestSetup
      { setupD
      , setupK
      , setupTestConfig
      , setupVersion
      }

  -- TODO shrink

tests :: TestTree
tests = testGroup "RealTPraos"
    [ testProperty "simple convergence" $ withMaxSuccess 20 $ \setup ->
        prop_simple_real_tpraos_convergence setup
    ]

prop_simple_real_tpraos_convergence :: TestSetup -> Property
prop_simple_real_tpraos_convergence TestSetup
  { setupD
  , setupK
  , setupTestConfig
  , setupVersion
  } =
    prop_general PropGeneralArgs
      { pgaBlockProperty      = const $ property True
      , pgaCountTxs           = fromIntegral . length . extractTxs
      , pgaExpectedCannotLead = noExpectedCannotLeads
      , pgaFirstBlockNo       = 0
      , pgaFixedMaxForkLength = Nothing
      , pgaFixedSchedule      = Nothing
      , pgaSecurityParam      = setupK
      , pgaTestConfig         = setupTestConfig
      , pgaTestConfigB        = testConfigB
      }
      testOutput
  where
    TestConfig
      { initSeed
      , numCoreNodes
      } = setupTestConfig

    testConfigB = TestConfigB
      { forgeEbbEnv  = Nothing
      , future       = singleEraFuture tpraosSlotLength epochSize
      , messageDelay = noCalcMessageDelay
      , nodeJoinPlan = trivialNodeJoinPlan numCoreNodes
      , nodeRestarts = noRestarts
      , txGenExtra   = ShelleyTxGenExtra $ mkGenEnv coreNodes
      , version      = setupVersion
      }

    testOutput =
        runTestNetwork setupTestConfig testConfigB TestConfigMB
            { nodeInfo = \(CoreNodeId nid) ->
              plainTestNodeInitialization $
                mkProtocolRealTPraos
                  genesisConfig
                  SL.NeutralNonce
                  (coreNodes !! fromIntegral nid)
            , mkRekeyM = Nothing
            }

    initialKESPeriod :: SL.KESPeriod
    initialKESPeriod = SL.KESPeriod 0

    maxKESEvolutions :: Word64
    maxKESEvolutions = fromIntegral $
      KES.totalPeriodsKES (Proxy @(KES Crypto))

    coreNodes :: [CoreNode Crypto]
    coreNodes =
        withSeed initSeed $
        replicateM (fromIntegral n) $
        genCoreNode initialKESPeriod
      where
        NumCoreNodes n = numCoreNodes

    genesisConfig :: ShelleyGenesis Crypto
    genesisConfig =
        mkGenesisConfig
          (SL.ProtVer 0 0)
          setupK
          setupD
          tpraosSlotLength
          maxKESEvolutions
          coreNodes

    epochSize :: EpochSize
    epochSize = sgEpochLength genesisConfig
