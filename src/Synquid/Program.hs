{-# LANGUAGE TemplateHaskell #-}

-- | Executable programs
module Synquid.Program where

import Synquid.Logic
import Synquid.Util

import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Map as Map
import Data.Map (Map)
import Control.Monad
import Control.Lens

{- Type skeletons -}

data BaseType r = BoolT | IntT | DatatypeT Id [TypeSkeleton r] | TypeVarT Id
  deriving (Eq, Ord)
  
-- | Type skeletons (parametrized by refinements)
data TypeSkeleton r =
  ScalarT (BaseType r) r |
  FunctionT Id (TypeSkeleton r) (TypeSkeleton r)  
  deriving (Eq, Ord)
    
baseTypeOf (ScalarT baseT _) = baseT
baseTypeOf _ = error "baseTypeOf: applied to a function type"
isFunctionType (FunctionT _ _ _) = True
isFunctionType _ = False
argType (FunctionT _ t _) = t
resType (FunctionT _ _ t) = t
dontCare = "_"

toSort BoolT = BoolS
toSort IntT = IntS
toSort (DatatypeT name tArgs) = UninterpretedS name (map (toSort . baseTypeOf) tArgs)
toSort (TypeVarT name) = UninterpretedS name []

fromSort BoolS = ScalarT BoolT ftrue
fromSort IntS = ScalarT IntT ftrue
fromSort (UninterpretedS name []) = ScalarT (TypeVarT name) ftrue
fromSort (UninterpretedS name sArgs) = ScalarT (DatatypeT name (map fromSort sArgs)) ftrue

-- | 'complies' @s s'@: are @s@ and @s'@ the same modulo unknowns?
complies :: Sort -> Sort -> Bool  
complies UnknownS s = True  
complies s UnknownS = True
complies (SetS s) (SetS s') = complies s s'
complies (UninterpretedS name sArgs) (UninterpretedS name' sArgs') = name == name' && and (zipWith complies sArgs sArgs')
complies s s' = s == s'

arity (FunctionT _ _ t) = arity t + 1
arity _ = 0

lastType t@(ScalarT _ _) = t
lastType (FunctionT _ _ tRes) = lastType tRes

allArgs (ScalarT _ _) = Set.empty
allArgs (FunctionT x tArg tRes) = case tArg of
  ScalarT baseT _ -> Set.insert (Var (toSort baseT) x) $ allArgs tRes 
  _ -> allArgs tRes
  
varRefinement x b = let s = toSort b in (Var s valueVarName |=| Var s x)
isVarRefinemnt (Binary Eq (Var _ v) (Var _ _)) = v == valueVarName
isVarRefinemnt _ = False

-- | Polymorphic type skeletons (parametrized by refinements)
data SchemaSkeleton r = 
  Monotype (TypeSkeleton r) |
  Forall Id (SchemaSkeleton r)
  deriving (Eq)
  
toMonotype :: SchemaSkeleton r -> TypeSkeleton r
toMonotype (Monotype t) = t
toMonotype (Forall _ t) = toMonotype t
  
-- | Mapping from type variables to types
type TypeSubstitution = Map Id RType

-- | 'typeSubstitute' @t@ : substitute all free type variables in @t@
typeSubstitute :: TypeSubstitution -> RType -> RType
typeSubstitute subst (ScalarT baseT r) = addRefinement substituteBase (typeSubstituteFML subst r)
  where
    substituteBase = case baseT of
      TypeVarT a -> case Map.lookup a subst of
        Just t -> typeSubstitute subst t
        Nothing -> ScalarT (TypeVarT a) ftrue
      DatatypeT name tArgs -> let tArgs' = map (typeSubstitute subst) tArgs 
        in ScalarT (DatatypeT name tArgs') ftrue
      _ -> ScalarT baseT ftrue
typeSubstitute subst (FunctionT x tArg tRes) = FunctionT x (typeSubstitute subst tArg) (typeSubstitute subst tRes)

typeSubstituteFML subst fml = case fml of 
  SetLit el es -> SetLit (sortSubstitute subst el) (map (typeSubstituteFML subst) es)
  Var s name -> Var (sortSubstitute subst s) name
  Unknown s name -> Unknown (Map.map (typeSubstituteFML subst) s) name
  Unary op e -> Unary op (typeSubstituteFML subst e)
  Binary op l r -> Binary op (typeSubstituteFML subst l) (typeSubstituteFML subst r)
  Measure s name e -> Measure (sortSubstitute subst s) name (typeSubstituteFML subst e)
  _ -> fml
  
sortSubstitute :: TypeSubstitution -> Sort -> Sort
sortSubstitute subst s@(UninterpretedS name []) = case Map.lookup name subst of
  Just (ScalarT b _) -> toSort b
  Just _ -> error $ unwords ["typeSubstituteFML: cannot substitute function type for", name]
  Nothing -> s
sortSubstitute subst (UninterpretedS name args) = UninterpretedS name (map (sortSubstitute subst) args)
sortSubstitute subst (SetS el) = SetS (sortSubstitute subst el)
sortSubstitute _ s = s
  
  
-- | 'typeVarsOf' @t@ : all type variables in @t@
typeVarsOf :: TypeSkeleton r -> Set Id
typeVarsOf t@(ScalarT baseT r) = case baseT of
  TypeVarT name -> Set.singleton name  
  DatatypeT _ tArgs -> Set.unions (map typeVarsOf tArgs)
  _ -> Set.empty
typeVarsOf (FunctionT _ tArg tRes) = typeVarsOf tArg `Set.union` typeVarsOf tRes

{- Refinement types -}

-- | Unrefined base
type SBaseType = BaseType ()

-- | Refined base
type RBaseType = BaseType Formula

-- | Unrefined typed
type SType = TypeSkeleton ()

-- | Refined types  
type RType = TypeSkeleton Formula

-- | Unrefined schemas
type SSchema = SchemaSkeleton ()

-- | Refined schemas  
type RSchema = SchemaSkeleton Formula

-- | Forget refinements of a type
shape :: RType -> SType  
shape (ScalarT (DatatypeT name tArgs) _) = ScalarT (DatatypeT name (map shape tArgs)) ()
shape (ScalarT IntT _) = ScalarT IntT ()
shape (ScalarT BoolT _) = ScalarT BoolT ()
shape (ScalarT (TypeVarT a) _) = ScalarT (TypeVarT a) ()
shape (FunctionT x tArg tFun) = FunctionT x (shape tArg) (shape tFun)

-- | Forget refinements of a schema
polyShape :: RSchema -> SSchema
polyShape (Monotype t) = Monotype (shape t)
polyShape (Forall a sch) = Forall a (polyShape sch)

-- | Insert weakest refinement
refineTop :: SType -> RType
refineTop (ScalarT (DatatypeT name tArgs) _) = ScalarT (DatatypeT name (map refineTop tArgs)) ftrue
refineTop (ScalarT IntT _) = ScalarT IntT ftrue
refineTop (ScalarT BoolT _) = ScalarT BoolT ftrue
refineTop (ScalarT (TypeVarT a) _) = ScalarT (TypeVarT a) ftrue
refineTop (FunctionT x tArg tFun) = FunctionT x (refineBot tArg) (refineTop tFun)

-- | Insert strongest refinement
refineBot :: SType -> RType
refineBot (ScalarT (DatatypeT name tArgs) _) = ScalarT (DatatypeT name (map refineBot tArgs)) ffalse
refineBot (ScalarT IntT _) = ScalarT IntT ffalse
refineBot (ScalarT BoolT _) = ScalarT BoolT ffalse
refineBot (ScalarT (TypeVarT a) _) = ScalarT (TypeVarT a) ffalse
refineBot (FunctionT x tArg tFun) = FunctionT x (refineTop tArg) (refineBot tFun)

addRefinement (ScalarT base fml) fml' = if isVarRefinemnt fml'
  then ScalarT base fml' -- the type of a polymorphic variable does not require any other refinements
  else ScalarT base (fml `andClean` fml')
addRefinement t (BoolLit True) = t
addRefinement t _ = error $ "addRefinement: applied to function type"

      
-- | 'renameVar' @old new t@: rename all occurrences of @old@ in @t@ into @new@
renameVar :: Id -> Id -> RType -> RType -> RType
renameVar old new (FunctionT _ _ _)   t = t -- function arguments cannot occur in types
renameVar old new t@(ScalarT b _)  (ScalarT baseT fml) = 
  let newRefinement = substitute (Map.singleton old (Var (toSort b) new)) fml
  in case baseT of
        DatatypeT name tArgs -> ScalarT (DatatypeT name $ map (renameVar old new t) tArgs) newRefinement
        _ -> ScalarT baseT newRefinement
renameVar old new t                  (FunctionT x tArg tRes) = FunctionT x (renameVar old new t tArg) (renameVar old new t tRes)

-- | 'unknownsOfType' @t: all unknowns in @t@
unknownsOfType :: RType -> Set Formula 
unknownsOfType (ScalarT (DatatypeT _ tArgs) fml) = Set.unions $ unknownsOf fml : map unknownsOfType tArgs
unknownsOfType (ScalarT _ fml) = unknownsOf fml
unknownsOfType (FunctionT _ tArg tRes) = unknownsOfType tArg `Set.union` unknownsOfType tRes

-- | Instantiate unknowns in a type
typeApplySolution :: Solution -> RType -> RType
typeApplySolution sol (ScalarT (DatatypeT name tArgs) fml) = ScalarT (DatatypeT name $ map (typeApplySolution sol) tArgs) (applySolution sol fml)
typeApplySolution sol (ScalarT base fml) = ScalarT base (applySolution sol fml)
typeApplySolution sol (FunctionT x tArg tRes) = FunctionT x (typeApplySolution sol tArg) (typeApplySolution sol tRes) 

-- | User-defined datatype representation
data Datatype = Datatype {
  _typeArgCount :: Int,
  _constructors :: [Id],  -- ^ Constructor names
  _wfMetric :: Maybe Id   -- ^ Name of the measure that serves as well founded termination metric
}

makeLenses ''Datatype

-- | Building types
bool = ScalarT BoolT  
bool_ = bool ()
boolAll = bool ftrue

int = ScalarT IntT
int_ = int ()
intAll = int ftrue
nat = int (valInt |>=| IntLit 0)
pos = int (valInt |>| IntLit 0)

vart n = ScalarT (TypeVarT n)
vart_ n = vart n ()
vartAll n = vart n ftrue

{- Program terms -}    
    
-- | One case inside a pattern match expression
data Case r = Case {
  constructor :: Id,      -- ^ Constructor name
  argNames :: [Id],       -- ^ Bindings for constructor arguments
  expr :: Program r       -- ^ Result of the match in this case
} deriving Eq    
    
-- | Program skeletons parametrized by information stored symbols, conditionals, and by node types
data BareProgram r =
  PSymbol Id |                            -- ^ Symbol (variable or constant)
  PApp (Program r) (Program r) |          -- ^ Function application
  PFun Id (Program r) |                   -- ^ Lambda abstraction
  PIf Formula (Program r) (Program r) |   -- ^ Conditional
  PMatch (Program r) [Case r] |           -- ^ Pattern match on datatypes
  PFix [Id] (Program r)                   -- ^ Fixpoint  
  deriving Eq
  
-- | Programs annotated with types  
data Program r = Program {
  content :: BareProgram r,
  typeOf :: TypeSkeleton r
} deriving Eq

-- | Fully defined programs 
type RProgram = Program Formula

hole t = Program (PSymbol "??") t

symbolList (Program (PSymbol name) _) = [name]
symbolList (Program (PApp fun arg) _) = symbolList fun ++ symbolList arg

-- | Instantiate type variables in a program
programSubstituteTypes :: TypeSubstitution -> RProgram -> RProgram
programSubstituteTypes subst (Program p t) = Program (programSubstituteTypes' p) (typeSubstitute subst t)
  where
    pst = programSubstituteTypes subst
    
    programSubstituteTypes' (PSymbol name) = PSymbol name
    programSubstituteTypes' (PApp fun arg) = PApp (pst fun) (pst arg)
    programSubstituteTypes' (PFun name p) = PFun name (pst p)    
    programSubstituteTypes' (PIf fml p1 p2) = PIf fml (pst p1) (pst p2)
    programSubstituteTypes' (PMatch scr cases) = PMatch (pst scr) (map (\(Case ctr args p) -> Case ctr args (pst p)) cases)
    programSubstituteTypes' (PFix args p) = PFix args (pst p)

-- | Instantiate unknowns in a program
programApplySolution :: Solution -> RProgram -> RProgram
programApplySolution sol (Program p t) = Program (programApplySolution' p) (typeApplySolution sol t)
  where
    pas = programApplySolution sol
    
    programApplySolution' (PSymbol name) = PSymbol name
    programApplySolution' (PApp fun arg) = PApp (pas fun) (pas arg)
    programApplySolution' (PFun name p) = PFun name (pas p)    
    programApplySolution' (PIf fml p1 p2) = PIf (applySolution sol fml) (pas p1) (pas p2)
    programApplySolution' (PMatch scr cases) = PMatch (pas scr) (map (\(Case ctr args p) -> Case ctr args (pas p)) cases)
    programApplySolution' (PFix args p) = PFix args (pas p)
    
-- | Substitute a symbol for a subterm in a program    
programSubstituteSymbol :: Id -> RProgram -> RProgram -> RProgram
programSubstituteSymbol name subterm (Program p t) = Program (programSubstituteSymbol' p) t
  where
    pss = programSubstituteSymbol name subterm
    
    programSubstituteSymbol' (PSymbol x) = if x == name then content subterm else p
    programSubstituteSymbol' (PApp fun arg) = PApp (pss fun) (pss arg)
    programSubstituteSymbol' (PFun name pBody) = PFun name (pss pBody)    
    programSubstituteSymbol' (PIf fml p1 p2) = PIf fml (pss p1) (pss p2)
    programSubstituteSymbol' (PMatch scr cases) = PMatch (pss scr) (map (\(Case ctr args pBody) -> Case ctr args (pss pBody)) cases)
    programSubstituteSymbol' (PFix args pBody) = PFix args (pss pBody)

{- Evaluation environment -}

-- | Typing environment
data Environment = Environment {
  -- | Variable part:
  _symbols :: Map Int (Map Id RSchema),    -- ^ Variables and constants (with their refinement types), indexed by arity
  _ghosts :: Map Id RType,                 -- ^ Ghost variables (to be used in embedding but not in the program)
  _boundTypeVars :: [Id],                  -- ^ Bound type variables
  _assumptions :: Set Formula,             -- ^ Positive unknown assumptions
  _negAssumptions :: Set Formula,          -- ^ Negative unknown assumptions
  _shapeConstraints :: Map Id SType,       -- ^ For polymorphic recursive calls, the shape their types must have
  _usedScrutinees :: [RProgram],           -- ^ Program terms that has already been scrutinized
  -- | Constant part:
  _constants :: Set Id,                    -- ^ Subset of symbols that are constants  
  _datatypes :: Map Id Datatype,           -- ^ Datatype representations
  _measures :: Map Id (Sort, Sort),        -- ^ Measure types
  _typeSynonyms :: TypeSubstitution        -- ^ Type synonym definitions
}

makeLenses ''Environment  

-- | Empty environment
emptyEnv = Environment {
  _symbols = Map.empty,
  _ghosts = Map.empty,
  _boundTypeVars = [],
  _assumptions = Set.empty,
  _negAssumptions = Set.empty,
  _shapeConstraints = Map.empty,
  _usedScrutinees = [],
  _constants = Set.empty,
  _datatypes = Map.empty,
  _measures = Map.empty,
  _typeSynonyms = Map.empty
}

-- | 'symbolsOfArity' @n env@: all symbols of arity @n@ in @env@
symbolsOfArity n env = Map.findWithDefault Map.empty n (env ^. symbols) 

-- | All symbols in an environment
allSymbols :: Environment -> Map Id RSchema
allSymbols env = Map.unions $ Map.elems (env ^. symbols)

-- | 'isBound' @tv env@: is type variable @tv@ bound in @env@?
isBound :: Id -> Environment -> Bool
isBound tv env = tv `elem` env ^. boundTypeVars

addVariable :: Id -> RType -> Environment -> Environment
addVariable name t = addPolyVariable name (Monotype t)

addPolyVariable :: Id -> RSchema -> Environment -> Environment
addPolyVariable name sch = let n = arity (toMonotype sch) in (symbols %~ Map.insertWith (Map.union) n (Map.singleton name sch))

-- | 'addConstant' @name t env@ : add type binding @name@ :: Monotype @t@ to @env@
addConstant :: Id -> RType -> Environment -> Environment
addConstant name t = addPolyConstant name (Monotype t)

addMeasure :: Id -> (Sort, Sort) -> Environment -> Environment
addMeasure measureName sorts = over measures (Map.insert measureName sorts)

-- | 'addPolyConstant' @name sch env@ : add type binding @name@ :: @sch@ to @env@
addPolyConstant :: Id -> RSchema -> Environment -> Environment
addPolyConstant name sch = addPolyVariable name sch . (constants %~ Set.insert name)

removeVariable :: Id -> Environment -> Environment
removeVariable name env = case Map.lookup name (allSymbols env) of
  Nothing -> env
  Just sch -> over symbols (Map.insertWith (flip Map.difference) (arity $ toMonotype sch) (Map.singleton name sch)) . over constants (Set.delete name) $ env

addTypeSynonym :: Id -> RType -> Environment -> Environment
addTypeSynonym name type' = over typeSynonyms (Map.insert name type')

-- | 'addDatatype' @name env@ : add datatype @name@ to the environment
addDatatype :: Id -> Datatype -> Environment -> Environment
addDatatype name dt = over datatypes (Map.insert name dt)

-- | 'lookupConstructor' @ctor env@ : the name of the datatype for which @ctor@ is regisered as a constructor in @env@, if any
lookupConstructor :: Id -> Environment -> Maybe Id
lookupConstructor ctor env = let m = Map.filter (\dt -> ctor `elem` dt ^. constructors) (env ^. datatypes)
  in if Map.null m
      then Nothing
      else Just $ fst $ Map.findMin m

-- | 'addTypeVar' @a@ : Add bound type variable @a@ to the environment
addTypeVar :: Id -> Environment -> Environment
addTypeVar a = over boundTypeVars (a :)

-- | 'allScalars' @env@ : logic terms for all scalar symbols in @env@
allScalars :: Environment -> TypeSubstitution -> [Formula]
allScalars env subst = catMaybes $ map toFormula $ Map.toList $ symbolsOfArity 0 env
  where
    toFormula (_, Forall _ _) = Nothing
    toFormula (x, Monotype t@(ScalarT (TypeVarT a) _)) | a `Map.member` subst = toFormula (x, Monotype $ typeSubstitute subst t)
    toFormula (_, Monotype (ScalarT IntT (Binary Eq _ (IntLit n)))) = Just $ IntLit n
    toFormula (x, Monotype (ScalarT b _)) = Just $ Var (toSort b) x

-- | 'addAssumption' @f env@ : @env@ with extra assumption @f@
addAssumption :: Formula -> Environment -> Environment
addAssumption f = assumptions %~ Set.insert f

-- | 'addNegAssumption' @f env@ : @env@ with extra assumption not @f@
addNegAssumption :: Formula -> Environment -> Environment
addNegAssumption f = negAssumptions %~ Set.insert f

-- | 'addScrutinee' @p env@ : @env@ with @p@ marked as having been scrutinized already
addScrutinee :: RProgram -> Environment -> Environment
addScrutinee p = usedScrutinees %~ (p :)

-- | Positive and negative formulas encoded in an environment    
embedding :: Environment -> TypeSubstitution -> (Set Formula, Set Formula)    
embedding env subst = ((env ^. assumptions) `Set.union` (Map.foldlWithKey (\fmls name sch -> fmls `Set.union` embedBinding name sch) Set.empty allSymbols), env ^.negAssumptions)
  where
    allSymbols = symbolsOfArity 0 env `Map.union` Map.map Monotype (env ^. ghosts)
    embedBinding x (Monotype t@(ScalarT (TypeVarT a) _)) | not (isBound a env) = if a `Map.member` subst 
      then embedBinding x (Monotype $ typeSubstitute subst t) -- Substitute free variables
      else Set.empty
      -- else error $ unwords ["embedding: encountered free type variable", a, "in", show $ Map.keys subst]
      -- else error $ unwords ["embedding: encountered free type variable", a, "in", show $ Map.keys subst]
    embedBinding _ (Monotype (ScalarT _ (BoolLit True))) = Set.empty -- Ignore trivial types
    embedBinding x (Monotype (ScalarT baseT fml)) = if Set.member x (env ^. constants) 
      then Set.empty -- Ignore constants
      else Set.singleton $ substitute (Map.singleton valueVarName (Var (toSort baseT) x)) fml
    embedBinding _ _ = Set.empty -- Ignore polymorphic things, since they could only be constants
    
{- Misc -}
          
-- | Typing constraints
data Constraint = Subtype Environment RType RType Bool
  | WellFormed Environment RType
  | WellFormedCond Environment Formula
  
-- | Synthesis goal
data Goal = Goal {
  gName :: Id, 
  gEnvironment :: Environment, 
  gSpec :: RSchema
}  
  
type ProgramAst = [Declaration]
data ConstructorDef = ConstructorDef Id RSchema
  deriving (Eq)
data Declaration =
  TypeDef Id RType |                            -- ^ Type name and definition
  FuncDef Id RSchema |                          -- ^ Function name and signature
  DataDef Id [Id] (Maybe Id) [ConstructorDef] | -- ^ Datatype name, type parameters, and constructor definitions
  MeasureDef Id Sort Sort |                     -- ^ Measure name, input sort, output sort
  QualifierDef [Formula] |                      -- ^ Qualifiers
  SynthesisGoal Id                              -- ^ Name of the function to synthesize
  deriving (Eq)

constructorName (ConstructorDef name _) = name