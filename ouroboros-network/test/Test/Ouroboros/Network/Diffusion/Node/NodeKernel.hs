{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Node kernel which does chain selection and block production.
--
module Test.Ouroboros.Network.Diffusion.Node.NodeKernel
  ( -- * Common types
    NtNAddr
  , NtNAddr_ (..)
  , NtNVersion
  , NtNVersionData (..)
  , NtCAddr
  , NtCVersion
  , NtCVersionData
    -- * Node kernel
  , BlockGeneratorArgs (..)
  , relayBlockGenerationArgs
  , randomBlockGenerationArgs
  , NodeKernel (..)
  , newNodeKernel
  , registerClientChains
  , unregisterClientChains
  , withNodeKernelThread
  , NodeKernelError (..)
  ) where

import           GHC.Generics (Generic)

import           Control.Concurrent.Class.MonadSTM.Strict
import           Control.Monad (replicateM, when)
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import qualified Data.ByteString.Char8 as BSC
import           Data.Coerce (coerce)
import           Data.Hashable (Hashable)
import           Data.IP (IP (..), toIPv4, toIPv6)
import qualified Data.IP as IP
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Typeable (Typeable)
import           Data.Void (Void)
import           Numeric.Natural (Natural)

import           System.Random (StdGen, randomR)

import           Data.Monoid.Synchronisation

import           Network.Socket (PortNumber)

import           Ouroboros.Network.AnchoredFragment (Anchor (..))
import           Ouroboros.Network.Block (HasHeader, SlotNo)
import qualified Ouroboros.Network.Block as Block
import           Ouroboros.Network.BlockFetch
import           Ouroboros.Network.NodeToNode.Version (DiffusionMode (..))
import           Ouroboros.Network.Protocol.Handshake.Unversioned
import           Ouroboros.Network.Snocket (TestAddress (..))

import           Ouroboros.Network.Mock.Chain (Chain)
import qualified Ouroboros.Network.Mock.Chain as Chain
import           Ouroboros.Network.Mock.ConcreteBlock (Block)
import qualified Ouroboros.Network.Mock.ConcreteBlock as ConcreteBlock
import           Ouroboros.Network.Mock.ProducerState

import           Simulation.Network.Snocket (AddressType (..),
                     GlobalAddressScheme (..))

import           Test.Ouroboros.Network.Orphans ()

import           Test.QuickCheck (Arbitrary (..), choose, chooseInt, frequency,
                     oneof)


-- | Node-to-node address type.
--
data NtNAddr_
  = EphemeralIPv4Addr Natural
  | EphemeralIPv6Addr Natural
  | IPAddr IP.IP PortNumber
  deriving (Eq, Ord, Generic)

instance Arbitrary NtNAddr_ where
  arbitrary = do
    -- TODO: Move this IP generator to ouroboros-network-testing
    a <- oneof [ IPv6 . toIPv6 <$> replicateM 8 (choose (0,0xffff))
               , IPv4 . toIPv4 <$> replicateM 4 (choose (0,255))
               ]
    frequency
      [ (1 , EphemeralIPv4Addr <$> (fromInteger <$> arbitrary))
      , (1 , EphemeralIPv6Addr <$> (fromInteger <$> arbitrary))
      , (3 , IPAddr a          <$> (read . show <$> chooseInt (0, 9999)))
      ]

instance Show NtNAddr_ where
    show (EphemeralIPv4Addr n) = "EphemeralIPv4Addr " ++ show n
    show (EphemeralIPv6Addr n) = "EphemeralIPv6Addr " ++ show n
    show (IPAddr ip port)      = "IPAddr (read \"" ++ show ip ++ "\") " ++ show port

instance GlobalAddressScheme NtNAddr_ where
    getAddressType (TestAddress addr) =
      case addr of
        EphemeralIPv4Addr _   -> IPv4Address
        EphemeralIPv6Addr _   -> IPv6Address
        IPAddr (IP.IPv4 {}) _ -> IPv4Address
        IPAddr (IP.IPv6 {}) _ -> IPv6Address
    ephemeralAddress IPv4Address = TestAddress . EphemeralIPv4Addr
    ephemeralAddress IPv6Address = TestAddress . EphemeralIPv6Addr

instance Hashable NtNAddr_

type NtNAddr        = TestAddress NtNAddr_
type NtNVersion     = UnversionedProtocol
data NtNVersionData = NtNVersionData { ntnDiffusionMode :: DiffusionMode }
  deriving Show
type NtCAddr        = TestAddress Int
type NtCVersion     = UnversionedProtocol
type NtCVersionData = UnversionedProtocolData


data BlockGeneratorArgs block s = BlockGeneratorArgs
  { bgaSlotDuration   :: DiffTime
    -- ^ slot duration

  , bgaBlockGenerator :: s -> Anchor block -> SlotNo -> (Maybe block, s)
    -- ^ block generator

  , bgaSeed           :: s
  }

-- | Do not generate blocks.
--
relayBlockGenerationArgs :: DiffTime -> seed -> BlockGeneratorArgs block seed
relayBlockGenerationArgs bgaSlotDuration bgaSeed =
  BlockGeneratorArgs
    { bgaSlotDuration
    , bgaBlockGenerator = \seed _ _ -> (Nothing, seed)
    , bgaSeed
    }


-- | Generate a block according to given probability.
--
randomBlockGenerationArgs :: DiffTime
                          -> StdGen
                          -> Int -- between 0 and 100
                          -> BlockGeneratorArgs Block StdGen
randomBlockGenerationArgs bgaSlotDuration bgaSeed quota =
  BlockGeneratorArgs
    { bgaSlotDuration
    , bgaBlockGenerator = \seed anchor slot ->
                            let block = ConcreteBlock.fixupBlock anchor
                                      . ConcreteBlock.mkPartialBlock slot
                                      -- TODO:
                                      --  * use ByteString, not String;
                                      --  * cycle through some bodies
                                      --
                                      $ ConcreteBlock.BlockBody (BSC.pack "")
                            in case randomR (0, 100) seed of
                                (r, seed') | r <= quota ->
                                             (Just block, seed')
                                           | otherwise  ->
                                             (Nothing, seed')
    , bgaSeed
    }

data NodeKernel header block m = NodeKernel {
      -- | upstream chains
      nkClientChains
        :: StrictTVar m (Map NtNAddr (StrictTVar m (Chain block))),

      -- | chain producer state
      nkChainProducerState
        :: StrictTVar m (ChainProducerState block),

      nkFetchClientRegistry :: FetchClientRegistry NtNAddr header block m
    }

newNodeKernel :: MonadSTM m => m (NodeKernel header block m)
newNodeKernel = NodeKernel
            <$> newTVarIO Map.empty
            <*> newTVarIO (ChainProducerState Chain.Genesis Map.empty 0)
            <*> newFetchClientRegistry

-- | Register a new upstream chain-sync client.
--
registerClientChains :: MonadSTM m
                     => NodeKernel header block m
                     -> NtNAddr
                     -> m (StrictTVar m (Chain block))
registerClientChains NodeKernel { nkClientChains } peerAddr = atomically $ do
    chainVar <- newTVar Chain.Genesis
    modifyTVar nkClientChains (Map.insert peerAddr chainVar)
    return chainVar


-- | Unregister an upstream chain-sync client.
--
unregisterClientChains :: MonadSTM m
                       => NodeKernel header block m
                       -> NtNAddr
                       -> m ()
unregisterClientChains NodeKernel { nkClientChains } peerAddr = atomically $
    modifyTVar nkClientChains (Map.delete peerAddr)

withSlotTime :: forall m a.
                ( MonadAsync         m
                , MonadDelay         m
                , MonadMonotonicTime m
                )
             => DiffTime
             -> ((SlotNo -> STM m SlotNo) -> m a)
             -- ^ continuation which receives a callback allowing to block until
             -- the given slot passes.  The stm action returns the slot current
             -- slot number.
             -> m a
withSlotTime slotDuration k = do
    let start = Block.SlotNo 0
    slotVar <- newTVarIO start
    let waitForSlot :: SlotNo -> STM m SlotNo
        waitForSlot slot = do
          current <- readTVar slotVar
          check (current >= slot)
          return current
    withAsync (loop slotVar (succ start)) $ \_async -> k waitForSlot
  where
    loop :: StrictTVar m SlotNo
         -> SlotNo
         -> m Void
    loop slotVar = go
      where
        go :: SlotNo -> m Void
        go next = do
          t <- getMonotonicTime
          let delay = abs
                    $ Time (slotDuration * fromIntegral (Block.unSlotNo next))
                      `diffTime` t
          threadDelay delay
          atomically $ writeTVar slotVar next
          go (succ next)


-- | Chain selection as a 'Monoid'.
--
newtype SelectChain block = SelectChain { getSelectedChain :: Chain block }

instance HasHeader block => Semigroup (SelectChain block) where
    (<>) = (coerce :: (     Chain block ->       Chain block ->       Chain block)
                   -> SelectChain block -> SelectChain block -> SelectChain block)
           Chain.selectChain

instance HasHeader block => Monoid (SelectChain block) where
    mempty = SelectChain Chain.Genesis


-- | Node kernel erros.
--
data NodeKernelError = UnexpectedSlot !SlotNo !SlotNo
  deriving (Typeable, Show)

instance Exception NodeKernelError where


-- | Run chain selection \/ block production thread.
--
withNodeKernelThread
  :: forall block header m seed a.
     ( MonadAsync         m
     , MonadMonotonicTime m
     , MonadTimer         m
     , MonadThrow         m
     , MonadThrow    (STM m)
     , HasHeader block
     )
  => BlockGeneratorArgs block seed
  -> (NodeKernel header block m -> Async m Void -> m a)
  -- ^ The continuation which has a handle to the chain selection \/ block
  -- production thread.  The thread might throw an exception.
  -> m a
withNodeKernelThread BlockGeneratorArgs { bgaSlotDuration, bgaBlockGenerator, bgaSeed }
                     k = do
    kernel <- newNodeKernel
    withSlotTime bgaSlotDuration $ \waitForSlot ->
      withAsync (blockProducerThread kernel waitForSlot) (k kernel)
  where
    blockProducerThread :: NodeKernel header block m
                        -> (SlotNo -> STM m SlotNo)
                        -> m Void
    blockProducerThread NodeKernel { nkClientChains, nkChainProducerState }
                        waitForSlot
                      = loop (Block.SlotNo 1) bgaSeed
      where
        loop :: SlotNo -> seed -> m Void
        loop nextSlot seed = do
          -- update 'ChainProducerState' whatever happens first:
          -- - generate a new block for the next slot
          -- - a longer candidate chain is available
          (nextSlot', seed') <- atomically $ runFirstToFinish $

               --
               -- block production
               --
               FirstToFinish
                 ( do currentSlot <- waitForSlot nextSlot
                      -- we are not supposed to block, apart from the above
                      -- blocking call to 'waitForSlot'.
                      when (currentSlot /= nextSlot)
                         $ throwIO (UnexpectedSlot currentSlot nextSlot)
                      cps@ChainProducerState { chainState } <-
                        readTVar nkChainProducerState
                      let anchor :: Anchor block
                          anchor = Chain.headAnchor chainState
                      -- generate a new block, which fits on top of the 'anchor'
                      case bgaBlockGenerator seed anchor currentSlot of
                        (Just block, seed')
                          |    Block.blockPoint block
                            >= Chain.headPoint chainState
                          -> let chainState' = Chain.addBlock block chainState in
                             writeTVar nkChainProducerState
                                       cps { chainState = chainState' }
                          >> return (succ nextSlot, seed')
                        (_, seed')
                          -> return (succ nextSlot, seed')
                 )

               --
               -- chain selection
               --
            <> FirstToFinish
                 ( do chains <- readTVar nkClientChains
                            >>= traverse readTVar
                      cps <- readTVar nkChainProducerState
                      let candidateChain = getSelectedChain
                                         $ foldMap SelectChain chains
                                        <> SelectChain (chainState cps)
                          cps' = switchFork candidateChain cps
                      check $ Chain.headPoint (chainState cps)
                           /= Chain.headPoint candidateChain
                      writeTVar nkChainProducerState cps'
                      -- do not update 'nextSlot'; This stm branch might run
                      -- multiple times within the current slot.
                      return (nextSlot, seed)
                 )
          loop nextSlot' seed'
