{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving  #-}

module Ouroboros.Network.Snocket
  ( -- * Snocket Interface
    Accept (..)
  , Accepted (..)
  , AddressFamily (..)
  , Snocket (..)
    -- ** Socket based Snocktes
  , SocketSnocket
  , socketSnocket
    -- ** Local Snockets
    -- Using unix sockets (posix) or named pipes (windows)
    --
  , LocalSnocket
  , localSnocket
  , LocalSocket (..)
  , LocalAddress (..)
  , localAddressFromPath
  , TestAddress (..)

  , FileDescriptor
  , socketFileDescriptor
  , localSocketFileDescriptor
  ) where

import           Control.Exception
import           Control.Monad (when)
import           Control.Monad.Class.MonadTime (DiffTime)
import           Control.Tracer (Tracer)
import           Data.Bifunctor (Bifunctor (..))
import           Data.Bifoldable (Bifoldable (..))
import           Data.Hashable
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           Quiet (Quiet (..))
#if !defined(mingw32_HOST_OS)
import           Network.Socket ( Family (AF_UNIX) )
#endif
import           Network.Socket ( Socket
                                , SockAddr (..)
                                )
#if defined(mingw32_HOST_OS)
import           Data.Bits
import           Foreign.Ptr (IntPtr (..), ptrToIntPtr)
import qualified System.Win32            as Win32
import qualified System.Win32.NamedPipes as Win32
import qualified System.Win32.Async      as Win32.Async

import           Network.Mux.Bearer.NamedPipe (namedPipeAsBearer)
#endif
import qualified Network.Socket as Socket

import           Network.Mux.Types (MuxBearer)
import           Network.Mux.Trace (MuxTrace)
import qualified Network.Mux.Bearer.Socket as Mx

import           Ouroboros.Network.IOManager


-- | Named pipes and Berkeley sockets have different API when accepting
-- a connection.  For named pipes the file descriptor created by 'createNamedPipe' is
-- supposed to be used for the first connected client.  Named pipe accept loop
-- looks this way:
--
-- > acceptLoop k = do
-- >   h <- createNamedPipe name
-- >   connectNamedPipe h
-- >   -- h is now in connected state
-- >   forkIO (k h)
-- >   acceptLoop k
--
-- For Berkeley sockets equivalent loop starts by creating a socket
-- which accepts connections and accept returns a new socket in connected
-- state
--
-- > acceptLoop k = do
-- >     s <- socket ...
-- >     bind s address
-- >     listen s
-- >     loop s
-- >   where
-- >     loop s = do
-- >       (s' , _addr') <- accept s
-- >       -- s' is in connected state
-- >       forkIO (k s')
-- >       loop s
--
-- To make common API for both we use a recursive type 'Accept', see
-- 'berkeleyAccept' below.  Creation of a socket / named pipe is part of
-- 'Snocket', but this means we need to have different recursion step for named
-- pipe & sockets.  For sockets its recursion step will always return 'accept'
-- syscall; for named pipes the first callback will reuse the file descriptor
-- created by 'open' and only subsequent calls will create a new file
-- descriptor by `createNamedPipe`, see 'namedPipeSnocket'.
--
newtype Accept m fd addr = Accept
  { runAccept :: m (Accepted fd addr, Accept m fd addr)
  }

instance Functor m => Bifunctor (Accept m) where
    bimap f g (Accept ac) = Accept (h <$> ac)
      where
        h (accepted, next) = (bimap f g accepted, bimap f g next)


data Accepted fd addr where
    AcceptFailure :: !SomeException -> Accepted fd addr
    Accepted      :: !fd -> !addr -> Accepted fd addr

instance Bifunctor Accepted where
    bimap f g (Accepted fd addr)  = Accepted (f fd) (g addr)
    bimap _ _ (AcceptFailure err) = AcceptFailure err

instance Bifoldable Accepted where
    bifoldMap f g (Accepted fd addr) = f fd <> g addr
    bifoldMap _ _ (AcceptFailure _) = mempty


-- | BSD accept loop.
--
berkeleyAccept :: IOManager
               -> Socket
               -> Accept IO Socket SockAddr
berkeleyAccept ioManager sock = go
    where
      go = Accept (acceptOne `catch` handleException)

      acceptOne
        :: IO ( Accepted  Socket SockAddr
              , Accept IO Socket SockAddr
              )
      acceptOne =
        bracketOnError
#if !defined(mingw32_HOST_OS)
          (Socket.accept sock)
#else
          (Win32.Async.accept sock)
#endif
          (Socket.close . fst)
          $ \(sock', addr') -> do
            associateWithIOManager ioManager (Right sock')
            return (Accepted sock' addr', go)

      -- Only non-async exceptions will be caught and put into the
      -- AcceptFailure variant.
      handleException
        :: SomeException
        -> IO ( Accepted  Socket SockAddr
              , Accept IO Socket SockAddr
              )
      handleException err =
        case fromException err of
          Just (SomeAsyncException _) -> throwIO err
          Nothing                     -> pure (AcceptFailure err, go)

-- | Local address, on Unix is associated with `Socket.AF_UNIX` family, on
--
-- Windows with `named-pipes`.
--
newtype LocalAddress = LocalAddress { getFilePath :: FilePath }
  deriving (Eq, Ord, Generic)
  deriving Show via Quiet LocalAddress

instance Hashable LocalAddress where
    hashWithSalt s (LocalAddress path) = hashWithSalt s path

newtype TestAddress addr = TestAddress { getTestAddress :: addr }
  deriving (Eq, Ord, Generic, Typeable)
  deriving Show via Quiet (TestAddress addr)

-- | We support either sockets or named pipes.
--
-- There are three families of addresses: 'SocketFamily' usef for Berkeley
-- sockets, 'LocalFamily' used for 'LocalAddress'es (either Unix sockets or
-- Windows named pipe addresses), and 'TestFamily' for testing purposes.
--
data AddressFamily addr where

    SocketFamily :: !Socket.Family
                 -> AddressFamily Socket.SockAddr

    LocalFamily  :: AddressFamily LocalAddress

    -- using a newtype wrapper make pattern matches on @AddressFamily@ complete,
    -- e.g. it makes 'AddressFamily' injective:
    -- @AddressFamily addr == AddressFamily addr'@ then @addr == addr'@. .
    --
    TestFamily   :: AddressFamily (TestAddress addr)

deriving instance Eq (AddressFamily addr)
deriving instance Show (AddressFamily addr)


-- | Abstract communication interface that can be used by more than
-- 'Socket'.  Snockets are polymorphic over monad which is used, this feature
-- is useful for testing and/or simulations.
--
data Snocket m fd addr = Snocket {
    getLocalAddr  :: fd -> m addr
  , getRemoteAddr :: fd -> m addr

  , addrFamily :: addr -> AddressFamily addr

  -- | Open a file descriptor  (socket / namedPipe).  For named pipes this is
  -- using 'CreateNamedPipe' syscall, for Berkeley sockets 'socket' is used..
  --
  , open          :: AddressFamily addr -> m fd

    -- | A way to create 'fd' to pass to 'connect'.  For named pipes it will
    -- use 'CreateFile' syscall.  For Berkeley sockets this the same as 'open'.
    --
    -- For named pipes we need full 'addr' rather than just address family as
    -- it is for sockets.
    --
  , openToConnect :: addr ->  m fd

    -- | `connect` is only needed for Berkeley sockets, for named pipes this is
    -- no-op.
    --
  , connect       :: fd -> addr -> m ()
  , bind          :: fd -> addr -> m ()
  , listen        :: fd -> m ()

  -- SomeException is chosen here to avoid having to include it in the Snocket
  -- type, and therefore refactoring a bunch of stuff.
  -- FIXME probably a good idea to abstract it.
  , accept        :: fd -> Accept m fd addr

  , close         :: fd -> m ()

  , toBearer      ::  DiffTime -> Tracer m MuxTrace -> fd -> MuxBearer m
  }


--
-- Socket based Snockets
--


socketAddrFamily
    :: Socket.SockAddr
    -> AddressFamily Socket.SockAddr
socketAddrFamily (Socket.SockAddrInet  _ _    ) = SocketFamily Socket.AF_INET
socketAddrFamily (Socket.SockAddrInet6 _ _ _ _) = SocketFamily Socket.AF_INET6
socketAddrFamily (Socket.SockAddrUnix _       ) = SocketFamily Socket.AF_UNIX


type SocketSnocket = Snocket IO Socket SockAddr


-- | Create a 'Snocket' for the given 'Socket.Family'. In the 'bind' method set
-- 'Socket.ReuseAddr` and 'Socket.ReusePort'.
--
socketSnocket
  :: IOManager
  -- ^ 'IOManager' interface.  We use it when we create a new socket and when we
  -- accept a connection.
  --
  -- Though it could be used in `open`, but that is going to be used in
  -- a bracket so it's better to keep it simple.
  --
  -> SocketSnocket
socketSnocket ioManager = Snocket {
      getLocalAddr   = Socket.getSocketName
    , getRemoteAddr  = Socket.getPeerName
    , addrFamily     = socketAddrFamily
    , open           = openSocket
    , openToConnect  = \addr -> openSocket (socketAddrFamily addr)
    , connect        = \s a -> do
#if !defined(mingw32_HOST_OS)
        Socket.connect s a
#else
        Win32.Async.connect s a
#endif
    , bind = \sd addr -> do
        let SocketFamily fml = socketAddrFamily addr
        when (fml == Socket.AF_INET ||
              fml == Socket.AF_INET6) $ do
          Socket.setSocketOption sd Socket.ReuseAddr 1
#if !defined(mingw32_HOST_OS)
          -- not supported on Windows 10
          Socket.setSocketOption sd Socket.ReusePort 1
#endif
          Socket.setSocketOption sd Socket.NoDelay 1
        when (fml == Socket.AF_INET6)
          -- An AF_INET6 socket can be used to talk to both IPv4 and IPv6 end points, and
          -- it is enabled by default on some systems. Disabled here since we run a separate
          -- IPv4 server instance if configured to use IPv4.
          $ Socket.setSocketOption sd Socket.IPv6Only 1

        Socket.bind sd addr
    , listen   = \s -> Socket.listen s 8
    , accept   = berkeleyAccept ioManager
      -- TODO: 'Socket.close' is interruptible by asynchronous exceptions; it
      -- should be fixed upstream, once that's done we can remove
      -- `unitnerruptibleMask_'
    , close    = uninterruptibleMask_ . Socket.close
    , toBearer = Mx.socketAsMuxBearer
    }
  where
    openSocket :: AddressFamily SockAddr -> IO Socket
    openSocket (SocketFamily family_) = do
      sd <- Socket.socket family_ Socket.Stream Socket.defaultProtocol
      associateWithIOManager ioManager (Right sd)
        -- open is designed to be used in `bracket`, and thus it's called with
        -- async exceptions masked.  The 'associteWithIOCP' is a blocking
        -- operation and thus it may throw.
        `catch` \(e :: IOException) -> do
          Socket.close sd
          throwIO e
        `catch` \(SomeAsyncException _) -> do
          Socket.close sd
          throwIO e
      return sd



--
-- LocalSnockets either based on unix sockets or named pipes.
--

#if defined(mingw32_HOST_OS)
type LocalHandle = Win32.HANDLE
#else
type LocalHandle = Socket
#endif

-- | System dependent LocalSnocket type
newtype LocalSocket  = LocalSocket { getLocalHandle :: LocalHandle }
    deriving (Eq, Generic)
    deriving Show via Quiet LocalSocket

-- | System dependent LocalSnocket
type    LocalSnocket = Snocket IO LocalSocket LocalAddress

localSnocket :: IOManager -> FilePath -> LocalSnocket
#if defined(mingw32_HOST_OS)
localSnocket ioManager path = Snocket {
      getLocalAddr  = \_ -> return localAddress
    , getRemoteAddr = \_ -> return localAddress
    , addrFamily  = \_ -> LocalFamily

    , open = \_addrFamily -> do
        hpipe <- Win32.createNamedPipe
                   path
                   (Win32.pIPE_ACCESS_DUPLEX .|. Win32.fILE_FLAG_OVERLAPPED)
                   (Win32.pIPE_TYPE_BYTE .|. Win32.pIPE_READMODE_BYTE)
                   Win32.pIPE_UNLIMITED_INSTANCES
                   65536   -- outbound pipe size
                   16384   -- inbound pipe size
                   0       -- default timeout
                   Nothing -- default security
        associateWithIOManager ioManager (Left hpipe)
          `catch` \(e :: IOException) -> do
            Win32.closeHandle hpipe
            throwIO e
          `catch` \(SomeAsyncException _) -> do
            Win32.closeHandle hpipe
            throwIO e
        pure (LocalSocket hpipe)

    -- To connect, simply create a file whose name is the named pipe name.
    , openToConnect  = \(LocalAddress pipeName) -> do
        hpipe <- Win32.connect pipeName
                   (Win32.gENERIC_READ .|. Win32.gENERIC_WRITE )
                   Win32.fILE_SHARE_NONE
                   Nothing
                   Win32.oPEN_EXISTING
                   Win32.fILE_FLAG_OVERLAPPED
                   Nothing
        associateWithIOManager ioManager (Left hpipe)
          `catch` \(e :: IOException) -> do
            Win32.closeHandle hpipe
            throwIO e
          `catch` \(SomeAsyncException _) -> do
            Win32.closeHandle hpipe
            throwIO e
        return (LocalSocket hpipe)
    , connect  = \_ _ -> pure ()

    -- Bind and listen are no-op.
    , bind     = \_ _ -> pure ()
    , listen   = \_ -> pure ()

    , accept   = \sock@(LocalSocket hpipe) -> Accept $ do
          Win32.Async.connectNamedPipe hpipe
          return (Accepted sock localAddress, acceptNext)

      -- Win32.closeHandle is not interrupible
    , close    = Win32.closeHandle . getLocalHandle

    , toBearer = \_sduTimeout tr -> namedPipeAsBearer tr . getLocalHandle
    }
  where
    localAddress :: LocalAddress
    localAddress = LocalAddress path

    acceptNext :: Accept IO LocalSocket LocalAddress
    acceptNext = go
      where
        go = Accept (acceptOne `catch` handleIOException)

        handleIOException
          :: IOException
          -> IO ( Accepted  LocalSocket LocalAddress
                , Accept IO LocalSocket LocalAddress
                )
        handleIOException err =
          pure ( AcceptFailure (toException err)
               , go
               )

        acceptOne
          :: IO ( Accepted  LocalSocket LocalAddress
                , Accept IO LocalSocket LocalAddress
                )
        acceptOne =
          bracketOnError
            (Win32.createNamedPipe
                 path
                 (Win32.pIPE_ACCESS_DUPLEX .|. Win32.fILE_FLAG_OVERLAPPED)
                 (Win32.pIPE_TYPE_BYTE .|. Win32.pIPE_READMODE_BYTE)
                 Win32.pIPE_UNLIMITED_INSTANCES
                 65536    -- outbound pipe size
                 16384    -- inbound pipe size
                 0        -- default timeout
                 Nothing) -- default security
             Win32.closeHandle
             $ \hpipe -> do
              associateWithIOManager ioManager (Left hpipe)
              Win32.Async.connectNamedPipe hpipe
              return (Accepted (LocalSocket hpipe) localAddress, go)

-- local snocket on unix
#else

localSnocket ioManager _ =
    Snocket {
        getLocalAddr  = fmap toLocalAddress . Socket.getSocketName . getLocalHandle
      , getRemoteAddr = fmap toLocalAddress . Socket.getPeerName . getLocalHandle
      , addrFamily    = const LocalFamily
      , connect       = \(LocalSocket s) addr ->
          Socket.connect s (fromLocalAddress addr)
      , bind          = \(LocalSocket fd) addr -> Socket.bind fd (fromLocalAddress addr)
      , listen        = flip Socket.listen 1 . getLocalHandle
      , accept        = bimap LocalSocket toLocalAddress
                      . berkeleyAccept ioManager
                      . getLocalHandle
      , open          = openSocket
      , openToConnect = \_addr -> openSocket LocalFamily
      , close         = uninterruptibleMask_ . Socket.close . getLocalHandle
      , toBearer      = \df tr (LocalSocket sd) -> Mx.socketAsMuxBearer df tr sd
      }
  where
    toLocalAddress :: SockAddr -> LocalAddress
    toLocalAddress (SockAddrUnix path) = LocalAddress path
    toLocalAddress _                   = error "localSnocket.toLocalAddr: impossible happend"

    fromLocalAddress :: LocalAddress -> SockAddr
    fromLocalAddress = SockAddrUnix . getFilePath

    openSocket :: AddressFamily LocalAddress -> IO LocalSocket
    openSocket LocalFamily = do
      sd <- Socket.socket AF_UNIX Socket.Stream Socket.defaultProtocol
      associateWithIOManager ioManager (Right sd)
        -- open is designed to be used in `bracket`, and thus it's called with
        -- async exceptions masked.  The 'associteWithIOManager' is a blocking
        -- operation and thus it may throw.
        `catch` \(e :: IOException) -> do
          Socket.close sd
          throwIO e
        `catch` \(SomeAsyncException _) -> do
          Socket.close sd
          throwIO e
      return (LocalSocket sd)
#endif

localAddressFromPath :: FilePath -> LocalAddress
localAddressFromPath = LocalAddress

-- | Socket file descriptor.
--
newtype FileDescriptor = FileDescriptor { getFileDescriptor :: Int }
  deriving Generic
  deriving Show via Quiet FileDescriptor

-- | We use 'unsafeFdSocket' but 'FileDescriptor' constructor is not exposed.
-- This forbids any usage of 'FileDescriptor' (at least in a straightforward
-- way) using any low level functions which operate on file descriptors.
--
socketFileDescriptor :: Socket -> IO FileDescriptor
socketFileDescriptor = fmap (FileDescriptor . fromIntegral) . Socket.unsafeFdSocket

localSocketFileDescriptor :: LocalSocket -> IO FileDescriptor
#if defined(mingw32_HOST_OS)
localSocketFileDescriptor =
  \(LocalSocket fd) -> case ptrToIntPtr fd of
    IntPtr i -> return (FileDescriptor i)
#else
localSocketFileDescriptor = socketFileDescriptor . getLocalHandle
#endif
