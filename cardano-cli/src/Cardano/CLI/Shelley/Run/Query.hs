{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.CLI.Shelley.Run.Query
  ( DelegationsAndRewards(..)
  , ShelleyQueryCmdError
  , ShelleyQueryCmdLocalStateQueryError (..)
  , renderShelleyQueryCmdError
  , renderLocalStateQueryError
  , runQueryCmd
  , mergeDelegsAndRewards
  , percentage
  , executeQuery
  ) where

import           Prelude (String, id)

import           Cardano.Api
import qualified Cardano.Api as Api
import           Cardano.Api.Byron
import           Cardano.Api.Shelley

import           Cardano.Binary (decodeFull)
import           Cardano.CLI.Environment (EnvSocketError, readEnvSocketPath, renderEnvSocketError)
import           Cardano.CLI.Helpers (HelpersError (..), hushM, pPrintCBOR, renderHelpersError)
import           Cardano.CLI.Shelley.Key
import           Cardano.CLI.Shelley.Orphans ()
import qualified Cardano.CLI.Shelley.Output as O
import           Cardano.CLI.Shelley.Parsers (OpCertCounterFile (..), OutputFile (..),
                   QueryCmd (..))
import           Cardano.CLI.Types
import           Cardano.Crypto.Hash (hashToBytesAsHex)
import           Cardano.Ledger.Coin
import           Cardano.Ledger.Compactible
import           Cardano.Ledger.Crypto (StandardCrypto)
import qualified Cardano.Ledger.Crypto as Crypto
import qualified Cardano.Ledger.Era as Era
import           Cardano.Ledger.Keys (KeyHash (..), KeyRole (..))
import qualified Cardano.Ledger.Shelley.API.Protocol as Ledger
import           Cardano.Ledger.Shelley.Constraints
import           Cardano.Ledger.Shelley.EpochBoundary
import           Cardano.Ledger.Shelley.LedgerState hiding (_delegations)
import           Cardano.Ledger.Shelley.Scripts ()
import           Cardano.Prelude hiding (atomically)
import           Control.Monad.Trans.Except (except)
import           Control.Monad.Trans.Except.Extra (firstExceptT, handleIOExceptT, hoistMaybe, left,
                   newExceptT)
import           Data.Aeson.Encode.Pretty (encodePretty)
import           Data.Aeson.Types as Aeson
import           Data.Coerce (coerce)
import           Data.List (nub)
import           Data.Time.Clock
import           Ouroboros.Consensus.BlockchainTime.WallClock.Types (RelativeTime (..),
                   SystemStart (..), toRelativeTime)
import           Ouroboros.Consensus.Cardano.Block as Consensus (EraMismatch (..))
import           Ouroboros.Network.Block (Serialised (..))
import           Ouroboros.Network.Protocol.LocalStateQuery.Type (AcquireFailure (..))
import           Text.Printf (printf)

import           Cardano.Protocol.TPraos.Rules.Prtcl
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Compact.VMap as VMap
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as T
import qualified Data.Text.IO as Text
import qualified Data.Vector as Vector
import           Numeric (showEFloat)

import qualified Ouroboros.Consensus.HardFork.History.Qry as Qry
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as LocalStateQuery
import qualified System.IO as IO


{- HLINT ignore "Reduce duplication" -}
{- HLINT ignore "Use const" -}
{- HLINT ignore "Use let" -}

data ShelleyQueryCmdError
  = ShelleyQueryCmdEnvVarSocketErr !EnvSocketError
  | ShelleyQueryCmdLocalStateQueryError !ShelleyQueryCmdLocalStateQueryError
  | ShelleyQueryCmdWriteFileError !(FileError ())
  | ShelleyQueryCmdHelpersError !HelpersError
  | ShelleyQueryCmdAcquireFailure !AcquireFailure
  | ShelleyQueryCmdEraConsensusModeMismatch !AnyConsensusMode !AnyCardanoEra
  | ShelleyQueryCmdByronEra
  | ShelleyQueryCmdPoolIdError (Hash StakePoolKey)
  | ShelleyQueryCmdEraMismatch !EraMismatch
  | ShelleyQueryCmdUnsupportedMode !AnyConsensusMode
  | ShelleyQueryCmdPastHorizon !Qry.PastHorizonException
  | ShelleyQueryCmdSystemStartUnavailable
  | ShelleyQueryCmdColdKeyReadFileError !(FileError InputDecodeError)
  | ShelleyQueryCmdOpCertCounterReadError !(FileError TextEnvelopeError)
  | ShelleyQueryCmdCountersNotEqual
      !(FilePath, Word64)
      -- ^ Operational certificate filepath and current count
      !(OpCertCounterFile, Word64)
      -- ^ Operataional certificate counter filepath and current count
  | ShelleyQueryCmdWrongKESPeriod
      !(FilePath, Word64)
      -- Operational certificate filepath with its KES period
      !Word64
      -- Calculated KES period based on genesis parameters and current slot
  | ShelleyQueryCmdProtocolStateDecodeFailure
  | ShelleyQueryCmdNodeStateCounterDifferent
      Word64
      -- ^ Operational certificate counter in the protocol state
      Word64
      -- ^ Operational certificate counter on disk
      FilePath
      -- ^ Operational certificate
  | ShelleyQueryCmdNodeUnknownStakePool
      FilePath
      -- ^ Operational certificate of the unknown stake pool.

  deriving Show

renderShelleyQueryCmdError :: ShelleyQueryCmdError -> Text
renderShelleyQueryCmdError err =
  case err of
    ShelleyQueryCmdEnvVarSocketErr envSockErr -> renderEnvSocketError envSockErr
    ShelleyQueryCmdLocalStateQueryError lsqErr -> renderLocalStateQueryError lsqErr
    ShelleyQueryCmdWriteFileError fileErr -> Text.pack (displayError fileErr)
    ShelleyQueryCmdHelpersError helpersErr -> renderHelpersError helpersErr
    ShelleyQueryCmdAcquireFailure acquireFail -> Text.pack $ show acquireFail
    ShelleyQueryCmdByronEra -> "This query cannot be used for the Byron era"
    ShelleyQueryCmdPoolIdError poolId -> "The pool id does not exist: " <> show poolId
    ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) (AnyCardanoEra era) ->
      "Consensus mode and era mismatch. Consensus mode: " <> show cMode <>
      " Era: " <> show era
    ShelleyQueryCmdEraMismatch (EraMismatch ledgerEra queryEra) ->
      "\nAn error mismatch occured." <> "\nSpecified query era: " <> queryEra <>
      "\nCurrent ledger era: " <> ledgerEra
    ShelleyQueryCmdUnsupportedMode mode -> "Unsupported mode: " <> renderMode mode
    ShelleyQueryCmdPastHorizon e -> "Past horizon: " <> show e
    ShelleyQueryCmdSystemStartUnavailable -> "System start unavailable"
    ShelleyQueryCmdColdKeyReadFileError e -> Text.pack $ displayError e
    ShelleyQueryCmdOpCertCounterReadError e -> Text.pack $ displayError e
    ShelleyQueryCmdCountersNotEqual (opCertFp, certCount) (OpCertCounterFile counterFp, counterFileCount) ->
      Text.pack $ "Counters in the node operational certificate at: " <> opCertFp <>
                  " Count: " <> show certCount <>
                  " and the node operational certificate counter file at: " <> counterFp <>
                  " Count: " <> show counterFileCount <>
                  " are not the same."

    ShelleyQueryCmdWrongKESPeriod (opCertFp, opCertKesPeriod) correctKesPeriod ->
      Text.pack $ "Node operational certificate at: " <> opCertFp <>
                  " has an incorrectly specified KES period: " <> show opCertKesPeriod <>
                  " The correct KES period is: " <> show correctKesPeriod
    ShelleyQueryCmdProtocolStateDecodeFailure -> "Failed to decode the protocol state."
    ShelleyQueryCmdNodeStateCounterDifferent ptclStateCounter onDiskOpCertCounter opCertFp ->
      Text.pack $ "The protocol state counter for the operational certificate at: " <> opCertFp <>
                  " does not agree with the ondisk counter. On disk count: " <> show onDiskOpCertCounter <>
                  " Protocol state count: " <> show ptclStateCounter
    ShelleyQueryCmdNodeUnknownStakePool nodeOpCert ->
      Text.pack $ "The current count for stake pool specified in the operational certificate at: " <> nodeOpCert <>
                  " was not found. "


runQueryCmd :: QueryCmd -> ExceptT ShelleyQueryCmdError IO ()
runQueryCmd cmd =
  case cmd of
    QueryProtocolParameters' consensusModeParams network mOutFile ->
      runQueryProtocolParameters consensusModeParams network mOutFile
    QueryTip consensusModeParams network mOutFile ->
      runQueryTip consensusModeParams network mOutFile
    QueryStakePools' consensusModeParams network mOutFile ->
      runQueryStakePools consensusModeParams network mOutFile
    QueryStakeDistribution' consensusModeParams network mOutFile ->
      runQueryStakeDistribution consensusModeParams network mOutFile
    QueryStakeAddressInfo consensusModeParams addr network mOutFile ->
      runQueryStakeAddressInfo consensusModeParams addr network mOutFile
    QueryDebugLedgerState' consensusModeParams network mOutFile ->
      runQueryLedgerState consensusModeParams network mOutFile
    QueryStakeSnapshot' consensusModeParams network poolid ->
      runQueryStakeSnapshot consensusModeParams network poolid
    QueryPoolParams' consensusModeParams network poolid ->
      runQueryPoolParams consensusModeParams network poolid
    QueryProtocolState' consensusModeParams network mOutFile ->
      runQueryProtocolState consensusModeParams network mOutFile
    QueryUTxO' consensusModeParams qFilter networkId mOutFile ->
      runQueryUTxO consensusModeParams qFilter networkId mOutFile
    QueryKesPeriodInfo consensusModeParams network nodeOpCert nodeOpCertCounter mOutFile ->
      runQueryKesPeriodInfo consensusModeParams network nodeOpCert nodeOpCertCounter mOutFile

runQueryProtocolParameters
  :: AnyConsensusModeParams
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryProtocolParameters (AnyConsensusModeParams cModeParams) network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr
                           readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  result <- liftIO $ executeLocalStateQueryExpr localNodeConnInfo Nothing $ \_ntcVersion -> runExceptT $ do
    anyE@(AnyCardanoEra era) <- lift $ determineEraExpr cModeParams

    case cardanoEraStyle era of
      LegacyByronEra -> left ShelleyQueryCmdByronEra
      ShelleyBasedEra sbe -> do
        let cMode = consensusModeOnly cModeParams

        eInMode <- toEraInMode era cMode
          & hoistMaybe (ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE)

        ppResult <- lift . queryExpr $ QueryInEra eInMode $ QueryInShelleyBasedEra sbe QueryProtocolParameters

        except ppResult & firstExceptT ShelleyQueryCmdEraMismatch

  writeProtocolParameters mOutFile =<< except (join (first ShelleyQueryCmdAcquireFailure result))
 where
  writeProtocolParameters
    :: Maybe OutputFile
    -> ProtocolParameters
    -> ExceptT ShelleyQueryCmdError IO ()
  writeProtocolParameters mOutFile' pparams =
    case mOutFile' of
      Nothing -> liftIO $ LBS.putStrLn (encodePretty pparams)
      Just (OutputFile fpath) ->
        handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError fpath) $
          LBS.writeFile fpath (encodePretty pparams)

-- | Calculate the percentage sync rendered as text.
percentage
  :: RelativeTime
  -- ^ 'tolerance'.  If 'b' - 'a' < 'tolerance', then 100% is reported.  This even if we are 'tolerance' seconds
  -- behind, we are still considered fully synced.
  -> RelativeTime
  -- ^ 'nowTime'.  The time of the most recently synced block.
  -> RelativeTime
  -- ^ 'tipTime'.  The time of the tip of the block chain to which we need to sync.
  -> Text
percentage tolerance a b = Text.pack (printf "%.2f" pc)
  where -- All calculations are in seconds (Integer)
        t  = relativeTimeSeconds tolerance
        -- Plus 1 to prevent division by zero.  The 's' prefix stands for strictly-positive.
        sa = relativeTimeSeconds a + 1
        sb = relativeTimeSeconds b + 1
        -- Fast forward the 'nowTime` by the tolerance, but don't let the result exceed the tip time.
        ua = min (sa + t) sb
        ub = sb
        -- Final percentage to render as text.
        pc = id @Double (fromIntegral ua / fromIntegral  ub) * 100.0

relativeTimeSeconds :: RelativeTime -> Integer
relativeTimeSeconds (RelativeTime dt) = floor (nominalDiffTimeToSeconds dt)

-- | Query the chain tip via the chain sync protocol.
--
-- This is a fallback query to support older versions of node to client protocol.
queryChainTipViaChainSync :: MonadIO m => LocalNodeConnectInfo mode -> m ChainTip
queryChainTipViaChainSync localNodeConnInfo = do
  liftIO . T.hPutStrLn IO.stderr $
    "Warning: Local header state query unavailable. Falling back to chain sync query"
  liftIO $ getLocalChainTip localNodeConnInfo

runQueryTip
  :: AnyConsensusModeParams
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryTip (AnyConsensusModeParams cModeParams) network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath

  case consensusModeOnly cModeParams of
    CardanoMode -> do
      let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

      eLocalState <- liftIO $ executeLocalStateQueryExpr localNodeConnInfo Nothing $ \ntcVersion -> do
        era <- queryExpr (QueryCurrentEra CardanoModeIsMultiEra)
        eraHistory <- queryExpr (QueryEraHistory CardanoModeIsMultiEra)
        mChainBlockNo <- if ntcVersion >= NodeToClientV_10
          then Just <$> queryExpr QueryChainBlockNo
          else return Nothing
        mChainPoint <- if ntcVersion >= NodeToClientV_10
          then Just <$> queryExpr (QueryChainPoint CardanoMode)
          else return Nothing
        mSystemStart <- if ntcVersion >= NodeToClientV_9
          then Just <$> queryExpr QuerySystemStart
          else return Nothing

        return O.QueryTipLocalState
          { O.era = era
          , O.eraHistory = eraHistory
          , O.mSystemStart = mSystemStart
          , O.mChainTip = makeChainTip <$> mChainBlockNo <*> mChainPoint
          }

      mLocalState <- hushM (first ShelleyQueryCmdAcquireFailure eLocalState) $ \e ->
        liftIO . T.hPutStrLn IO.stderr $ "Warning: Local state unavailable: " <> renderShelleyQueryCmdError e

      chainTip <- case mLocalState >>= O.mChainTip of
        Just chainTip -> return chainTip

        -- The chain tip is unavailable via local state query because we are connecting with an older
        -- node to client protocol so we use chain sync instead which necessitates another connection.
        -- At some point when we can stop supporting the older node to client protocols, this fallback
        -- can be removed.
        Nothing -> queryChainTipViaChainSync localNodeConnInfo

      let tipSlotNo :: SlotNo = case chainTip of
            ChainTipAtGenesis -> 0
            ChainTip slotNo _ _ -> slotNo

      localStateOutput <- forM mLocalState $ \localState -> do
        case slotToEpoch tipSlotNo (O.eraHistory localState) of
          Left e -> do
            liftIO . T.hPutStrLn IO.stderr $
              "Warning: Epoch unavailable: " <> renderShelleyQueryCmdError (ShelleyQueryCmdPastHorizon e)
            return $ O.QueryTipLocalStateOutput
              { O.localStateChainTip = chainTip
              , O.mEra = Nothing
              , O.mEpoch = Nothing
              , O.mSyncProgress = Nothing
              }

          Right (epochNo, _, _) -> do
            syncProgressResult <- runExceptT $ do
              systemStart <- fmap getSystemStart (O.mSystemStart localState) & hoistMaybe ShelleyQueryCmdSystemStartUnavailable
              nowSeconds <- toRelativeTime (SystemStart systemStart) <$> liftIO getCurrentTime
              tipTimeResult <- getProgress tipSlotNo (O.eraHistory localState) & bimap ShelleyQueryCmdPastHorizon fst & except

              let tolerance = RelativeTime (secondsToNominalDiffTime 600)

              return $ flip (percentage tolerance) nowSeconds tipTimeResult

            mSyncProgress <- hushM syncProgressResult $ \e -> do
              liftIO . T.hPutStrLn IO.stderr $ "Warning: Sync progress unavailable: " <> renderShelleyQueryCmdError e

            return $ O.QueryTipLocalStateOutput
              { O.localStateChainTip = chainTip
              , O.mEra = Just (O.era localState)
              , O.mEpoch = Just epochNo
              , O.mSyncProgress = mSyncProgress
              }

      case mOutFile of
        Just (OutputFile fpath) -> liftIO $ LBS.writeFile fpath $ encodePretty localStateOutput
        Nothing                 -> liftIO $ LBS.putStrLn        $ encodePretty localStateOutput

    mode -> left (ShelleyQueryCmdUnsupportedMode (AnyConsensusMode mode))

-- | Query the UTxO, filtered by a given set of addresses, from a Shelley node
-- via the local state query protocol.
--

runQueryUTxO
  :: AnyConsensusModeParams
  -> QueryUTxOFilter
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryUTxO (AnyConsensusModeParams cModeParams)
             qfilter network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  case toEraInMode era cMode of
    Just eInMode -> do
      let query   = QueryInShelleyBasedEra sbe (QueryUTxO qfilter)
          qInMode = QueryInEra eInMode query
      result <- executeQuery
                  era
                  cModeParams
                  localNodeConnInfo
                  qInMode
      writeFilteredUTxOs sbe mOutFile result
    Nothing -> left $ ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE


runQueryKesPeriodInfo
  :: AnyConsensusModeParams
  -> NetworkId
  -> FilePath
  -> OpCertCounterFile
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryKesPeriodInfo (AnyConsensusModeParams cModeParams) network nodeOpCertFile
                       oCIssueCounter@(OpCertCounterFile opCertCountFile) mOutFile = do

  opCert <- firstExceptT ShelleyQueryCmdOpCertCounterReadError
              . newExceptT $ readFileTextEnvelope AsOperationalCertificate nodeOpCertFile

  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  eInMode <- toEraInMode era cMode
    & hoistMaybe (ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE)

  -- We check that the KES period specified in the operational certificate is correct
  -- based on the KES period defined in the genesis parameters and the current slot number
  let genesisQinMode = QueryInEra eInMode . QueryInShelleyBasedEra sbe $ QueryGenesisParameters
  gParams@GenesisParameters{protocolParamMaxKESEvolutions, protocolParamSlotsPerKESPeriod}
    <- executeQuery era cModeParams localNodeConnInfo genesisQinMode

  chainTip <- liftIO $ getLocalChainTip localNodeConnInfo

  (slotsTillNewKesKey, calculatedKesPeriod) <- opCertKesPeriodCheck opCert chainTip gParams

  -- We get the operational certificate counter from the protocol state and check that
  -- it is equivalent to what we have on disk.

  let ptclStateQinMode = QueryInEra eInMode . QueryInShelleyBasedEra sbe $ QueryProtocolState
  ptclState <- executeQuery era cModeParams localNodeConnInfo ptclStateQinMode
  ptclStateCounter <- opCertCounterStateCheck ptclState opCert

  let kesPeriodInfo = O.QueryKesPeriodInfoOutput
                        { O.qKesInfoCurrentKESPeriod = calculatedKesPeriod
                        , O.qKesInfoRemainingSlotsInPeriod = slotsTillNewKesKey
                        , O.qKesInfoLatestOperationalCertNo = ptclStateCounter
                        , O.qKesInfoMaxKesKeyEvolutions = fromIntegral protocolParamMaxKESEvolutions
                        , O.qKesInfoSlotsPerKesPeriod = fromIntegral protocolParamSlotsPerKESPeriod
                        }
      kesPeriodInfoJSON = encodePretty kesPeriodInfo
  case mOutFile of
    Just (OutputFile oFp) ->
      handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError oFp)
        $ LBS.writeFile oFp kesPeriodInfoJSON
    Nothing -> liftIO $ LBS.putStrLn kesPeriodInfoJSON
 where
   -- We first check the operational certificate issue counter's count is
   -- equal to the count in the operational certificate (on disk)
   opCertCounterOndiskCheck :: OperationalCertificate -> ExceptT ShelleyQueryCmdError IO Word64
   opCertCounterOndiskCheck opCert = do
     opCertCounter
       <- firstExceptT ShelleyQueryCmdOpCertCounterReadError
            . newExceptT $ readFileTextEnvelope AsOperationalCertificateIssueCounter opCertCountFile

     let currentOpCertCount =  getOpCertCount opCert
         -- Why 'pred'? Because the op cert issue counter tells us what the next
         -- count should be.
         currentOpCertIssueCount = pred $ opCertIssueCount opCertCounter
     if currentOpCertCount == currentOpCertIssueCount
     then return currentOpCertCount
     else left $ ShelleyQueryCmdCountersNotEqual
                  (nodeOpCertFile, currentOpCertCount)
                  (oCIssueCounter, currentOpCertIssueCount)

   -- Returns the number of slots left until KES key rotation and the KES period.
   -- We check the calculated current KES period based on the current slot and
   -- protocolParamSlotsPerKESPeriod matches what is specified in the 'OperationalCertificate'.
   opCertKesPeriodCheck
     :: OperationalCertificate
     -> ChainTip
     -> GenesisParameters
     -> ExceptT ShelleyQueryCmdError IO (Word64, Word64)
   opCertKesPeriodCheck _ ChainTipAtGenesis
                          GenesisParameters{protocolParamSlotsPerKESPeriod} =
     return ( fromIntegral protocolParamSlotsPerKESPeriod
            , fromIntegral protocolParamSlotsPerKESPeriod
            )
   opCertKesPeriodCheck opCert (ChainTip currSlot _ _)
                        GenesisParameters{protocolParamSlotsPerKESPeriod} = do

     let slotsPerKesPeriod = fromIntegral protocolParamSlotsPerKESPeriod
         (calculatedKesPeriod, remainder) =
           unSlotNo currSlot `quotRem` slotsPerKesPeriod
         opCertKesPeriod = fromIntegral $ getKesPeriod opCert
         slotsTillNewKesKey = slotsPerKesPeriod - remainder
     if calculatedKesPeriod == opCertKesPeriod
     then return (slotsTillNewKesKey, calculatedKesPeriod)
     else left $ ShelleyQueryCmdWrongKESPeriod
                   (nodeOpCertFile, opCertKesPeriod)
                   calculatedKesPeriod

   -- We get the operational certificate counter from the protocol state and check that
   -- it is equivalent to what we have on disk.
   opCertCounterStateCheck
     :: ProtocolState era
     -> OperationalCertificate
     -> ExceptT ShelleyQueryCmdError IO Word64
   opCertCounterStateCheck ptclState opCert@(OperationalCertificate _ stakePoolVKey) = do
    onDiskOpCertCount <- opCertCounterOndiskCheck opCert
    case decodeProtocolState ptclState of
      Left _ -> left ShelleyQueryCmdProtocolStateDecodeFailure
      Right chainDepState -> do
        -- We need the stake pool id to determine what the counter of our SPO
        -- should be.
        let PrtclState opCertCounterMap _ _ = Ledger.csProtocol chainDepState
            StakePoolKeyHash blockIssuerHash = verificationKeyHash stakePoolVKey
        case Map.lookup (coerce blockIssuerHash) opCertCounterMap of
          Just ptclStateCounter ->
            if ptclStateCounter /= onDiskOpCertCount
            then left $ ShelleyQueryCmdNodeStateCounterDifferent
                          ptclStateCounter onDiskOpCertCount nodeOpCertFile
            else return ptclStateCounter
          Nothing -> left $ ShelleyQueryCmdNodeUnknownStakePool nodeOpCertFile



-- | Query the current and future parameters for a stake pool, including the retirement date.
-- Any of these may be empty (in which case a null will be displayed).
--

runQueryPoolParams
  :: AnyConsensusModeParams
  -> NetworkId
  -> Hash StakePoolKey
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryPoolParams (AnyConsensusModeParams cModeParams) network poolid = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  eInMode <- toEraInMode era cMode
    & hoistMaybe (ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE)

  let qInMode = QueryInEra eInMode . QueryInShelleyBasedEra sbe $ QueryDebugLedgerState
  result <- executeQuery era cModeParams localNodeConnInfo qInMode
  obtainLedgerEraClassConstraints sbe (writePoolParams poolid) result


-- | Obtain stake snapshot information for a pool, plus information about the total active stake.
-- This information can be used for leader slot calculation, for example, and has been requested by SPOs.
-- Obtaining the information directly is significantly more time and memory efficient than using a full ledger state dump.
runQueryStakeSnapshot
  :: AnyConsensusModeParams
  -> NetworkId
  -> Hash StakePoolKey
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryStakeSnapshot (AnyConsensusModeParams cModeParams) network poolid = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  eInMode <- toEraInMode era cMode
    & hoistMaybe (ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE)

  let qInMode = QueryInEra eInMode . QueryInShelleyBasedEra sbe $ QueryDebugLedgerState
  result <- executeQuery era cModeParams localNodeConnInfo qInMode
  obtainLedgerEraClassConstraints sbe (writeStakeSnapshot poolid) result


runQueryLedgerState
  :: AnyConsensusModeParams
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryLedgerState (AnyConsensusModeParams cModeParams)
                    network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  case toEraInMode era cMode of
    Just eInMode -> do
      let qInMode = QueryInEra eInMode
                      . QueryInShelleyBasedEra sbe
                      $ QueryDebugLedgerState
      result <- executeQuery
                  era
                  cModeParams
                  localNodeConnInfo
                  qInMode
      obtainLedgerEraClassConstraints sbe (writeLedgerState mOutFile) result
    Nothing -> left $ ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE


runQueryProtocolState
  :: AnyConsensusModeParams
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryProtocolState (AnyConsensusModeParams cModeParams)
                      network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  case toEraInMode era cMode of
    Just eInMode -> do
      let qInMode = QueryInEra eInMode
                      . QueryInShelleyBasedEra sbe
                      $ QueryProtocolState
      result <- executeQuery
                  era
                  cModeParams
                  localNodeConnInfo
                  qInMode
      writeProtocolState mOutFile result
    Nothing -> left $ ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE

-- | Query the current delegations and reward accounts, filtered by a given
-- set of addresses, from a Shelley node via the local state query protocol.

runQueryStakeAddressInfo
  :: AnyConsensusModeParams
  -> StakeAddress
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryStakeAddressInfo (AnyConsensusModeParams cModeParams)
                         (StakeAddress _ addr) network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  case toEraInMode era cMode of
    Just eInMode -> do
      let stakeAddr = Set.singleton $ fromShelleyStakeCredential addr
          query = QueryInEra eInMode
                    . QueryInShelleyBasedEra sbe
                    $ QueryStakeAddresses stakeAddr network

      result <- executeQuery
                  era
                  cModeParams
                  localNodeConnInfo
                  query
      writeStakeAddressInfo mOutFile $ DelegationsAndRewards result
    Nothing -> left $ ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE

-- -------------------------------------------------------------------------------------------------

-- | An error that can occur while querying a node's local state.
data ShelleyQueryCmdLocalStateQueryError
  = AcquireFailureError !LocalStateQuery.AcquireFailure
  | EraMismatchError !EraMismatch
  -- ^ A query from a certain era was applied to a ledger from a different
  -- era.
  | ByronProtocolNotSupportedError
  -- ^ The query does not support the Byron protocol.
  | ShelleyProtocolEraMismatch
  -- ^ The Shelley protocol only supports the Shelley era.
  deriving (Eq, Show)

renderLocalStateQueryError :: ShelleyQueryCmdLocalStateQueryError -> Text
renderLocalStateQueryError lsqErr =
  case lsqErr of
    AcquireFailureError err -> "Local state query acquire failure: " <> show err
    EraMismatchError err ->
      "A query from a certain era was applied to a ledger from a different era: " <> show err
    ByronProtocolNotSupportedError ->
      "The attempted local state query does not support the Byron protocol."
    ShelleyProtocolEraMismatch ->
        "The Shelley protocol mode can only be used with the Shelley era, "
     <> "i.e. with --shelley-mode use --shelley-era flag"

writeStakeAddressInfo
  :: Maybe OutputFile
  -> DelegationsAndRewards
  -> ExceptT ShelleyQueryCmdError IO ()
writeStakeAddressInfo mOutFile delegsAndRewards =
  case mOutFile of
    Nothing -> liftIO $ LBS.putStrLn (encodePretty delegsAndRewards)
    Just (OutputFile fpath) ->
      handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError fpath)
        $ LBS.writeFile fpath (encodePretty delegsAndRewards)

writeLedgerState :: forall era ledgerera.
                    ShelleyLedgerEra era ~ ledgerera
                 => ToJSON (DebugLedgerState era)
                 => FromCBOR (DebugLedgerState era)
                 => Maybe OutputFile
                 -> SerialisedDebugLedgerState era
                 -> ExceptT ShelleyQueryCmdError IO ()
writeLedgerState mOutFile qState@(SerialisedDebugLedgerState serLedgerState) =
  case mOutFile of
    Nothing -> case decodeLedgerState qState of
                 Left bs -> firstExceptT ShelleyQueryCmdHelpersError $ pPrintCBOR bs
                 Right ledgerState -> liftIO . LBS.putStrLn $ encodePretty ledgerState
    Just (OutputFile fpath) ->
      handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError fpath)
        $ LBS.writeFile fpath $ unSerialised serLedgerState

writeStakeSnapshot :: forall era ledgerera. ()
  => ShelleyLedgerEra era ~ ledgerera
  => Era.Crypto ledgerera ~ StandardCrypto
  => FromCBOR (DebugLedgerState era)
  => PoolId
  -> SerialisedDebugLedgerState era
  -> ExceptT ShelleyQueryCmdError IO ()
writeStakeSnapshot (StakePoolKeyHash hk) qState =
  case decodeLedgerState qState of
    -- In the event of decode failure print the CBOR instead
    Left bs -> firstExceptT ShelleyQueryCmdHelpersError $ pPrintCBOR bs

    Right ledgerState -> do
      -- Ledger State
      let (DebugLedgerState snapshot) = ledgerState

      -- The three stake snapshots, obtained from the ledger state
      let (SnapShots markS setS goS _) = esSnapshots $ nesEs snapshot

      -- Calculate the three pool and active stake values for the given pool
      liftIO . LBS.putStrLn $ encodePretty $ Stakes
        { markPool = getPoolStake hk markS
        , setPool = getPoolStake hk setS
        , goPool = getPoolStake hk goS
        , markTotal = getAllStake markS
        , setTotal = getAllStake setS
        , goTotal = getAllStake goS
        }

-- | Sum all the stake that is held by the pool
getPoolStake :: KeyHash Cardano.Ledger.Keys.StakePool crypto -> SnapShot crypto -> Integer
getPoolStake hash ss = pStake
  where
    Coin pStake = fold (Map.map fromCompact $ VMap.toMap s)
    Stake s = poolStake hash (_delegations ss) (_stake ss)

-- | Sum the active stake from a snapshot
getAllStake :: SnapShot crypto -> Integer
getAllStake (SnapShot stake _ _) = activeStake
  where
    Coin activeStake = fold (fmap fromCompact (VMap.toMap (unStake stake)))

-- | This function obtains the pool parameters, equivalent to the following jq query on the output of query ledger-state
--   .nesEs.esLState._delegationState._pstate._pParams.<pool_id>
writePoolParams :: forall era ledgerera. ()
  => ShelleyLedgerEra era ~ ledgerera
  => FromCBOR (DebugLedgerState era)
  => Crypto.Crypto (Era.Crypto ledgerera)
  => Era.Crypto ledgerera ~ StandardCrypto
  => PoolId
  -> SerialisedDebugLedgerState era
  -> ExceptT ShelleyQueryCmdError IO ()
writePoolParams (StakePoolKeyHash hk) qState =
  case decodeLedgerState qState of
    -- In the event of decode failure print the CBOR instead
    Left bs -> firstExceptT ShelleyQueryCmdHelpersError $ pPrintCBOR bs

    Right ledgerState -> do
      let DebugLedgerState snapshot = ledgerState
      let poolState = _pstate $ _delegationState $ esLState $ nesEs snapshot

      -- Pool parameters
      let poolParams = Map.lookup hk $ _pParams poolState
      let fPoolParams = Map.lookup hk $ _fPParams poolState
      let retiring = Map.lookup hk $ _retiring poolState

      liftIO . LBS.putStrLn $ encodePretty $ Params poolParams fPoolParams retiring

decodeLedgerState :: forall era. ()
  => FromCBOR (DebugLedgerState era)
  => SerialisedDebugLedgerState era
  -> Either LBS.ByteString (DebugLedgerState era)
decodeLedgerState (SerialisedDebugLedgerState (Serialised ls)) = first (const ls) (decodeFull ls)

writeProtocolState :: Maybe OutputFile
                   -> ProtocolState era
                   -> ExceptT ShelleyQueryCmdError IO ()
writeProtocolState mOutFile ps@(ProtocolState pstate) =
  case mOutFile of
    Nothing -> case decodeProtocolState ps of
                 Left bs -> firstExceptT ShelleyQueryCmdHelpersError $ pPrintCBOR bs
                 Right chainDepstate -> liftIO . LBS.putStrLn $ encodePretty chainDepstate
    Just (OutputFile fpath) ->
      handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError fpath)
        . LBS.writeFile fpath $ unSerialised pstate

decodeProtocolState
  :: ProtocolState era
  -> Either LBS.ByteString (Ledger.ChainDepState StandardCrypto)
decodeProtocolState (ProtocolState (Serialised pbs)) =
  first (const pbs) (decodeFull pbs)

writeFilteredUTxOs :: Api.ShelleyBasedEra era
                   -> Maybe OutputFile
                   -> UTxO era
                   -> ExceptT ShelleyQueryCmdError IO ()
writeFilteredUTxOs shelleyBasedEra' mOutFile utxo =
    case mOutFile of
      Nothing -> liftIO $ printFilteredUTxOs shelleyBasedEra' utxo
      Just (OutputFile fpath) ->
        case shelleyBasedEra' of
          ShelleyBasedEraShelley -> writeUTxo fpath utxo
          ShelleyBasedEraAllegra -> writeUTxo fpath utxo
          ShelleyBasedEraMary -> writeUTxo fpath utxo
          ShelleyBasedEraAlonzo -> writeUTxo fpath utxo
 where
   writeUTxo fpath utxo' =
     handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError fpath)
       $ LBS.writeFile fpath (encodePretty utxo')

printFilteredUTxOs :: Api.ShelleyBasedEra era -> UTxO era -> IO ()
printFilteredUTxOs shelleyBasedEra' (UTxO utxo) = do
  Text.putStrLn title
  putStrLn $ replicate (Text.length title + 2) '-'
  case shelleyBasedEra' of
    ShelleyBasedEraShelley ->
      mapM_ (printUtxo shelleyBasedEra') $ Map.toList utxo
    ShelleyBasedEraAllegra ->
      mapM_ (printUtxo shelleyBasedEra') $ Map.toList utxo
    ShelleyBasedEraMary    ->
      mapM_ (printUtxo shelleyBasedEra') $ Map.toList utxo
    ShelleyBasedEraAlonzo ->
      mapM_ (printUtxo shelleyBasedEra') $ Map.toList utxo
 where
   title :: Text
   title =
     "                           TxHash                                 TxIx        Amount"

printUtxo
  :: Api.ShelleyBasedEra era
  -> (TxIn, TxOut CtxUTxO era)
  -> IO ()
printUtxo shelleyBasedEra' txInOutTuple =
  case shelleyBasedEra' of
    ShelleyBasedEraShelley ->
      let (TxIn (TxId txhash) (TxIx index), TxOut _ value _) = txInOutTuple
      in Text.putStrLn $
           mconcat
             [ Text.decodeLatin1 (hashToBytesAsHex txhash)
             , textShowN 6 index
             , "        " <> printableValue value
             ]

    ShelleyBasedEraAllegra ->
      let (TxIn (TxId txhash) (TxIx index), TxOut _ value _) = txInOutTuple
      in Text.putStrLn $
           mconcat
             [ Text.decodeLatin1 (hashToBytesAsHex txhash)
             , textShowN 6 index
             , "        " <> printableValue value
             ]
    ShelleyBasedEraMary ->
      let (TxIn (TxId txhash) (TxIx index), TxOut _ value _) = txInOutTuple
      in Text.putStrLn $
           mconcat
             [ Text.decodeLatin1 (hashToBytesAsHex txhash)
             , textShowN 6 index
             , "        " <> printableValue value
             ]
    ShelleyBasedEraAlonzo ->
      let (TxIn (TxId txhash) (TxIx index), TxOut _ value mDatum) = txInOutTuple
      in Text.putStrLn $
           mconcat
             [ Text.decodeLatin1 (hashToBytesAsHex txhash)
             , textShowN 6 index
             , "        " <> printableValue value <> " + " <> Text.pack (show mDatum)
             ]
 where
  textShowN :: Show a => Int -> a -> Text
  textShowN len x =
    let str = show x
        slen = length str
    in Text.pack $ replicate (max 1 (len - slen)) ' ' ++ str

  printableValue :: TxOutValue era -> Text
  printableValue (TxOutValue _ val) = renderValue val
  printableValue (TxOutAdaOnly _ (Lovelace i)) = Text.pack $ show i

runQueryStakePools
  :: AnyConsensusModeParams
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryStakePools (AnyConsensusModeParams cModeParams)
                          network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath

  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  result <- ExceptT . fmap (join . first ShelleyQueryCmdAcquireFailure) $
    executeLocalStateQueryExpr localNodeConnInfo Nothing $ \_ntcVersion -> runExceptT @ShelleyQueryCmdError $ do
      anyE@(AnyCardanoEra era) <- case consensusModeOnly cModeParams of
        ByronMode -> return $ AnyCardanoEra ByronEra
        ShelleyMode -> return $ AnyCardanoEra ShelleyEra
        CardanoMode -> lift . queryExpr $ QueryCurrentEra CardanoModeIsMultiEra

      let cMode = consensusModeOnly cModeParams

      case toEraInMode era cMode of
        Just eInMode -> do
          sbe <- getSbe $ cardanoEraStyle era

          firstExceptT ShelleyQueryCmdEraMismatch . ExceptT $
            queryExpr . QueryInEra eInMode . QueryInShelleyBasedEra sbe $ QueryStakePools

        Nothing -> left $ ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE

  writeStakePools mOutFile result

writeStakePools
  :: Maybe OutputFile
  -> Set PoolId
  -> ExceptT ShelleyQueryCmdError IO ()
writeStakePools (Just (OutputFile outFile)) stakePools =
  handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError outFile) $
    LBS.writeFile outFile (encodePretty stakePools)

writeStakePools Nothing stakePools =
  forM_ (Set.toList stakePools) $ \poolId ->
    liftIO . putStrLn $ Text.unpack (serialiseToBech32 poolId)

runQueryStakeDistribution
  :: AnyConsensusModeParams
  -> NetworkId
  -> Maybe OutputFile
  -> ExceptT ShelleyQueryCmdError IO ()
runQueryStakeDistribution (AnyConsensusModeParams cModeParams)
                          network mOutFile = do
  SocketPath sockPath <- firstExceptT ShelleyQueryCmdEnvVarSocketErr readEnvSocketPath
  let localNodeConnInfo = LocalNodeConnectInfo cModeParams network sockPath

  anyE@(AnyCardanoEra era) <- determineEra cModeParams localNodeConnInfo
  let cMode = consensusModeOnly cModeParams
  sbe <- getSbe $ cardanoEraStyle era

  case toEraInMode era cMode of
    Just eInMode -> do
      let query = QueryInEra eInMode
                    . QueryInShelleyBasedEra sbe
                    $ QueryStakeDistribution
      result <- executeQuery
                  era
                  cModeParams
                  localNodeConnInfo
                  query
      writeStakeDistribution mOutFile result
    Nothing -> left $ ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode cMode) anyE


writeStakeDistribution
  :: Maybe OutputFile
  -> Map PoolId Rational
  -> ExceptT ShelleyQueryCmdError IO ()
writeStakeDistribution (Just (OutputFile outFile)) stakeDistrib =
  handleIOExceptT (ShelleyQueryCmdWriteFileError . FileIOError outFile) $
    LBS.writeFile outFile (encodePretty stakeDistrib)

writeStakeDistribution Nothing stakeDistrib =
  liftIO $ printStakeDistribution stakeDistrib


printStakeDistribution :: Map PoolId Rational -> IO ()
printStakeDistribution stakeDistrib = do
  Text.putStrLn title
  putStrLn $ replicate (Text.length title + 2) '-'
  sequence_
    [ putStrLn $ showStakeDistr poolId stakeFraction
    | (poolId, stakeFraction) <- Map.toList stakeDistrib ]
 where
   title :: Text
   title =
     "                           PoolId                                 Stake frac"

   showStakeDistr :: PoolId
                  -> Rational
                  -- ^ Stake fraction
                  -> String
   showStakeDistr poolId stakeFraction =
     concat
       [ Text.unpack (serialiseToBech32 poolId)
       , "   "
       , showEFloat (Just 3) (fromRational stakeFraction :: Double) ""
       ]

-- | A mapping of Shelley reward accounts to both the stake pool that they
-- delegate to and their reward account balance.
-- TODO: Move to cardano-api
newtype DelegationsAndRewards
  = DelegationsAndRewards (Map StakeAddress Lovelace, Map StakeAddress PoolId)
    deriving (Eq, Show)


mergeDelegsAndRewards :: DelegationsAndRewards -> [(StakeAddress, Maybe Lovelace, Maybe PoolId)]
mergeDelegsAndRewards (DelegationsAndRewards (rewardsMap, delegMap)) =
 [ (stakeAddr, Map.lookup stakeAddr rewardsMap, Map.lookup stakeAddr delegMap)
 | stakeAddr <- nub $ Map.keys rewardsMap ++ Map.keys delegMap
 ]


instance ToJSON DelegationsAndRewards where
  toJSON delegsAndRwds =
      Aeson.Array . Vector.fromList
        . map delegAndRwdToJson $ mergeDelegsAndRewards delegsAndRwds
    where
      delegAndRwdToJson :: (StakeAddress, Maybe Lovelace, Maybe PoolId) -> Aeson.Value
      delegAndRwdToJson (addr, mRewards, mPoolId) =
        Aeson.object
          [ "address" .= addr
          , "delegation" .= mPoolId
          , "rewardAccountBalance" .= mRewards
          ]

instance FromJSON DelegationsAndRewards where
  parseJSON = withArray "DelegationsAndRewards" $ \arr -> do
    let vals = Vector.toList arr
    decoded <- mapM decodeObject vals
    pure $ zipper decoded
   where
     zipper :: [(StakeAddress, Maybe Lovelace, Maybe PoolId)]
             -> DelegationsAndRewards
     zipper l = do
       let maps = [ ( maybe mempty (Map.singleton sa) delegAmt
                    , maybe mempty (Map.singleton sa) mPool
                    )
                  | (sa, delegAmt, mPool) <- l
                  ]
       DelegationsAndRewards
         $ foldl
             (\(amtA, delegA) (amtB, delegB) -> (amtA <> amtB, delegA <> delegB))
             (mempty, mempty)
             maps

     decodeObject :: Aeson.Value
                  -> Aeson.Parser (StakeAddress, Maybe Lovelace, Maybe PoolId)
     decodeObject  = withObject "DelegationsAndRewards" $ \o -> do
       address <- o .: "address"
       delegation <- o .:? "delegation"
       rewardAccountBalance <- o .:? "rewardAccountBalance"
       pure (address, rewardAccountBalance, delegation)

-- Helpers

calcEraInMode
  :: CardanoEra era
  -> ConsensusMode mode
  -> ExceptT ShelleyQueryCmdError IO (EraInMode era mode)
calcEraInMode era mode=
  hoistMaybe (ShelleyQueryCmdEraConsensusModeMismatch (AnyConsensusMode mode) (anyCardanoEra era))
                   $ toEraInMode era mode

determineEra
  :: ConsensusModeParams mode
  -> LocalNodeConnectInfo mode
  -> ExceptT ShelleyQueryCmdError IO AnyCardanoEra
determineEra cModeParams localNodeConnInfo =
  case consensusModeOnly cModeParams of
    ByronMode -> return $ AnyCardanoEra ByronEra
    ShelleyMode -> return $ AnyCardanoEra ShelleyEra
    CardanoMode -> do
      eraQ <- liftIO . queryNodeLocalState localNodeConnInfo Nothing
                     $ QueryCurrentEra CardanoModeIsMultiEra
      case eraQ of
        Left acqFail -> left $ ShelleyQueryCmdAcquireFailure acqFail
        Right anyCarEra -> return anyCarEra

executeQuery
  :: forall result era mode. CardanoEra era
  -> ConsensusModeParams mode
  -> LocalNodeConnectInfo mode
  -> QueryInMode mode (Either EraMismatch result)
  -> ExceptT ShelleyQueryCmdError IO result
executeQuery era cModeP localNodeConnInfo q = do
  eraInMode <- calcEraInMode era $ consensusModeOnly cModeP
  case eraInMode of
    ByronEraInByronMode -> left ShelleyQueryCmdByronEra
    _ -> liftIO execQuery >>= queryResult
 where
   execQuery :: IO (Either AcquireFailure (Either EraMismatch result))
   execQuery = queryNodeLocalState localNodeConnInfo Nothing q

getSbe :: Monad m => CardanoEraStyle era -> ExceptT ShelleyQueryCmdError m (Api.ShelleyBasedEra era)
getSbe LegacyByronEra = left ShelleyQueryCmdByronEra
getSbe (Api.ShelleyBasedEra sbe) = return sbe

queryResult
  :: Either AcquireFailure (Either EraMismatch a)
  -> ExceptT ShelleyQueryCmdError IO a
queryResult eAcq =
  case eAcq of
    Left acqFailure -> left $ ShelleyQueryCmdAcquireFailure acqFailure
    Right eResult ->
      case eResult of
        Left err -> left . ShelleyQueryCmdLocalStateQueryError $ EraMismatchError err
        Right result -> return result

obtainLedgerEraClassConstraints
  :: ShelleyLedgerEra era ~ ledgerera
  => Api.ShelleyBasedEra era
  -> (( UsesValue ledgerera
      , ToJSON (DebugLedgerState era)
      , FromCBOR (DebugLedgerState era)
      , Era.Crypto ledgerera ~ StandardCrypto
      ) => a) -> a
obtainLedgerEraClassConstraints ShelleyBasedEraShelley f = f
obtainLedgerEraClassConstraints ShelleyBasedEraAllegra f = f
obtainLedgerEraClassConstraints ShelleyBasedEraMary    f = f
obtainLedgerEraClassConstraints ShelleyBasedEraAlonzo  f = f

