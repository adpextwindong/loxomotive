module Scanner where

import Util

import Token
import TokenType

import Control.Conditional

import Control.Monad.State
import Control.Monad.Except
import Control.Monad.Identity

data ScannerState = ScannerState
  { source  :: String
  , tokens  :: [Token]
  , line    :: Int
  , start   :: Int
  , current :: Int
  } deriving (Show)

data ScannerError = ScannerError String deriving (Show)

type Scanner a = ExceptT ScannerError (StateT ScannerState Identity) a

runScanner :: ScannerState -> Scanner a -> Either ScannerError a
runScanner st s = runIdentity $ evalStateT (runExceptT s) st

initState :: String -> ScannerState
initState source = ScannerState source [] 1 0 0

scanToken :: Scanner Token
scanToken = do
    c <- advance
    case c of
      '(' -> addToken LEFT_PAREN
      ')' -> addToken RIGHT_PAREN
      '{' -> addToken LEFT_BRACE
      '}' -> addToken RIGHT_BRACE
      ',' -> addToken COMMA
      '.' -> addToken DOT
      '-' -> addToken MINUS
      '+' -> addToken PLUS
      ';' -> addToken SEMICOLON
      '*' -> addToken STAR
      _ -> throwError $ ScannerError ("Invalid Token: '" ++ (c:"'"))

scanTokens :: Scanner [Token]
scanTokens = ifM isAtEnd done next
  where
    done = do
        st <- get
        return $ reverse (tokens st)
    next = do
        st <- get
        put (st {start = current st})
        _ <- scanToken
        scanTokens

addToken :: TokenType -> Scanner Token
addToken t = do
    st <- get
    let lexeme = slice (start st) (current st) (source st)
    let token = Token t lexeme Nothing (line st)
    put (st {tokens = token : (tokens st)})
    return token

isAtEnd :: Scanner Bool
isAtEnd = do
    st <- get
    return ((current st) >= (length $ source st))

advance :: Scanner Char
advance = do
    st <- get
    let cur = current st
    put $ st {current = cur + 1}
    return $ (source st) !! cur