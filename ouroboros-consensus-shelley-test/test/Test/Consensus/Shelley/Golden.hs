{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE NamedFieldPuns           #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TypeApplications         #-}
module Test.Consensus.Shelley.Golden (tests) where

import           Codec.CBOR.FlatTerm (FlatTerm, TermToken (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import           Cardano.Binary (toCBOR)
import           Cardano.Crypto.Hash (ShortHash)

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Ledger.Abstract

import           Shelley.Spec.Ledger.BaseTypes (StrictMaybe (..))
import qualified Shelley.Spec.Ledger.Credential as SL
import qualified Shelley.Spec.Ledger.Delegation.Certificates as SL
import qualified Shelley.Spec.Ledger.Keys as SL
import qualified Shelley.Spec.Ledger.PParams as SL
import           Test.Shelley.Spec.Ledger.ConcreteCryptoTypes (hashKeyVRF)
import           Test.Shelley.Spec.Ledger.Orphans ()

import           Ouroboros.Consensus.Shelley.Ledger

import           Test.Tasty
import           Test.Tasty.HUnit

import           Test.Util.Golden
import           Test.Util.Orphans.Arbitrary ()

import           Test.Cardano.Crypto.VRF.Fake (VerKeyVRF (..))

import           Test.Consensus.Shelley.Examples
import           Test.Consensus.Shelley.MockCrypto

tests :: TestTree
tests = testGroup "Golden tests"
    [ testCase "ChainDepState"  test_golden_ChainDepState
    , testCase "LedgerState"    test_golden_LedgerState
    , testCase "HeaderState"    test_golden_HeaderState
    , testCase "ExtLedgerState" test_golden_ExtLedgerState
    , testQueries
    , testResults
    ]

testQueries :: TestTree
testQueries = testGroup "Queries"
    [ testCase "LedgerTip"
        $ goldenTestQuery GetLedgerTip tipTerm
    , testCase "EpochNo"
        $ goldenTestQuery GetEpochNo echoNoTerm
    , testCase "NonMyopicMemberRewards"
        $ goldenTestQuery queryNonMyopicMemberRewards nonMyopicMemberRewardsTerm
    , testCase "CurrentPParams"
        $ goldenTestQuery GetCurrentPParams currentPParamsTerm
    , testCase "ProposedPParamsUpdates"
        $ goldenTestQuery GetProposedPParamsUpdates proposedPParamsUpdatesTerm
    , testCase "StakeDistribution"
        $ goldenTestQuery GetStakeDistribution stakeDistributionTerm
    ]
  where
    tipTerm, echoNoTerm, nonMyopicMemberRewardsTerm, currentPParamsTerm :: FlatTerm
    proposedPParamsUpdatesTerm, stakeDistributionTerm :: FlatTerm

    tipTerm =
      [ TkListLen 1
      , TkInt 0
      ]

    echoNoTerm =
      [ TkListLen 1
      , TkInt 1
      ]

    nonMyopicMemberRewardsTerm =
      [ TkListLen 2
      , TkInt 2
      , TkTag 258
      , TkListLen 1
      , TkListLen 2
      , TkInt 1
      , TkListLen 2
      , TkInt 0
      , TkBytes "}\234\&6+"
      ]

    currentPParamsTerm =
      [ TkListLen 1
      , TkInt 3
      ]

    proposedPParamsUpdatesTerm =
      [ TkListLen 1
      , TkInt 4
      ]

    stakeDistributionTerm =
      [ TkListLen 1
      , TkInt 5
      ]

    queryNonMyopicMemberRewards
      :: Query (Block ShortHash) (NonMyopicMemberRewards (TPraosMockCrypto ShortHash))
    queryNonMyopicMemberRewards =
      GetNonMyopicMemberRewards $ Set.singleton $ Right $
        (SL.KeyHashObj . SL.hashKey . SL.vKey) $ SL.KeyPair 0 0

    goldenTestQuery :: Query (Block ShortHash) result -> FlatTerm -> Assertion
    goldenTestQuery = goldenTestCBOR encodeShelleyQuery

testResults :: TestTree
testResults = testGroup "Results"
    [ testCase "LedgerTip"
        $ goldenTestResult GetLedgerTip GenesisPoint [TkListLen 0]
    , testCase "EpochNo"
        $ goldenTestResult GetEpochNo 0 [TkInt 0]
    , testCase "NonMyopicMemberRewards"
        $ goldenTestResult (GetNonMyopicMemberRewards Set.empty) nonMyopicMemberRewards [TkMapLen 0]
    , testCase "CurrentPParams"
        $ goldenTestResult GetCurrentPParams currentPParams currentPParamsTerm
    , testCase "ProposedPParamsUpdates"
        $ goldenTestResult GetProposedPParamsUpdates proposedPParamsUpdates proposedPParamsUpdatesTerm
    , testCase "StakeDistribution"
        $ goldenTestResult GetStakeDistribution stakeDistribution stakeDistributionTerm
    ]
  where
    -- TODO move to Test.Consensus.Shelley.Examples?

    nonMyopicMemberRewards :: (NonMyopicMemberRewards (TPraosMockCrypto ShortHash))
    nonMyopicMemberRewards = NonMyopicMemberRewards Map.empty

    currentPParams :: SL.PParams
    currentPParams = SL.emptyPParams

    proposedPParamsUpdates :: SL.ProposedPPUpdates (TPraosMockCrypto ShortHash)
    proposedPParamsUpdates = SL.ProposedPPUpdates $ Map.singleton
      (SL.hashKey 0)
      (SL.emptyPParamsUpdate {SL._keyDeposit = SJust 100})

    stakeDistribution :: SL.PoolDistr (TPraosMockCrypto ShortHash)
    stakeDistribution = SL.PoolDistr $ Map.singleton
      (SL.KeyHash $ SL.hash 0)
      (1, hashKeyVRF $ VerKeyFakeVRF 0)

    currentPParamsTerm :: FlatTerm
    currentPParamsTerm =
      [ TkListLen 18
      , TkInt 0
      , TkInt 0
      , TkInt 0
      , TkInt 2048
      , TkInt 0
      , TkInt 0
      , TkInt 0
      , TkInt 0
      , TkInt 100
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkTag 30
      , TkListLen 2
      , TkInt 0
      , TkInt 1
      , TkListLen 1
      , TkInt 0
      , TkInt 0
      , TkInt 0
      , TkInt 0
      , TkInt 0
      ]

    proposedPParamsUpdatesTerm :: FlatTerm
    proposedPParamsUpdatesTerm =
      [ TkMapLen 1
      , TkBytes "}\234\&6+"
      , TkMapLen 1
      , TkInt 5
      , TkInt 100
      ]

    stakeDistributionTerm :: FlatTerm
    stakeDistributionTerm =
      [ TkMapLen 1
      , TkBytes "\247\223\&4\142"
      , TkListLen 2
      , TkListLen 2
      , TkInt 1
      , TkInt 1
      , TkBytes "}\234\&6+"
      ]

    goldenTestResult :: Query (Block ShortHash) result -> result -> FlatTerm -> Assertion
    goldenTestResult q = goldenTestCBOR (encodeShelleyResult q)

test_golden_ChainDepState :: Assertion
test_golden_ChainDepState = goldenTestCBOR
    toCBOR
    exampleChainDepState
    [ TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkMapLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkListLen 3
    , TkListLen 5
    , TkMapLen 2
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkBytes "\158h\140X"
    , TkInt 2
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 3
    , TkListLen 5
    , TkMapLen 2
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkBytes "\158h\140X"
    , TkInt 2
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    ]

test_golden_LedgerState :: Assertion
test_golden_LedgerState = goldenTestCBOR
    encodeShelleyLedgerState
    exampleLedgerState
    [ TkListLen 2
    , TkInt 0
    , TkListLen 3
    , TkListLen 2
    , TkInt 10
    , TkBytes "t\177\DC2\228"
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 0
    , TkListLen 7
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 6
    , TkListLen 2
    , TkInt 0
    , TkInt 34000000000000000
    , TkListLen 4
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkInt 0
    , TkListLen 2
    , TkListLen 4
    , TkMapLen 2
    , TkListLen 2
    , TkBytes "\157\184\164\ETB"
    , TkInt 1
    , TkListLen 2
    , TkBytes "\NULC\188\v\214q\172\&3\241"
    , TkInt 1000000000000000
    , TkListLen 2
    , TkBytes "\183\233\133\n"
    , TkInt 0
    , TkListLen 2
    , TkBytes "\NUL\213\129\&3\178\247P(\218"
    , TkInt 9999999999999726
    , TkInt 271
    , TkInt 3
    , TkListLen 2
    , TkMapLen 1
    , TkBytes "4\233C\154"
    , TkMapLen 1
    , TkInt 5
    , TkInt 255
    , TkMapLen 0
    , TkListLen 2
    , TkListLen 7
    , TkMapLen 3
    , TkListLen 2
    , TkInt 0
    , TkBytes "q\172\&3\241"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "\215\a\ETX\128"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "\247P(\218"
    , TkInt 10
    , TkMapLen 3
    , TkBytes "\224q\172\&3\241"
    , TkInt 0
    , TkBytes "\224\215\a\ETX\128"
    , TkInt 0
    , TkBytes "\224\247P(\218"
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 3
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "\247P(\218"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 1
    , TkListLen 2
    , TkInt 0
    , TkBytes "q\172\&3\241"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\215\a\ETX\128"
    , TkMapLen 0
    , TkMapLen 7
    , TkBytes "$\172 \147"
    , TkListLen 2
    , TkBytes "y\209\150\SI"
    , TkBytes "\239T\206\151"
    , TkBytes "4\233C\154"
    , TkListLen 2
    , TkBytes "\142/F\EM"
    , TkBytes "\231\144p\221"
    , TkBytes "h\204\223#"
    , TkListLen 2
    , TkBytes "\ENQ\233\131\170"
    , TkBytes "\SO5\v\244"
    , TkBytes "\155\240{\183"
    , TkListLen 2
    , TkBytes "\ENQ\223\182H"
    , TkBytes "\199\211z\180"
    , TkBytes "\165\&0]\254"
    , TkListLen 2
    , TkBytes "\241\&5\"Q"
    , TkBytes "\ACK\142\154~"
    , TkBytes "\170u8\193"
    , TkListLen 2
    , TkBytes "\DLE#\211\224"
    , TkBytes "\129\"\168&"
    , TkBytes "\188w6*"
    , TkListLen 2
    , TkBytes "\129\FS\253C"
    , TkBytes "\166Dj\RS"
    , TkListLen 2
    , TkMapLen 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\215\a\ETX\128"
    , TkInt 110
    , TkListLen 2
    , TkInt 0
    , TkBytes "\216e\202\188"
    , TkInt 99
    , TkMapLen 0
    , TkListLen 4
    , TkMapLen 1
    , TkBytes "K\157;\134"
    , TkInt 10
    , TkMapLen 1
    , TkBytes "K\157;\134"
    , TkListLen 9
    , TkBytes "K\157;\134"
    , TkBytes "\182\147\&0\254"
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 10
    , TkBytes "\224\247P(\218"
    , TkListLen 1
    , TkBytes "\247P(\218"
    , TkListLen 0
    , TkListLen 2
    , TkString "alice.pool"
    , TkBytes "{}"
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 18
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkInt 250
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
    , TkInt 0
    , TkInt 1
    , TkTag 30
    , TkListLen 2
    , TkInt 21
    , TkInt 10000
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 1
    , TkInt 0
    , TkInt 0
    , TkInt 0
    , TkInt 100
    , TkInt 0
    , TkListLen 18
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkInt 250
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
    , TkInt 0
    , TkInt 1
    , TkTag 30
    , TkListLen 2
    , TkInt 21
    , TkInt 10000
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 1
    , TkInt 0
    , TkInt 0
    , TkInt 0
    , TkInt 100
    , TkInt 0
    , TkListLen 3
    , TkMapLen 0
    , TkInt 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 0
    , TkMapLen 0
    , TkMapLen 7
    , TkBytes "$\172 \147"
    , TkListBegin
    , TkInt 0
    , TkInt 14
    , TkInt 28
    , TkInt 42
    , TkInt 56
    , TkInt 70
    , TkInt 84
    , TkInt 98
    , TkBreak
    , TkBytes "4\233C\154"
    , TkListBegin
    , TkInt 2
    , TkInt 16
    , TkInt 30
    , TkInt 44
    , TkInt 58
    , TkInt 72
    , TkInt 86
    , TkBreak
    , TkBytes "h\204\223#"
    , TkListBegin
    , TkInt 4
    , TkInt 18
    , TkInt 32
    , TkInt 46
    , TkInt 60
    , TkInt 74
    , TkInt 88
    , TkBreak
    , TkBytes "\155\240{\183"
    , TkListBegin
    , TkInt 6
    , TkInt 20
    , TkInt 34
    , TkInt 48
    , TkInt 62
    , TkInt 76
    , TkInt 90
    , TkBreak
    , TkBytes "\165\&0]\254"
    , TkListBegin
    , TkInt 8
    , TkInt 22
    , TkInt 36
    , TkInt 50
    , TkInt 64
    , TkInt 78
    , TkInt 92
    , TkBreak
    , TkBytes "\170u8\193"
    , TkListBegin
    , TkInt 10
    , TkInt 24
    , TkInt 38
    , TkInt 52
    , TkInt 66
    , TkInt 80
    , TkInt 94
    , TkBreak
    , TkBytes "\188w6*"
    , TkListBegin
    , TkInt 12
    , TkInt 26
    , TkInt 40
    , TkInt 54
    , TkInt 68
    , TkInt 82
    , TkInt 96
    , TkBreak
    ]

test_golden_HeaderState :: Assertion
test_golden_HeaderState = goldenTestCBOR
    encodeShelleyHeaderState
    exampleHeaderState
    [ TkListLen 3
    , TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkMapLen 1
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkListLen 3
    , TkListLen 5
    , TkMapLen 1
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 0
    , TkListLen 0
    ]

test_golden_ExtLedgerState :: Assertion
test_golden_ExtLedgerState = goldenTestCBOR
    encodeShelleyExtLedgerState
    exampleExtLedgerState
    [ TkListLen 2
    , TkInt 0
    , TkListLen 3
    , TkListLen 2
    , TkInt 10
    , TkBytes "t\177\DC2\228"
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 0
    , TkListLen 7
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 6
    , TkListLen 2
    , TkInt 0
    , TkInt 34000000000000000
    , TkListLen 4
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkInt 0
    , TkListLen 2
    , TkListLen 4
    , TkMapLen 2
    , TkListLen 2
    , TkBytes "\157\184\164\ETB"
    , TkInt 1
    , TkListLen 2
    , TkBytes "\NULC\188\v\214q\172\&3\241"
    , TkInt 1000000000000000
    , TkListLen 2
    , TkBytes "\183\233\133\n"
    , TkInt 0
    , TkListLen 2
    , TkBytes "\NUL\213\129\&3\178\247P(\218"
    , TkInt 9999999999999726
    , TkInt 271
    , TkInt 3
    , TkListLen 2
    , TkMapLen 1
    , TkBytes "4\233C\154"
    , TkMapLen 1
    , TkInt 5
    , TkInt 255
    , TkMapLen 0
    , TkListLen 2
    , TkListLen 7
    , TkMapLen 3
    , TkListLen 2
    , TkInt 0
    , TkBytes "q\172\&3\241"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "\215\a\ETX\128"
    , TkInt 10
    , TkListLen 2
    , TkInt 0
    , TkBytes "\247P(\218"
    , TkInt 10
    , TkMapLen 3
    , TkBytes "\224q\172\&3\241"
    , TkInt 0
    , TkBytes "\224\215\a\ETX\128"
    , TkInt 0
    , TkBytes "\224\247P(\218"
    , TkInt 0
    , TkMapLen 0
    , TkMapLen 3
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 0
    , TkListLen 2
    , TkInt 0
    , TkBytes "\247P(\218"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 1
    , TkListLen 2
    , TkInt 0
    , TkBytes "q\172\&3\241"
    , TkListLen 3
    , TkInt 10
    , TkInt 0
    , TkInt 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\215\a\ETX\128"
    , TkMapLen 0
    , TkMapLen 7
    , TkBytes "$\172 \147"
    , TkListLen 2
    , TkBytes "y\209\150\SI"
    , TkBytes "\239T\206\151"
    , TkBytes "4\233C\154"
    , TkListLen 2
    , TkBytes "\142/F\EM"
    , TkBytes "\231\144p\221"
    , TkBytes "h\204\223#"
    , TkListLen 2
    , TkBytes "\ENQ\233\131\170"
    , TkBytes "\SO5\v\244"
    , TkBytes "\155\240{\183"
    , TkListLen 2
    , TkBytes "\ENQ\223\182H"
    , TkBytes "\199\211z\180"
    , TkBytes "\165\&0]\254"
    , TkListLen 2
    , TkBytes "\241\&5\"Q"
    , TkBytes "\ACK\142\154~"
    , TkBytes "\170u8\193"
    , TkListLen 2
    , TkBytes "\DLE#\211\224"
    , TkBytes "\129\"\168&"
    , TkBytes "\188w6*"
    , TkListLen 2
    , TkBytes "\129\FS\253C"
    , TkBytes "\166Dj\RS"
    , TkListLen 2
    , TkMapLen 2
    , TkListLen 2
    , TkInt 0
    , TkBytes "\215\a\ETX\128"
    , TkInt 110
    , TkListLen 2
    , TkInt 0
    , TkBytes "\216e\202\188"
    , TkInt 99
    , TkMapLen 0
    , TkListLen 4
    , TkMapLen 1
    , TkBytes "K\157;\134"
    , TkInt 10
    , TkMapLen 1
    , TkBytes "K\157;\134"
    , TkListLen 9
    , TkBytes "K\157;\134"
    , TkBytes "\182\147\&0\254"
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 10
    , TkBytes "\224\247P(\218"
    , TkListLen 1
    , TkBytes "\247P(\218"
    , TkListLen 0
    , TkListLen 2
    , TkString "alice.pool"
    , TkBytes "{}"
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 18
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkInt 250
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
    , TkInt 0
    , TkInt 1
    , TkTag 30
    , TkListLen 2
    , TkInt 21
    , TkInt 10000
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 1
    , TkInt 0
    , TkInt 0
    , TkInt 0
    , TkInt 100
    , TkInt 0
    , TkListLen 18
    , TkInt 0
    , TkInt 0
    , TkInt 50000
    , TkInt 10000
    , TkInt 10000
    , TkInt 7
    , TkInt 250
    , TkInt 10000
    , TkInt 100
    , TkTag 30
    , TkListLen 2
    , TkInt 0
    , TkInt 1
    , TkTag 30
    , TkListLen 2
    , TkInt 21
    , TkInt 10000
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 5
    , TkTag 30
    , TkListLen 2
    , TkInt 1
    , TkInt 2
    , TkListLen 1
    , TkInt 0
    , TkInt 0
    , TkInt 0
    , TkInt 100
    , TkInt 0
    , TkListLen 3
    , TkMapLen 0
    , TkInt 0
    , TkListLen 3
    , TkMapLen 0
    , TkMapLen 0
    , TkMapLen 0
    , TkListLen 0
    , TkMapLen 0
    , TkMapLen 7
    , TkBytes "$\172 \147"
    , TkListBegin
    , TkInt 0
    , TkInt 14
    , TkInt 28
    , TkInt 42
    , TkInt 56
    , TkInt 70
    , TkInt 84
    , TkInt 98
    , TkBreak
    , TkBytes "4\233C\154"
    , TkListBegin
    , TkInt 2
    , TkInt 16
    , TkInt 30
    , TkInt 44
    , TkInt 58
    , TkInt 72
    , TkInt 86
    , TkBreak
    , TkBytes "h\204\223#"
    , TkListBegin
    , TkInt 4
    , TkInt 18
    , TkInt 32
    , TkInt 46
    , TkInt 60
    , TkInt 74
    , TkInt 88
    , TkBreak
    , TkBytes "\155\240{\183"
    , TkListBegin
    , TkInt 6
    , TkInt 20
    , TkInt 34
    , TkInt 48
    , TkInt 62
    , TkInt 76
    , TkInt 90
    , TkBreak
    , TkBytes "\165\&0]\254"
    , TkListBegin
    , TkInt 8
    , TkInt 22
    , TkInt 36
    , TkInt 50
    , TkInt 64
    , TkInt 78
    , TkInt 92
    , TkBreak
    , TkBytes "\170u8\193"
    , TkListBegin
    , TkInt 10
    , TkInt 24
    , TkInt 38
    , TkInt 52
    , TkInt 66
    , TkInt 80
    , TkInt 94
    , TkBreak
    , TkBytes "\188w6*"
    , TkListBegin
    , TkInt 12
    , TkInt 26
    , TkInt 40
    , TkInt 54
    , TkInt 68
    , TkInt 82
    , TkInt 96
    , TkBreak
    , TkListLen 3
    , TkListLen 2
    , TkInt 0
    , TkListLen 2
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkMapLen 1
    , TkListLen 2
    , TkInt 1
    , TkInt 1
    , TkListLen 3
    , TkListLen 5
    , TkMapLen 1
    , TkBytes "U\165@\b"
    , TkInt 1
    , TkListLen 2
    , TkInt 1
    , TkBytes "K\245\DC2/4ET\197;\222.\187\140\210\183\227\209`\n\214\&1\195\133\165\215\204\226<w\133E\154"
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkListLen 1
    , TkInt 0
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 2
    , TkInt 1
    , TkBytes "\219\193\180\201\NUL\255\228\141W[]\165\198\&8\EOT\SOH%\246]\176\254>$IKv\234\152dW\217\134"
    , TkListLen 0
    , TkListLen 0
    ]
