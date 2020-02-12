{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE NamedFieldPuns      #-}

{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# LANGUAGE GADTs               #-}

{-# OPTIONS_GHC -Wno-orphans     #-}

module Test.Subscription (tests) where

import           Control.Concurrent hiding (threadDelay)
import           Control.Monad (replicateM, unless, when)
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadSay
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Monad.IOSim (runSimStrictShutdown)
import           Control.Tracer
import qualified Data.ByteString.Lazy as BL
import           Data.Functor (void)
import           Data.Int
import qualified Data.IP as IP
import           Data.List as L
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as M
import           Data.Void (Void)
import           Data.Word
import qualified Network.DNS as DNS
import qualified Network.Socket as Socket
import           Test.QuickCheck
import           Test.Tasty (TestTree, testGroup)
import           Text.Printf
import           Text.Show.Functions ()

import           Test.Tasty.QuickCheck (shuffle, testProperty)

import           Network.Mux.Time (microsecondsToDiffTime)

import           Network.TypedProtocol.Driver
import qualified Network.TypedProtocol.ReqResp.Client as ReqResp
import qualified Network.TypedProtocol.ReqResp.Server as ReqResp
import qualified Network.TypedProtocol.ReqResp.Codec.Cbor as ReqResp
import qualified Network.TypedProtocol.ReqResp.Examples as ReqResp
import           Ouroboros.Network.Protocol.Handshake.Type (acceptEq, cborTermVersionDataCodec)
import           Ouroboros.Network.Protocol.Handshake.Version (simpleSingletonVersions)


import           Ouroboros.Network.Connections.Types (Initiated, LocalOnlyRequest (..))
import qualified Ouroboros.Network.Connections.Concurrent as Connections (concurrent)
import qualified Ouroboros.Network.Connections.Concurrent as Concurrent
import           Ouroboros.Network.Connections.Socket.Types hiding (ConnectionId)
import qualified Ouroboros.Network.Connections.Socket.Types as Connections
import qualified Ouroboros.Network.Connections.Socket.Client as Socket (client)
import           Ouroboros.Network.Magic
import           Ouroboros.Network.Mux
import           Ouroboros.Network.NodeToNode
import           Ouroboros.Network.Socket as Socket
import           Ouroboros.Network.Subscription
import           Ouroboros.Network.Subscription.Ip
import           Ouroboros.Network.Subscription.Dns
import           Ouroboros.Network.Subscription.Worker as Subscription

defaultMiniProtocolLimit :: Int64
defaultMiniProtocolLimit = 3000000

data TestProtocols1 = ChainSyncPr
  deriving (Eq, Ord, Enum, Bounded, Show)

instance ProtocolEnum TestProtocols1 where
  fromProtocolEnum ChainSyncPr = MiniProtocolNum 2

instance MiniProtocolLimits TestProtocols1 where
  maximumMessageSize ChainSyncPr  = defaultMiniProtocolLimit
  maximumIngressQueue ChainSyncPr = defaultMiniProtocolLimit

-- |
-- Allow to run a singly req-resp protocol.
--
data TestProtocols2 = ReqRespPr
  deriving (Eq, Ord, Enum, Bounded, Show)

instance ProtocolEnum TestProtocols2 where
  fromProtocolEnum ReqRespPr = MiniProtocolNum 4

instance MiniProtocolLimits TestProtocols2 where
  maximumMessageSize ReqRespPr  = defaultMiniProtocolLimit
  maximumIngressQueue ReqRespPr = defaultMiniProtocolLimit


activeTracer :: Show a => Tracer IO a
activeTracer = nullTracer
-- activeTracer = _verboseTracer -- Dump log messages to stdout.

--
-- The list of all tests
--

tests :: TestTree
tests =
    testGroup "Subscription"
        [ testProperty "Resolve (Sim)"      prop_resolv_sim
        , testProperty "Resolve (IO)"       _prop_resolv_io
        , testProperty "Resolve Subscribe (IO)" prop_sub_io
        -- ^ takes about 10 minutes to run due to delays in realtime.
        , testProperty "Send Recive with Dns worker (IO)" prop_send_recv
        , testProperty "Send Recieve with IP worker, Initiator and responder (IO)"
               prop_send_recv_init_and_rsp
        -- , testProperty "subscription demo" _demo
        ]

data LookupResult = LookupResult {
      lrIpv4Result  :: !(Either DNS.DNSError [Socket.SockAddr])
    , lrIpv4Delay   :: !DiffTime
    , lrIpv6Result  :: !(Either DNS.DNSError [Socket.SockAddr])
    , lrIpv6Delay   :: !DiffTime
    , connectionRtt :: !DiffTime
    }

data LookupResultIO = LookupResultIO {
      lrioIpv4Result :: !(Either DNS.DNSError [Word16])
    , lrioIpv6Result :: !(Either DNS.DNSError [Word16])
    , lrioValency    :: !Int
    }

mockResolver :: forall m. (MonadTimer m) => LookupResult -> Resolver m
mockResolver lr = Resolver lA lAAAA
   where
    lA :: DNS.Domain -> m (Either DNS.DNSError [Socket.SockAddr])
    lA    _ = do
        threadDelay (lrIpv4Delay lr)
        return $ lrIpv4Result lr

    lAAAA :: DNS.Domain -> m (Either DNS.DNSError [Socket.SockAddr])
    lAAAA _ = do
        threadDelay (lrIpv6Delay lr)
        return $ lrIpv6Result lr

mockResolverIO :: M.Map (Socket.Family, Word16) Socket.PortNumber
               -> LookupResultIO
               -> Resolver IO
mockResolverIO portMap lr = Resolver lA lAAAA
  where
    sidToPort sid =
        case M.lookup sid portMap of
             Just port -> port
             Nothing   -> error $ "missing port for sid " ++ show sid -- XXX

    lA :: DNS.Domain -> IO (Either DNS.DNSError [Socket.SockAddr])
    lA    _ = do
        let r = case lrioIpv4Result lr of
                     (Right sids) -> Right $ map (\sid -> Socket.SockAddrInet
                         (fromIntegral $ sidToPort (Socket.AF_INET, sid))
                         (IP.toHostAddress "127.0.0.1")) sids
                     (Left e)      -> Left e
        return r

    lAAAA :: DNS.Domain -> IO (Either DNS.DNSError [Socket.SockAddr])
    lAAAA _ = do
        let r = case lrioIpv6Result lr of
                     (Right sids) -> Right $ map (\sid ->
                         Socket.SockAddrInet6 (fromIntegral $ sidToPort (Socket.AF_INET6, sid)) 0
                                              (IP.toHostAddress6 "::1") 0) sids
                     (Left e)      -> Left e
        return r

instance Show LookupResult where
    show a = printf "LookupResult: ipv4: %s delay %s ipv6: %s delay %s rtt %s" (show $ lrIpv4Result a)
                    (show $ lrIpv4Delay a) (show $ lrIpv6Result a) (show $ lrIpv6Delay a)
                    (show $ connectionRtt a)

instance Show LookupResultIO where
    show a = printf "LookupResultIO: ipv4: %s ipv6: %s first %s valency %d"
                    (show $ lrioIpv4Result a)
                    (show $ lrioIpv6Result a)
                    (lrioValency a)

instance Arbitrary DNS.DNSError where
    arbitrary = oneof [ return DNS.SequenceNumberMismatch
                      , return DNS.RetryLimitExceeded
                      ]

instance Arbitrary IP.IPv4 where
    arbitrary = do
        a <- replicateM 4 (choose (0,255))
        return $ IP.toIPv4 a

instance Arbitrary IP.IPv6 where
    arbitrary = do
        a <- replicateM 8 (choose (0,0xffff))
        return $ IP.toIPv6 a

instance Arbitrary Socket.Family where
    arbitrary = oneof [ return Socket.AF_INET
                      , return Socket.AF_INET6
                      ]

instance Arbitrary LookupResult where
    arbitrary = do
      ipv4r <- arbitrary :: Gen (Either DNS.DNSError [IP.IPv4])
      ipv4d <- choose (0, 3000)
      ipv6r <- arbitrary
      ipv6d <- oneof [ choose (0, 3000)
                     , choose (ipv4d, ipv4d + round (1000 * resolutionDelay))
                     ]
      conrtt <- choose (0, 250)

      let minDistance = 10 -- 10ms minimum time between IPv4 and IPv6 result.

      {-
       - For predictability we don't generate lookup results that are closer than 10ms to
       - each other. Since 10ms is still less than resolutionDelay we can still test that
       - behaviour related to resolutionDelay works correctly.
       -}
      let (ipv4d', ipv6d') = if abs (ipv4d - ipv6d) < minDistance
                                 then if ipv4d > ipv6d then (ipv4d + minDistance, ipv6d)
                                                       else (ipv4d, ipv6d + minDistance)
                                 else (ipv4d, ipv6d)
      let sa4s = case ipv4r of
                      (Right ips) -> Right $ map (Socket.SockAddrInet 1 . IP.toHostAddress) ips
                      (Left e)    -> Left e
      let sa6s = case ipv6r of
                      (Right ips) -> Right $ map (\ip -> Socket.SockAddrInet6 1 0
                                                 (IP.toHostAddress6 ip) 0) ips
                      (Left e)   -> Left e
      return $ LookupResult sa4s (microsecondsToDiffTime $ 1000 * ipv4d') sa6s
                            (microsecondsToDiffTime $ 1000 * ipv6d')
                            (microsecondsToDiffTime $ 1000 * conrtt)


instance Arbitrary LookupResultIO where
    arbitrary = do
        ipv4r <- oneof [ Left <$> arbitrary
                       , Right <$> shortList
                       ]
        ipv6r <- oneof [ Left <$> arbitrary
                       , Right <$> shortList
                       ]
        valency <- choose (1, 8)
        return $ LookupResultIO ipv4r ipv6r valency
      where
        shortList :: Gen [Word16]
        shortList = do
            lx <- shuffle [0..3]
            k <- choose (0, 4)
            return $ take k lx

-- | Return true if  `a` is a permutation of `b`.
permCheck :: Ord o => [o] -> [o] -> Bool
permCheck a b = L.sort a == L.sort b

--
-- Properties
--

prop_resolv :: forall m.
     ( MonadAsync m
     , MonadCatch m
     , MonadSay   m
     , MonadSTM   m
     , MonadTime  m
     , MonadTimer m
     , MonadThrow m
     )
     => LookupResult
     -> m Property
prop_resolv lr =  do
    --say $ printf "%s" $ show lr
    let resolver = mockResolver lr
        domain = "shelley-1.iohk.example"
    x <- dnsResolve nullTracer resolver domain
    !res <- checkResult <$> extractResult x []

    return $ tabulate "Resolution Result" [resolvLabel] res

  where
    checkResult :: [Socket.SockAddr] -> Property
    checkResult addrs =
        case (lrIpv4Result lr, lrIpv6Result lr) of
            (Left _, Left _)   ->
              counterexample ("got addresses from errors " ++ show addrs) $
                property $ null addrs

            (Right [], Right [])   ->
              counterexample ("got addresses from no results " ++ show addrs) $
                property $ null addrs

            (Right ea, Left _) ->
              counterexample ("A lookup not a permutation " ++ show addrs) $
                -- Expect a permutation of the result of the A lookup.
                property $ permCheck addrs ea

            (Left _, Right ea) ->
              counterexample ("AAAA lookup not a permutation " ++ show addrs) $
                -- Expect a permutation of the result of the AAAA lookup.
                property $ permCheck addrs ea

            (Right sa4s, Right sa6s) ->
                counterexample ("Addresses do not alternate or are not a permutation " ++ show addrs) $
                  property $ permCheck addrs (sa4s ++ sa6s) && alternateFamily addrs

    -- Once both the A and the AAAA lookup has returned the result should
    -- alternate between the address families until one family is out of addresses.
    -- This means that:
    -- AAAABABABABABABBB is a valid sequense.
    -- AAAABABAAABABABBB is not a valid sequense.

    alternateFamily :: [Socket.SockAddr] -> Bool
    alternateFamily (x:y:zs) =
      if sockAddrFamily x == sockAddrFamily y
      -- Once we see the same family adjacent, the rest of the list must be
      -- that family (same as that of y)
      then sameFamily (y:zs)
      else alternateFamily zs
    -- List of length 1 or 0 is alternating.
    alternateFamily _ = True

    sameFamily :: [Socket.SockAddr] -> Bool
    sameFamily (x:y:zs) = sockAddrFamily x == sockAddrFamily y && sameFamily zs
    sameFamily _        = True

    extractResult :: [Socket.SockAddr] -> [Socket.SockAddr] -> m [Socket.SockAddr]
    extractResult targets addrs = case targets of
        [] -> return $ reverse addrs
        (t:ts) -> do
          threadDelay (connectionRtt lr)
          extractResult ts (t:addrs)

    resolvLabel :: String
    resolvLabel =
        case (lrIpv4Result lr, lrIpv6Result lr) of
             (Left _, Left _) -> "A and AAAA error"
             (Left _, Right []) -> "A error, AAAA no result"
             (Left _, Right _)  -> "A error, AAAA success"
             (Right [], Left _) -> "A error, AAAA no result"
             (Right _, Left _)  -> "A success, AAAA error"
             (Right _, Right _) | lrIpv6Delay lr < lrIpv4Delay lr -> "AAAA before A"
                                | lrIpv4Delay lr + resolutionDelay > lrIpv6Delay lr ->
                                    "AAAA before A (Resolution Delay)"
                                | otherwise -> "A before AAAA"

-- | Time to wait for an AAAA response after receiving an A response.
resolutionDelay :: DiffTime
resolutionDelay = 0.05 -- 50ms delay

sockAddrFamily
    :: Socket.SockAddr
    -> Socket.Family
sockAddrFamily (Socket.SockAddrInet  _ _    ) = Socket.AF_INET
sockAddrFamily (Socket.SockAddrInet6 _ _ _ _) = Socket.AF_INET6
sockAddrFamily (Socket.SockAddrUnix _       ) = Socket.AF_UNIX

prop_resolv_sim :: LookupResult -> Property
prop_resolv_sim lr =
    case runSimStrictShutdown $ prop_resolv lr of
         Left _  -> property False
         Right r -> r

_prop_resolv_io :: LookupResult -> Property
_prop_resolv_io lr = ioProperty $ prop_resolv lr

prop_sub_io :: LookupResultIO
            -> Property
prop_sub_io lr = ioProperty $ do
    let serverIdsv4 = case lrioIpv4Result lr of
                           Left  _ -> []
                           Right r -> zip (repeat Socket.AF_INET) r
        serverIdsv6 = case lrioIpv6Result lr of
                               Left  _ -> []
                               Right r -> zip (repeat Socket.AF_INET6) r
        ipv4ClientCount = case lrioIpv4Result lr of
                               Left  _ -> 0
                               Right r -> length r
        ipv6ClientCount = case lrioIpv6Result lr of
                               Left  _ -> 0
                               Right r -> length r

    clientCountVar <- newTVarM (ipv4ClientCount + ipv6ClientCount)
    serverCountVar <- newTVarM (ipv4ClientCount + ipv6ClientCount)
    serverPortMapVar  <- newTVarM M.empty
    observedConnectionOrderVar <- newTVarM []
    serverWaitVar <- newTVarM False

    ipv4Servers <- replicateM (length serverIdsv4) (head <$> Socket.getAddrInfo Nothing (Just "127.0.0.1")
                            (Just "0"))
    ipv6Servers <- replicateM (length serverIdsv6) (head <$> Socket.getAddrInfo Nothing (Just "::1")
                            (Just "0"))

    ipv4Client <- head <$> Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
    ipv6Client <- head <$> Socket.getAddrInfo Nothing (Just "::1") (Just "0")

    serverAids <- mapM (async . spawnServer serverCountVar serverPortMapVar
                        observedConnectionOrderVar serverWaitVar ) $
                           zip (serverIdsv4 ++ serverIdsv6) $ ipv4Servers ++ ipv6Servers

    atomically $ do
        c <- readTVar serverCountVar
        when (c > 0) retry

    serverPortMap <- atomically $ readTVar serverPortMapVar

    let localAddresses = case someSockType (Socket.addrAddress ipv4Client) of
          Some addr4@(SockAddrIPv4 _ _) -> case someSockType (Socket.addrAddress ipv6Client) of
            Some addr6@(SockAddrIPv6 _ _ _ _) -> LocalAddresses
              (Just addr4)
              (Just addr6)
              Nothing
            _ -> error "unexpected address family"
          _ -> error "unexpected address family"

    let subThread = Connections.concurrent (initiatorCallback clientCountVar) $ \connections -> do
          let resolver = mockResolverIO serverPortMap lr
          addrs <- dnsResolve activeTracer resolver "shelley-0.iohk.example"
          case ipSubscriptionTargets addrs localAddresses of
            -- In thie Nothing case, it means we couldn't resolve any addresses
            -- to match one in localAddresses. This could be due to a DNS resolution
            -- failure, and that's OK: the test is set up so that, in case no
            -- addresses could be resolved, it will pass.
            Nothing -> pure ()
            Just connIds -> Subscription.worker
              activeTracer
              activeTracer
              connIds
              -- Valency 1 guarantees ordering. Using lrioValency lr does not.
              -- Higher valency does _not_ guarantee the subscriptions go
              -- in order. Is that a problem?
              -- FIXME
              1
              minConnectionAttemptDelay
              (\connId -> Socket.client connId LocalOnlyRequest)
              connections

    -- FIXME
    -- The reason why this fails is that the new DNS subscription target thing
    -- simply waits for all resolutions before trying to subscribe.
    -- So even though there is that wacky TVar trick to make one or the other
    -- return first, it won't affect the order.

    withAsync subThread $ \workerThread -> do
      link workerThread
      let waitForCount = atomically $ do
            c <- readTVar clientCountVar
            when (c > 0) retry
            writeTVar serverWaitVar True
      _ <- concurrently (mapM_ wait serverAids) waitForCount
      observedConnectionOrder <- fmap reverse $ atomically $ readTVar observedConnectionOrderVar
      return $ counterexample (show observedConnectionOrder) $
        property $ verifyOrder observedConnectionOrder

  where

    verifyOrder
        :: [(Socket.Family, Word16)]
        -> Bool
    verifyOrder observedConnectionOrder =
        case (lrioIpv4Result lr, lrioIpv6Result lr) of
             (Left _, Left _)     -> null observedConnectionOrder
             (Right [], Right []) -> null observedConnectionOrder
             (Left _, Right a)    -> a == map snd observedConnectionOrder
             (Right a, Left _)    -> a == map snd observedConnectionOrder
             (Right a, Right [])  -> a == map snd observedConnectionOrder
             (Right [], Right a)  -> a == map snd observedConnectionOrder
             (Right r4, Right r6) ->
                 not (null observedConnectionOrder) &&
                 permCheck (r4 ++ r6) (map snd observedConnectionOrder)

    initiatorCallback
        :: StrictTVar IO Int
        -> Initiated provenance
        -> Connections.ConnectionId
        -> Socket.Socket
        -> LocalOnlyRequest provenance
        -> IO (Concurrent.Decision IO provenance reject (ConnectionHandle IO))
    initiatorCallback clientCountVar _ _ _ _ = do
        tvar <- atomically $ newTVar Running
        pure $ Concurrent.Accept $ \_ ->
          let action = atomically $ do
                modifyTVar clientCountVar (\a -> a - 1)
                -- Really should put Finished into the TVar on exception but
                -- shouldn't matter for this test env.
                writeTVar tvar (Finished Nothing)
              handle' = ConnectionHandle { status = readTVar tvar }
          in  pure (Concurrent.Handler handle' action)


    spawnServer serverCountVar serverPortMapVar traceVar stopVar (sid, addr) =
        bracket
            (Socket.socket (Socket.addrFamily addr) Socket.Stream Socket.defaultProtocol)
            Socket.close
            (\sd -> do
                Socket.setSocketOption sd Socket.ReuseAddr 1
                Socket.bind sd (Socket.addrAddress addr)
                localPort <- Socket.socketPort sd
                atomically $ modifyTVar serverPortMapVar (M.insert sid localPort)
                Socket.listen sd 10
                atomically $ modifyTVar serverCountVar (\a -> a - 1)
                bracket
                    (Socket.accept sd)
                    (\(sd',_) -> Socket.close sd')
                    (\(_,_) -> do
                        atomically $ modifyTVar traceVar (\sids -> sid:sids)
                        atomically $ do
                            doneWaiting <- readTVar stopVar
                            unless doneWaiting retry
                    )
             )


prop_send_recv
    :: (Int -> Int -> (Int, Int))
    -> [Int]
    -> Socket.Family
    -> Property
prop_send_recv f xs first = ioProperty $ do

    let lr = LookupResultIO (Right [0]) (Right [0]) 1
        serverPortMap = M.fromList [((Socket.AF_INET, 0), 6062), ((Socket.AF_INET6, 0), 6062)]

    responderAddr4:_ <- Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "6062")
    responderAddr6:_ <- Socket.getAddrInfo Nothing (Just "::1") (Just "6062")
    let (responderAddr, faultyAddress) = case first of
                                              Socket.AF_INET  -> (responderAddr6, responderAddr4)
                                              Socket.AF_INET6 -> (responderAddr4, responderAddr6)
                                              _  -> error "prop_send_recv: invalid address family"
    initiatorAddr4:_ <- Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
    initiatorAddr6:_ <- Socket.getAddrInfo Nothing (Just "::1") (Just "0")

    let localAddresses = case someSockType (Socket.addrAddress initiatorAddr4) of
          Some addr4@(SockAddrIPv4 _ _) -> case someSockType (Socket.addrAddress initiatorAddr6) of
            Some addr6@(SockAddrIPv6 _ _ _ _) -> LocalAddresses
              (Just addr4)
              (Just addr6)
              Nothing
            _ -> error "unexpected address family"
          _ -> error "unexpected address family"

    cv <- newEmptyTMVarM
    sv <- newEmptyTMVarM
    siblingVar <- newTVarM 2

    let -- Server Node; only req-resp server
        responderApp :: OuroborosApplication ResponderApp ConnectionId TestProtocols2 IO BL.ByteString Void ()
        responderApp = OuroborosResponderApplication $
          \_peerid ReqRespPr channel -> do
            r <- runPeer (tagTrace "Responder" activeTracer)
                         ReqResp.codecReqResp
                         channel
                         (ReqResp.reqRespServerPeer (ReqResp.reqRespServerMapAccumL (\a -> pure . f a) 0))
            atomically $ putTMVar sv r
            waitSiblingSub siblingVar

        -- Client Node; only req-resp client
        initiatorApp :: OuroborosApplication InitiatorApp ConnectionId TestProtocols2 IO BL.ByteString () Void
        initiatorApp = OuroborosInitiatorApplication $
          \_peerid ReqRespPr channel -> do
            r <- runPeer (tagTrace "Initiator" activeTracer)
                         ReqResp.codecReqResp
                         channel
                         (ReqResp.reqRespClientPeer (ReqResp.reqRespClientMap xs))
            atomically $ putTMVar cv r
            waitSiblingSub siblingVar

        connectionRequest
          :: forall provenance .
             LocalOnlyRequest provenance
          -> ConnectionData TestProtocols2 NodeToNodeVersion provenance
        connectionRequest LocalOnlyRequest = ConnectionDataLocal
          nullNetworkConnectTracers
          cborTermVersionDataCodec
          (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData $ NetworkMagic 0)
          (DictVersion nodeToNodeCodecCBORTerm) initiatorApp)

    withDummyServer faultyAddress $
      withServerNode
        nullNetworkServerTracers
        (someSockType (Socket.addrAddress responderAddr))
        cborTermVersionDataCodec
        (\(DictVersion _) -> acceptEq)
        (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData $ NetworkMagic 0) (DictVersion nodeToNodeCodecCBORTerm) responderApp)
        nullErrorPolicies $ \_ _ -> do
          let subThread = Socket.withConnections connectionRequest $ \connections -> do
                let resolver = mockResolverIO serverPortMap lr
                addrs <- dnsResolve activeTracer resolver "shelley-0.iohk.example"
                case ipSubscriptionTargets addrs localAddresses of
                  Nothing -> error "unexpected"
                  Just connIds -> do
                    Subscription.worker
                      activeTracer
                      activeTracer
                      connIds
                      1 -- valency
                      minConnectionAttemptDelay
                      (\connId -> Socket.client connId LocalOnlyRequest)
                      connections
          withAsync subThread $ \workerThread -> do
            link workerThread
            atomically (waitSiblingSTM siblingVar)

    res <- atomically $ (,) <$> takeTMVar sv <*> takeTMVar cv
    return (res == mapAccumL f 0 xs)

  where
    -- FIXME what is this testing? Why put up a "dummy server"? To test that
    -- the client connects to the proper address family?
    withDummyServer addr k =
        bracket
            (Socket.socket (Socket.addrFamily addr) Socket.Stream Socket.defaultProtocol)
            Socket.close
            (\sd -> do
                -- bind the socket, so that it is used, but don't listen to it.
                Socket.setSocketOption sd Socket.ReuseAddr 1
                Socket.bind sd (Socket.addrAddress addr)
                k
            )


data ReqRspCfg = ReqRspCfg {
      rrcTag         :: !String
    , rrcServerVar   :: !(StrictTMVar IO Int)
    , rrcClientVar   :: !(StrictTMVar IO [Int])
    , rrcSiblingVar  :: !(StrictTVar IO Int)
}

newReqRspCfg :: String -> StrictTVar IO Int -> IO ReqRspCfg
newReqRspCfg tag siblingVar = do
    sv <- newEmptyTMVarM
    cv <- newEmptyTMVarM
    return $ ReqRspCfg tag sv cv siblingVar

prop_send_recv_init_and_rsp
    :: (Int -> Int -> (Int, Int))
    -> [Int]
    -> Property
prop_send_recv_init_and_rsp f xs = ioProperty $ do

    responderAddr4A:_ <- Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
    responderAddr4B:_ <- Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "0")

    addrAVar <- newEmptyTMVarM
    addrBVar <- newEmptyTMVarM

    siblingVar <- newTVarM 4
    {- 4 comes from one initiator and responder running on the server and one initiator and
     - and responder running on the client.
     -}

    rrcfgA <- newReqRspCfg "A" siblingVar
    rrcfgB <- newReqRspCfg "B" siblingVar

    a_aid <- async $ startPassiveServer
      responderAddr4A
      addrAVar
      rrcfgA

    b_aid <- async $ startActiveServer
      responderAddr4B
      addrBVar
      addrAVar
      rrcfgB

    (resA, resB) <- waitBoth a_aid b_aid
    return $ (resA == mapAccumL f 0 xs) && (resB == mapAccumL f 0 xs)

  where

    appX :: ReqRspCfg -> OuroborosApplication InitiatorAndResponderApp ConnectionId TestProtocols2 IO BL.ByteString () ()
    appX ReqRspCfg {rrcTag, rrcServerVar, rrcClientVar, rrcSiblingVar} = OuroborosInitiatorAndResponderApplication
            -- Initiator
            (\_peerid ReqRespPr channel -> do
             r <- runPeer (tagTrace (rrcTag ++ " Initiator") activeTracer)
                         ReqResp.codecReqResp
                         channel
                         (ReqResp.reqRespClientPeer (ReqResp.reqRespClientMap xs))
             atomically $ putTMVar rrcClientVar r
             -- wait for our responder and peer
             waitSiblingSub rrcSiblingVar
            )
            -- Responder
            (\_peerid ReqRespPr channel -> do
             r <- runPeer (tagTrace (rrcTag ++ " Responder") activeTracer)
                         ReqResp.codecReqResp
                         channel
                         (ReqResp.reqRespServerPeer (ReqResp.reqRespServerMapAccumL
                           (\a -> pure . f a) 0))
             atomically $ putTMVar rrcServerVar r
             -- wait for our initiator and peer
             waitSiblingSub rrcSiblingVar
            )

    startPassiveServer responderAddr localAddrVar rrcfg = withServerNode
        nullNetworkServerTracers
        (someSockType (Socket.addrAddress responderAddr))
        cborTermVersionDataCodec
        (\(DictVersion _) -> acceptEq)
        (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData $ NetworkMagic 0) (DictVersion nodeToNodeCodecCBORTerm) (appX rrcfg))
        nullErrorPolicies
        $ \localAddr _ -> do
          atomically $ putTMVar localAddrVar localAddr
          r <- atomically $ (,) <$> takeTMVar (rrcServerVar rrcfg)
                                <*> takeTMVar (rrcClientVar rrcfg)
          waitSibling (rrcSiblingVar rrcfg)
          return r

    startActiveServer responderAddr localAddrVar remoteAddrVar rrcfg = withServerNode
        nullNetworkServerTracers
        (someSockType (Socket.addrAddress responderAddr))
        cborTermVersionDataCodec
        (\(DictVersion _) -> acceptEq)
        ((simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData $ NetworkMagic 0) (DictVersion nodeToNodeCodecCBORTerm) (appX rrcfg)))
        nullErrorPolicies
        $ \localAddr _ -> do
          atomically $ putTMVar localAddrVar localAddr
          remoteAddr <- atomically $ takeTMVar remoteAddrVar
          let connectionId :: Connections.ConnectionId
              connectionId = case someSockType localAddr of
                Some laddr -> case matchSockType laddr remoteAddr of
                  Just raddr -> makeConnectionId laddr raddr
                  Nothing -> error "unexpected address family"

              connectionRequest
                :: forall provenance .
                   LocalOnlyRequest provenance
                -> ConnectionData TestProtocols2 NodeToNodeVersion provenance
              connectionRequest LocalOnlyRequest = ConnectionDataLocal
                nullNetworkConnectTracers
                cborTermVersionDataCodec
                (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData $ NetworkMagic 0)
                  (DictVersion nodeToNodeCodecCBORTerm) $ appX rrcfg)

              subThread = Socket.withConnections connectionRequest $ \connections ->
                Subscription.worker
                  activeTracer
                  activeTracer
                  (connectionId NE.:| [])
                  1 -- valency
                  minConnectionAttemptDelay
                  (\connId -> Socket.client connId LocalOnlyRequest)
                  connections
          withAsync subThread $ \workerThread -> do
            link workerThread
            atomically $ (,) <$> takeTMVar (rrcServerVar rrcfg)
                             <*> takeTMVar (rrcClientVar rrcfg)


waitSiblingSub :: StrictTVar IO Int -> IO ()
waitSiblingSub cntVar = do
    atomically $ modifyTVar cntVar (\a -> a - 1)
    waitSibling cntVar

waitSiblingSTM :: StrictTVar IO Int -> STM IO ()
waitSiblingSTM cntVar = do
    cnt <- readTVar cntVar
    unless (cnt == 0) retry

waitSibling :: StrictTVar IO Int -> IO ()
waitSibling = atomically . waitSiblingSTM

{-
 - XXX Doesn't really test anything, doesn't exit in a resonable time.
 - XXX Depends on external network config
 - unbound DNS config example:
local-data: "shelley-1.iohk.example. IN A 192.168.1.115"
local-data: "shelley-1.iohk.example. IN A 192.168.1.215"
local-data: "shelley-1.iohk.example. IN A 192.168.1.216"
local-data: "shelley-1.iohk.example. IN A 192.168.1.100"
local-data: "shelley-1.iohk.example. IN A 192.168.1.101"
local-data: "shelley-1.iohk.example. IN A 127.0.0.1"
local-data: "shelley-1.iohk.example. IN AAAA ::1"

local-data: "shelley-0.iohk.example. IN AAAA ::1"
-}
_demo :: Property
_demo = ioProperty $ do
    server:_ <- Socket.getAddrInfo Nothing (Just "192.168.1.100") (Just "6062")
    server':_ <- Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "6062")
    server6:_ <- Socket.getAddrInfo Nothing (Just "::1") (Just "6062")
    server6':_ <- Socket.getAddrInfo Nothing (Just "::1") (Just "6064")
    client:_ <- Socket.getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
    client6:_ <- Socket.getAddrInfo Nothing (Just "::1") (Just "0")


    spawnServer server 10000
    spawnServer server' 10000
    spawnServer server6 100
    spawnServer server6' 45

    let localAddresses :: LocalAddresses
        localAddresses = case someSockType (Socket.addrAddress client) of
          Some client'@(SockAddrIPv4 _ _) -> case someSockType (Socket.addrAddress client6) of
            Some client6'@(SockAddrIPv6 _ _ _ _) -> LocalAddresses
              (Just client')
              (Just client6')
              Nothing
            _ -> error "unexpected address family"
          _ -> error "unexpected address family"

        connectionRequest
          :: forall provenance .
             LocalOnlyRequest provenance
          -> ConnectionData TestProtocols1 NodeToNodeVersion provenance
        connectionRequest LocalOnlyRequest = ConnectionDataLocal
          nullNetworkConnectTracers
          cborTermVersionDataCodec
          (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData $ NetworkMagic 0)
          (DictVersion nodeToNodeCodecCBORTerm) appReq)


    Socket.withConnections connectionRequest $ \connections -> do
      mkResolverIO 6064 $ \resolver -> do
        addrs <- dnsResolve activeTracer resolver "shelley-0.iohk.example"
        case ipSubscriptionTargets addrs localAddresses of
          Nothing -> error "no matching addresses resolved"
          Just connIds -> do
            let subWorker = Subscription.worker
                  activeTracer
                  activeTracer
                  connIds
                  1 -- valency
                  minConnectionAttemptDelay
                  (\connId -> Socket.client connId LocalOnlyRequest)
                  connections
            withAsync subWorker $ \_subThread -> do
              (threadDelay 130 :: IO ())
              -- bring the servers back again
              spawnServer server6 10000
              spawnServer server6' 10000
              (threadDelay 1000 :: IO ())
              return ()

  where

    spawnServer addr delay =
        void $ async $ withServerNode
            nullNetworkServerTracers
            (someSockType (Socket.addrAddress addr))
            cborTermVersionDataCodec
            (\(DictVersion _) -> acceptEq)
            (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData $ NetworkMagic 0)
                (DictVersion nodeToNodeCodecCBORTerm) appRsp)
            nullErrorPolicies
            (\_ _ -> (threadDelay delay :: IO ()))


    appReq = OuroborosInitiatorApplication (\_ ChainSyncPr -> error "req fail")
    appRsp = OuroborosResponderApplication (\_ ChainSyncPr -> error "rsp fail")


data WithThreadAndTime a = WithThreadAndTime {
      wtatOccuredAt    :: !UTCTime
    , wtatWithinThread :: !ThreadId
    , wtatEvent        :: !a
    }

instance (Show a) => Show (WithThreadAndTime a) where
    show WithThreadAndTime {wtatOccuredAt, wtatWithinThread, wtatEvent} =
        printf "%s: %s: %s" (show wtatOccuredAt) (show wtatWithinThread) (show wtatEvent)

_verboseTracer :: Show a => Tracer IO a
_verboseTracer = threadAndTimeTracer $ showTracing stdoutTracer

threadAndTimeTracer :: Tracer IO (WithThreadAndTime a) -> Tracer IO a
threadAndTimeTracer tr = Tracer $ \s -> do
    !now <- getCurrentTime
    !tid <- myThreadId
    traceWith tr $ WithThreadAndTime now tid s

data WithTag a = WithTag {
      wtTag   :: !String
    , wtEvent :: !a
    }

instance (Show a) => Show (WithTag a) where
    show WithTag {wtTag, wtEvent} =
        printf "%s: %s" wtTag (show wtEvent)

tagTrace :: String -> Tracer IO (WithTag a) -> Tracer IO a
tagTrace tag tr = Tracer $ \s -> traceWith tr $ WithTag tag s
