{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Test.Consensus.Ledger.Mock (tests) where

import           Codec.CBOR.Write (toLazyByteString)
import           Codec.Serialise (Serialise, encode)
import qualified Data.ByteString as Strict
import qualified Data.ByteString.Lazy as Lazy
import           Data.Proxy
import           Data.Typeable

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.QuickCheck

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Mock.Ledger.Block

import           Ouroboros.Consensus.Storage.Common (BinaryBlockInfo (..))

import           Test.Consensus.Ledger.Mock.Generators ()

tests :: TestTree
tests = testGroup "Mock"
    [ props (Proxy @SimpleStandardCrypto) "SimpleStandardCrypto"
    , props (Proxy @SimpleMockCrypto)     "SimpleMockCrypto"
    ]
  where
    props :: forall c proxy.
             ( SimpleCrypto c
             , Arbitrary (HeaderHash (SimpleBlock c ()))
             )
          => proxy c -> String -> TestTree
    props _ title = testGroup title
      [ testProperty "BinaryBlockInfo sanity check" (prop_simpleBlockBinaryBlockInfo @c @())
      , testGroup "ConvertRawHash sanity check"
          [ testProperty "fromRawHash/toRawHash" (prop_simpleBlock_fromRawHash_toRawHash @c @())
          , testProperty "hashSize sanity check" (prop_simpleBlock_hashSize @c @())
          ]
      ]

{-------------------------------------------------------------------------------
  BinaryBlockInfo
-------------------------------------------------------------------------------}

prop_simpleBlockBinaryBlockInfo
  :: (SimpleCrypto c, Serialise ext, Typeable ext)
  => SimpleBlock c ext -> Property
prop_simpleBlockBinaryBlockInfo blk =
    serialisedHeader === extractedHeader
  where
    BinaryBlockInfo { headerOffset, headerSize } =
      simpleBlockBinaryBlockInfo blk

    extractedHeader :: Lazy.ByteString
    extractedHeader =
        Lazy.take (fromIntegral headerSize)   $
        Lazy.drop (fromIntegral headerOffset) $
        toLazyByteString (encode blk)

    serialisedHeader :: Lazy.ByteString
    serialisedHeader = toLazyByteString $
      encodeSimpleHeader encode (getHeader blk)

{-------------------------------------------------------------------------------
  ConvertRawHash
-------------------------------------------------------------------------------}

prop_simpleBlock_fromRawHash_toRawHash
  :: forall c ext. SimpleCrypto c
  => HeaderHash (SimpleBlock c ext) -> Property
prop_simpleBlock_fromRawHash_toRawHash h =
    h === fromRawHash p (toRawHash p h)
  where
    p = Proxy @(SimpleBlock c ext)

prop_simpleBlock_hashSize
  :: forall c ext. SimpleCrypto c
  => HeaderHash (SimpleBlock c ext) -> Property
prop_simpleBlock_hashSize h =
      counterexample ("rawHash: " ++ show (toRawHash p h))
    $ hashSize p === fromIntegral (Strict.length (toRawHash p h))
  where
    p = Proxy @(SimpleBlock c ext)
