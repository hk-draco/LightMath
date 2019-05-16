module Test where
import Data.Char
import Data.List
import Data.Maybe
import Control.Monad.State
import Parse
import Engine

props = extractMaybe $maybe [] (map toProp) (fst declas)
(stepRule, implRule, simpList) = makeRuleMap props

tokenizeTest line = intercalate "," $ map show $ tokenize line
parserTest x = show . runState x . tokenize

simplifyTest:: String -> String
simplifyTest str = "out:" ++ out ++ "\n"
        -- ++ "out':" ++ out' ++ "\n"
        -- ++ "simp:" ++ show simp ++ "\n"
        -- ++ "expr':" ++ show expr' ++ "\n"
        -- ++ "expr'':"  ++ show expr'' ++ "\n"
        -- ++ "expr:" ++ show expr ++ "\n" 
        ++ "simpList:" ++ show simpList ++ "\n"
        ++ "stepRule:" ++ show stepRule ++ "\n"
        ++ "implRule:" ++ show implRule ++ "\n"
        -- ++ "declas:" ++ show declas ++ "\n" 
        -- ++ "props:" ++ show declas ++ "\n"
        -- ++ "rules:" ++ show (makeRules props) ++ "\n" 
        where
    expr' = evalState parseExpr (tokenize str)
    expr'' = fromMaybe (error "wrong expr") expr'
    expr = appSimp simpList expr''
    simp = simplify stepRule expr
    steps = reverse $ showSteps simp
    out = intercalate "\n=" (map showExpr steps)
    out' = intercalate "\n=" (map show steps)

unifyTest:: String -> String
unifyTest str = out where
    exprs = fromMaybe [] $ evalState (parseCommaSeparated parseExpr) $ tokenize str
    [a, b] = exprs
    out = show $ unify a b

a = unify (IdentExpr "a") (Rewrite (IdentExpr "", IdentExpr "") (IdentExpr "x") (IdentExpr "y"))

test x = forever $ getLine >>= (putStrLn . x)
-- testFunc = test $ parserTest parseVarDecs 
testFunc = test simplifyTest
