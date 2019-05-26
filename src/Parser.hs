module Parser where
import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Foldable as F
import qualified Data.Map as M
import Control.Monad
import Control.Monad.Writer
import Control.Monad.State
import Control.Arrow
import Control.Applicative
import Library
import Data

popToken:: Lexer (Maybe PosToken)
popToken = Lexer $ \(pos, all) -> case all of 
    [] -> ([], pos, [], Just $ PosToken pos EndToken)
    (x:xs)
        | isDigit x -> make (Number . read) isDigit
        | isIdentHead x -> make Ident isIdentBody
        | isOperator x -> make Operator isOperator
        | isSymbol x -> ([], nextChar pos, xs, Just $ PosToken pos $ toSymbol [x])
        | x == '"' -> make' Literal ('"' /=)
        | x == '#' -> let (t, rest) = span ('\n' /=) xs in ([], stepChar pos $ length t, rest, Nothing) 
        | x == '\'' -> make' toChar ('\'' /=)
        | x == '\n' -> ([], nextLine pos, xs, Nothing)
        | isSpace x -> ([], nextChar pos, xs, Nothing)
        | otherwise -> ([Message (StringIdent pos [x]) "wrong"], nextChar pos, xs, Nothing)
        where
        -- (token constructor, tail condition) -> (messages, position, rest string, token)
        make f g = ([], stepChar pos $ length t, rest, (Just . (PosToken pos) . f . (x:)) t) where (t, rest) = span g xs
        make' f g = case all of 
            [] -> ([Message (StringIdent pos [x]) "error"], pos, drop 1 rest, Nothing)
            _ -> ([], pos, drop 1 rest, Just $ PosToken pos (f all)) 
            where 
            pos = stepChar pos $ length t
            (t, rest) = span g xs
        make'' f g = case all of
            [] -> ([Message (StringIdent pos [x]) "error"], pos, drop 1 rest, Nothing)
            (x:xs) -> ([Message (StringIdent pos [x]) "error"], pos, drop 1 rest, Nothing)
            where
            pos = stepChar pos $ length t
            (t, rest) = span g xs
    where
    -- Char -> Bool
    [isIdentSymbol, isOperator, isSymbol] = map (flip elem) ["_'" , "+-*/\\<>|?=@^$~`.&%", "(){}[],:"]
    [isIdentHead, isIdentBody] = map any [[isLetter, ('_' ==)], [isLetter, isDigit, isIdentSymbol]]
        where any = F.foldr ((<*>) . (<$>) (||)) $ const False
    -- String -> Token
    toChar all = case all of [x] -> LiteralOne x; 
    toSymbol all = case all of "(" -> ParenOpen; ")" -> ParenClose; "," -> Comma; _ -> Symbol all

-- string to tokens
tokenize:: Lexer [PosToken]
tokenize = do
    mtoken <- popToken
    case mtoken of
        Just token@(PosToken _ EndToken) -> return []
        Just token -> do
            rest <- tokenize
            return $ token:rest
        Nothing -> tokenize

-- parse expression by shunting yard algorithm
parseExpr:: OpeMap -> Parser (Maybe Expr)
parseExpr omap = Parser $ \ts-> parseExpr ts [] [] where
    -- (input tokens, operation stack, expression queue) -> (expression, rest token)
    parseExpr:: [PosToken] -> [(PosToken, Int)] -> [Expr] -> ([Message], [PosToken], Maybe Expr)
    parseExpr [] s q = ([], [], Just $ head $ makeExpr s q)
    parseExpr all@(px@(PosToken pos x):xs) s q = case x of
        Number n    -> maybeEnd $ parseExpr xs s (NumberExpr pos n:q)
        Ident id    -> maybeEnd $ case xs of
            (po@(PosToken _ ParenOpen):xs')-> parseExpr xs' ((po, 2):(px, 1):s) q
            _-> parseExpr xs s (IdentExpr (StringIdent pos id):q)
        ParenOpen   -> maybeEnd $ parseExpr xs ((px, 2):(tuple, 1):s) q -- 2 args for end condition
        ParenClose  -> maybeEnd $ parseExpr xs rest $ makeExpr opes q where
            (opes, _:rest) = span ((not <$> isParenOpen) . fst) s
        Comma       -> maybeEnd $ parseExpr xs rest $ makeExpr opes q where
            isIdent = \case PosToken _ (Ident _) -> True; _ -> False
            incrementArg = apply (isIdent . fst) (fmap (1+))
            (opes, rest) = incrementArg <$> span ((not <$> isParenOpen) . fst) s
        Operator ope -> parseExpr xs ((px, narg):rest) $ makeExpr opes q where
            (msg, (narg, preceed, lassoc)) = getOpe $ StringIdent pos ope
            (opes, rest) = span (precederEq (preceed, lassoc) . fst) s
        Symbol{} -> result
        where
            isParenOpen = \case PosToken _ ParenOpen -> True; _ -> False
            result = ([], all, Just $ head $ makeExpr s q)
            maybeEnd a = if sum (map ((-1+) . snd) s) + 1 == length q then result else a
    tuple = PosToken NonePosition (Ident "tuple")
    -- ((operator or function token, argument number), input) -> output
    makeExpr:: [(PosToken, Int)] -> [Expr] -> [Expr]
    makeExpr [] q = q
    makeExpr ((PosToken _ (Ident "tuple"), 1):os) q = makeExpr os q
    makeExpr ((PosToken pos t, n):os) q = makeExpr os $ FuncExpr (StringIdent pos $ showToken t) args:rest
        where (args, rest) = (reverse $ take n q, drop n q)
    -- apply 'f' to a element that satisfy 'cond' for the first time
    apply cond f all = case b of [] -> all; (x:xs) -> a ++ f x:xs
        where (a, b) = span (not <$> cond) all
    -- String -> (preceed, left associative)
    defaultOpe = (-1, 2, True)
    getOpe:: Ident -> ([Message], (Int, Int, Bool))
    getOpe x@(StringIdent pos id) = maybe ([Message x "Not defined infix"], defaultOpe) ([], ) (M.lookup id omap)
    precederEq:: (Int, Bool) -> PosToken -> Bool
    precederEq _ (PosToken _ ParenOpen) = False
    precederEq _ (PosToken _ (Ident _)) = True
    precederEq (apre, aleft) (PosToken _ (Operator t)) = aleft && ((bleft && apre <= bpre) || apre < bpre)
        where (_, bpre, bleft) = fromMaybe defaultOpe $ M.lookup t omap

-- atom parsers
parseToken:: Token -> Parser (Maybe Token)
parseToken x = Parser $ \case
    [] -> ([], [], Nothing)
    all@((PosToken _ t):ts) -> if t == x then ([], ts, Just x) else ([], all, Nothing)
parseSymbol x = parseToken (Symbol x)
parseOperator x = parseToken (Operator x)

parseAnyOperator:: Parser (Maybe Ident)
parseAnyOperator = Parser $ \case
    [] -> ([], [], Nothing)
    (PosToken pos (Operator str):ts) -> ([], ts, Just $ StringIdent pos str)
    all -> ([], all, Nothing)

parseNumber:: Parser (Maybe Int)
parseNumber = Parser $ \case
    [] -> ([], [], Nothing)
    all@(PosToken _ t:ts) -> case t of Number n-> ([], ts, Just n); _-> ([], all, Nothing)

parseIdent:: Parser (Maybe Ident)
parseIdent = Parser $ \case
    [] -> ([], [], Nothing)
    (PosToken _ (Ident "operator"):PosToken pos (Operator str):ts) -> ([], ts, Just $ StringIdent pos str)
    (PosToken pos (Ident str):ts) -> ([], ts, Just $ StringIdent pos str)
    all -> ([], all, Nothing)

parseSeparated:: Parser (Maybe s) -> Parser (Maybe a) -> Parser [a]
parseSeparated s p = p >>= \case
    Just x' -> s >>= \case
        Just _ -> parseSeparated s p >>= \r' -> return (x':r')
        Nothing -> return [x']
    Nothing -> return []

-- parser connecters
infixl 1 <++>
(<++>):: Parser (Maybe (a->b)) -> Parser (Maybe a) -> Parser (Maybe b)
former <++> latter = former >>= \case
    Just f -> latter >>= \case
            Just x -> return $ Just (f x)
            Nothing -> return Nothing
    Nothing -> return Nothing

infixl 1 <&&>
(<&&>):: Parser (Maybe (a->b)) -> Parser a -> Parser (Maybe b)
former <&&> latter = former >>= \case
    Just f -> latter >>= return . Just . f
    Nothing -> return Nothing

infixl 1 <::>
(<::>):: Parser (Maybe a) -> Parser (Maybe b) -> Parser (Maybe a)
former <::> latter = former >>= \case
    Just f -> latter >>= \case
            Just x -> return $ Just f
            Nothing -> return Nothing
    Nothing -> return Nothing

infixl 1 <!!>
(<!!>):: Parser (Maybe (Maybe a -> b)) -> Parser (Maybe a) -> Parser (Maybe b)
former <!!> latter = former >>= \case
    Just f -> latter >>= \case
            Just x -> return $ Just (f $ Just x)
            Nothing -> return $ Just (f Nothing)
    Nothing -> return Nothing

parseSequence:: Parser (Maybe a) -> Parser [a]
parseSequence p = p >>= \case
    Just x' -> parseSequence p >>= return . (x':)
    Nothing -> return $ []

parseCommaSeparated:: Parser (Maybe a) -> Parser [a]
parseCommaSeparated = parseSeparated $ parseToken Comma

parseVarDecSet:: OpeMap -> Parser (Maybe VarDecSet)
parseVarDecSet omap = return (Just VarDecSet) <&&> parseCommaSeparated parseIdent <::> parseSymbol ":" <++> parseExpr omap

-- [proof] = [command] [expr] [command] [expr]

-- [proof]
-- [command] assume [expr] {
--     being [expr]
--     [multi-proof]
-- }

-- [proof]
-- fork [proof]
-- fork [proof]

makeParser f = return $ Just ([], f)

parseMultiLineStm:: OpeMap -> Parser (Maybe Statement)
parseMultiLineStm omap = return (Just BlockStm) <&&> parseSequence (parseStatement omap)

parseStatement:: OpeMap -> Parser (Maybe Statement)
parseStatement omap = parseSymbol "{" >>= \case 
    Just{} -> parseBlock
    Nothing -> parseSingleStm
    where
    parseCmd = parseIdent >>= \case
        Just (StringIdent _ "step") -> return $ Just StepCmd
        Just (StringIdent _ "impl") -> return $ Just ImplCmd
        Just (StringIdent _ s) -> return $ Just $ WrongCmd s
        Nothing -> return Nothing
    parseBlock = return (Just BlockStm) <&&> parseSequence (parseStatement omap) <::> parseSymbol "}"
    parseSingleStm = parseCmd >>= \case
        Just cmd -> parseIdent >>= \case
            Just (StringIdent _ "assume") -> return (Just $ AssumeStm cmd)
                <++> parseExpr omap <::> parseSymbol "{"
                <::> parseToken (Ident "begin") <++> parseExpr omap 
                <++> parseMultiLineStm omap <::> parseSymbol "}"
            _ -> return (Just $ SingleStm cmd) <++> parseExpr omap
        Nothing -> return Nothing

parseVarDecs:: OpeMap -> Parser (Maybe VarDec)
parseVarDecs omap = fmap (Just . conv) parse
    where
    parse:: Parser [VarDecSet]
    parse = parseCommaSeparated $ parseVarDecSet omap
    conv:: [VarDecSet] -> VarDec
    conv = concatMap (uncurry zip) . (map toTuple)
    toTuple (VarDecSet ns t) = (ns, repeat t)
parseParenVarDecs omap = return (Just id) <::> parseToken ParenOpen <++> parseVarDecs omap <::> parseToken ParenClose
parseParenVarDecsSet omap = fmap Just $ parseSequence $ parseParenVarDecs omap

parseLatex:: OpeMap -> Parser (Maybe Expr)
parseLatex omap = return (Just id) <::> parseToken (Ident "proof") <::> parseSymbol "(" <++> parseExpr omap <::> parseSymbol ")"

parseDeclaBody:: OpeMap -> String -> Parser (Maybe Decla)
parseDeclaBody omap "axiom" = return (Just Axiom)
    <++> parseParenVarDecsSet omap
    <::> parseSymbol "{" <++> parseExpr omap <::> parseSymbol "}"
parseDeclaBody omap "theorem" = return (Just Theorem)
    <++> parseParenVarDecsSet omap
    <::> parseSymbol "{" 
    <++> parseExpr omap
    <::> parseToken (Ident "proof") <::> parseSymbol ":" <++> parseMultiLineStm omap
    <::> parseSymbol "}"
parseDeclaBody omap "define" = return (Just Define)
    <++> parseIdent
    <++> parseParenVarDecsSet omap
    <::> parseSymbol ":" <++> parseExpr omap
    <::> parseSymbol "{" <++> parseExpr omap <::> parseSymbol "}"
parseDeclaBody omap "predicate" = return (Just Predicate)
    <++> parseIdent
    <::> parseSymbol "[" <++> parseIdent <::> parseSymbol ":" <++> parseExpr omap<::> parseSymbol "]"
    <++> parseParenVarDecsSet omap
    <::> parseSymbol "{" <++> parseExpr omap <::> parseSymbol "}"
parseDeclaBody omap "data" = return (Just DataType)
    <++> parseIdent <::> parseOperator "=" <++> parseExpr omap
parseDeclaBody omap "undef" = return (Just Undef)
    <++> parseIdent <::> parseSymbol ":" <++> parseExpr omap <!!> parseLatex omap
parseDeclaBody omap "infixl" = return (Just (InfixDecla True 2))
    <++> parseNumber <++> parseAnyOperator
parseDeclaBody omap "infixr" = return (Just (InfixDecla False 2))
    <++> parseNumber <++> parseAnyOperator 
parseDeclaBody omap "unaryl" = return (Just (InfixDecla True 1))
    <++> parseNumber <++> parseAnyOperator
parseDeclaBody omap "unaryr" = return (Just (InfixDecla False 1))
    <++> parseNumber <++> parseAnyOperator
parseDeclaBody _ _ = return Nothing

parseDecla:: OpeMap -> Parser (Maybe Decla)
parseDecla omap = parseIdent >>= \case
    Just (StringIdent _ x)-> parseDeclaBody omap x
    Nothing -> return Nothing

parseProgram:: Parser ([Decla], OpeMap)
parseProgram = parseProgram' buildInOpe where
    buildInOpe = M.fromList [(">>=", (2, 0, True)), ("->", (2, 1, True)), ("|", (2, 2, True))]
    parseRest:: Decla -> OpeMap -> Parser ([Decla], OpeMap)
    parseRest x omap = parseProgram' omap >>= \(xs, omap')-> return (x:xs, omap')
    parseProgram':: OpeMap -> Parser ([Decla], OpeMap)
    parseProgram' omap = parseDecla omap >>= \case
        Just x@(InfixDecla leftAssoc narg pre (StringIdent _ s)) -> parseRest x $ M.insert s (narg, pre, leftAssoc) omap
        Just x -> parseRest x omap
        Nothing -> return ([], omap)