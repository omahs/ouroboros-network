{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Various things common to iterations of the Praos protocol.
module Ouroboros.Consensus.Protocol.Praos.Common (
    MaxMajorProtVer (..)
  , PraosCanBeLeader (..)
  , PraosChainSelectView (..)
  , SelfIssued (..)
  ) where

import qualified Cardano.Crypto.VRF as VRF
import           Cardano.Ledger.Crypto (Crypto, VRF)
import qualified Cardano.Ledger.Shelley.API as SL
import qualified Cardano.Protocol.TPraos.OCert as OCert
import           Cardano.Slotting.Block (BlockNo)
import           Cardano.Slotting.Slot (SlotNo)
import           Data.Function (on)
import           Data.Ord (Down (Down))
import           Data.Word (Word64)
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks)
import           Numeric.Natural (Natural)

-- | The maximum major protocol version.
--
-- Must be at least the current major protocol version. For Cardano mainnet, the
-- Shelley era has major protocol verison __2__.
newtype MaxMajorProtVer = MaxMajorProtVer
  { getMaxMajorProtVer :: Natural
  }
  deriving (Eq, Show, Generic)
  deriving newtype NoThunks

-- | Separate type instead of 'Bool' for the custom 'Ord' instance +
-- documentation.
data SelfIssued
  = -- | A block we produced ourself
    SelfIssued
  | -- | A block produced by another node
    NotSelfIssued
  deriving (Show, Eq)

instance Ord SelfIssued where
  compare SelfIssued SelfIssued       = EQ
  compare NotSelfIssued NotSelfIssued = EQ
  compare SelfIssued NotSelfIssued    = GT
  compare NotSelfIssued SelfIssued    = LT

-- | View of the ledger tip for chain selection.
--
-- We order between chains as follows:
--
-- 1. By chain length, with longer chains always preferred.
-- 2. If the tip of each chain has the same slot number, we prefer the one tip
--    that we produced ourselves.
-- 3. If the tip of each chain was issued by the same agent, then we prefer
--    the chain whose tip has the highest ocert issue number.
-- 4. By the leader value of the chain tip, with lower values preferred.
data PraosChainSelectView c = PraosChainSelectView
  { csvChainLength :: BlockNo,
    csvSlotNo      :: SlotNo,
    csvIssuer      :: SL.VKey 'SL.BlockIssuer c,
    csvIssueNo     :: Word64,
    csvLeaderVRF   :: VRF.OutputVRF (VRF c)
  }
  deriving (Show, Eq, Generic, NoThunks)



instance Crypto c => Ord (PraosChainSelectView c) where
  compare =
    mconcat
      [ compare `on` csvChainLength,
        whenSame csvIssuer (compare `on` csvIssueNo),
        whenWithinDeltaSlots (compare `on` Down . csvLeaderVRF)
      ]
    where
      -- When the @a@s are equal, use the given comparison function,
      -- otherwise, no preference.
      whenSame ::
        Eq a =>
        (view -> a) ->
        (view -> view -> Ordering) ->
        (view -> view -> Ordering)
      whenSame f comp v1 v2
        | f v1 == f v2 =
            comp v1 v2
        | otherwise =
            EQ

      -- When the chain tips are within Delta (5) slots of each other,
      -- use the given comparison function, otherwise, no preference.
      whenWithinDeltaSlots ::
        (PraosChainSelectView c -> PraosChainSelectView c -> Ordering) ->
        (PraosChainSelectView c -> PraosChainSelectView c -> Ordering)
      whenWithinDeltaSlots comp v1 v2
          -- slot numbers are unsigned, so have to take care with subtraction
        | csvSlotNo v1 >= csvSlotNo v2
        , csvSlotNo v1 - csvSlotNo v2 > 5 =
            EQ

        | csvSlotNo v2 >= csvSlotNo v1
        , csvSlotNo v2 - csvSlotNo v1 > 5 =
            EQ

        | otherwise =
            comp v1 v2



data PraosCanBeLeader c = PraosCanBeLeader
  { -- | Certificate delegating rights from the stake pool cold key (or
    -- genesis stakeholder delegate cold key) to the online KES key.
    praosCanBeLeaderOpCert     :: !(OCert.OCert c),
    -- | Stake pool cold key or genesis stakeholder delegate cold key.
    praosCanBeLeaderColdVerKey :: !(SL.VKey 'SL.BlockIssuer c),
    praosCanBeLeaderSignKeyVRF :: !(SL.SignKeyVRF c)
  }
  deriving (Generic)

instance Crypto c => NoThunks (PraosCanBeLeader c)
