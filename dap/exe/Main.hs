----------------------------------------------------------------------------
-- |
-- Module      :  Main
-- Copyright   :  (C) 2023 David M. Johnson
-- License     :  BSD3-style (see the file LICENSE)
-- Maintainer  :  David M. Johnson <djohnson.m@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
-- |
----------------------------------------------------------------------------
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE LambdaCase          #-}
----------------------------------------------------------------------------
module Main (main) where
----------------------------------------------------------------------------
import           Data.List
import           Data.String.Conversions               (cs)
import           Text.PrettyPrint.ANSI.Leijen          (pretty, plain)
import           Codec.Archive.Zip                     (withArchive, unEntrySelector, getEntries)
import           Data.IntSet                           ( IntSet )
import qualified Data.IntSet                           as IntSet
import qualified Data.Set                              as Set
import           Control.Arrow
import           Data.IORef
import           Control.Exception                     hiding (catch)
import           Control.Monad.IO.Class                (liftIO)
import           Control.Exception.Lifted              (catch)
import           Control.Monad
import           Control.Monad.State.Strict            ( gets )
import           Data.Aeson                            ( Value(Null), FromJSON )
import           Data.IntMap.Strict                    ( IntMap )
import qualified Data.IntMap.Strict                    as IntMap
import           Data.Bimap                            ( Bimap )
import qualified Data.Bimap                            as Bimap
import qualified Data.Map.Strict                       as M
import           Data.Map.Strict                       ( Map )
import qualified Data.Text.Encoding                    as T
import           Data.Text                             ( Text )
import qualified Data.Text                             as T
import           Data.Typeable                         ( typeOf )
import           Data.Maybe                            ( fromMaybe )
import           Data.List                             ( sortOn )
import           GHC.Generics                          ( Generic )
import           System.Environment                    ( lookupEnv )
import           System.FilePath                       ((</>), takeDirectory, takeExtension, dropExtension, splitFileName)
import           Text.Read                             ( readMaybe )
import qualified Data.ByteString.Lazy.Char8            as BL8 ( pack, unpack, fromStrict, toStrict )
import qualified Control.Concurrent.Chan.Unagi.Bounded as Unagi
import qualified Control.Concurrent.MVar               as MVar
----------------------------------------------------------------------------
import           Stg.Syntax                            hiding (sourceName, Scope)
import           Stg.IRLocation
import           Stg.Pretty
import           Stg.Interpreter
import           Stg.Interpreter.Debug
import           Stg.Interpreter.Base                  hiding (lookupEnv, getCurrentThreadState, Breakpoint)
import qualified Stg.Interpreter.Base                  as Stg
import           Stg.Interpreter.Debugger
import           Stg.Interpreter.Debugger.UI
import           Stg.IO
import           Stg.Program
import           Data.Yaml                             hiding (Array)
----------------------------------------------------------------------------
import           DAP                                   hiding (send)
----------------------------------------------------------------------------
-- | DAP entry point
-- Extracts configuration information from the environment
-- Opens a listen socket on a port (defaulting to '4711')
-- Converts the 'Socket' to a 'Handle' for convenience
main :: IO ()
main = do
  config <- getConfig
  runDAPServer config talk
----------------------------------------------------------------------------
-- | Fetch config from environment, fallback to sane defaults
getConfig :: IO ServerConfig
getConfig = do
  let
    hostDefault = "127.0.0.1"
    portDefault = 4711
  ServerConfig
    <$> do fromMaybe hostDefault <$> lookupEnv "DAP_HOST"
    <*> do fromMaybe portDefault . (readMaybe =<<) <$> do lookupEnv "DAP_PORT"
    <*> pure defaultCapabilities
    <*> pure True
----------------------------------------------------------------------------
-- | VSCode arguments are custom for attach
-- > "arguments": {
-- >      "__configurationTarget": 6,
-- >      "__sessionId": "6c0ba6f8-e478-4698-821e-356fc4a72c3d",
-- >      "name": "thing",
-- >      "program": "/home/dmjio/Desktop/stg-dap/test.fullpak",
-- >      "request": "attach",
-- >      "type": "dap-extension"
-- >  }
--
data AttachArgs
  = AttachArgs
  { __sessionId :: Text
    -- ^ SessionID from VSCode
  , program :: String
    -- ^ Path to .fullpak file
  } deriving stock (Show, Eq, Generic)
    deriving anyclass FromJSON
----------------------------------------------------------------------------
-- | External STG Interpreter application internal state
--type VariableReferences = IntMap (IntMap (IntMap Variable))
data ESTG
  = ESTG
  { debuggerChan      :: DebuggerChan
  , fullPakPath       :: String
  , breakpointMapRef  :: IORef (Map Stg.Breakpoint IntSet)
  , loadedSourcesRef  :: IORef [Source]

  -- application specific resource handling

  , dapSourceRefMap       :: !(Bimap DapSourceRefDescriptor Int)
    -- ^ Used to track source reference IDs
    --
  , dapFrameIdMap         :: !(Bimap DapFrameIdDescriptor Int)
    -- ^ Used to track stack frame IDs
    --
  , dapVariablesRefMap    :: !(Bimap DapVariablesRefDescriptor Int)
    -- ^ Used to track variablesReferences
    --
  , dapVariablesRefStore  :: !(IntMap [Variable])
    -- ^ Stores the assigned Variables for each VariablesReference
    --
  , nextFreshBreakpointId :: !Int
    -- ^ monotinic counter for unique BreakpointId assignment
    --
  }
----------------------------------------------------------------------------
-- | Intialize ESTG interpreter
----------------------------------------------------------------------------
initESTG :: AttachArgs -> Adaptor ESTG ()
initESTG AttachArgs {..} = do
  (dbgAsyncI, dbgAsyncO) <- liftIO (Unagi.newChan 100)
  dbgRequestMVar <- liftIO MVar.newEmptyMVar
  dbgResponseMVar <- liftIO MVar.newEmptyMVar
  breakpointMapRef <- liftIO $ newIORef mempty
  loadedSourcesRef <- liftIO $ newIORef mempty
  let dbgChan = DebuggerChan
        { dbgSyncRequest    = dbgRequestMVar
        , dbgSyncResponse   = dbgResponseMVar
        , dbgAsyncEventIn   = dbgAsyncI
        , dbgAsyncEventOut  = dbgAsyncO
        }
      estg = ESTG
        { debuggerChan          = dbgChan
        , fullPakPath           = program
        , breakpointMapRef      = breakpointMapRef
        , loadedSourcesRef      = loadedSourcesRef
        , dapSourceRefMap       = Bimap.empty
        , dapFrameIdMap         = Bimap.empty
        , dapVariablesRefMap    = Bimap.empty
        , dapVariablesRefStore  = mempty
        , nextFreshBreakpointId = 1
        }
  flip catch handleDebuggerExceptions
    $ registerNewDebugSession __sessionId estg
      (liftIO $ loadAndRunProgram True True program [] dbgChan DbgStepByStep False defaultDebugSettings)
      (handleDebugEvents dbgChan)
----------------------------------------------------------------------------
-- | Debug Event Handler
handleDebugEvents :: DebuggerChan -> Adaptor ESTG ()
handleDebugEvents DebuggerChan{..} = forever $ do
  dbgEvent <- liftIO (Unagi.readChan dbgAsyncEventOut)
  ESTG {..} <- getDebugSession
  let sendEvent ev = sendSuccesfulEvent ev . setBody
  case dbgEvent of
    DbgEventStopped -> do
      StgState{..} <- getStgState
      sendEvent EventTypeStopped $ object
        [ "reason"             .= String "step"
        , "allThreadsStopped"  .= True
        , "threadId"           .= Number (fromIntegral ssCurrentThreadId)
        ]

    DbgEventHitBreakpoint bkpName -> do
      StgState{..} <- getStgState
      breakpointMap <- liftIO $ readIORef breakpointMapRef
      sendEvent EventTypeStopped . object $
        [ "reason"             .= String "breakpoint"
        , "allThreadsStopped"  .= True
        , "threadId"           .= Number (fromIntegral ssCurrentThreadId)
        ] ++
        [ "hitBreakpointIds" .= idSet
        | Just idSet <- pure $ M.lookup bkpName breakpointMap
        ]

----------------------------------------------------------------------------
-- | Exception Handler
handleDebuggerExceptions :: SomeException -> Adaptor ESTG ()
handleDebuggerExceptions e | Just ThreadKilled <- fromException e = do
  sendTerminatedEvent (TerminatedEvent False)
  sendExitedEvent (ExitedEvent 0)
handleDebuggerExceptions e = do
  logError $ BL8.pack ("Caught: " <> show e)
  sendTerminatedEvent (TerminatedEvent False)
  sendExitedEvent (ExitedEvent 1)

pathToName path =
  case splitFileName (cs path) of
    (init -> moduleName, takeExtension -> ".ghccore") ->
      cs (moduleName <> ".core")
    (init -> moduleName, takeExtension -> ".stgbin") ->
      cs (moduleName <> ".stg")
    (init -> moduleName, takeExtension -> ext) ->
      cs (moduleName <> ext)

----------------------------------------------------------------------------
-- | Clears the currently known breakpoint set
clearBreakpoints :: Adaptor ESTG ()
clearBreakpoints = do
  ESTG {..} <- getDebugSession
  liftIO $ atomicWriteIORef breakpointMapRef mempty

----------------------------------------------------------------------------
-- | Adds new BreakpointId for a givent StgPoint
addNewBreakpoint :: Stg.Breakpoint -> Adaptor ESTG BreakpointId
addNewBreakpoint breakpoint = do
  ESTG {..} <- getDebugSession
  bkpId <- getFreshBreakpointId
  liftIO $ atomicModifyIORef' breakpointMapRef $ \m -> (M.insertWith mappend breakpoint (IntSet.singleton bkpId) m, ())
  pure bkpId

----------------------------------------------------------------------------
-- | Main function where requests are received and Events + Responses are returned.
-- The core logic of communicating between the client <-> adaptor <-> debugger
-- is implemented in this function.
----------------------------------------------------------------------------
talk :: Command -> Adaptor ESTG ()
----------------------------------------------------------------------------
-- | Register SessionId and initialize program in the 'AppStore'
talk CommandAttach = do
  initESTG =<< getArguments
  sendAttachResponse
    where
      emitEvent :: DebugOutput -> Adaptor ESTG ()
      emitEvent cmd = logInfo $ BL8.pack (show cmd)
----------------------------------------------------------------------------
talk CommandContinue = do
  ESTG {..} <- getDebugSession
  sendAndWait CmdContinue
  sendContinueResponse (ContinueResponse True)
----------------------------------------------------------------------------
talk CommandConfigurationDone = do
  sendConfigurationDoneResponse
----------------------------------------------------------------------------
talk CommandDisconnect = do
  destroyDebugSession
  sendExitedEvent (ExitedEvent 0)
  sendDisconnectResponse
----------------------------------------------------------------------------
talk CommandInitialize = do
  sendInitializeResponse
  sendInitializedEvent
----------------------------------------------------------------------------

talk CommandLoadedSources = do
  moduleInfos <- getModuleListFromFullPak
  sendLoadedSourcesResponse =<< do
    sourceList <- forM moduleInfos $ \ModuleInfo {..} -> case isCSource of
      True -> do
        let cSourcesSourcePath = cs qualifiedModuleName
        cSourcesSourceRef <- getSourceRef $ SourceRef_FileInFullpak ForeignC cSourcesSourcePath
        pure defaultSource
          { sourceName            = Just (cs qualifiedModuleName)
          , sourceSourceReference = Just cSourcesSourceRef
          , sourcePath            = Just (cs qualifiedModuleName)
          }

      False -> do
        let
          hsSourcePath    = cs (qualifiedModuleName </> "module.hs")
          coreSourcePath  = cs (qualifiedModuleName </> "module.ghccore")
          estgSourcePath  = cs (qualifiedModuleName </> "module.stgbin")
          stgSourcePath   = cs (qualifiedModuleName </> "module.ghcstg")
          cmmSourcePath   = cs (qualifiedModuleName </> "module.cmm")
          asmSourcePath   = cs (qualifiedModuleName </> "module.s")
          cStubSourcePath = cs (qualifiedModuleName </> "module_stub.c")
          hStubSourcePath = cs (qualifiedModuleName </> "module_stub.h")

        hsSourceRef     <- getSourceRef $ SourceRef_FileInFullpak Haskell  hsSourcePath
        coreSourceRef   <- getSourceRef $ SourceRef_FileInFullpak GhcCore  coreSourcePath
        estgSourceRef   <- getSourceRef $ SourceRef_FileInFullpak ExtStg   estgSourcePath
        stgSourceRef    <- getSourceRef $ SourceRef_FileInFullpak GhcStg   stgSourcePath
        cmmSourceRef    <- getSourceRef $ SourceRef_FileInFullpak Cmm      cmmSourcePath
        asmSourceRef    <- getSourceRef $ SourceRef_FileInFullpak Asm      asmSourcePath
        cStubSourceRef  <- getSourceRef $ SourceRef_FileInFullpak FFICStub cStubSourcePath
        hStubSourceRef  <- getSourceRef $ SourceRef_FileInFullpak FFIHStub hStubSourcePath

        let
          hsSource =
            defaultSource
            { sourceName = Just (pathToName hsSourcePath)
            , sourceSourceReference = Just hsSourceRef
            , sourcePath = Just hsSourcePath
            }
          coreSource =
            defaultSource
            { sourceName = Just (pathToName coreSourcePath)
            , sourceSourceReference = Just coreSourceRef
            , sourcePath = Just coreSourcePath
            }
          stgSource =
            defaultSource
            { sourceName = Just (pathToName stgSourcePath)
            , sourceSourceReference = Just stgSourceRef
            , sourcePath = Just stgSourcePath
            }
          cStubSource =
            defaultSource
            { sourceName = Just (pathToName cStubSourcePath)
            , sourceSourceReference = Just cStubSourceRef
            , sourcePath = Just cStubSourcePath
            }
          hStubSource =
            defaultSource
            { sourceName = Just (pathToName hStubSourcePath)
            , sourceSourceReference = Just hStubSourceRef
            , sourcePath = Just hStubSourcePath
            }
          cmmSource =
            defaultSource
            { sourceName            = Just (pathToName cmmSourcePath)
            , sourceSourceReference = Just cmmSourceRef
            , sourcePath            = Just cmmSourcePath
            }
          asmSource =
            defaultSource
            { sourceName            = Just (pathToName asmSourcePath)
            , sourceSourceReference = Just asmSourceRef
            , sourcePath            = Just asmSourcePath
            }
          estgSource =
            defaultSource
            { sourceName = Just (pathToName estgSourcePath)
            , sourceSourceReference = Just estgSourceRef
            , sourcePath = Just (pathToName estgSourcePath)
            , sourceSources = Just $
                [ hsSource
                , coreSource
                , cmmSource
                , asmSource
                , stgSource
                ] ++
                [ cStubSource
                | cStub
                ] ++
                [ hStubSource
                | hStub
                ]
            }
        pure estgSource
    ESTG {..} <- getDebugSession
    liftIO $ atomicModifyIORef' loadedSourcesRef (const (sourceList, ()))
    pure sourceList

----------------------------------------------------------------------------
talk CommandModules = do
  sendModulesResponse (ModulesResponse [] Nothing)
----------------------------------------------------------------------------
talk CommandPause = sendPauseResponse
----------------------------------------------------------------------------
talk CommandSetBreakpoints = do
  SetBreakpointsArguments {..} <- getArguments
  let maybeSourceRef = sourceSourceReference setBreakpointsArgumentsSource
  clearBreakpoints
  case (setBreakpointsArgumentsBreakpoints, maybeSourceRef) of
    (Just sourceBreakpoints, Just sourceRef) -> do
      (_sourceCodeText, locations) <- getSourceFromFullPak sourceRef
      breakpoints <- forM sourceBreakpoints $ \SourceBreakpoint{..} -> do
        -- filter all relevant ranges
        {-
          SP_RhsClosureExpr
        -}
        let onlySupported = \case
              SP_RhsClosureExpr{} -> True
              _ -> False
        let relevantLocations = filter (onlySupported . fst) $ case sourceBreakpointColumn of
              Nothing ->
                [ p
                | p@(_,((startRow, startCol), (endRow, endCol))) <- locations
                , startRow <= sourceBreakpointLine
                , endRow >= sourceBreakpointLine
                ]
              Just col  ->
                [ p
                | p@(_,((startRow, startCol), (endRow, endCol))) <- locations
                , startRow <= sourceBreakpointLine
                , endRow >= sourceBreakpointLine
                , startCol <= col
                , endCol >= col
                ]
        liftIO $ putStrLn $ "relevantLocations: " ++ show relevantLocations
        -- use the first location found
        case sortOn snd relevantLocations of
          (stgPoint@(SP_RhsClosureExpr closureName), ((startRow, startCol), (endRow, endCol))) : _ -> do
            let hitCount = fromMaybe 0 (sourceBreakpointHitCondition >>= readMaybe . T.unpack) :: Int
            sendAndWait (CmdAddBreakpoint (BkpStgPoint stgPoint) hitCount)
            bkpId <- addNewBreakpoint $ BkpStgPoint stgPoint
            pure $ defaultBreakpoint
              { breakpointVerified  = True
              , breakpointSource    = Just setBreakpointsArgumentsSource
              , breakpointLine      = Just startRow
              , breakpointColumn    = Just startCol
              , breakpointEndLine   = Just endRow
              , breakpointEndColumn = Just endCol
              , breakpointId        = Just bkpId
              }
          _ ->
            pure $ defaultBreakpoint
              { breakpointVerified  = False
              , breakpointSource    = Just setBreakpointsArgumentsSource
              , breakpointMessage   = Just "no code found"
              }
      sendSetBreakpointsResponse breakpoints
    _ ->
      sendSetBreakpointsResponse []
----------------------------------------------------------------------------
talk CommandStackTrace = do
  {-
    TODO:
    done - use the thread id from the arguments
    done - generate source location for stack frames where possible
    done - add the top frame derived from the current closure and env
    done - generate frameIds properly, store thread id and frame index for each frameId
      REQUIREMENT:
        move all resource handling code to the application side, the library should only be a message framework
  -}
  StackTraceArguments {..} <- getArguments
  StgState{..} <- getStgState
  case IntMap.lookup stackTraceArgumentsThreadId ssThreads of
    Nothing -> do
      sendError (ErrorMessage (T.pack $ "Unknown threadId: " ++ show stackTraceArgumentsThreadId)) Nothing

    Just ThreadState{..} -> do
      -- create the top stack frame from the current closure, but only for the current thread
      --  other (not currently running) threads do have everything on the thread stack
      topFrame <- case ssCurrentClosure of
        Just currentClosureId
          | ssCurrentThreadId == stackTraceArgumentsThreadId
          -> do
          (source, line, column, endLine, endColumn) <- getSourceAndPositionForStgPoint currentClosureId (SP_RhsClosureExpr currentClosureId)
          frameId <- getFrameId FrameId_CurrentThreadTopStackFrame
          pure [ defaultStackFrame
                  { stackFrameId        = frameId
                  , stackFrameName      = T.pack (show currentClosureId)
                  , stackFrameSource    = source
                  , stackFrameLine      = line
                  , stackFrameColumn    = column
                  , stackFrameEndLine   = Just endLine
                  , stackFrameEndColumn = Just endColumn
                  }
               ]
        _ -> pure []

      -- create the rest of frames from the Thread's stack frames
      stackFrames <- forM (zip [0..] tsStack) $ \(frameIndex, stackCont) -> case stackCont of
        CaseOf _ _ _ scrutResultId _ _ -> do
          -- HINT: use the case scrutinee result's unique binder id to lookup source location info
          (source, line, column, endLine, endColumn) <- getSourceAndPositionForStgPoint scrutResultId (SP_CaseScrutineeExpr scrutResultId)
          frameId <- getFrameId $ FrameId_ThreadStackFrame stackTraceArgumentsThreadId frameIndex
          pure $ defaultStackFrame
            { stackFrameId        = frameId
            , stackFrameName      = T.pack (showStackCont stackCont)
            , stackFrameSource    = source
            , stackFrameLine      = line
            , stackFrameColumn    = column
            , stackFrameEndLine   = Just endLine
            , stackFrameEndColumn = Just endColumn
            }

        _ -> do
          frameId <- getFrameId $ FrameId_ThreadStackFrame stackTraceArgumentsThreadId frameIndex
          pure $ defaultStackFrame
              -- HINT: no source location info
              { stackFrameId        = frameId
              , stackFrameName      = T.pack (showStackCont stackCont)
              , stackFrameLine      = 0
              , stackFrameColumn    = 0
              }

      sendStackTraceResponse $ StackTraceResponse
        { stackFrames = topFrame ++ stackFrames
        , totalFrames = Just (length topFrame + length stackFrames)
        }

----------------------------------------------------------------------------
talk CommandSource = do
  SourceArguments {..} <- getArguments -- save path of fullpak in state
  (source, _locations) <- getSourceFromFullPak sourceArgumentsSourceReference
  sendSourceResponse (SourceResponse source Nothing)
----------------------------------------------------------------------------
talk CommandThreads = do
  resetObjectLifetimes
  allThreads <- IntMap.toList . ssThreads <$> getStgState
  sendThreadsResponse
    [ Thread
      { threadId    = threadId
      , threadName  = T.pack (show threadId <> " " <> threadLabel)
      }
    | (threadId, threadState) <- allThreads
    , isThreadLive $ tsStatus threadState
    , let threadLabel = mkThreadLabel threadState
    ]
----------------------------------------------------------------------------
talk CommandScopes = do
  ScopesArguments {..} <- getArguments
  StgState{..} <- getStgState
  ESTG {..} <- getDebugSession
  case Bimap.lookupR scopesArgumentsFrameId dapFrameIdMap of
    Nothing -> do
      sendError (ErrorMessage (T.pack $ "Unknown frameId: " ++ show scopesArgumentsFrameId)) Nothing

    Just FrameId_CurrentThreadTopStackFrame -> do
      sendScopesResponse (ScopesResponse []) -- TODO

    Just frameIdDescriptor@(FrameId_ThreadStackFrame threadId frameIndex) -> do
      let stackFrame = (tsStack $ ssThreads IntMap.! threadId) !! frameIndex
      scopes <- generateScopes frameIdDescriptor stackFrame
      sendScopesResponse (ScopesResponse scopes)

----------------------------------------------------------------------------
talk CommandVariables = do
  VariablesArguments {..} <- getArguments
  variables <- getVariables variablesArgumentsVariablesReference
  sendVariablesResponse (VariablesResponse variables)
----------------------------------------------------------------------------
talk CommandNext = do
  NextArguments {..} <- getArguments
  sendAndWait CmdStep
  pure ()
----------------------------------------------------------------------------
talk CommandBreakpointLocations       = sendBreakpointLocationsResponse []
talk CommandSetDataBreakpoints        = sendSetDataBreakpointsResponse []
talk CommandSetExceptionBreakpoints   = sendSetExceptionBreakpointsResponse []
talk CommandSetFunctionBreakpoints    = sendSetFunctionBreakpointsResponse []
talk CommandSetInstructionBreakpoints = sendSetInstructionBreakpointsResponse []
----------------------------------------------------------------------------
talk cmd = logInfo $ BL8.pack ("GOT cmd " <> show cmd)
----------------------------------------------------------------------------


getSourceAndPositionForStgPoint :: Id -> StgPoint -> Adaptor ESTG (Maybe Source, Int, Int, Int, Int)
getSourceAndPositionForStgPoint (Id Binder{..}) stgPoint = do
      ESTG {..} <- getDebugSession
      loadedSources <- liftIO $ readIORef loadedSourcesRef
      let srcName = cs $ getModuleName binderModule
          source  = head $ filter (\s -> (dropExtension . cs <$> sourceName s) == Just srcName) loadedSources
          -- TODO: use functional model: Id's module name -> source path -> source ref
          -- TODO: remove IORef
          Just sourceRef = sourceSourceReference source
      (_sourceCodeText, locations) <- getSourceFromFullPak sourceRef
      case filter ((== stgPoint) . fst) locations of
        (_, ((line, column),(endLine, endColumn))) : _ -> do
          pure (Just source, line, column, endLine, endColumn)
        _ -> do
          pure (Just source, 0, 0, 0, 0)

----------------------------------------------------------------------------

data ModuleInfo
  = ModuleInfo
  { cStub :: Bool
    -- ^ If stubs.c is included in the .fullpak for this module
  , hStub :: Bool
    -- ^ If stubs.h is included in the .fullpak for this module
  , isCSource :: Bool
    -- ^ Is a C source file located in c-sources
  , qualifiedModuleName :: String
    -- ^ Fully qualified module name
  }
----------------------------------------------------------------------------
-- | Retrieves list of modules from .fullpak file
-- TODO: Check if stubs file exists, if so, return it.
getModuleListFromFullPak :: Adaptor ESTG [ModuleInfo]
getModuleListFromFullPak = do
  ESTG {..} <- getDebugSession
  let appName = "app.ghc_stgapp"
  bytes <- liftIO (readModpakL fullPakPath appName id)
  rawEntries <- fmap unEntrySelector . M.keys <$> withArchive fullPakPath getEntries
  let folderNames = Set.fromList (takeDirectory <$> rawEntries)
  GhcStgApp {..} <- liftIO (decodeThrow (BL8.toStrict bytes))
  let
    unitModules :: [String]
    unitModules = concat
      [ unitExposedModules ++ unitHiddenModules
      | UnitLinkerInfo {..} <- appLibDeps
      ]

    cbitsSources :: [String]
    cbitsSources =
      [ entry
      | entry <- rawEntries
      , "cbits-source" `isPrefixOf` entry
      ]

  let rawEntriesSet = Set.fromList rawEntries

  pure
    [ ModuleInfo
      { cStub = (moduleName </> "module_stub.c") `Set.member` rawEntriesSet
      , hStub = (moduleName </> "module_stub.h") `Set.member` rawEntriesSet
      , qualifiedModuleName = moduleName
      , ..
      }
    | moduleName <- unitModules <> appModules <> cbitsSources
    , let isCSource = "cbits-source" `isPrefixOf` moduleName
    , moduleName `Set.member` folderNames || isCSource
    ]

----------------------------------------------------------------------------
-- | Retrieves list of modules from .fullpak file
getSourceFromFullPak :: SourceId -> Adaptor ESTG (Text, [(StgPoint, SrcRange)])
getSourceFromFullPak sourceId = do
  ESTG {..} <- getDebugSession
  SourceRef_FileInFullpak srcLang sourcePath <- case Bimap.lookupR sourceId dapSourceRefMap of
    Nothing     -> do
      sendError (ErrorMessage (T.pack $ "Unknown sourceId: " ++ show sourceId)) Nothing
    Just value  -> pure value
  --sourcePath <- T.unpack <$> getSourcePathBySourceReferenceId sourceId
  liftIO $
    case srcLang of
      ExtStg -> do
        m <- readModpakL fullPakPath (cs sourcePath) decodeStgbin
        pure . pShow $ pprModule m
      _ -> do
        ir <- readModpakS fullPakPath (cs sourcePath) T.decodeUtf8
        pure (ir, [])
----------------------------------------------------------------------------
-- | Synchronous call to Debugger, sends message and waits for response
sendAndWait :: DebugCommand -> Adaptor ESTG DebugOutput
sendAndWait cmd = do
  ESTG {..} <- getDebugSession
  let DebuggerChan{..} = debuggerChan
  liftIO $ do
    MVar.putMVar dbgSyncRequest cmd
    MVar.takeMVar dbgSyncResponse

getStgState :: Adaptor ESTG StgState
getStgState = do
  sendAndWait (CmdInternal "get-stg-state") >>= \case
    DbgOutStgState stgState ->
      pure stgState
    otherMessage -> do
      let errorMsg
            = concat
            [ "Unexpected Message received from interpreter: "
            , show otherMessage
            ]
      logInfo (BL8.pack errorMsg)
      sendError (ErrorMessage (T.pack errorMsg)) Nothing

----------------------------------------------------------------------------
mkThreadLabel :: ThreadState -> String
mkThreadLabel = maybe "<unknown>" (BL8.unpack . BL8.fromStrict) . tsLabel

----------------------------------------------------------------------------
generateScopes
  :: DapFrameIdDescriptor
  -> StackContinuation
  -- ^ The stack instruction that we're generating Scopes for
  -> Adaptor ESTG [Scope]
  -- ^ List of Scopes for this StackFrame
generateScopes frameIdDesc stackCont@(CaseOf _ closureId env _ _ _) = do
  (source, line, column, endLine, endColumn) <- getSourceAndPositionForStgPoint closureId (SP_RhsClosureExpr closureId)
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  setVariables scopeVarablesRef
    -- DMJ: for now everything is local.
    -- Inspect StaticOrigin to put things top-level, or as arguments, where applicable
    [ defaultVariable
      { variableName  = cs binderName
      , variableValue = cs variableValue
      , variableType  = Just (cs variableType)
      }
    | (Id (Binder{..}), (_, atom)) <- M.toList env
    , let (variableType, variableValue) = getAtomTypeAndValue atom
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just (M.size env)
      , scopeSource = source
      , scopeLine = Just line
      , scopeColumn = Just column
      , scopeEndLine = Just endLine
      , scopeEndColumn = Just endColumn
      }
    ]
generateScopes frameIdDesc stackCont@(Update addr) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "Address"
      , variableValue = T.pack (show addr)
      , variableType = Just "Ptr"
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals: " <> T.pack (showStackCont stackCont)
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 1
      }
    ]
generateScopes frameIdDesc stackCont@(Apply atoms) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "Closure argument"
      , variableValue = cs variableValue
      , variableType = Just (cs variableType)
      }
    | atom <- atoms
    , let (variableType, variableValue) = getAtomTypeAndValue atom
    ]
  pure
    [ defaultScope
      { scopeName = "Locals: " <> T.pack (showStackCont stackCont)
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just (length atoms)
      }
    ]
generateScopes frameIdDesc stackCont@(Catch atom blockAsync interruptible) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  let (variableType, variableValue) = getAtomTypeAndValue atom
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "Exception Handler"
      , variableValue = cs variableValue
      , variableType = Just (cs variableType)
      }
    , defaultVariable
      { variableName = "BlockAsyncExceptions"
      , variableValue = T.pack (show blockAsync)
      , variableType = Just $ T.pack $ show (typeOf blockAsync)
      }
    , defaultVariable
      { variableName = "Interruptible"
      , variableValue = T.pack (show interruptible)
      , variableType = Just $ T.pack $ show (typeOf interruptible)
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 3
      }
    ]
generateScopes frameIdDesc stackCont@(RestoreExMask blockAsync interruptible) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "BlockAsyncExceptions"
      , variableValue = T.pack (show blockAsync)
      , variableType = Just $ T.pack $ show (typeOf blockAsync)
      }
    , defaultVariable
      { variableName = "Interruptible"
      , variableValue = T.pack (show interruptible)
      , variableType = Just $ T.pack $ show (typeOf interruptible)
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 2
      }
    ]
generateScopes frameIdDesc stackCont@(RunScheduler reason) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "Schedule Reason"
      , variableValue = showScheduleReason reason
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 1
      }
    ] where
      showScheduleReason :: ScheduleReason            -> Text
      showScheduleReason SR_ThreadFinished            = "Thread Finished"
      showScheduleReason SR_ThreadFinishedFFICallback = "Thread Finished FFI Callback"
      showScheduleReason SR_ThreadBlocked             = "Thread Blocked"
      showScheduleReason SR_ThreadYield               = "Thread Yield"
      showScheduleReason SR_ThreadFinishedMain        = "Thread Finished Main"

generateScopes frameIdDesc stackCont@(Atomically atom) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  let (variableType, variableValue) = getAtomTypeAndValue atom
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "STM action"
      , variableValue = cs variableValue
      , variableType = Just (cs variableType)
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 1
      }
    ]
generateScopes frameIdDesc stackCont@(CatchRetry atom1 atom2 interruptible) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  let (variableType1, variableValue1) = getAtomTypeAndValue atom1
  let (variableType2, variableValue2) = getAtomTypeAndValue atom2
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "First STM action"
      , variableValue = cs variableValue1
      , variableType = Just (cs variableType1)
      }
    , defaultVariable
      { variableName = "Second STM action"
      , variableValue = T.pack (show atom2)
      , variableType = Just (T.pack (show (typeOf atom2)))
      }
    , defaultVariable
      { variableName = "Interruptible"
      , variableValue = T.pack (show interruptible)
      , variableType = Just "Bool"
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals: " <> T.pack (showStackCont stackCont)
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 3
      }
    ]
generateScopes frameIdDesc (CatchSTM atom1 atom2) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  let (variableType1, variableValue1) = getAtomTypeAndValue atom1
      (variableType2, variableValue2) = getAtomTypeAndValue atom2
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "STM action"
      , variableValue = cs variableValue1
      , variableType = Just (cs variableValue1)
      }
    , defaultVariable
      { variableName = "Exception Handler"
      , variableValue = cs variableValue2
      , variableType = Just (cs variableType2)
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 2
      }
    ]
generateScopes frameIdDesc stackCont@DataToTagOp = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 0
      }
    ]
generateScopes frameIdDesc stackCont@(RaiseOp atom) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  let (variableType, variableValue) = getAtomTypeAndValue atom
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "RaiseOp"
      , variableValue = cs variableValue
      , variableType = Just (cs variableType)
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 1
      }
    ]
generateScopes frameIdDesc stackCont@(KeepAlive atom) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  let (variableType, variableValue) = getAtomTypeAndValue atom
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "Managed Object"
      , variableValue = cs variableValue
      , variableType = Just (cs variableType)
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 1
      }
    ]
generateScopes frameIdDesc stackCont@(DebugFrame (RestoreProgramPoint maybeId _)) = do
  scopeVarablesRef <- getVariablesRef $ VariablesRef_StackFrameVariables frameIdDesc
  setVariables scopeVarablesRef
    [ defaultVariable
      { variableName = "DebugFrame"
      , variableValue = cs (show maybeId)
      , variableType = Just "RestoreProgramPoint"
      }
    ]
  pure
    [ defaultScope
      { scopeName = "Locals"
      , scopePresentationHint = Just ScopePresentationHintLocals
      , scopeVariablesReference = scopeVarablesRef
      , scopeNamedVariables = Just 1
      }
    ]

showLitNumType :: LitNumType -> String
showLitNumType LitNumInt8   = "Int8"
showLitNumType LitNumInt16  = "Int16"
showLitNumType LitNumInt32  = "Int32"
showLitNumType LitNumInt64  = "Int64"
showLitNumType LitNumWord   = "Word"
showLitNumType LitNumWord8  = "Word8"
showLitNumType LitNumWord16 = "Word16"
showLitNumType LitNumWord32 = "Word32"
showLitNumType LitNumWord64 = "Word64"

showElemRep :: PrimElemRep -> String
showElemRep Int8ElemRep   = "Int8Rep"
showElemRep Int16ElemRep  = "Int16Rep"
showElemRep Int32ElemRep  = "Int32Rep"
showElemRep Int64ElemRep  = "Int64Rep"
showElemRep Word8ElemRep  = "Word8Rep"
showElemRep Word16ElemRep = "Word16Rep"
showElemRep Word32ElemRep = "Word32Rep"
showElemRep Word64ElemRep = "Word64Rep"
showElemRep FloatElemRep  = "FloatRep"
showElemRep DoubleElemRep = "DoubleRep"

showRubbishType :: Type -> String
showRubbishType (SingleValue primRep) = showPrimRep primRep

showRubbishType (UnboxedTuple primReps) =
  concat
  [ "(# "
  , intercalate "," (showPrimRep <$> primReps)
  , " #)"
  ]
showRubbishType PolymorphicRep = show PolymorphicRep

showPrimRep :: PrimRep -> String
showPrimRep (VecRep n primElemRep) =
  concat
  [ "<"
  , intercalate "," (replicate n (showElemRep primElemRep))
  , ">"
  ]
showPrimRep rep = show rep

getAtomTypeAndValue
  :: Atom
  -> (String, String)
getAtomTypeAndValue = \case
  HeapPtr addr                                 -> ("HeapPtr", show addr)
  Literal (LitChar char)                       -> ("Char", [char])
  Literal (LitString bytes)                    -> ("String", cs bytes)
  Literal LitNullAddr                          -> ("Address", "0x00000000")
  Literal (LitFloat float)                     -> ("Float", show float)
  Literal (LitDouble double)                   -> ("Double", show double)
  Literal (LitLabel labelName FunctionLabel{}) -> ("Foreign Function", cs labelName)
  Literal (LitLabel labelName DataLabel)       -> ("Foreign Data", cs labelName)
  Literal (LitNumber num value)                -> (showLitNumType num, show value)
  Literal (LitRubbish rubbishType)             -> ("Rubbish", showRubbishType rubbishType)
  Void                                         -> ("Void", "()")
  PtrAtom _ x                                  -> ("Ptr", show x)
  IntAtom x                                    -> ("Int", show x)
  WordAtom x                                   -> ("Word", show x)
  FloatAtom x                                  -> ("Float", show x)
  DoubleAtom x                                 -> ("Double", show x)
  MVar x                                       -> ("MVar", show x)
  MutVar x                                     -> ("MutVar", show x)
  TVar x                                       -> ("TVar", show x)
  Array idx                                    -> ("Array", show idx)
  MutableArray idx                             -> ("MutableArray", show idx)
  SmallArray idx                               -> ("SmallArray", show idx)
  SmallMutableArray idx                        -> ("SmallMutableArray", show idx)
  ArrayArray idx                               -> ("ArrayArray", show idx)
  MutableArrayArray idx                        -> ("MutableArrayArray", show idx)
  ByteArray idx                                -> ("ByteArray", show idx)
  MutableByteArray idx                         -> ("MutableByteArray", show idx)
  WeakPointer x                                -> ("WeakPoint", show x)
  StableName x                                 -> ("StableName", show x)
  ThreadId x                                   -> ("ThreadId", show x)
  LiftedUndefined                              -> ("LiftedUndefined","undefined")

-- + on watch causes "CommandEvaluate"
-- right click - set value - [127.0.0.1:49599][INFO][GOT cmd CommandSetVariable]
-- right click - copy value - [127.0.0.1:49599][INFO][GOT cmd CommandEvaluate]
-- save breakpoints from breakpoints request into AdaptrClient set, set them on the interpreter after configuration done (not attach)

-- resource handling

getsApp f = f <$> getDebugSession
modifyApp = updateDebugSession


-------------------------------------
{-
  IDEA:
    pure design
      use pure and unique resource descriptors to select items from StgState
      maintain a bimap between the pure resource descriptors and DAP integer ids

    IMPORTANT: avoid use of counters
    BENEFIT:
      DAP request order independence
      no resource caching is needed
      stateless
      use of descriptive resource identification instead of integers

  IDEA:
    ResourceID ADT - structured key
    idMap :: ResourceID -> Int

    DAP request argument -> estg domian idientifiers
    request argument's id -> estg domain 

  resource ids
    threadRef     = thread id
    frameRef      = thread id + frame index
    scopeRef      = thread id + frame index + argument index
    variablesRef  = ??
    sourceRef

  HINT: VariablesRef -> [Variable]

  DAP id types:
    thread
    stack frame
    variable


  Threads             args: NONE
    StackTrace        args: threadId
      Scopes          args: frameId
        Variables     args: variablesRef
          ...
            Variables
-}

type StackFrameIndex = Int

data DapFrameIdDescriptor
  = FrameId_CurrentThreadTopStackFrame
  | FrameId_ThreadStackFrame ThreadId StackFrameIndex
  deriving (Show, Eq, Ord)

data DapVariablesRefDescriptor
  = VariablesRef_StackFrameVariables DapFrameIdDescriptor
  deriving (Show, Eq, Ord)

data SourceLanguage
  = Haskell
  | GhcCore
  | GhcStg
  | Cmm
  | Asm
  | ExtStg
  | FFICStub
  | FFIHStub
  | ForeignC
  deriving (Show, Eq, Ord)

data DapSourceRefDescriptor
  = SourceRef_FileInFullpak SourceLanguage SourcePath
  deriving (Show, Eq, Ord)

getFrameId :: DapFrameIdDescriptor -> Adaptor ESTG Int
getFrameId key = do
  getsApp (Bimap.lookup key . dapFrameIdMap) >>= \case
    Just frameId -> pure frameId
    Nothing -> do
      frameId <- getsApp (succ . Bimap.size . dapFrameIdMap)
      modifyApp $ \s -> s {dapFrameIdMap = Bimap.insert key frameId (dapFrameIdMap s)}
      pure frameId

getVariablesRef :: DapVariablesRefDescriptor -> Adaptor ESTG Int
getVariablesRef key = do
  getsApp (Bimap.lookup key . dapVariablesRefMap) >>= \case
    Just varRef -> pure varRef
    Nothing -> do
      varRef <- getsApp (succ . Bimap.size . dapVariablesRefMap)
      modifyApp $ \s -> s {dapVariablesRefMap = Bimap.insert key varRef (dapVariablesRefMap s)}
      pure varRef

getSourceRef :: DapSourceRefDescriptor -> Adaptor ESTG Int
getSourceRef key = do
  getsApp (Bimap.lookup key . dapSourceRefMap) >>= \case
    Just srcRef -> pure srcRef
    Nothing -> do
      srcRef <- getsApp (succ . Bimap.size . dapSourceRefMap)
      modifyApp $ \s -> s {dapSourceRefMap = Bimap.insert key srcRef (dapSourceRefMap s)}
      pure srcRef

setVariables :: Int -> [Variable] -> Adaptor ESTG ()
setVariables variablesRef variableList = do
  modifyApp $ \s -> s {dapVariablesRefStore = IntMap.insert variablesRef variableList (dapVariablesRefStore s)}

getVariables :: Int -> Adaptor ESTG [Variable]
getVariables variablesRef = do
  ESTG {..} <- getDebugSession
  case IntMap.lookup variablesRef dapVariablesRefStore of
    Nothing       -> sendError (ErrorMessage (T.pack $ "Unknown variablesRef: " ++ show variablesRef)) Nothing
    Just varList  -> pure varList

----------------------------------------------------------------------------
-- | Note: this `Int` should act as if it were an unsigned 31-bit integer (0, 2^31).

getAllVars :: Adaptor ESTG [Variable]
getAllVars = getsApp (concat . IntMap.elems . dapVariablesRefStore)

-- | Invoked when a StepEvent has occurred
resetObjectLifetimes :: Adaptor ESTG ()
resetObjectLifetimes = do
  modifyApp $ \s -> s
    { dapFrameIdMap         = Bimap.empty
    , dapVariablesRefMap    = Bimap.empty
    , dapVariablesRefStore  = mempty
    }

getFreshBreakpointId :: Adaptor ESTG BreakpointId
getFreshBreakpointId = do
  bkpId <- getsApp nextFreshBreakpointId
  modifyApp $ \s -> s { nextFreshBreakpointId = nextFreshBreakpointId s + 1 }
  pure bkpId


type SourcePath = Text
type BreakpointId = Int
type SourceId = Int
type ThreadId = Int
