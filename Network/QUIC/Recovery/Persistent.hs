{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.QUIC.Recovery.Persistent (
    getMaxAckDelay
  , calcPTO
  , backOff
  , inPersistentCongestion
  , findDuration -- for testing
  , getPTO
  ) where

import Data.Sequence (Seq, ViewL(..))
import qualified Data.Sequence as Seq
import Data.UnixTime

import Network.QUIC.Imports
import Network.QUIC.Recovery.Constants
import Network.QUIC.Recovery.Misc
import Network.QUIC.Recovery.Types
import Network.QUIC.Types

getMaxAckDelay :: Maybe EncryptionLevel -> Microseconds -> Microseconds
getMaxAckDelay Nothing n = n
getMaxAckDelay (Just lvl) n
  | lvl `elem` [InitialLevel,HandshakeLevel] = 0
  | otherwise                                = n

-- Sec 6.2.1. Computing PTO
-- PTO = smoothed_rtt + max(4*rttvar, kGranularity) + max_ack_delay
calcPTO :: RTT -> Maybe EncryptionLevel -> Microseconds
calcPTO RTT{..} mlvl = smoothedRTT + max (rttvar !<<. 2) kGranularity + dly
  where
    dly = getMaxAckDelay mlvl maxAckDelay1RTT

backOff :: Microseconds -> Int -> Microseconds
backOff n cnt = n * (2 ^ cnt)

-- Sec 7.8. Persistent Congestion
inPersistentCongestion :: LDCC -> Seq SentPacket -> IO Bool
inPersistentCongestion ldcc@LDCC{..} lostPackets = do
    pn <- getPktNumPersistent ldcc
    let mduration = findDuration lostPackets pn
    case mduration of
      Nothing -> return False
      Just duration -> do
          rtt <- readIORef recoveryRTT
          let pto = calcPTO rtt Nothing
              Microseconds congestionPeriod = kPersistentCongestionThreshold pto
              threshold = microSecondsToUnixDiffTime congestionPeriod
          return (duration > threshold)

findDuration :: Seq SentPacket -> PacketNumber -> Maybe UnixDiffTime
findDuration pkts0 pn = leftEdge pkts0 Nothing
  where
    leftEdge pkts mdiff = case Seq.viewl pkts' of
        EmptyL      -> mdiff
        l :< pkts'' -> case rightEdge (spPacketNumber l) pkts'' Nothing of
          (Nothing, pkts''') -> leftEdge pkts''' mdiff
          (Just r,  pkts''') ->
              let diff' = spTimeSent r `diffUnixTime` spTimeSent l
              in case mdiff of
                Nothing          -> leftEdge pkts''' $ Just diff'
                Just diff
                  | diff' > diff -> leftEdge pkts''' $ Just diff'
                  | otherwise    -> leftEdge pkts''' $ Just diff
      where
        (_, pkts') = Seq.breakl (\x -> spAckEliciting x && spPacketNumber x >= pn) pkts
    rightEdge n pkts Nothing = case Seq.viewl pkts of
        EmptyL -> (Nothing, Seq.empty)
        r :< pkts'
          | spPacketNumber r == n + 1 ->
              if spAckEliciting r then
                  rightEdge (n + 1) pkts' $ Just r
                else
                  rightEdge (n + 1) pkts' Nothing
          | otherwise -> (Nothing, pkts)
    rightEdge n pkts mr0 = case Seq.viewl pkts of
        EmptyL -> (mr0, Seq.empty)
        r :< pkts'
          | spPacketNumber r == n + 1 ->
              if spAckEliciting r then
                  rightEdge (n + 1) pkts' $ Just r
                else
                  rightEdge (n + 1) pkts' mr0
          | otherwise -> (mr0, pkts)

getPTO :: LDCC -> IO Microseconds
getPTO LDCC{..} = do
    rtt <- readIORef recoveryRTT
    return $ calcPTO rtt Nothing
