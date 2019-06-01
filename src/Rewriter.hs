module Rewriter where
import Data.Char
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Map as M
import Control.Monad
import Control.Monad.Writer
import Control.Monad.State
import Control.Arrow
import Control.Applicative
import Library
import Data

instance Eq Fom where
    a@FunFom{} == b@FunFom{} = sameAttr && case (funAttr a, funAttr b) of
            (ACFun{}, _) -> equalACFun a b
            (_, ACFun{}) -> equalACFun a b
            _ -> funArgs a == funArgs b
        where
        sameAttr:: Bool
        sameAttr = funName a == funName b && funType a == funType b
        equalACFun:: Fom -> Fom -> Bool
        equalACFun a b = equalArgSet (funArgs a) (funArgs b) where
        equalArgSet:: [Fom] -> [Fom] -> Bool
        equalArgSet xs ys = length xs == length ys && equalArgSet xs ys where
            equalArgSet:: [Fom] -> [Fom] -> Bool
            equalArgSet [] [] = True
            equalArgSet (x:xs) ys = maybe False (equalArgSet xs) $ equalRest x ys []
        equalRest:: Fom -> [Fom] -> [Fom] -> Maybe [Fom]
        equalRest x [] _ = Nothing
        equalRest x (y:ys) rest = if x == y then Just $ ys ++ rest else equalRest x ys (y:rest)
    (PredFom vl ty) == (PredFom vl' ty') = vl == vl' && ty == ty'
    (FunTypeFom id args ret) == (FunTypeFom id' args' ret') = id == id' && args == args' && ret == ret'
    (CstFom a x) == (CstFom b y) = a == b && x == y
    (VarFom a x) == (VarFom b y) = a == b && x == y
    (StrFom a) == (StrFom b) = a == b
    (NumFom a) == (NumFom b) = a == b
    UnknownFom == UnknownFom = True
    TypeOfType == TypeOfType = True
    _ == _ = False

normalize:: Fom -> Fom
normalize = normalizeEx const

normalizeRewrite:: Fom -> Fom
normalizeRewrite = normalizeEx $ Rewrite SortReason

normalizeEx:: (Fom -> Fom -> Fom) -> Fom -> Fom
normalizeEx rewrite fun@FunFom{} = case funAttr fun of
    AFun -> nAssoc
    ACFun{} -> nAssoc
    _ -> fun{funArgs=map (normalizeEx rewrite) args}
    where
    nAssoc = if length args == length nArgs then fun else rewrite nFun fun
    args = funArgs fun
    nArgs = concatMap (extractArgs (idStr $ funName fun)) args
    nFun = fun{funArgs=map (normalizeEx rewrite . latestFom) nArgs}
normalizeEx _ fom = fom

(<||>):: (a -> Maybe a) -> (a -> Maybe a) -> (a -> Maybe a)
a <||> b = \m-> a m <|> b m

extractArgs:: String -> Fom -> [Fom]
extractArgs str fun@FunFom{} = if str == idStr (funName fun)
    then concatMap (extractArgs str) (funArgs fun)
    else [fun]
extractArgs str expr = [expr]

convert:: Fom -> Fom -> Analyzer Bool
convert from to = if from == to 
    then return True
    else do
        fromEnt <- lookupEnt (idStr $ showIdent from)
        toEnt <- lookupEnt (idStr $ showIdent to)
        fromMaybe (return False) $ cast to <$> fromEnt <*> toEnt
    where
    cast:: Fom -> Entity -> Entity -> Analyzer Bool
    cast trg from@PredEntity{} to@Entity{} = return $ predExtend from == trg
    cast trg from@Entity{} to@PredEntity{} = do
        rules <- lookupPredRules (predName to) (idStr $ showIdent trg)
        case unifyList predRuleTrg rules trg of
            Just (asg, rule) -> return True
            Nothing -> return False

unify:: Fom -> Fom -> Maybe AssignMap
unify ptn trg = unifyWithAsg ptn trg M.empty

unifyFun:: ([Fom] -> [Fom] -> AssignMap -> Maybe AssignMap) -> Fom -> Fom -> AssignMap -> Maybe AssignMap
unifyFun unifyArgs ptn trg = if funName ptn /= funName trg then const Nothing else \m-> do
    tyAsg <- unifyWithAsg (funType ptn) (funType trg) m
    vlAsg <- unifyArgs (funArgs ptn) (funArgs trg) tyAsg
    return $ M.union tyAsg vlAsg

unifyArgsOrder:: [Fom] -> [Fom] -> AssignMap -> Maybe AssignMap
unifyArgsOrder ptns args = if length ptns /= length args 
    then return Nothing
    else unifyArgs ptns args
    where
    unifyArgs:: [Fom] -> [Fom] -> AssignMap -> Maybe AssignMap
    unifyArgs (e:ex) (e':ex') = unifyWithAsg e e' >=> unifyArgs ex ex'
    unifyArgs [] [] = Just
    unifyArgs _ _ = const Nothing

unifyWithAsg:: Fom -> Fom -> AssignMap -> Maybe AssignMap
unifyWithAsg Rewrite{} _ = const $ error "Do not use Rewrite in a rule"
unifyWithAsg ptn trg@Rewrite{} = unifyWithAsg ptn $ rewLater trg
unifyWithAsg TypeOfType TypeOfType = Just
unifyWithAsg ptn@(CstFom id ty) trg@(CstFom id' ty') = if id == id' then unifyWithAsg ty ty' else const Nothing
unifyWithAsg ptn@NumFom{} trg = if ptn == trg then Just else const Nothing
unifyWithAsg ptn@StrFom{} trg = if ptn == trg then Just else const Nothing
unifyWithAsg (PredFom trgVl trgTy) (PredFom ptnVl ptnTy) = unifyWithAsg trgVl ptnVl >=> unifyWithAsg trgTy ptnTy
unifyWithAsg ptn@(VarFom id ty) trg = \m-> case M.lookup (idStr id) m of
    Just x -> if x == trg then Just m else Nothing
    Nothing -> Just $ M.insert (idStr id) (latestFom trg) m
unifyWithAsg ptn@FunFom{} trg@(FunFom OFun _ _ _) = unifyFun unifyArgsOrder ptn trg
unifyWithAsg ptn@FunFom{} trg@(FunFom AFun _ _ _) = unifyFun unifyArgsOrder ptn trg
unifyWithAsg ptn@FunFom{} trg@(FunFom CFun _ _ _) = unifyFun unifyArgs ptn trg where
    unifyArgs:: [Fom] -> [Fom] -> AssignMap -> Maybe AssignMap
    unifyArgs [a, b] [a', b'] = (unifyWithAsg a a' >=> unifyWithAsg b b') <||> (unifyWithAsg a b' >=> unifyWithAsg b a')
unifyWithAsg ptn@FunFom{} trg@(FunFom (ACFun _) _ _ _) = unifyFun unifyArgs ptn trg where
    unifyArgs:: [Fom] -> [Fom] -> AssignMap -> Maybe AssignMap
    unifyArgs [] [] = Just
    unifyArgs [] [rest] = Just . M.insert "_" rest
    unifyArgs [] rests = Just . M.insert "_" trg{funArgs=rests}
    unifyArgs (ptn:ptns) trgs = matchForPtn ptn ptns [] trgs
    matchForPtn:: Fom -> [Fom] -> [Fom] -> [Fom] -> AssignMap -> Maybe AssignMap
    matchForPtn ptn ptns noMatchTrgs [] = const Nothing
    matchForPtn ptn ptns noMatchTrgs (trg:restTrgs) = main <||> rest where
        main = unifyWithAsg ptn trg >=> unifyArgs ptns (noMatchTrgs ++ restTrgs)
        rest = matchForPtn ptn ptns (noMatchTrgs ++ [trg]) restTrgs
unifyWithAsg _ _ = const Nothing

unifyList:: (a -> Fom) -> [a] -> Fom -> Maybe (AssignMap, a)
unifyList f (x:xs) trg = case unify (f x) trg of
    Just asg -> Just (asg, x)
    Nothing -> unifyList f xs trg

assign:: AssignMap -> Fom -> Fom
assign m fom@(VarFom id ty) = fromMaybe fom $ M.lookup (idStr id) m
assign m fom@(FunFom (ACFun name) _ _ args@(x:xs)) = case M.lookup name m of
    Just rest -> fom{funArgs=[main, rest]}
    Nothing -> main
    where
    main = if null xs then assign m x else applyArgs (assign m) fom
assign m fom@FunFom{} = applyArgs (assign m) fom
assign m fom = fom

insertSimp:: Ident -> Fom -> Fom -> Analyzer ()
insertSimp id a b = case (funIdent a, funIdent b) of
    (Just fn, Just gn) -> insertSimpByName (idStr fn) (idStr gn)
    (Nothing, Just gn) -> analyzeError id "定数は関数よりも常に簡単なため、定数を左辺に使うことはできません"
    (Just fn, Nothing) -> updateList $ \list-> let f = idStr fn in if f `elem` list then list else f:list
    (Nothing, Nothing) -> analyzeError id "全ての定数は等しい簡略性を持つため、定数を両端に持つ命題は無効です"
    where
    funIdent:: Fom -> Maybe Ident
    funIdent fun@FunFom{} = Just $ funName fun
    funIdent _ = Nothing
    insertSimpByName:: String -> String -> Analyzer ()
    insertSimpByName f g = do
        m <- fmap conList getContext
        case (elemIndex f m, elemIndex g m) of
            (Just fi, Just gi) -> when (fi > gi) $ analyzeError id "すでに宣言された命題から推論した関数の簡略性によると、左辺の方が右辺よりも簡単です"
            (Just fi, Nothing) -> updateList $ insertAt g fi
            (Nothing, Just gi) -> updateList $ insertAt f (gi+1)
            (Nothing, Nothing) -> updateList $ \m-> if f == g then f:m else g:f:m
        where
        insertAt:: a -> Int -> [a] -> [a] 
        insertAt item idx xs = as ++ (item:bs) where (as, bs) = splitAt idx xs

simplify:: Fom -> Analyzer Fom
simplify fom = do
    simp <- fmap conSimp getContext
    list <- fmap conList getContext
    return $ simplifyStepLoop list simp fom

simplifyStepLoop:: Simplicity -> RuleMap -> Fom -> Fom
simplifyStepLoop simps m _fom = maybe _fom (simplifyStepLoop simps m) $ simplifyStep _fom where
    lookupHeads:: Fom -> [(String, Int)]
    lookupHeads rew@Rewrite{} = lookupHeads $ rewLater rew
    lookupHeads fun@FunFom{} = maybe rest (:rest) head where
            f = idStr $ funName fun
            head = elemIndex f simps >>= Just . (f, )
            rest = concatMap lookupHeads (funArgs fun)
    lookupHeads _ = []
    applyWithSimp:: [Rule] -> Int -> Fom -> Maybe Fom
    applyWithSimp rules simp rew@(Rewrite res trg old) = applyWithSimp rules simp trg >>= \case
        (Rewrite newRes new _)-> Just $ Rewrite newRes new rew -- rewrite whole
        new -> Just $ Rewrite res new old                      -- rewrite argument
    applyWithSimp rules simp fun@FunFom{} = if simp == fsimp then apply rules fun <|> rest else rest where
        fsimp = fromMaybe (-1) $ elemIndex (idStr $ funName fun) simps
        rest = normalizeRewrite <$> applyArgsOnce (applyWithSimp rules simp) fun
        apply:: [Rule] -> Fom -> Maybe Fom
        apply (rule:rules) trg = case unify (ruleBf rule) trg of
            Just asg -> Just $ Rewrite (NormalReason rule asg) (assign asg (ruleAf rule)) trg
            Nothing -> apply rules trg
        apply [] _ = Nothing
    applyWithSimp _ _ _ = Nothing
    applyByHeadList:: [(String, Int)] -> Fom -> Maybe Fom
    applyByHeadList [] _ = Nothing
    applyByHeadList ((f, s):xs) e = (M.lookup f m >>= \x-> applyWithSimp x s e) <|> applyByHeadList xs e
    simplifyStep:: Fom -> Maybe Fom
    simplifyStep e = applyByHeadList heads e where
        simpCompare (_, a) (_, b) = compare b a
        heads = sortBy simpCompare $ lookupHeads e

type Derivater = (Fom, Fom) -> Analyzer (Maybe Fom)

applyDiff:: Derivater -> (Fom, Fom) -> Analyzer (Maybe Fom)
applyDiff derivater pair@(bg@FunFom{}, gl@FunFom{}) = if funName bg == funName gl && length as == length bs
    then case num of
        0 -> return Nothing
        1 -> do
            let (xs', x:xs) = splitAt idx args
            res <- applyDiff derivater x
            return $ normalizeRewrite . (\t-> bg{funArgs=map snd xs' ++ t:map snd xs}) <$> res
        _ -> derivater pair
    else derivater pair where
        (as, bs) = (funArgs bg, funArgs gl)
        args = zip as bs
        matchArgs = fmap (uncurry (==)) args
        (idx, num) = encount False matchArgs
        -- (element, list) -> (index of the first encountered element, number of encounters)
        encount:: Eq a => a -> [a] -> (Int, Int)
        encount = encount' (-1, 0) where
            encount':: Eq a => (Int, Int) -> a -> [a] -> (Int, Int)
            encount' (i, n) e (x:xs) = encount' (if n > 0 then i else i + 1, if e == x then n + 1 else n) e xs
            encount' p _ [] = p
applyDiff derivater (a, b) = derivater (a, b)

derivate:: Derivater
derivate = applyDiff derivateByRuleList where
    derivateByRule:: Rule -> Derivater
    derivateByRule rule = applyDiff $ derivateByRule rule where
        derivateByRule:: Rule -> Derivater
        derivateByRule rule (begin, goal) = case unify (ruleBf rule) begin of
            Just asg -> return $ if assign asg (ruleAf rule) == goal
                then Just $ Rewrite (NormalReason rule asg) goal begin
                else Nothing
            Nothing -> return Nothing
    derivateByRuleList:: Derivater
    derivateByRuleList pair@(FunFom _ h ty as, goal) = do
        rmap <- fmap conImpl getContext
        let or a b = a >>= \x-> b >>= return . (<|>x)
        case M.lookup (idStr h) rmap of
            Just rules -> foldr (or . flip derivateByRule pair) (return Nothing) rules
            Nothing -> return Nothing
    derivateByRuleList _ = return Nothing

derivateExists:: Derivater
derivateExists = applyDiff derivateExists where
    contains:: Eq a => [a] -> [a] -> Bool
    contains [] _ = True
    contains (x:xs) set = x `elem` set && contains xs set
    derivateExists:: Derivater
    derivateExists (fom, var@(VarFom id varTy)) = do
        vmap <- fmap conVar getContext 
        case M.lookup (idStr id) vmap of
            (Just (Variable (Exists refs) ty)) -> if ty == varTy && contains ids refs 
                then return $ Just var
                else return Nothing
            _ -> return $ if fom == var then Just var else Nothing
        where
        ids = lookupVars fom
    derivateExists (_, goal) = return $ Just goal

derivateUnfold:: Derivater
derivateUnfold = applyDiff unfold where
    getMaybe (Just (Just x)) = Just x
    getMaybe _ = Nothing
    unfold:: Derivater
    unfold (bg@FunFom{}, gl) = do
        mEnt <- lookupEnt (idStr $ funName bg)
        case mEnt of
            Just ent -> do
                let asg = unify <$> entDef ent <*> Just gl
                maybe (return Nothing) (insertEntFromAsg ent) (getMaybe asg)
        where
        insertEntFromAsg:: Entity -> AssignMap -> Analyzer (Maybe Fom)
        insertEntFromAsg ent asg = do
            mapM_ addEnt (M.toList asg)
            return $ Just $ Rewrite (UnfoldReason ent asg) gl bg
        addEnt (str, VarFom id ty) = do
            mEnt <- lookupEnt (idStr id)
            maybe (insertEnt False id ty) (const $ return ()) mEnt
        addEnt _ = return ()
    unfold _ = return Nothing
-- (A & B & A | B & A & B) => P & Q, (A & B | A & B) => P & Q
mergeRewrite:: Fom -> Fom -> Maybe Fom
mergeRewrite = mergeRewrite Nothing where
    mergeRewrite:: Maybe (Reason, Fom, Reason) -> Fom -> Fom -> Maybe Fom
    mergeRewrite junction former@(Rewrite r a b) latter@(Rewrite r' a' b') = case mergeRewrite Nothing a a' of
        Just res -> if hasRewrite res then Just $ appendStep r' (Rewrite r res b) b' else mergeRewrite (Just (r, a, r')) b b'
        Nothing -> junction >>= \(jr, je, jr') -> Just $ appendStep jr' (Rewrite jr je former) latter 
    mergeRewrite _ former latter@(Rewrite r a b) = mergeRewrite Nothing former a >>= \x-> Just $ appendStep r x b
    mergeRewrite _ former@(Rewrite r a b) latter = mergeRewrite Nothing a latter >>= \x-> Just $ Rewrite r x b
    mergeRewrite _ funA@FunFom{} funB@FunFom{} = if funName funA == funName funB
        then (\x-> funA{funArgs=x}) <$> conjMaybe (zipWith (mergeRewrite Nothing) (funArgs funA) (funArgs funB))
        else Nothing
    mergeRewrite _ a b = if a == b then Just a else Nothing
    appendStep:: Reason -> Fom -> Fom -> Fom
    appendStep r' t (Rewrite r a b) = Rewrite r a (appendStep r' t b)
    appendStep r t u = Rewrite r u t
    hasRewrite:: Fom -> Bool
    hasRewrite Rewrite{} = True
    hasRewrite fun@FunFom{} = all hasRewrite $ funArgs fun
    hasRewrite _ = False

lookupVars:: Fom -> [Ident]
lookupVars fun@FunFom{} = concatMap lookupVars $ funArgs fun
lookupVars (VarFom id _) = [id]
lookupVars _ = []