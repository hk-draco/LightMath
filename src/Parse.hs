module Parse where
import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Foldable as F
import qualified Data.Map as M
import Control.Monad.Writer
import Control.Monad.State
import Control.Arrow
import Control.Applicative

data Position = Position Int Int | NonePosition deriving (Eq, Show)
data Token = EndLine | Ident String | Number Int 
    | Literal String | LiteralOne Char | Symbol String 
    | Comma | ParenOpen | ParenClose | Error String String deriving (Eq, Show)
data PosToken = PosToken Position Token deriving (Eq, Show)
data Message = Message PosStr String deriving (Show)
type PosStr = (Position, String)

tokenize:: String -> [PosToken]
tokenize = tokenize' $ Position 1 1 where
    tokenize' :: Position -> String -> [PosToken]
    tokenize' p [] = []
    tokenize' p all = let (x, xs, p') = getToken p all in maybe id (:) x (tokenize' p' xs) where
    getToken :: Position -> String -> (Maybe PosToken, String, Position)
    getToken p [] = (Nothing, [], p)
    getToken p (x:xs)
        | isDigit x = make (Number . read) isDigit
        | isIdentHead x = make Ident isIdentBody
        | isOperator x = make Symbol isOperator
        | isBracket x = (Just $ PosToken p $ toSymbol [x], xs, nextChar p)
        | x == '"' = make' Literal ('"' /=)
        | x == '#' = let (t, rest) = span ('\n' /=) xs in (Nothing, rest, addChar p $ length t) 
        | x == '\'' = make' toChar ('\'' /=)
        | x == '\n' = (Nothing, xs, nextLine p)
        | isSpace x = (Nothing, xs, nextChar p)
        | otherwise = (Just $ PosToken p $ Error [x] "wrong", xs, nextChar p)
        where
            appPos = PosToken p
            -- (token constructor, tail condition) -> (token, rest string, position)
            make f g = ((Just . appPos . f . (x:)) t, rest, addChar p $ length t) where (t, rest) = span g xs
            make' f g = (appPos <$> (h t), drop 1 rest, addChar p $ length t) where 
                (t, rest) = span g xs
                h all = Just $ case all of [] -> Error all "no"; _ -> f all
            -- Char -> Bool
            [isIdentSymbol, isOperator, isBracket] = map (flip elem) ["_'" , "+-*/\\<>|?=@^$:~`.&", "(){}[],"]
            [isIdentHead, isIdentBody] = map any [[isLetter, ('_' ==)], [isLetter, isDigit, isIdentSymbol]]
                where any = F.foldr ((<*>) . (<$>) (||)) $ const False
            -- String -> Token
            toChar all = case all of [x] -> LiteralOne x; [] -> Error all "too short"; (x:xs) -> Error all "too long"
            toSymbol all = case all of "(" -> ParenOpen; ")" -> ParenClose; "," -> Comma; _ -> Symbol all
            
            addChar (Position c l) n = Position (c+n) l
            nextChar (Position c l) = Position (c+1) l
            nextLine (Position c l) = Position c (l+1)

type Rule = (Expr, Expr)
type OpeMap = M.Map String (Int, Bool)
data ExprHead = ExprHead PosStr Int | PureExprHead PosStr deriving (Show, Eq)
data Expr = IdentExpr PosStr | FuncExpr ExprHead [Expr] 
        | StringExpr PosStr | NumberExpr Position Int | Rewrite Rule Expr Expr deriving (Show, Eq)

makePosStr s = (NonePosition, s)
makeExprHead = PureExprHead . makePosStr
makeIdentExpr = IdentExpr . makePosStr

getPosAndStr:: Expr -> PosStr
getPosAndStr (IdentExpr ps) = ps
getPosAndStr (StringExpr ps) = ps
getPosAndStr (NumberExpr p n) = (p, show n)
getPosAndStr (Rewrite _ a _) = getPosAndStr a
getPosAndStr (FuncExpr (ExprHead ps _) _) = ps
getPosAndStr (FuncExpr (PureExprHead ps) _) = ps

showToken:: Token -> String
showToken (Symbol s) = s
showToken (Ident s) = s

showHead:: ExprHead -> String
showHead (ExprHead (_, t) _) = t
showHead (PureExprHead (_, t)) = t
        
parseExpr:: OpeMap -> State [PosToken] (Maybe Expr)
parseExpr omap = state $ \ts-> parseExpr ts [] [] where
    -- (input tokens, operation stack, expression queue) -> (expression, rest token)
    parseExpr:: [PosToken] -> [(PosToken, Int)] -> [Expr] -> (Maybe Expr, [PosToken])
    parseExpr [] s q = (Just $ head $ makeExpr s q, [])
    parseExpr all@(px@(PosToken p x):xs) s q = case x of
        Error t m   -> (Nothing, all)
        Number n    -> maybeEnd $ parseExpr xs s (NumberExpr p n:q)
        Ident i     -> maybeEnd $ if xs /= [] && getToken (head xs) == ParenOpen
            then parseExpr xs ((px, 1):s) q
            else parseExpr xs s (IdentExpr (p, i):q)
        ParenOpen   -> maybeEnd $ parseExpr xs ((px, 2):s) q -- 2 args for end condition
        ParenClose  -> maybeEnd $ parseExpr xs rest $ makeExpr opes q where
            (opes, _:rest) = span ((not <$> isParenOpen) . fst) s
        Comma       -> maybeEnd $ parseExpr xs rest $ makeExpr opes q where
            isIdent = \case PosToken _ (Ident _) -> True; _ -> False
            incrementArg = apply (isIdent . fst) (fmap (1+))
            (opes, rest) = incrementArg <$> span ((not <$> isParenOpen) . fst) s
        Symbol ope  -> case getOpe ope of 
            Just _      -> parseExpr xs ((px, 2):rest) $ makeExpr opes q where
                (opes, rest) = span (precederEq ope . fst) s
            Nothing     -> result
        where
            isParenOpen = \case PosToken _ ParenOpen -> True; _ -> False
            result = (Just $ head $ makeExpr s q, all)
            maybeEnd a = if sum (map ((-1+) . snd) s) + 1 == length q then result else a
    -- ((operator or function token, argument number), input) -> output
    makeExpr:: [(PosToken, Int)] -> [Expr] -> [Expr]
    makeExpr [] q = q
    makeExpr ((PosToken p t, n):os) q = makeExpr os $ FuncExpr (PureExprHead (p, showToken t)) args:rest
        where (args, rest) = (reverse $ take n q, drop n q)
    getToken (PosToken _ t) = t
    -- apply 'f' to a element that satisfy 'cond' for the first time
    apply cond f all = case b of [] -> all; (x:xs) -> a ++ f x:xs
        where (a, b) = span (not <$> cond) all
    -- String -> (preceed, left associative)
    getOpe = flip M.lookup $ M.union buildInOpe omap
    buildInOpe = M.fromList [(">>=", (0, True)), ("->", (1, True)), ("|", (2, True))]
    precederEq:: String -> PosToken -> Bool
    precederEq s (PosToken _ ParenOpen) = False
    precederEq s (PosToken _ (Ident _)) = True
    precederEq s (PosToken _ (Symbol t)) = precederEq' $ map getOpe' [s, t] where
        precederEq' [(aPre, aLeft), (bPre, bLeft)] = bLeft && ((aLeft && aPre <= bPre) || aPre < bPre)
        getOpe' = fromMaybe (0, True) . getOpe

infixl 1 <++>
(<++>):: State [PosToken] (Maybe (a->b)) -> State [PosToken] (Maybe a) -> State [PosToken] (Maybe b)
f <++> a = f >>= maybe (return Nothing) (\f'-> fmap f' <$> a)

infixl 1 <::>
(<::>):: State [PosToken] (Maybe a) -> State [PosToken] (Maybe b) -> State [PosToken] (Maybe a)
f <::> a = f >>= maybe (return Nothing) (\f'-> maybe Nothing (const $ Just f') <$> a)

parseSequence:: State [PosToken] (Maybe a)-> State [PosToken] (Maybe [a])
parseSequence p = p >>= \case
    Just x' -> parseSequence p >>= \case
        Just s' -> return $ Just (x':s')
        Nothing -> return Nothing
    Nothing -> return $ Just []

parseToken:: Token -> State [PosToken] (Maybe Token)
parseToken x = state $ \case
    [] -> (Nothing, [])
    all@((PosToken _ t):ts) -> if t == x then (Just x, ts) else (Nothing, all)
parseSymbol x = parseToken (Symbol x)

parseAnySymbol:: State [PosToken] (Maybe PosStr)
parseAnySymbol = state $ \case
    [] -> (Nothing, [])
    (PosToken p (Symbol s):ts) -> (Just (p, s), ts)
    all -> (Nothing, all)

parseNumber:: State [PosToken] (Maybe Int)
parseNumber = state $ \case
    [] -> (Nothing, [])
    all@((PosToken _ t):ts) -> case t of Number n-> (Just n, ts); _-> (Nothing, all)

parseIdent:: State [PosToken] (Maybe PosStr)
parseIdent = state $ \case
    [] -> (Nothing, [])
    all@((PosToken p (Ident s)):ts) -> (Just (p, s), ts)
    all -> (Nothing, all)

parseSeparated:: State [PosToken] (Maybe s) -> State [PosToken] (Maybe a) -> State [PosToken] (Maybe [a]) 
parseSeparated s p = p >>= \case
    Just x' -> s >>= \case
        Just _ -> parseSeparated s p >>= \case
            Just r' -> return $ Just (x':r')
            Nothing -> return Nothing
        Nothing -> return $ Just [x']
    Nothing -> return $ Just []

parseCommaSeparated:: State [PosToken] (Maybe a) -> State [PosToken] (Maybe [a]) 
parseCommaSeparated = parseSeparated $ parseToken Comma

data VarDecSet = VarDecSet [PosStr] Expr deriving (Show)
parseVarDecSet:: OpeMap -> State [PosToken] (Maybe VarDecSet)
parseVarDecSet omap = return (Just VarDecSet) <++> parseCommaSeparated parseIdent <::> parseSymbol ":" <++> parseExpr omap

data Statement = StepStm Expr | ImplStm Expr | AssumeStm Expr [Statement] | BlockStm String Expr [Statement] deriving (Show)
parseStatement:: OpeMap -> State [PosToken] (Maybe Statement)
parseStatement omap = parseIdent >>= \case
    Just (_, "step") -> return (Just StepStm) <++> parseExpr omap
    Just (_, "impl") -> return (Just ImplStm) <++> parseExpr omap
    Just (_, "assume") -> return (Just AssumeStm) <++> parseExpr omap <++> parseBlock
    _ -> return Nothing 
    where parseBlock = return (Just id) <::> parseSymbol "{" <++> parseSequence (parseStatement omap) <::> parseSymbol "}"

type VarDec = [(PosStr, Expr)]
parseVarDecs:: OpeMap -> State [PosToken] (Maybe VarDec)
parseVarDecs omap = fmap conv parse where
    parse:: State [PosToken] (Maybe [VarDecSet])
    parse = parseCommaSeparated $ parseVarDecSet omap
    conv:: Maybe [VarDecSet] -> Maybe VarDec
    conv = Just . concatMap (uncurry zip) . maybe [] (map toTuple)
    toTuple (VarDecSet ns t) = (ns, repeat t)
parseParenVarDecs omap = return (Just id) <::> parseToken ParenOpen <++> parseVarDecs omap <::> parseToken ParenClose

data Decla = Axiom VarDec Expr | Theorem VarDec Expr [Statement] 
    | Define PosStr VarDec Expr Expr | Predicate PosStr PosStr Expr VarDec Expr
    | DataType PosStr Expr | Undef PosStr Expr
    | InfixDecla Bool PosStr Int PosStr deriving (Show)
parseDeclaBody:: OpeMap -> String -> State [PosToken] (Maybe Decla)
parseDeclaBody omap "axiom" = return (Just Axiom)
    <++> parseParenVarDecs omap
    <::> parseSymbol "{" <++> parseExpr omap <::> parseSymbol "}"
parseDeclaBody omap "theorem" = return (Just Theorem) 
    <++> parseParenVarDecs omap
    <::> parseSymbol "{" 
    <++> parseExpr omap
    <::> parseToken (Ident "proof") <::> parseSymbol ":" <++> parseSequence (parseStatement omap)
    <::> parseSymbol "}"
parseDeclaBody omap "define" = return (Just Define)
    <++> parseIdent
    <++> parseParenVarDecs omap
    <::> parseSymbol ":" <++> parseExpr omap
    <::> parseSymbol "{" <++> parseExpr omap <::> parseSymbol "}"
parseDeclaBody omap "predicate" = return (Just Predicate)
    <++> parseIdent
    <::> parseSymbol "[" <++> parseIdent <::> parseSymbol ":" <++> parseExpr omap<::> parseSymbol "]"
    <++> parseParenVarDecs omap
    <::> parseSymbol "{" <++> parseExpr omap <::> parseSymbol "}"
parseDeclaBody omap "data" = return (Just DataType)
    <++> parseIdent <::> parseSymbol "=" <++> parseExpr omap
parseDeclaBody omap "undef" = return (Just Undef)
    <++> parseIdent <::> parseSymbol ":" <++> parseExpr omap
parseDeclaBody omap "infixl" = return (Just $ InfixDecla True)
    <++> parseAnySymbol <++> parseNumber <::> parseSymbol "=>" <++> parseIdent
parseDeclaBody omap "infixr" = return (Just $ InfixDecla False)
    <++> parseAnySymbol <++> parseNumber <::> parseSymbol "=>" <++> parseIdent
parseDeclaBody _ _ = return Nothing

parseDecla:: OpeMap -> State [PosToken] (Maybe Decla)
parseDecla omap = parseIdent >>= \case (Just (_, x))-> parseDeclaBody omap x; _ -> return Nothing

parseProgram:: State [PosToken] ([Decla], OpeMap)
parseProgram = parseProgram' M.empty where
    parseRest:: Decla -> OpeMap -> State [PosToken] ([Decla], OpeMap)
    parseRest x omap = parseProgram' omap >>= \(xs, omap')-> return (x:xs, omap')
    parseProgram':: OpeMap -> State [PosToken] ([Decla], OpeMap)
    parseProgram' omap = parseDecla omap >>= \case
        Just x@(InfixDecla leftAssoc (_, s) pre fun) -> parseRest x $ M.insert s (pre, leftAssoc) omap
        Just x -> parseRest x omap
        Nothing -> return ([], omap)