{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}
-- | Consensus state for Transitional Praos
module Ouroboros.Consensus.Shelley.Protocol.State (
    TPraosState -- opaque
  , currentState
  , empty
  , lastSlot
  , append
  , rewind
  , prune
  , size
  , updateLast
  ) where

import qualified Codec.CBOR.Encoding as CBOR
import           Codec.Serialise (Serialise (..))
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           GHC.Generics (Generic)
import           GHC.Stack (HasCallStack)

import           Cardano.Binary (FromCBOR (..), ToCBOR (..), enforceSize)
import           Cardano.Prelude (NoUnexpectedThunks (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Util.Assert
import           Ouroboros.Consensus.Util.Versioned

import qualified Shelley.Spec.Ledger.API as SL
import           Shelley.Spec.Ledger.Crypto

-- | Praos consensus state.
--
-- The transitional praos implementation itself has a concept of state, given
-- by the @STS.State (PRTCL c)@ type. This state, however, doesn't support
-- rewinding.
data TPraosState c = TPraosState {
      -- | Anchor
      --
      -- The anchor is the earliest slot to which we can roll back. It should
      -- correspond to the first slot with an entry in the historical state.
      --
      -- We store this for easy computation of whether a rollback is allowed,
      -- and for sanity checking of the state.
      --
      -- INVARIANT:
      -- > fst (Map.findMin historicalStates) == anchor
      --
      -- TODO remove this? This is just caching
      anchor           :: !(WithOrigin SlotNo)

      -- | Historical state snapshots.
    , historicalStates :: !(Map (WithOrigin SlotNo) (SL.ChainDepState c))
    }
  deriving (Generic, Show, Eq)

instance Crypto c => NoUnexpectedThunks (TPraosState c)

checkInvariants :: TPraosState c -> Either String ()
checkInvariants TPraosState { anchor, historicalStates }
    -- Don't use 'Map.findMin', as its partial, giving a worse error message.
    -- Use 'minViewWithKey' instead.
    | mbExpectedAnchor <- fst . fst <$> Map.minViewWithKey historicalStates
    , mbExpectedAnchor /= Just anchor
    = Left $
        "anchor (" <> show anchor <>
        ") isn't the oldest historical snapshot (" <>
        maybe "missing" show mbExpectedAnchor <>")"
    | otherwise
    = Right ()

assertInvariants :: HasCallStack => TPraosState c -> TPraosState c
assertInvariants st = assertWithMsg (checkInvariants st) st

-- | Extract the current state
currentState :: HasCallStack => TPraosState c -> SL.ChainDepState c
currentState st
    | Just (cs, _) <- Map.maxView (historicalStates st)
    = cs
    | otherwise
    = error "Empty state"

-- | Find the slot for the last state snapshot.
lastSlot :: HasCallStack => TPraosState c -> WithOrigin SlotNo
lastSlot st
    | Just ((slot, _), _) <- Map.maxViewWithKey (historicalStates st)
    = slot
    | otherwise
    = error "Empty state"

-- | Append a new state to the history.
--
-- This does not prune anything from the old history - so it's possible after
-- calling this to have a state containing more history than needed.
append
  :: SlotNo
  -> SL.ChainDepState c
  -> TPraosState c
  -> TPraosState c
append slot prtclState st = st {
      historicalStates = Map.insert (NotOrigin slot) prtclState (historicalStates st)
    }

-- | Update the last entry in the history.
--
--   This function is used to 'tick' the chain state. We expect it to be removed
--   when we update the Ticked family.
updateLast
  :: SL.ChainDepState c
  -> TPraosState c
  -> TPraosState c
updateLast prtclState st = st {
    historicalStates = Map.insert (lastSlot st) prtclState (historicalStates st)
  }

-- | Prune the state to a given maximum size
prune
  :: Int -- ^ Size (in terms of number of blocks) to prune the state to.
  -> TPraosState c
  -> TPraosState c
prune toSize st
    | oldestIx < 0
    = st
    | otherwise
    = let (newAnchor, anchoredSt) = Map.elemAt oldestIx hs
          (_, newStates)          = Map.split newAnchor hs
      in assertInvariants TPraosState {
          anchor           = newAnchor
        , historicalStates = Map.insert newAnchor anchoredSt newStates
        }
  where
    hs = historicalStates st
    oldestIx = Map.size hs - toSize

size :: TPraosState c -> Int
size = Map.size . historicalStates

-- | Rewind the state to the specified slot
--
-- The state is rewound to its position at the _end_ of the specified slot
-- (i.e. after any blocks in that slot have been applied)
--
-- Callers of this function should ensure that the slot we are requesting to
-- rewind to contains a block which was previously applies. However, we do not
-- technically require this - if a block has not been applied in this slot,
-- then we simply return the state as it was following the last applied block.
rewind
  :: WithOrigin SlotNo -- ^ Slot to rewind to
  -> TPraosState c
  -> Maybe (TPraosState c)
rewind toSlot st
  | toSlot < anchor st = Nothing
  | otherwise = Just $ assertInvariants TPraosState {
        -- The anchor remains the same when we rewind
        anchor           = anchor st
        -- We trim the historical states to only those before the rollback
        -- point
      , historicalStates = newStates
      }
    where
      (older, mbCurrent, _ ) = Map.splitLookup toSlot $ historicalStates st
      newStates = case mbCurrent of
        Nothing      -> older
        Just current -> Map.insert toSlot current older

empty :: WithOrigin SlotNo -> SL.ChainDepState c -> TPraosState c
empty slot prtclState = TPraosState {
      anchor           = slot
    , historicalStates = Map.singleton slot prtclState
    }

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

serialisationFormatVersion0 :: VersionNumber
serialisationFormatVersion0 = 0

instance Crypto c => Serialise (TPraosState c) where
  encode TPraosState { anchor, historicalStates } =
    encodeVersion serialisationFormatVersion0 $ mconcat [
      CBOR.encodeListLen 2
    , encode anchor
    , toCBOR historicalStates
    ]

  decode = decodeVersion
      [(serialisationFormatVersion0, Decode decodeTPraosState0)]
    where
      decodeTPraosState0 = do
        enforceSize "TPraosState" 2
        st <- TPraosState <$> fromCBOR <*> fromCBOR
        either fail return $ checkInvariants st
        return st

instance Crypto c => ToCBOR (TPraosState c) where
  toCBOR = encode

instance Crypto c => FromCBOR (TPraosState c) where
  fromCBOR = decode
