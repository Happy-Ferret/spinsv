module Main where
--
-- TODO check 'async' module
-- TODO use `IO Either` as return type when it makes sense

import System.Posix.IO
import System.Posix (Fd)
import System.Posix.Signals
import System.Posix.Process
import System.Posix.Directory
import System.Exit
import System.Environment
import System.Console.GetOpt
import Control.Concurrent
import System.IO
import Data.Char
import Control.Monad

import qualified Network as Net

type Cmd = (String, [String])

data Want = Up | Down deriving (Show)

data Config = Config
    { inCmd   :: String
    , outCmd  :: String
    , inArgs  :: [String]
    , outArgs :: [String]
    , port    :: Maybe Int
    , dir     :: String
    , help    :: Bool
    , version :: Bool
    } deriving Show

data Task = Task
    { tCmd  :: Cmd
    , tWant :: MVar Want
    }

versionString :: String
versionString = "0.0.0"

tee :: String
tee = "tee"

mkTask :: MVar Want -> Config -> (Config -> String) -> (Config -> [String]) -> Task
mkTask w cfg cmdf argsf =
    Task{tCmd = (cmdf cfg, argsf cfg), tWant = w}

defaultConfig :: Config
defaultConfig = Config
    { inCmd   = tee
    , outCmd  = tee
    , inArgs  = []
    , outArgs = []
    , port    = Nothing
    , dir     = "."
    , help    = False
    , version = False
    }

helpString :: String -> String
helpString prog =
    usageInfo header options 
    where
        header = unlines [ concat [ "usage: ", prog, " [<option>...]"]
                         ,"\nstart and monitor a service and its appendant log service\n"
                         , "options:"
                         ]

options :: [OptDescr (Config -> Config)]
options = 
    [ Option [] ["in.cmd"]
        (ReqArg (\o cfg -> cfg{inCmd = o})                    "<cmd>")  "input command (tee)"
    , Option [] ["out.cmd"]
        (ReqArg (\o cfg -> cfg{outCmd = o})                   "<cmd>")  "output command (tee)"
    , Option [] ["in.arg"]
        (ReqArg (\o cfg -> cfg{inArgs = inArgs cfg ++ [o]})   "<arg>")  "input argument (may be given multiple times)"
    , Option [] ["out.arg"]
        (ReqArg (\o cfg -> cfg{outArgs = outArgs cfg ++ [o]}) "<arg>")  "output argument (may be given multiple times)"
    , Option [] ["port"]
        (ReqArg (\o cfg -> cfg{port = Just $ read o})         "<port>") "port to bind to (optional)"
    , Option [] ["dir"]
        (ReqArg (\o cfg -> cfg{dir = o})                      "<dir>")  "directory to run in (.)"
    , Option [] ["help"]
        (NoArg  (\cfg   -> cfg{help = True}))                           "print the help and exit"
    , Option [] ["version"]
        (NoArg  (\cfg   -> cfg{version = True}))                        "print the version and exit"
    ]

spawn :: MVar () -> String -> Task -> [Maybe Fd] -> IO ()
spawn done wd t fds = do
    changeWorkingDirectory wd
    pid <- forkProcess $ child fds
    sequence $ map maybeClose fds
    ps <- getProcessStatus True False pid

    case ps of
        Just status ->
            case status of
                Exited ExitSuccess -> return ()
                _                  -> readMVar (tWant t) >>= failWith
            where
                failWith Up   = spawn done wd t fds
                failWith Down = putMVar done () >> return ()

        Nothing ->
            return ()

    where
        maybeClose :: Maybe Fd -> IO ()
        maybeClose (Just fd) = closeFd fd
        maybeClose _         = return ()

        child :: [Maybe Fd] -> IO ()
        child fds' = do
            sequence $ zipWith maybeDup fds' [stdInput, stdOutput, stdError]
            sequence $ map maybeClose fds'

            executeFile cmd True args Nothing

            where
                (cmd, args) = tCmd t
                maybeDup (Just fd) std = dupTo fd std >> return ()
                maybeDup Nothing   _   = return ()

getCmd :: IO (Config, String)
getCmd = do
    a <- getArgs
    n <- getProgName

    case getOpt RequireOrder options a of
        (flags, [], []) ->
            return $ (foldl (\def t -> t def) defaultConfig flags, n)
        (_, nonOpts, []) ->
            error $ "unrecognized arguments: " ++ unwords nonOpts
        (_, _, msgs) ->
            error $ head msgs

handleReq :: MVar Want -> String -> IO String
handleReq wants line =
    case line of
        "?" -> fmap (map toLower . show) (readMVar wants)
        "u" -> putMVar wants Up   >> {- TODO start service if stopped -} return ok
        "d" -> putMVar wants Down >> {- TODO send SIGTERM to service -}  return ok
        "x" -> {- TODO kill child services -} exitSuccess
        cmd -> return $ err (" unknown command '" ++ cmd ++ "'")
    where
        ok    = "OK"
        err m = "ERROR" ++ m

recvTCP :: Handle -> MVar Want -> IO a
recvTCP handle w =
    forever $ hGetLine handle >>= handleReq w >>= hPutStrLn handle
    -- Consider using hGetChar

acceptTCP :: Net.Socket -> MVar Want -> IO a
acceptTCP s w = forever $ do
    (handle, _, _) <- Net.accept s
    hSetBuffering handle NoBuffering
    forkIO $ recvTCP handle w

listenTCP :: Int -> MVar Want -> IO Net.Socket
listenTCP p wants = do
    sock <- Net.listenOn $ Net.PortNumber $ fromIntegral p
    forkIO $ acceptTCP sock wants
    return sock

main :: IO ()
main =
    getCmd >>= execute

    where
        execute (cfg, _) | version cfg = putStrLn versionString  >> exitSuccess
        execute (cfg, n) | help    cfg = putStrLn (helpString n) >> exitSuccess
        execute (cfg, _) = do
            done <- newEmptyMVar
            wants <- newMVar Up

            installHandler sigPIPE Ignore Nothing
            blockSignals $ addSignal sigCHLD emptySignalSet

            (readfd, writefd) <- createPipe

            let spawn' = spawn done (dir cfg)

            forkIO $ spawn' (mkTask wants cfg outCmd outArgs) [(Just readfd), Nothing, Nothing]
            forkIO $ spawn' (mkTask wants cfg inCmd inArgs)   [Nothing, (Just writefd), (Just writefd)]
            
            sock <- case (port cfg) of
                Nothing -> return Nothing
                Just p  -> return (Just $ listenTCP p wants)

            takeMVar done >> takeMVar done

            case sock of
                Nothing -> return ()
                Just s  -> s >>= Net.sClose
            

