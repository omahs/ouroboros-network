{-# LANGUAGE DeriveGeneric #-}

module Ouroboros.Network.PeerSelection.PeerSharing.Type
  ( PeerSharing (..)
  , combinePeerInformation
  ) where

import           Data.Aeson
import qualified Data.Text as Text
import           GHC.Generics (Generic)
import           Ouroboros.Network.PeerSelection.PeerAdvertise.Type
                     (PeerAdvertise (..))

-- | Is a peer willing to participate in Peer Sharing? If yes are others allowed
-- to share this peer's address?
-- This information shall come from the Node's configuration file. Other peer's
-- willingness information is received via Handshake.
--
-- NOTE: This information is only useful if P2P flag is enabled.
--
data PeerSharing = NoPeerSharing -- ^ Peer does not participate in Peer Sharing
                                 -- at all
                 | PeerSharingPrivate -- ^ Peer participates in Peer Sharing but
                                      -- its address should be private
                 | PeerSharingPublic -- ^ Peer participates in Peer Sharing
  deriving  (Eq, Show, Read, Generic)

instance FromJSON PeerSharing where
  parseJSON = withText "PeerSharing" $
    return . read . Text.unpack

instance ToJSON PeerSharing where
  toJSON = String . Text.pack . show

-- Combine a 'PeerSharing' value and a 'PeerAdvertise' value into a
-- resulting 'PeerSharing' that can be used to decide if we should
-- share or not the given Peer. According to the following rules:
--
-- - If no PeerSharing value is known then there's nothing we can assess
-- - If a peer is not participating in Peer Sharing ignore all other information
-- - If a peer said it wasn't okay to share its address, respect that no matter what.
-- - If a peer was privately configured with DoNotAdvertisePeer respect that no matter
-- what.
--
combinePeerInformation :: Maybe PeerSharing -> PeerAdvertise -> Maybe PeerSharing
combinePeerInformation Nothing                   _                  = Nothing
combinePeerInformation (Just NoPeerSharing)      _                  = Just NoPeerSharing
combinePeerInformation (Just PeerSharingPrivate) _                  = Just PeerSharingPrivate
combinePeerInformation (Just PeerSharingPublic)  DoNotAdvertisePeer = Just PeerSharingPrivate
combinePeerInformation _                         _                  = Just PeerSharingPublic
