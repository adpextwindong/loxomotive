module Resolver (resolve) where

import Expr
import Stmt
import Token
import Interpreter (InterpreterState(..))

import Control.Monad.Except
import Control.Monad.State

import Control.Monad.Extra (ifM, maybeM)
import Control.Conditional  (if')
import Data.Maybe

import Data.Stack
import qualified Data.Map.Strict as Map

data ResolverState
    = ResolverState
    { scopes :: Stack Scope
    , interpreterState  :: InterpreterState
    , currentFunction :: FunctionType
    , currentClass :: ClassType
    } deriving (Show)


data ResolverError = ResolverError Token String deriving (Show)
type Scope = Map.Map String Bool
type Resolver a = ExceptT ResolverError (StateT ResolverState IO) a

data FunctionType = FUN_NONE | FUNCTION | INITITIALIZER | METHOD deriving (Show, Eq)
data ClassType = CLASS_NONE | CLASS | SUBCLASS deriving (Show, Eq)

resolve :: InterpreterState -> [Stmt] -> IO (Either ResolverError InterpreterState)
resolve i stmts = do
    (res, s) <- runResolver (initState i) (resolveStmts stmts)
    either (return . Left) (\_ -> return $ Right (interpreterState s)) (res)

runResolver :: ResolverState -> Resolver a -> IO (Either ResolverError a, ResolverState)
runResolver st i = runStateT (runExceptT i) st

initState :: InterpreterState -> ResolverState
initState i = ResolverState stackNew i FUN_NONE CLASS_NONE

-- resolve Stmts

resolveStmts :: [Stmt] -> Resolver ()
resolveStmts stmts = mapM_ resolveStmt stmts

resolveStmt :: Stmt -> Resolver ()
resolveStmt (Block stmts) = beginScope >> resolveStmts stmts >> endScope

resolveStmt (Class name superclass methods) = do
    declare name
    define name
    enclosingClass <- gets currentClass
    maybe
      (setCurrentClass CLASS)
      (\sc -> setCurrentClass SUBCLASS >> resolveExpr sc >> beginScope >> setInScope "super" True)
      (superclass)
    beginScope
    setInScope "this" True
    mapM_ resolveMethod methods
    endScope
    maybe
      (endScope)
      (\_ -> endScope >> endScope)
      (superclass)
    setCurrentClass enclosingClass
  where
    resolveMethod :: Stmt -> Resolver ()
    resolveMethod m@(Function name' _ _) =
        if' (t_lexeme name' == "init")
            (resolveFunction m INITITIALIZER)
            (resolveFunction m METHOD)
    resolveMethod _ = undefined
    setCurrentClass :: ClassType -> Resolver ()
    setCurrentClass c = do
        st <- get
        put st { currentClass = c}

resolveStmt (Expression expr) =  resolveExpr expr

resolveStmt stmt@(Function name _ _) =
    declare name >> define name >> resolveFunction stmt FUNCTION

resolveStmt (If condition thenStmt elseStmt) =
    resolveExpr condition >> resolveStmt thenStmt >> maybe (return ()) (resolveStmt) (elseStmt)

resolveStmt (Print expr) = resolveExpr expr

resolveStmt (Return keyword value) =
  ifM (liftM ((==) FUN_NONE) (gets currentFunction))
      (resolverError keyword "Cannot return from top-level code.")
      (maybe
          (return ())
          (\valueExpr -> ifM (liftM ((==) INITITIALIZER) (gets currentFunction))
             (resolverError keyword "Cannot return a value from an initializer.")
             (resolveExpr valueExpr))
          (value))

resolveStmt (Var name initializer) =
    declare name >> maybe (return ()) (resolveExpr) (initializer) >> define name


resolveStmt (While condition body) = resolveExpr condition >> resolveStmt body

resolveFunction :: Stmt -> FunctionType -> Resolver ()
resolveFunction (Function _ parameters body) f_type = do
    enclosingFunction <- gets currentFunction
    setCurrentFunction f_type
    beginScope
    mapM_ (\p -> declare p >> define p) parameters
    resolveStmts body
    endScope
    setCurrentFunction enclosingFunction
  where
    setCurrentFunction :: FunctionType -> Resolver ()
    setCurrentFunction f = do
        st <- get
        put st { currentFunction = f}
resolveFunction _ _ = undefined

-- resolve Exprs

resolveExpr :: Expr -> Resolver ()
resolveExpr expr@(Assign name value) = resolveExpr value >> resolveLocal expr name
resolveExpr (Binary left _ right) = resolveExpr left >> resolveExpr right
resolveExpr (Call callee _ arguments) = resolveExpr callee >> mapM_ resolveExpr arguments
resolveExpr (Get object _) = resolveExpr object
resolveExpr (Grouping expression) = resolveExpr expression
resolveExpr (Literal _) = return ()
resolveExpr (Logical left _ right) = resolveExpr left >> resolveExpr right
resolveExpr (Set object _ value) = resolveExpr value >> resolveExpr object
resolveExpr expr@(Super keyword _) =
    ifM (liftM ((==) CLASS_NONE) (gets currentClass))
        (resolverError keyword "Cannot use 'super' outside of a class.")
        (ifM (liftM ((==) SUBCLASS) (gets currentClass))
            (resolverError keyword "Cannot use 'super' in a class with no superclass.")
            (resolveLocal expr keyword))

resolveExpr expr@(This keyword) =
    ifM (liftM ((==) CLASS_NONE) (gets currentClass))
        (resolverError keyword "Cannot use 'this' outside of a class.")
        (resolveLocal expr keyword)

resolveExpr (Unary _ right) = resolveExpr right
resolveExpr expr@(Variable name) =
    maybeM
     (return ())
     (\scope ->
         if' ( not $ maybe (True) (id) (Map.lookup (t_lexeme name) scope))
             (resolverError name "Cannot read local variable in its own inititalizer")
             (resolveLocal expr name))
     (liftM stackPeek $ gets scopes)

-- Resolver Utils

beginScope, endScope :: Resolver ()
beginScope = beginScope' Map.empty
endScope   = endScope' >> return ()

beginScope' :: Scope -> Resolver ()
beginScope' s = gets scopes >>= \scopes' -> putScopes (stackPush scopes' s)

endScope' :: Resolver Scope
endScope' =
    gets scopes >>= return . fromJust . stackPop >>= \(scopes', scope) -> putScopes scopes' >> return scope

putScopes :: Stack Scope -> Resolver ()
putScopes s = get >>= \st -> put st { scopes = s }

declare, define :: Token -> Resolver ()
declare name =
    maybeM
     (return ())
     (\scope ->
         if' (Map.member (t_lexeme name) scope)
             (resolverError name "Variable with this name already declared in this scope.")
             (setInScope (t_lexeme name) False))
     (liftM stackPeek $ gets scopes)

define name =
    maybeM
     (return ())
     (\_ -> setInScope (t_lexeme name) True)
     (liftM stackPeek $ gets scopes)

resolveLocal :: Expr -> Token -> Resolver ()
resolveLocal expr name =  resolveLocal' 0
  where
    resolveLocal' depth =
        maybeM
         (return ()) -- stack empty
         (\scope ->
             if' (Map.member (t_lexeme name) scope)
                 (interpreterResolve expr depth)
                 (do
                     cur <- endScope'
                     resolveLocal' (depth + 1)
                     beginScope' cur))
         (liftM stackPeek $ gets scopes)
    -- This is part of the Interpreter in the Java implementation. Its called 'resolve' there
    interpreterResolve :: Expr -> Int -> Resolver ()
    interpreterResolve exp' depth = do
        st <- get
        let
        put $ st {interpreterState = insertLocals (interpreterState st) exp' depth}
    insertLocals :: InterpreterState -> Expr -> Int -> InterpreterState
    insertLocals (InterpreterState e l) expr' depth = InterpreterState e (Map.insert expr' depth l)


setInScope :: String -> Bool -> Resolver ()
setInScope name val = do
    st <- get
    let (scopes', scope) = (fromJust . stackPop) (scopes st)
    let scope' = Map.insert name val scope
    put $ st { scopes = stackPush scopes' scope'}

resolverError :: Token -> String -> Resolver ()
resolverError token msg = throwError $ ResolverError token msg