{-# LANGUAGE FlexibleContexts #-}

-- | Resource analysis
module Synquid.Solver.Resource (
  -- checkResources,
  solveResourceConstraints,
  isResourceConstraint,
  simplifyRCs,
  allRMeasures,
  partitionType,
  getAnnotationStyle,
  getPolynomialDomain,
  replaceCons
) where

import Synquid.Logic
import Synquid.Type hiding (set)
import Synquid.Program
import Synquid.Solver.Monad
import Synquid.Pretty
import Synquid.Solver.CEGIS
import Synquid.Solver.Types
import Synquid.Synthesis.Util hiding (writeLog)
import Synquid.Solver.CVC4

import           Data.Maybe
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.List (tails)
import           Control.Monad.Logic
import           Control.Monad.Reader
import           Control.Lens
import           Debug.Trace
import           Data.List.NonEmpty (NonEmpty(..))
import           Data.Semigroup (sconcat)


-- | Process, but do not solve, a set of resource constraints
simplifyRCs :: (MonadHorn s, MonadSMT s, RMonad s)
            => [Constraint]
            -> TCSolver s ()
simplifyRCs [] = return ()
simplifyRCs constraints = do
  rcs <- mapM generateFormula (filter isResourceConstraint constraints)
  resourceConstraints %= (++ rcs)

-- | 'solveResourceConstraints' @accConstraints constraints@ : Transform @constraints@ into logical constraints and attempt to solve the complete system by conjoining with @accConstraints@
solveResourceConstraints :: (MonadHorn s, RMonad s)
                         => [ProcessedRFormula]
                         -> [Constraint]
                         -> TCSolver s (Maybe [ProcessedRFormula])
solveResourceConstraints _ [] = return $ Just []
solveResourceConstraints oldConstraints constraints = do
    writeLog 3 $ linebreak <> text "Generating resource constraints:"
    -- Check satisfiability
    constraintList <- mapM generateFormula constraints
    b <- satisfyResources oldConstraints constraintList
    let result = if b then "SAT" else "UNSAT"
    writeLog 7 $ nest 4 $ text "Accumulated resource constraints:"
      $+$ pretty (map bodyFml oldConstraints)
    writeLog 8 $ nest 4 $ text "Solved resource constraint after conjoining formulas:"
      <+> text result $+$ prettyConjuncts (map bodyFml constraintList)
    return $ if b
      then Just constraintList -- $ Just $ if hasUniversals
      else Nothing

-- | 'generateFormula' @c@: convert constraint @c@ into a logical formula
--    If there are no universal quantifiers, we can cache the generated formulas
--    Otherwise, we must re-generate every time
generateFormula :: (MonadHorn s, RMonad s)
                => Constraint
                -> TCSolver s ProcessedRFormula
generateFormula c = do
  checkMults <- view (resourceArgs . checkMultiplicities) 
  generateFormula' checkMults c

generateFormula' :: (MonadHorn s, RMonad s)
                 => Bool
                 -> Constraint
                 -> TCSolver s ProcessedRFormula
generateFormula' checkMults c = do
  writeLog 4 $ indent 2 $ simplePrettyConstraint c <+> operator "~>"
  let mkRForm = RFormula Set.empty Set.empty Set.empty
  let freeParams = deBrujnOrVee 3  -- TODO: better solution. 3 is arbitrary.
  case c of
    Subtype{} -> error $ show $ text "generateFormula: subtype constraint present:" <+> pretty c
    WellFormed{} -> error $ show $ text "generateFormula: well-formedness constraint present:" <+> pretty c
    RSubtype env pl pr -> do
      op <- subtypeOp
      substs1 <- freshenFormula env freeParams pl
      substs2 <- freshenFormula env freeParams pr
      let substs = Map.union substs1 substs2
      let fml = mkRForm substs $ pl `op` pr
      embedAndProcessConstraint env fml 
    SharedForm env f fl fr -> do
      let sharingFml = f |=| (fl |+| fr)
      let wf = conjunction [f |>=| fzero, fl |>=| fzero, fr |>=| fzero]
      substs <- renameValueVar env
      let fml = mkRForm substs (wf |&| sharingFml)
      embedAndProcessConstraint env fml
    ConstantRes env -> do
      substs <- renameValueVar env
      f <- assertZeroPotential env 
      let fml = mkRForm substs f
      embedAndProcessConstraint env fml
    Transfer env env' -> do
      substs <- renameValueVar env
      fmls <- redistribute env env' 
      let fml = mkRForm substs $ conjunction fmls
      embedAndProcessConstraint env fml
    _ -> error $ show $ text "Constraint not relevant for resource analysis:" <+> pretty c


-- Constraint pre-processing pipeline
embedAndProcessConstraint :: (MonadHorn s, RMonad s)
                          => Environment
                          -> RawRFormula
                          -> TCSolver s ProcessedRFormula
embedAndProcessConstraint env rfml = do
  hasUnivs <- isJust <$> asks _cegisDomain
  let go = embedConstraint env
       >=> replaceAbstractPotentials
       >=> instantiateUnknowns
       >=> instantiateAxioms env
       >=> elaborateAssumptions
       >=> updateVariables
       >=> formatVariables
       >=> applyAssumptions
  if hasUnivs
    then go rfml
    else translateAndFinalize rfml
    {- else return $ rfml {
      _knownAssumptions = (),
      _unknownAssumptions = ()
    } -}

translateAndFinalize :: (MonadHorn s, RMonad s) => RawRFormula -> TCSolver s ProcessedRFormula 
translateAndFinalize rfml = do 
  writeLog 3 $ indent 4 $ pretty (bodyFml rfml)
  z3lit <- lift . lift . lift $ translate $ bodyFml rfml
  return $ rfml {
    _knownAssumptions = ftrue,
    _unknownAssumptions = (),
    _rconstraints = z3lit
  }


-- Embed context and generate constructor axioms
embedConstraint :: (MonadHorn s, RMonad s)
                => Environment
                -> RawRFormula
                -> TCSolver s RawRFormula
embedConstraint env rfml = do 
  useMeasures <- maybe False shouldUseMeasures <$> asks _cegisDomain
  -- Get assumptions related to all non-ghost scalar variables in context
  vars <- use universalVars
  -- Small hack -- need to ensure we grab the assumptions related to _v
  -- Note that sorts DO NOT matter here -- the embedder will ignore them.
  let vars' = Set.insert (Var AnyS valueVarName) $ Set.map (Var AnyS) vars
  ass <- embedSynthesisEnv env (conjunction vars') True useMeasures
  -- Split embedding into known/unknown parts
  let emb = Set.filter (not . isUnknownForm) ass
  let unk = Set.filter isUnknownForm ass
  return $ over knownAssumptions (Set.union emb) 
         $ over unknownAssumptions (Set.union unk) rfml

-- Replace predicate applications with variables
replaceAbstractPotentials :: MonadHorn s => RawRFormula -> TCSolver s RawRFormula
replaceAbstractPotentials rfml = do
  rvs <- use resourceVars 
  let fml' = replaceAbsPreds rvs $ _rconstraints rfml
  return $ set rconstraints fml' rfml

replaceAbsPreds :: Map String [Formula] -> Formula -> Formula
replaceAbsPreds rvs p@(Pred s x fs) =
  case Map.lookup x rvs of
    Nothing -> p
    Just _  -> Var s x
replaceAbsPreds rvs (WithSubst s e) = WithSubst s $ replaceAbsPreds rvs e
replaceAbsPreds rvs (Unary op f) = Unary op $ replaceAbsPreds rvs f
replaceAbsPreds rvs (Binary op f g) = Binary op (replaceAbsPreds rvs f) (replaceAbsPreds rvs g)
replaceAbsPreds rvs (Ite g t f) = Ite (replaceAbsPreds rvs g) (replaceAbsPreds rvs t) (replaceAbsPreds rvs f)
replaceAbsPreds rvs (All _ _) = error "replaceAbsPreds: found forall you should handle that"
replaceAbsPreds _ f = f

-- Use strongest possible assignment to unknown assumptions
instantiateUnknowns :: MonadHorn s => RawRFormula -> TCSolver s RawRFormula
instantiateUnknowns rfml = do 
  unknown' <- assignUnknowns (_unknownAssumptions rfml)
  fml' <- assignUnknownsInFml (_rconstraints rfml)
  return $ set unknownAssumptions Set.empty
         $ set rconstraints fml'
         $ over knownAssumptions (Set.union unknown') rfml

-- Instantiate constructor axioms
instantiateAxioms :: MonadHorn s => Environment -> RawRFormula -> TCSolver s RawRFormula
instantiateAxioms env rfml = do 
  let known = _knownAssumptions rfml
  useMeasures <- maybe False shouldUseMeasures <$> asks _cegisDomain
  let axioms = if useMeasures
        then instantiateConsAxioms (env { _measureDefs = allRMeasures env } ) True Nothing (conjunction known)
        else Set.empty
  return $ over knownAssumptions (Set.union axioms) rfml


replaceCons f@Cons{} = mkFuncVar f
replaceCons f = f


-- Instantiate universally quantified expressions
-- Generate congruence axioms
elaborateAssumptions :: MonadHorn s => RawRFormula -> TCSolver s (RawRFormula, Set Formula)
elaborateAssumptions rfml = do 
  -- Instantiate universals
  res <- mapM instantiateForall $ Set.toList (_knownAssumptions rfml)
  let instantiatedEmb = map fst res
  -- Generate variables for predicate applications
  let bodyPreds = gatherPreds (_rconstraints rfml)
  -- Generate congruence axioms
  let allPreds = Set.unions $ bodyPreds : map snd res
  let congruenceAxioms = generateCongAxioms allPreds
  let completeEmb = Set.fromList $ congruenceAxioms ++ concat instantiatedEmb
  return (set knownAssumptions completeEmb rfml, allPreds)

-- apply variable substitutions
updateVariables :: MonadHorn s => (RawRFormula, Set Formula) -> TCSolver s RawRFormula
updateVariables (rfml, allPreds) = do
  -- substitute all universally quantified expressions in body, known, and allPreds  
  let substs = _varSubsts rfml
  cons <- use matchCases
  let format = Set.map (transformFml mkFuncVar . substitute substs)
  universalMeasures %= Set.union (Set.map (transformFml mkFuncVar) (Set.map (substitute substs) allPreds))
  return $ set renamedPreds (format (cons `Set.union` allPreds))
         $ over knownAssumptions (Set.map (substitute substs)) 
         $ over rconstraints (substitute substs) rfml

-- Turn predicate / constructor applications into variables 
formatVariables :: MonadHorn s => RawRFormula -> TCSolver s RawRFormula
formatVariables rfml = do 
  let update = Set.map (transformFml mkFuncVar)
  return $ over unknownAssumptions update 
         $ over knownAssumptions update 
         $ over rconstraints (transformFml mkFuncVar) rfml

-- Produce final formula
applyAssumptions :: MonadHorn s
                 => RawRFormula
                 -> TCSolver s ProcessedRFormula
applyAssumptions (RFormula known unknown preds substs fml) = do
  let ass = conjunction $ Set.union known unknown
  writeLog 3 $ indent 4 $ pretty (ass |=>| fml) -- conjunction (map lcToFml lcs))
  return $ RFormula ass () preds substs fml 


-- | Check the satisfiability of the generated resource constraints, instantiating universally
--     quantified expressions as necessary.
satisfyResources :: RMonad s
                 => [ProcessedRFormula]
                 -> [ProcessedRFormula]
                 -> TCSolver s Bool
satisfyResources oldfmls newfmls = do
  let rfmls = oldfmls ++ newfmls
  let runInSolver = lift . lift . lift
  noUnivs <- isNothing <$> asks _cegisDomain
  if noUnivs
    then do
      let fml = conjunction $ map bodyFml rfmls
      model <- runInSolver $ solveAndGetModel fml
      case model of
        Nothing -> return False
        Just m' -> do
          writeLog 6 $ nest 2 (text "Solved with model") </> nest 6 (text (snd m'))
          return True
    else do
      solver <- view (resourceArgs . rsolver)
      deployHigherOrderSolver solver oldfmls newfmls 

deployHigherOrderSolver :: RMonad s
                        => ResourceSolver
                        -> [ProcessedRFormula] 
                        -> [ProcessedRFormula]
                        -> TCSolver s Bool
-- Solve with synthesizer
deployHigherOrderSolver CVC4 oldfmls newfmls = do
  let rfmls = oldfmls ++ newfmls
  -- check that there are no measures in problem domain
  dom <- fromJust <$> asks _cegisDomain
  case dom of
    Variable -> do
      let runInSolver = lift . lift . lift
      log <- view (resourceArgs . sygusLog)
      ufmls <- map (Var IntS) . Set.toList <$> use universalVars
      universals <- collectUniversals rfmls ufmls
      rvs <- use resourceVars
      env <- use initEnv 
      runInSolver $ solveWithCVC4 log env rvs rfmls universals
    _ -> error "Cannot use CVC4 to solve resource constraints involving measures"  

-- Solve with CEGIS (incremental or not)
deployHigherOrderSolver _ oldfmls newfmls = do
  let rfmls = oldfmls ++ newfmls
  let runInSolver = lift . lift . lift
  ufmls <- map (Var IntS) . Set.toList <$> use universalVars
  universals <- collectUniversals rfmls ufmls
  cMax <- view (resourceArgs . cegisBound) 
  cstate <- updateCEGISState

  writeLog 3 $ text "Solving resource constraint with CEGIS:"
  writeLog 5 $ pretty $ conjunction $ map completeFml rfmls
  logUniversals
  
  let go = solveWithCEGIS cMax rfmls universals
  (sat, cstate') <- runInSolver $ runCEGIS go cstate
  storeCEGISState cstate'
  return sat


storeCEGISState :: Monad s => CEGISState -> TCSolver s ()
storeCEGISState st = do 
  cegisState .= st
  let isIncremental s = 
        case s of
          Incremental -> True
          _           -> False
  incremental <- isIncremental <$> view (resourceArgs . rsolver) 
  -- For non-incremental solving, don't reset resourceVars
  when incremental $
    resourceVars .= Map.empty

-- Given a list of resource constraints, assemble the relevant universally quantified 
--   expressions for the CEGIS solver: renamed variables, constructor and measure applications
-- collectUniversals :: Monad s => [ProcessedRFormula] -> TCSolver s Universals
-- collectUniversals rfmls = do 
--   let preds = map (\(Var s x) -> (x, Var s x)) (collectUFs rfmls) 
--   return $ Universals (formatUniversals (collectVars rfmls)) preds

-- A different version of collectUniversals. 
--  Allows a list of extra formulas
collectUniversals :: Monad s => [ProcessedRFormula] -> [Formula] -> TCSolver s Universals
collectUniversals rfmls extra = do 
  let preds = map (\(Var s x) -> (x, Var s x)) (collectUFs rfmls) 
  return $ Universals (formatUniversals (extra ++ collectVars rfmls)) preds

collectVars :: [ProcessedRFormula] -> [Formula]
collectVars = concatMap (Map.elems . _varSubsts)

collectUFs :: [ProcessedRFormula] -> [Formula]
collectUFs = concatMap (Set.toList . _renamedPreds)

shouldUseMeasures :: AnnotationDomain -> Bool
shouldUseMeasures ad = case ad of
    Variable -> False
    _ -> True

-- Nondeterministically redistribute top-level potentials between variables in context
redistribute :: Monad s
             => Environment
             -> Environment
             -- -> TCSolver s (PendingRSubst, [Formula])
             -> TCSolver s [Formula]
redistribute envIn envOut = do
  let fpIn  = envIn ^. freePotential
  let fpOut = envOut ^. freePotential
  let cfpIn  = totalConditionalFP envIn
  let cfpOut = totalConditionalFP envOut
  let wellFormedFP = fmap (|>=| fzero) [fpIn, fpOut, cfpIn, cfpOut]
  -- Sum of top-level potential annotations
  let envSum = sumFormulas . allPotentials
  -- Assert that all potentials are well-formed
  let wellFormed env = map (|>=| fzero) (Map.elems (allPotentials env))
  -- Assert (fresh) potentials in output context are well-formed
  let wellFormedAssertions = wellFormedFP ++ wellFormed envOut
  --Assert that top-level potentials are re-partitioned
  let transferAssertions = (envSum envIn |+| fpIn |+| cfpIn) |=| (envSum envOut |+| fpOut |+| cfpOut)
  return $ transferAssertions : wellFormedAssertions

-- Assert that a context contains zero "free" potential
assertZeroPotential :: Monad s
                    => Environment
                    -- -> TCSolver s (PendingRSubst, Formula)
                    -> TCSolver s Formula
assertZeroPotential env = do
  let envSum = sumFormulas . allPotentials 
  let fml = ((env ^. freePotential) |+| envSum env) |=| fzero
  return fml

-- collect all top level potentials in context, wrapping them in an appropriate pending substitution
allPotentials :: Environment -> Map String Formula 
allPotentials env = Map.mapMaybeWithKey substTopPotential $ toMonotype <$> nonGhostScalars env
  where 
    substTopPotential x t = 
      let sub = Map.singleton valueVarName (Var (toSort (baseTypeOf t)) x) 
       in WithSubst sub . substitute sub <$> topPotentialOf t

-- Generate fresh version of _v
renameValueVar :: Monad s => Environment -> TCSolver s Substitution
renameValueVar env = do 
  let univs = Map.filterWithKey (\x _ -> x == valueVarName) $ symbolsOfArity 0 env
  Map.traverseWithKey freshen univs
  where 
    sortFrom = toSort . baseTypeOf . toMonotype
    freshen x sch = do 
      x' <- freshVersion x 
      return $ Var (sortFrom sch) x'


-- generate fresh value var if it's present
-- then traverse formula, generating de bruijns as needed (and passing upwards)
freshenFormula :: Monad s => Environment -> [String] -> Formula -> TCSolver s Substitution
freshenFormula env fList f = do
  subst <- renameValueVar env
  freshenFormula' fList subst f

freshenFormula' :: Monad s => [String] -> Substitution -> Formula -> TCSolver s Substitution -- APs
freshenFormula' fList subst (Var sort id) 
  | id `elem` fList = do
      var' <- Var sort <$> freshVersion id
      return $ Map.insertWith (\_ x -> x) id var' subst
  | otherwise = return subst
freshenFormula' fList subst (Unary _ fml) =
  freshenFormula' fList subst fml
freshenFormula' fList subst (Binary _ fml1 fml2) =
  Map.union <$> freshenFormula' fList subst fml1 <*> freshenFormula' fList subst fml2
freshenFormula' fList subst (Ite i t e) =
  Map.union <$> (Map.union <$> freshenFormula' fList subst i <*> 
    freshenFormula' fList subst t) <*> freshenFormula' fList subst e
freshenFormula' fList subst (Pred _ _ fmls) = 
  Map.unions <$> mapM (freshenFormula' fList subst) fmls
freshenFormula' fList subst (Cons _ _ fmls) = 
  Map.unions <$> mapM (freshenFormula' fList subst) fmls
freshenFormula' _ subst x = return subst

deBrujnOrVee :: Int -> [String]
deBrujnOrVee n = valueVarName : take n deBrujns


-- Generate sharing constraints, given a type and the two types
--   into which it is shared
partitionType :: Bool
              -> Environment
              -> (Maybe String, RType)
              -> RType
              -> RType
              -> [Constraint]
partitionType cm env (x, t@(ScalarT b _ f)) (ScalarT bl _ _) (ScalarT br _ _) 
  | f == fzero = partitionBase cm env (x, b) bl br
partitionType cm env (x, t@(ScalarT b _ f)) (ScalarT bl _ fl) (ScalarT br _ fr)
  = let env' = 
          case x of 
            Nothing -> addVariable valueVarName t env  
            Just n  -> addVariable valueVarName (addRefinement t (varRefinement n (toSort b))) env
    in SharedForm env' f fl fr : partitionBase cm env (x, b) bl br

partitionBase cm env (x, DatatypeT _ ts _) (DatatypeT _ tsl _) (DatatypeT _ tsr _)
  = concat $ zipWith3 (partitionType cm env) (zip (repeat Nothing) ts) tsl tsr
partitionBase cm env (x, b@(TypeVarT _ a m)) (TypeVarT _ _ ml) (TypeVarT _ _ mr)
  = [SharedForm env m ml mr | cm]
partitionBase _ _ _ _ _ = []


-- Is given constraint relevant for resource analysis
isResourceConstraint :: Constraint -> Bool
isResourceConstraint (Subtype _ ScalarT{} ScalarT{} _) = False
isResourceConstraint RSubtype{}    = True
isResourceConstraint WellFormed{}  = False
isResourceConstraint SharedEnv{}   = False -- should never be present by now
isResourceConstraint SharedForm{}  = True
isResourceConstraint ConstantRes{} = True
isResourceConstraint Transfer{}    = True
isResourceConstraint _             = False

-- Instantiate universally quantified expression with all possible arguments in the
--   quantified position. Also generate congruence axioms.
-- POSSIBLE PROBLEM: this doesn't really recurse looking for arbitrary foralls
--   It will find them if top-level or nested below a single operation. This SHOULD
--   be ok for our current scenario...
-- The function returns a pair, the first element of which is a list of all formulas,
--   including new predicate applications, the second is a set of just the instantiated apps
instantiateForall :: Monad s => Formula -> TCSolver s ([Formula], Set Formula)
instantiateForall f@All{} = instantiateForall' f
instantiateForall f       = return ([f], gatherPreds f)

instantiateForall' (All f g) = instantiateForall' g
instantiateForall' f         = instantiatePred f

instantiatePred :: Monad s => Formula -> TCSolver s ([Formula], Set Formula)
instantiatePred fml@(Binary op p@(Pred s x args) axiom) = do
  env <- use initEnv
  case Map.lookup x (allRMeasures env) of
    Nothing -> error $ show $ text "instantiatePred: measure definition not found" <+> pretty p
    Just mdef -> do
      let substs = allValidCArgs env mdef p
      let allPreds = map (`substitute` p) substs
      let allFmls = map (`substitute` fml) substs
      return (allFmls, Set.fromList allPreds)

-- Replace predicate applications in formula f with appropriate variables,
--   collecting all such predicate applications present in f
gatherPreds :: Formula -> Set Formula
gatherPreds (Unary op f)    = gatherPreds f
gatherPreds (Binary op f g) = gatherPreds f `Set.union` gatherPreds g
gatherPreds (Ite g t f)     = Set.unions [gatherPreds g, gatherPreds t, gatherPreds f]
gatherPreds (All f g)       = gatherPreds g -- maybe should handle quantified fmls...
gatherPreds (SetLit s fs)   = Set.unions $ map gatherPreds fs
gatherPreds f@Pred{}        = Set.singleton f
gatherPreds f               = Set.empty

-- Generate all congruence axioms, given all instantiations of universally quantified
--   measure applications
generateCongAxioms :: Set Formula -> [Formula]
generateCongAxioms preds = concatMap assertCongruence $ Map.elems (groupPreds preds)
  where
    groupPreds = foldl (\pmap p@(Pred _ x _) -> Map.insertWith (++) x [p] pmap) Map.empty

-- Generate all congruence relations given a list of possible applications of
--   some measure
assertCongruence :: [Formula] -> [Formula]
assertCongruence allApps = map assertCongruence' (pairs allApps)
  where
    -- All pairs from a list
    pairs xs = [(x, y) | (x:ys) <- tails xs, y <- ys]

assertCongruence' (pl@(Pred _ ml largs), pr@(Pred _ mr rargs)) =
  conjunction (zipWith (|=|) largs rargs) |=>| (pl |=| pr)
assertCongruence' ms = error $ show $ text "assertCongruence: called with non-measure formulas:"
  <+> pretty ms

getAnnotationStyle :: Map String [Bool] -> [RSchema] -> Maybe AnnotationDomain 
getAnnotationStyle flagMap schemas =
  let get sch = getAnnotationStyle' flagMap (getPredParamsSch sch) (toMonotype sch)
   in case catMaybes (map get schemas) of
        [] -> Nothing
        (a:as) -> Just $ sconcat (a :| as) -- can probably skip the catmaybes? and combine semigroups?

getAnnotationStyle' flagMap predParams t =
  let rforms = conjunction $ allRFormulas flagMap t
      allVars = getVarNames t
  in case (hasVar allVars rforms, hasMeasure predParams rforms) of
      (True, True)  -> Just Both
      (False, True) -> Just Measure
      (True, _)     -> Just Variable
      _             -> Nothing

getPolynomialDomain :: Map String [Bool] -> RSchema -> Maybe AnnotationDomain
getPolynomialDomain flagMap sch = getPolynomialDomain' flagMap (getPredParamsSch sch) (toMonotype sch)

getPolynomialDomain' flagMap predParams t = 
  let rforms = conjunction $ allRFormulas flagMap t 
      allVars = getVarNames t
  in case (hasVarITE allVars rforms, hasMeasureITE predParams rforms) of 
      (True, True)  -> Just Both
      (False, True) -> Just Measure
      (True, _)     -> Just Variable
      _             -> Nothing

getPredParamsSch :: RSchema -> Set String
getPredParamsSch (ForallP (PredSig x _ _) s) = Set.insert x (getPredParamsSch s)
getPredParamsSch (ForallT _ s) = getPredParamsSch s 
getPredParamsSch (Monotype _) = Set.empty 

getVarNames :: RType -> Set String
getVarNames (FunctionT x argT resT _) = 
  Set.insert x $ Set.union (getVarNames argT) (getVarNames resT)
getVarNames _ = Set.empty

subtypeOp :: Monad s => TCSolver s (Formula -> Formula -> Formula)
subtypeOp = do
  ct <- view (resourceArgs . constantTime)
  return $ if ct then (|=|) else (|>=|)

logUniversals :: Monad s => TCSolver s ()
logUniversals = do 
  uvars <- Set.toList <$> use universalVars
  ufuns <- Set.toList <$> use universalMeasures
  capps <- Set.toList <$> use matchCases
  writeLog 3 $ indent 2 $ text "Over universally quantified variables:"
    <+> hsep (map pretty uvars) <+> text "and functions:"
    <+> hsep (map pretty (ufuns ++ capps))

writeLog level msg = do
  maxLevel <- asks _tcSolverLogLevel
  when (level <= maxLevel) $ traceShow (plain msg) $ return ()
