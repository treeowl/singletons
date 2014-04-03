{- Data/Singletons/Singletons.hs

(c) Richard Eisenberg 2013
eir@cis.upenn.edu

This file contains functions to refine constructs to work with singleton
types. It is an internal module to the singletons package.
-}
{-# LANGUAGE TemplateHaskell, CPP, TupleSections #-}

module Data.Singletons.Singletons where

import Prelude hiding ( exp )
import Language.Haskell.TH hiding ( cxt )
import Language.Haskell.TH.Syntax (falseName, trueName, Quasi(..))
import Data.Singletons.Util
import Data.Singletons.Promote
import Data.Singletons.Promote.Monad
import Data.Singletons.Names
import Data.Singletons
import Data.Singletons.Decide
import Language.Haskell.TH.Desugar
import Language.Haskell.TH.Desugar.Sweeten
import qualified Data.Map as Map
import Control.Monad
import Control.Applicative
import Data.List (find)

-- reduce the four cases of a 'Con' to just two: monomorphic and polymorphic
-- and convert 'StrictType' to 'Type'
ctorCases :: (Name -> [Type] -> a) -> ([TyVarBndr] -> Cxt -> Con -> a) -> Con -> a
ctorCases genFun forallFun ctor = case ctor of
  NormalC name stypes -> genFun name (map snd stypes)
  RecC name vstypes -> genFun name (map (\(_,_,ty) -> ty) vstypes)
  InfixC (_,ty1) name (_,ty2) -> genFun name [ty1, ty2]
  ForallC [] [] ctor' -> ctorCases genFun forallFun ctor'
  ForallC tvbs cx ctor' -> forallFun tvbs cx ctor'

-- reduce the four cases of a 'Con' to just 1: a polymorphic Con is treated
-- as a monomorphic one
ctor1Case :: (Name -> [Type] -> a) -> Con -> a
ctor1Case mono = ctorCases mono (\_ _ ctor -> ctor1Case mono ctor)

-- tuple up a list of patterns
mkTuplePat :: [Pat] -> Pat
mkTuplePat [x] = x
mkTuplePat xs  = TupP xs

-- tuple up a list of expressions
mkTupleExp :: [Exp] -> Exp
mkTupleExp [x] = x
mkTupleExp xs  = TupE xs

mkTyFamInst :: Name -> [Type] -> Type -> Dec
mkTyFamInst name lhs rhs =
#if __GLASGOW_HASKELL__ >= 707
  TySynInstD name (TySynEqn lhs rhs)
#else
  TySynInstD name lhs rhs
#endif

-- Get argument kinds from an arrow kind. Removing ForallT is an
-- important preprocessing step required by promoteType.
unravel :: Kind -> [Kind]
unravel (ForallT _ _ ty) = unravel ty
unravel (AppT (AppT ArrowT k1) k2) =
    let ks = unravel k2 in k1 : ks
unravel k = [k]

-- Reconstruct arrow kind from the list of kinds
ravel :: [Kind] -> Kind
ravel []    = error "Internal error: raveling nil"
ravel [k]   = k
ravel (h:t) = AppT (AppT ArrowT h) (ravel t)

oldPromoteType :: Quasi q => Type -> q Kind
oldPromoteType ty = do
  ty' <- dsType ty
  (ki, _) <- promoteM $ promoteType ty'
  return $ kindToTH ki

oldPromoteDecs :: Quasi q => [Dec] -> q [Dec]
oldPromoteDecs decs = do
  decs' <- dsDecs decs
  (decs'', others) <- promoteM $ promoteDecs decs'
  return $ decsToTH (decs'' ++ others)

extractTvbName_ :: TyVarBndr -> Name
extractTvbName_ (PlainTV n) = n
extractTvbName_ (KindedTV n _) = n

-- extract the kind from a TyVarBndr. Returns '*' by default.
extractTvbKind_ :: TyVarBndr -> Kind
extractTvbKind_ (PlainTV _) = StarT -- FIXME: This seems wrong.
extractTvbKind_ (KindedTV _ k) = k

emptyMatches_ :: [Match]
emptyMatches_ = [Match WildP (NormalB (AppE (VarE 'error) (LitE (StringL errStr)))) []]
  where errStr = "Empty case reached -- this should be impossible"

extractNameArgs_ :: Con -> (Name, Int)
extractNameArgs_ = ctor1Case (\name tys -> (name, length tys))
                                             
introduceApply :: (Name, Int) -> Type -> (Type, Bool)
introduceApply funData' typeT =
    case go funData' typeT of
      (t, f, _ ) -> (t, f)
    where
      go funData (ForallT tyvars ctx ty) =
          let (ty', isApplyAdded, n) = go funData ty
          in (ForallT tyvars ctx ty', isApplyAdded, n)
      go (funName, funArity) (AppT (VarT name) ty) =
          let (ty', isApplyAdded, _) = go (funName, funArity) ty
          in if funName == name -- if we found our type variable then use Apply
             then (AppT (AppT (ConT applyName) (VarT name)) ty'
                  , True, funArity - 1)
             else (AppT                        (VarT name)  ty'
                  , isApplyAdded, 0)
      go funData (AppT ty1 ty2) =
          let (ty1', isApplyAdded1, n) = go funData ty1
              (ty2', isApplyAdded2, _) = go funData ty2
          in if n /= 0 -- do we need to insert more Applies because arity > 1?
             then (AppT (AppT (ConT applyName) ty1') ty2', True  , n - 1)
             else (AppT ty1' ty2', isApplyAdded1 || isApplyAdded2, n    )
      go _ ty = (ty, False, 0)


-- map to track bound variables
type ExpTable = Map.Map Name Exp

-- translating a type gives a type with a hole in it,
-- represented here as a function
type TypeFn = Type -> Type

-- a list of argument types extracted from a type application
type TypeContext = [Type]

singFamily :: Type
singFamily = ConT singFamilyName

singKindConstraint :: Kind -> Pred
singKindConstraint k = ClassP singKindClassName [kindParam k]

demote :: Type
demote = ConT demoteRepName

singDataConName :: Name -> Name
singDataConName nm
  | nm == nilName                           = snilName
  | nm == consName                          = sconsName
  | Just degree <- tupleNameDegree_maybe nm = mkTupleName degree
  | otherwise                               = prefixUCName "S" ":%" nm

singTyConName :: Name -> Name
singTyConName name
  | name == listName                          = sListName
  | Just degree <- tupleNameDegree_maybe name = mkTupleName degree
  | otherwise                                 = prefixUCName "S" ":%" name

singClassName :: Name -> Name
singClassName = singTyConName

singDataCon :: Name -> Exp
singDataCon = ConE . singDataConName

singValName :: Name -> Name
singValName n
  | nameBase n == "undefined" = undefinedName
  | otherwise                 = (prefixLCName "s" "%") $ upcase n

singVal :: Name -> Exp
singVal = VarE . singValName

kindParam :: Kind -> Type
kindParam k = SigT (ConT kProxyDataName) (AppT (ConT kProxyTypeName) k)

-- Counts the arity of type level function represented with TyFun constructors
-- TODO: this and isTuFun looks like a good place to use PatternSynonyms
tyFunArity_ :: Kind -> Int
tyFunArity_ (AppT (AppT ArrowT (AppT (AppT (ConT tyFunNm) _) b)) StarT) =
    if tyFunName == tyFunNm
    then 1 + tyFunArity_ b
    else 0
tyFunArity_ _ = 0

promoteLit_ :: Quasi q => Lit -> q Type
promoteLit_ = fmap typeToTH . promoteLit

-- build a pattern match over several expressions, each with only one pattern
multiCase_ :: [Exp] -> [Pat] -> Exp -> Exp
multiCase_ [] [] body = body
multiCase_ scruts pats body =
  CaseE (mkTupleExp scruts)
        [Match (mkTuplePat pats) (NormalB body) []]

isTyFun_ :: Type -> Bool
isTyFun_ (AppT (AppT ArrowT (AppT (AppT (ConT tyFunNm) _) _)) StarT) =
    tyFunName == tyFunNm
isTyFun_ _ = False

-- | Generate singleton definitions from a type that is already defined.
-- For example, the singletons package itself uses
--
-- > $(genSingletons [''Bool, ''Maybe, ''Either, ''[]])
--
-- to generate singletons for Prelude types.
genSingletons :: Quasi q => [Name] -> q [Dec]
genSingletons names = do
  checkForRep names
  concatMapM (singInfo <=< reifyWithWarning) names

singInfo :: Quasi q => Info -> q [Dec]
singInfo (ClassI _dec _instances) =
  fail "Singling of class info not supported"
singInfo (ClassOpI _name _ty _className _fixity) =
  fail "Singling of class members info not supported"
singInfo i@(TyConI dec@(DataD {})) = do -- TODO: document this special case
  (newDecls, binds) <- evalForPair $ singDec dec --rename binds
  newDecls' <- mapM (singDec' binds) newDecls
  i' <- dsInfo i
  (promotedDataDecs, otherDecs) <- promoteM $ promoteInfo i'
  return $ decsToTH (promotedDataDecs ++ otherDecs) ++ newDecls'
singInfo (TyConI dec) = do
  (newDecls, binds)  <- evalForPair $ singDec dec --rename binds
  newDecls' <- mapM (singDec' binds) newDecls
  return newDecls'
singInfo (FamilyI _dec _instances) =
  fail "Singling of type family info not yet supported" -- KindFams
singInfo (PrimTyConI _name _numArgs _unlifted) =
  fail "Singling of primitive type constructors not supported"
singInfo (DataConI _name _ty _tyname _fixity) =
  fail $ "Singling of individual constructors not supported; " ++
         "single the type instead"
singInfo (VarI _name _ty _mdec _fixity) =
  fail "Singling of value info not supported"
singInfo (TyVarI _name _ty) =
  fail "Singling of type variable info not supported"

-- refine a constructor. the first parameter is the type variable that
-- the singleton GADT is parameterized by
-- runs in the QWithDecs monad because auxiliary declarations are produced
singCtor :: Quasi q => Type -> Con -> QWithAux [Dec] q Con
singCtor a = ctorCases
  -- monomorphic case
  (\name types -> do
    let sName = singDataConName name
        sCon = singDataCon name
        pCon = PromotedT name
    indexNames <- replicateM (length types) (qNewName "n")
    let indices = map VarT indexNames
    kinds <- mapM oldPromoteType types
    args <- buildArgTypes types indices
    let tvbs = zipWith KindedTV indexNames kinds
        kindedIndices = zipWith SigT indices kinds

    -- SingI instance
    addElement $ InstanceD (map (ClassP singIName . listify) indices)
                           (AppT (ConT singIName)
                                 (foldl AppT pCon kindedIndices))
                           [ValD (VarP singMethName)
                                 (NormalB $ foldl AppE sCon (replicate (length types)
                                                           (VarE singMethName)))
                                 []]

    return $ ForallC tvbs
                     [EqualP a (foldl AppT pCon indices)]
                     (NormalC sName $ map (NotStrict,) args))

  -- polymorphic case
  (\_tvbs cxt ctor -> case cxt of
    _:_ -> fail "Singling of constrained constructors not yet supported"
    [] -> singCtor a ctor) -- polymorphic constructors are handled just
                           -- like monomorphic ones -- the polymorphism in
                           -- the kind is automatic
  where buildArgTypes :: Quasi q => [Type] -> [Type] -> q [Type]
        buildArgTypes types indices = do
          typeFns <- mapM singType types
          return $ map fst $ zipWith id typeFns indices

-- | Make promoted and singleton versions of all declarations given, retaining
-- the original declarations.
-- See <http://www.cis.upenn.edu/~eir/packages/singletons/README.html> for
-- further explanation.
singletons :: Quasi q => q [Dec] -> q [Dec]
singletons = (>>= singDecs True)

-- | Make promoted and singleton versions of all declarations given, discarding
-- the original declarations.
singletonsOnly :: Quasi q => q [Dec] -> q [Dec]
singletonsOnly = (>>= singDecs False)

-- Note [Creating singleton functions in two stages]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Creating a singletons from declaration is conducted in two stages:
--
--  1) Singletonize everything except function bodies. When
--     singletonizing type signature for a function it might happen
--     that parameters that are functions will receive extra 'Proxy t'
--     arguments. We record information about number of Proxy
--     arguments required by each function argument.
--  2) Singletonize function bodies. We use information acquired in
--     step one to introduce extra Proxy arguments in the function body.

-- first parameter says whether or not to include original decls
singDecs :: Quasi q => Bool -> [Dec] -> q [Dec]
singDecs originals decls = do
  promDecls <- oldPromoteDecs decls
  (newDecls, proxyTable) <- evalForPair $ mapM singDec decls
  newDecls' <- mapM (singDec' proxyTable) (concat newDecls)
  return $ (if originals then (decls ++) else id) $ promDecls ++ newDecls'

-- ProxyTable stores a mapping between function name and a list of
-- extra Proxy parameters required by this function's arguments. For
-- example if ProxyTable stores mapping "foo -> [0,1,0]" it means that
-- foo accepts three parameters and that second parameter is a
-- function that requires one extra Proxy passed as argument when foo
-- is applied in the body of foo.
type ProxyTable = Map.Map Name [Int]
type SingletonQ q = QWithAux ProxyTable q

singDec :: Quasi q => Dec -> SingletonQ q [Dec]
singDec (FunD name clauses) =   -- handled by singDec'. See Note [Creating
    return [FunD name clauses]  -- singleton functions in two stages]
singDec (ValD _ (GuardedB _) _) =
  fail "Singling of definitions of values with a pattern guard not yet supported"
singDec (ValD _ _ (_:_)) =
  fail "Singling of definitions of values with a <<where>> clause not yet supported"
singDec (ValD pat (NormalB exp) []) = do
  (sPat, vartbl) <- evalForPair $ singPat TopLevel pat
  sExp <- singExp [] vartbl exp
  return [ValD sPat (NormalB sExp) []]
singDec (DataD cxt name tvbs ctors derivings) =
  singDataD False cxt name tvbs ctors derivings
singDec (NewtypeD cxt name tvbs ctor derivings) =
  singDataD False cxt name tvbs [ctor] derivings
singDec (TySynD _name _tvbs _ty) =
  fail "Singling of type synonyms not yet supported"
singDec (ClassD _cxt _name _tvbs _fundeps _decs) =
  fail "Singling of class declaration not yet supported"
singDec (InstanceD _cxt _ty _decs) =
  fail "Singling of class instance not yet supported"
singDec (SigD name ty) = do
  tyTrans <- singType ty
  let (typeSig, proxyTable) = tyTrans (ConT $ promoteValNameLhs name)
                               -- TODO: the above line is fishy.
  addBinding name proxyTable -- assign proxy table to function name
  return [SigD (singValName name) typeSig]
singDec (ForeignD fgn) =
  let name = extractName fgn in do
    qReportWarning $ "Singling of foreign functions not supported -- " ++
                    (show name) ++ " ignored"
    return []
  where extractName :: Foreign -> Name
        extractName (ImportF _ _ _ n _) = n
        extractName (ExportF _ _ n _) = n
singDec (InfixD fixity name)
  | isUpcase name = return [InfixD fixity (singDataConName name)]
  | otherwise     = return [InfixD fixity (singValName name)]
singDec (PragmaD _prag) = do
    qReportWarning "Singling of pragmas not supported"
    return []
singDec (FamilyD _flavour _name _tvbs _mkind) =
  fail "Singling of type and data families not yet supported"
singDec (DataInstD _cxt _name _tys _ctors _derivings) =
  fail "Singling of data instances not yet supported"
singDec (NewtypeInstD _cxt _name _tys _ctor _derivings) =
  fail "Singling of newtype instances not yet supported"
#if __GLASGOW_HASKELL__ >= 707
singDec (RoleAnnotD _name _roles) =
  return [] -- silently ignore role annotations, as they're harmless
singDec (ClosedTypeFamilyD _name _tvs _mkind _eqns) =
  fail "Singling of closed type families not yet supported"
singDec (TySynInstD _name _eqns) =
#else
singDec (TySynInstD _name _lhs _rhs) =
#endif
  fail "Singling of type family instances not yet supported"

singDec' :: Quasi q => ProxyTable -> Dec -> q Dec
singDec' proxyTable (FunD name clauses) = do
  let sName = singValName name
      vars = Map.singleton name (VarE sName)
  case Map.lookup name proxyTable of
    Nothing -> fail $ "No proxy table for function " ++ show name ++
                      "; please report this as a bug."
    Just proxyCount -> FunD sName <$> (mapM (singClause vars proxyCount) clauses)
singDec' _ dec = return dec

-- | Create instances of 'SEq' and type-level '(:==)' for each type in the list
singEqInstances :: Quasi q => [Name] -> q [Dec]
singEqInstances = concatMapM singEqInstance

-- | Create instance of 'SEq' and type-level '(:==)' for the given type
singEqInstance :: Quasi q => Name -> q [Dec]
singEqInstance name = do
  promotion <- promoteEqInstance name
  dec <- singEqualityInstance sEqClassDesc name
  return $ dec : promotion

-- | Create instances of 'SEq' (only -- no instance for '(:==)', which 'SEq' generally
-- relies on) for each type in the list
singEqInstancesOnly :: Quasi q => [Name] -> q [Dec]
singEqInstancesOnly = concatMapM singEqInstanceOnly

-- | Create instances of 'SEq' (only -- no instance for '(:==)', which 'SEq' generally
-- relies on) for the given type
singEqInstanceOnly :: Quasi q => Name -> q [Dec]
singEqInstanceOnly name = listify <$> singEqualityInstance sEqClassDesc name

-- | Create instances of 'SDecide' for each type in the list.
--
-- Note that, due to a bug in GHC 7.6.3 (and lower) optimizing instances
-- for SDecide can make GHC hang. You may want to put
-- @{-# OPTIONS_GHC -O0 #-}@ in your file.
singDecideInstances :: Quasi q => [Name] -> q [Dec]
singDecideInstances = concatMapM singDecideInstance

-- | Create instance of 'SDecide' for the given type.
--
-- Note that, due to a bug in GHC 7.6.3 (and lower) optimizing instances
-- for SDecide can make GHC hang. You may want to put
-- @{-# OPTIONS_GHC -O0 #-}@ in your file.
singDecideInstance :: Quasi q => Name -> q [Dec]
singDecideInstance name = listify <$> singEqualityInstance sDecideClassDesc name

-- generalized function for creating equality instances
singEqualityInstance :: Quasi q => EqualityClassDesc q -> Name -> q Dec
singEqualityInstance desc@(_, className, _) name = do
  (tvbs, cons) <- getDataD ("I cannot make an instance of " ++
                            show className ++ " for it.") name
  let tyvars = map (VarT . extractTvbName_) tvbs
      kind = foldl AppT (ConT name) tyvars
  aName <- qNewName "a"
  let aVar = VarT aName
  scons <- mapM (evalWithoutAux . singCtor aVar) cons
  mkEqualityInstance kind scons desc

-- making the SEq instance and the SDecide instance are rather similar,
-- so we generalize
type EqualityClassDesc q = ((Con, Con) -> q Clause, Name, Name)
sEqClassDesc, sDecideClassDesc :: Quasi q => EqualityClassDesc q
sEqClassDesc = (mkEqMethClause, sEqClassName, sEqMethName)
sDecideClassDesc = (mkDecideMethClause, sDecideClassName, sDecideMethName)

-- pass the *singleton* constructors, not the originals
mkEqualityInstance :: Quasi q => Kind -> [Con]
                   -> EqualityClassDesc q -> q Dec
mkEqualityInstance k ctors (mkMeth, className, methName) = do
  let ctorPairs = [ (c1, c2) | c1 <- ctors, c2 <- ctors ]
  methClauses <- if null ctors
                 then mkEmptyMethClauses
                 else mapM mkMeth ctorPairs
  return $ InstanceD (map (\kvar -> ClassP className [kindParam kvar])
                          (getKindVars k))
                     (AppT (ConT className)
                           (kindParam k))
                     [FunD methName methClauses]
  where getKindVars :: Kind -> [Kind]
        getKindVars (AppT l r) = getKindVars l ++ getKindVars r
        getKindVars (VarT x)   = [VarT x]
        getKindVars (ConT _)   = []
        getKindVars StarT      = []
        getKindVars other      =
          error ("getKindVars sees an unusual kind: " ++ show other)

        mkEmptyMethClauses :: Quasi q => q [Clause]
        mkEmptyMethClauses = do
          a <- qNewName "a"
          return [Clause [VarP a, WildP] (NormalB (CaseE (VarE a) emptyMatches_)) []]

mkEqMethClause :: Quasi q => (Con, Con) -> q Clause
mkEqMethClause (c1, c2)
  | lname == rname = do
    lnames <- replicateM lNumArgs (qNewName "a")
    rnames <- replicateM lNumArgs (qNewName "b")
    let lpats = map VarP lnames
        rpats = map VarP rnames
        lvars = map VarE lnames
        rvars = map VarE rnames
    return $ Clause
      [ConP lname lpats, ConP rname rpats]
      (NormalB $
        allExp (zipWith (\l r -> foldl AppE (VarE sEqMethName) [l, r])
                        lvars rvars))
      []
  | otherwise =
    return $ Clause
      [ConP lname (replicate lNumArgs WildP),
       ConP rname (replicate rNumArgs WildP)]
      (NormalB (singDataCon falseName))
      []
  where allExp :: [Exp] -> Exp
        allExp [] = singDataCon trueName
        allExp [one] = one
        allExp (h:t) = AppE (AppE (singVal andName) h) (allExp t)

        (lname, lNumArgs) = extractNameArgs_ c1
        (rname, rNumArgs) = extractNameArgs_ c2

mkDecideMethClause :: Quasi q => (Con, Con) -> q Clause
mkDecideMethClause (c1, c2)
  | lname == rname =
    if lNumArgs == 0
    then return $ Clause [ConP lname [], ConP rname []]
                         (NormalB (AppE (ConE provedName) (ConE reflName))) []
    else do
      lnames <- replicateM lNumArgs (qNewName "a")
      rnames <- replicateM lNumArgs (qNewName "b")
      contra <- qNewName "contra"
      let lpats = map VarP lnames
          rpats = map VarP rnames
          lvars = map VarE lnames
          rvars = map VarE rnames
      return $ Clause
        [ConP lname lpats, ConP rname rpats]
        (NormalB $
         CaseE (mkTupleExp $
                zipWith (\l r -> foldl AppE (VarE sDecideMethName) [l, r])
                        lvars rvars)
               ((Match (mkTuplePat (replicate lNumArgs
                                      (ConP provedName [ConP reflName []])))
                       (NormalB $ AppE (ConE provedName) (ConE reflName))
                      []) :
                [Match (mkTuplePat (replicate i WildP ++
                                    ConP disprovedName [VarP contra] :
                                    replicate (lNumArgs - i - 1) WildP))
                       (NormalB $ AppE (ConE disprovedName)
                                       (LamE [ConP reflName []]
                                             (AppE (VarE contra)
                                                   (ConE reflName))))
                       [] | i <- [0..lNumArgs-1] ]))
        []

  | otherwise =
    return $ Clause
      [ConP lname (replicate lNumArgs WildP),
       ConP rname (replicate rNumArgs WildP)]
      (NormalB (AppE (ConE disprovedName) (LamCaseE emptyMatches_)))
      []

  where
    (lname, lNumArgs) = extractNameArgs_ c1
    (rname, rNumArgs) = extractNameArgs_ c2

-- the first parameter is True when we're refining the special case "Rep"
-- and false otherwise. We wish to consider the promotion of "Rep" to be *
-- not a promoted data constructor.
singDataD :: Quasi q => Bool -> Cxt -> Name -> [TyVarBndr] -> [Con] -> [Name] -> q [Dec]
singDataD rep cxt name tvbs ctors derivings
  | (_:_) <- cxt = fail "Singling of constrained datatypes is not supported"
  | otherwise    = do
  aName <- qNewName "z"
  let a = VarT aName
  let tvbNames = map extractTvbName_ tvbs
  k <- oldPromoteType (foldl AppT (ConT name) (map VarT tvbNames))
  (ctors', ctorInstDecls) <- evalForPair $ mapM (singCtor a) ctors

  -- instance for SingKind
  fromSingClauses <- mapM mkFromSingClause ctors
  toSingClauses   <- mapM mkToSingClause ctors
  let singKindInst =
        InstanceD (map (singKindConstraint . VarT) tvbNames)
                  (AppT (ConT singKindClassName)
                        (kindParam k))
                  [ mkTyFamInst demoteRepName
                     [kindParam k]
                     (foldl AppT (ConT name)
                       (map (AppT demote . kindParam . VarT) tvbNames))
                  , FunD fromSingName (fromSingClauses `orIfEmpty` emptyMethod aName)
                  , FunD toSingName   (toSingClauses   `orIfEmpty` emptyMethod aName) ]

  -- SEq instance
  sEqInsts <- if elem eqName derivings
              then mapM (mkEqualityInstance k ctors') [sEqClassDesc, sDecideClassDesc]
              else return []

  -- e.g. type SNat (a :: Nat) = Sing a
  let kindedSynInst =
        TySynD (singTyConName name)
               [KindedTV aName k]
               (AppT singFamily a)

  return $ (DataInstD [] singFamilyName [SigT a k] ctors' []) :
           kindedSynInst :
           singKindInst :
           sEqInsts ++
           ctorInstDecls
  where -- in the Rep case, the names of the constructors are in the wrong scope
        -- (they're types, not datacons), so we have to reinterpret them.
        mkConName :: Name -> Name
        mkConName = if rep then reinterpret else id

        mkFromSingClause :: Quasi q => Con -> q Clause
        mkFromSingClause c = do
          let (cname, numArgs) = extractNameArgs_ c
          varNames <- replicateM numArgs (qNewName "b")
          return $ Clause [ConP (singDataConName cname) (map VarP varNames)]
                          (NormalB $ foldl AppE
                             (ConE $ mkConName cname)
                             (map (AppE (VarE fromSingName) . VarE) varNames))
                          []

        mkToSingClause :: Quasi q => Con -> q Clause
        mkToSingClause = ctor1Case $ \cname types -> do
          varNames  <- mapM (const $ qNewName "b") types
          svarNames <- mapM (const $ qNewName "c") types
          promoted  <- mapM oldPromoteType types
          let recursiveCalls = zipWith mkRecursiveCall varNames promoted
          return $
            Clause [ConP (mkConName cname) (map VarP varNames)]
                   (NormalB $
                    multiCase_ recursiveCalls
                              (map (ConP someSingDataName . listify . VarP)
                                   svarNames)
                              (AppE (ConE someSingDataName)
                                        (foldl AppE (ConE (singDataConName cname))
                                                 (map VarE svarNames))))
                   []

        mkRecursiveCall :: Name -> Kind -> Exp
        mkRecursiveCall var_name ki =
          SigE (AppE (VarE toSingName) (VarE var_name))
               (AppT (ConT someSingTypeName) (kindParam ki))

        emptyMethod :: Name -> [Clause]
        emptyMethod n = [Clause [VarP n] (NormalB $ CaseE (VarE n) emptyMatches_) []]

singKind :: Quasi q => Kind -> q (Kind -> Kind)
singKind (ForallT _ _ _) =
  fail "Singling of explicitly quantified kinds not yet supported"
singKind (VarT _) = fail "Singling of kind variables not yet supported"
singKind (ConT _) = fail "Singling of named kinds not yet supported"
singKind (TupleT _) = fail "Singling of tuple kinds not yet supported"
singKind (UnboxedTupleT _) = fail "Unboxed tuple used as kind"
singKind ArrowT = fail "Singling of unsaturated arrow kinds not yet supported"
singKind ListT = fail "Singling of list kinds not yet supported"
singKind (AppT (AppT ArrowT k1) k2) = do
  k1fn <- singKind k1
  k2fn <- singKind k2
  k <- qNewName "k"
  return $ \f -> AppT (AppT ArrowT (k1fn (VarT k))) (k2fn (AppT f (VarT k)))
singKind (AppT _ _) = fail "Singling of kind applications not yet supported"
singKind (SigT _ _) =
  fail "Singling of explicitly annotated kinds not yet supported"
singKind (LitT _) = fail "Type literal used as kind"
singKind (PromotedT _) = fail "Promoted data constructor used as kind"
singKind (PromotedTupleT _) = fail "Promoted tuple used as kind"
singKind PromotedNilT = fail "Promoted nil used as kind"
singKind PromotedConsT = fail "Promoted cons used as kind"
singKind StarT = return $ \k -> AppT (AppT ArrowT k) StarT
singKind ConstraintT = fail "Singling of constraint kinds not yet supported"

-- Note [Singletonizing type signature]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- Proces of singletonizing a type signature is conducted in two steps:
--
--  1. Prepare a singletonized (but not defunctionalized) type
--     signature. The result is returned as a function that expects
--     one type parameter. That parameter is the name of a type-level
--     equivalent (ie. a type family) of a function being promoted.
--     This is done by singTypeRep. Most of the implementation is
--     straightforward. The most interesting part is the promotion of
--     arrows (ArrowT clause). When we reach an arrow we expect that
--     both its parameters are placed within the context (this is done
--     by AppT clause). We promote the type of first parameter to a
--     kind and introduce it via kind-annotated type variable in a
--     forall. At this point arguments that are functions are
--     converted to TyFun representation. This is important for
--     defunctionalization.
--
--  2. Lift out foralls: accumulate separate foralls at the beginning
--     of type signature. So this:
--
--      forall (a :: k). Proxy a -> forall (b :: [k]). Proxy b -> SList (a ': b)
--
--     becomes:
--
--      forall (a :: k) (b :: [k]). Proxy a -> Proxy b -> SList (a ': b)
--
--     This was originally a workaround for #8031 but later this was
--     used as a part of defunctionalization algorithm. Lifting
--     foralls produces new type signature and a list of type
--     variables that represent type level functions (TyFun kind).
--
--  3. Introduce Apply and Proxy. Using the list of type variables
--     that are type level functions (see step 2) we convert each
--     application of such variable into application of Apply type
--     family. Also, for each type variable that was converted to
--     Apply we introduce a Proxy parameter. For example this
--     signature:
--
--       sEither_ ::
--         forall (t1 :: TyFun k1 k3 -> *)
--                (t2 :: TyFun k2 k3 -> *)
--                (t3 :: Either k1 k2).
--                (forall (t4 :: k1). Sing t4 -> Sing (t1 t4))
--             -> (forall (t5 :: k2). Sing t5 -> Sing (t2 t5))
--             -> Sing t3 -> Sing (Either_ t1 t2 t3)
--
--     is converted to:
--
--       sEither_ ::
--         forall (t1 :: TyFun k1 k3 -> *)
--                (t2 :: TyFun k2 k3 -> *)
--                (t3 :: Either k1 k2).
--                (forall (t4 :: k1). Proxy t1 -> Sing t4 -> Sing (Apply t1 t4))
--             -> (forall (t5 :: k2). Proxy t2 -> Sing t5 -> Sing (Apply t2 t5))
--             -> Sing t3 -> Sing (Either_ t1 t2 t3)
--
--     Note that Proxy parameters were introduced only for arguments
--     that are functions. This will require us to add extra Proxy
--     arguments when calling these functions in the function body
--     (see Note [Creating singleton functions in two stages]).
--
--  4. Steps 2 and 3 are mutually recursive, ie. we introduce Apply and Proxy
--     for each parameter in the function signature we are singletonizing. Why?
--     Because a higher order function may accept parameters that are themselves
--     higher order functions:
--
--       foo :: ((a -> b) -> a -> b) -> (a -> b)  -> a -> b
--       foo f g a = f g a
--
--     Here 'foo' is a higher order function for which we must introduce Apply
--     and Proxy, but so is 'f'. Hence the mutually recursive calls between
--     introduceApplyAndProxy and introduceApplyAndProxyWorker. Singletonized
--     foo looks like this:
--
--       sFoo :: forall (k1 :: TyFun (TyFun a b -> *) (TyFun a b -> *) -> *)
--                      (k2 :: TyFun a b -> *)
--                      (k3 :: a).
--               (forall (t1 :: TyFun a b -> *).
--                       Proxy k1 ->
--                       (forall (t2 :: a). Proxy t1 -> Sing t2 -> Sing (Apply t1 t2))
--               -> forall (t3 :: a). Sing t3 -> Sing (Apply (Apply k1 t1) t3))
--               -> (forall (t4 :: a). Proxy k2 -> Sing t4 -> Sing (Apply k2 t4))
--               -> Sing k3 -> Sing (Foo k1 k2 k3)
--       sFoo f g a = (f Proxy g) a
--
--     Luckily for us the Proxies we introduce for the higher-order parameter
--     are not reflected in the body of sFoo - it is assumed that 'f' will
--     handle passing Proxy paramters to 'g' internally. This allows us to
--     discard the Proxy count returned by introduceApplyAndProxy in the body of
--     introduceApplyAndProxyWorker.


-- The return type of singType is:
--
--   Type -> (Type, [Int])
--
-- where first Type is the type that will be substituted in the
-- signature (see Note [Singletonizing type signature]). The result is
-- a tuple containing the final type signature with its proxy table.
singType :: Quasi q => Type -> q (Type -> (Type, [Int]))
singType ty = do
  sTypeFn <- singTypeRec [] ty
  return $ \inner_ty -> introduceApplyAndProxy (sTypeFn inner_ty)

introduceApplyAndProxy :: Type -> (Type, [Int])
introduceApplyAndProxy t =
    let (singFunType, tyFunNames) = liftOutForalls t
        inputCount     = length (unravel singFunType) - 1 -- number of arguments
        initProxyCount = replicate inputCount 0
    in foldr introduceApplyAndProxyWorker (singFunType, initProxyCount) tyFunNames

introduceApplyAndProxyWorker :: (Name, Int) -> (Type, [Int]) -> (Type, [Int])
introduceApplyAndProxyWorker tyFun@(tyFunTyVar, _) ((ForallT tyvars ctx ty), proxyCount) =
    (ForallT tyvars ctx (ravel tysWithProxy), proxyCount')
    where tys          = map (fst . introduceApplyAndProxy) $ unravel ty
                       -- t1 -> t2 -> t3  ==>  [t1, t2, t3]
          tysWithApply = map (introduceApply tyFun) tys
                       -- each type has a flag that says whether Apply was
                       -- introduced in that type
          proxyCount'  = zipWith incProxyCount tysWithApply proxyCount
                       -- update the proxy count that was passed as input
          tysWithProxy = map introduceProxy tysWithApply
                       -- introduce Proxy if necessary, discard flags
          incProxyCount  (_, flag) n = if flag then n + 1                 else n
          introduceProxy (t, flag)   = if flag then addProxy tyFunTyVar t else t
introduceApplyAndProxyWorker _ t = t

-- Takes a name of type variable and introduces it via Proxy type
addProxy :: Name -> Type -> Type
addProxy tyVar (ForallT tyvars ctx ty) =
    ForallT tyvars ctx (addProxy tyVar ty)
addProxy tyVar funTy =
    AppT (AppT ArrowT (AppT (ConT proxyTypeName) (VarT tyVar))) funTy

-- Lifts free-standing foralls to the top-level.
liftOutForalls :: Type -> (Type, [(Name, Int)])
liftOutForalls =
  go [] [] []
  where
    go tyvars cxt args (ForallT tyvars1 cxt1 t1)
      = go (reverse tyvars1 ++ tyvars) (reverse cxt1 ++ cxt) args t1
    go tyvars cxt args (SigT t1 _kind)  -- ignore these kind annotations, which have to be *
      = go tyvars cxt args t1
    go tyvars cxt args (AppT (AppT ArrowT arg1) res1)
      = go tyvars cxt (arg1 : args) res1
    go [] [] args t1
      = (mk_fun_ty (reverse args) t1, [])
    go tyvars cxt args t1
      = (ForallT (reverse tyvars) (reverse cxt) (mk_fun_ty (reverse args) t1),
         getTyFunNames tyvars)

    mk_fun_ty [] res = res
    mk_fun_ty (arg1:args) res = AppT (AppT ArrowT arg1) (mk_fun_ty args res)

    -- Takes a list of type variable bindings and returns names of
    -- variables that are type functions together with their arity
    getTyFunNames :: [TyVarBndr] -> [(Name, Int)]
    getTyFunNames [] = []
    getTyFunNames (PlainTV _ : tys) = getTyFunNames tys
    getTyFunNames (KindedTV name kind : tys)
                  | isTyFun_ kind = (name, tyFunArity_ kind) : getTyFunNames tys
                  | otherwise    = getTyFunNames tys

-- the first parameter is the list of types the current type is applied to
singTypeRec :: Quasi q => TypeContext -> Type -> q TypeFn
singTypeRec (_:_) (ForallT _ _ _) =
  fail "I thought this was impossible in Haskell. Email me at eir@cis.upenn.edu with your code if you see this message."
singTypeRec [] (ForallT _ [] ty) = -- Sing makes handling foralls automatic
  singTypeRec [] ty
singTypeRec ctx (ForallT _tvbs cxt innerty) = do
  cxt' <- singContext cxt
  innerty' <- singTypeRec ctx innerty
  return $ \ty -> ForallT [] cxt' (innerty' ty)
singTypeRec (_:_) (VarT _) =
  fail "Singling of type variables of arrow kinds not yet supported"
singTypeRec [] (VarT _name) =
  return $ \ty -> AppT singFamily ty
singTypeRec _ctx (ConT _name) = -- we don't need to process the context with Sing
  return $ \ty -> AppT singFamily ty
singTypeRec _ctx (TupleT _n) = -- just like ConT
  return $ \ty -> AppT singFamily ty
singTypeRec _ctx (UnboxedTupleT _n) =
  fail "Singling of unboxed tuple types not yet supported"
singTypeRec ctx ArrowT = case ctx of
  [ty1, ty2] -> do
    t    <- qNewName "t"
    sty1 <- singTypeRec [] ty1
    sty2 <- singTypeRec [] ty2
    k1   <- oldPromoteType ty1
    return (\f -> ForallT [KindedTV t k1]
                          []
                          (AppT (AppT ArrowT (sty1 (VarT t)))
                                (sty2 (AppT f (VarT t)))))
  _ -> fail "Internal error in Sing: converting ArrowT with improper context"
singTypeRec _ctx ListT =
  return $ \ty -> AppT singFamily ty
singTypeRec ctx (AppT ty1 ty2) =
  singTypeRec (ty2 : ctx) ty1 -- recur with the ty2 in the applied context
singTypeRec _ctx (SigT _ty _knd) =
  fail "Singling of types with explicit kinds not yet supported"
singTypeRec _ctx (LitT _) = fail "Singling of type-level literals not yet supported"
singTypeRec _ctx (PromotedT _) =
  fail "Singling of promoted data constructors not yet supported"
singTypeRec _ctx (PromotedTupleT _) =
  fail "Singling of type-level tuples not yet supported"
singTypeRec _ctx PromotedNilT = fail "Singling of promoted nil not yet supported"
singTypeRec _ctx PromotedConsT = fail "Singling of type-level cons not yet supported"
singTypeRec _ctx StarT = fail "* used as type"
singTypeRec _ctx ConstraintT = fail "Constraint used as type"

-- refine a constraint context
singContext :: Quasi q => Cxt -> q Cxt
singContext = mapM singPred

singPred :: Quasi q => Pred -> q Pred
singPred (ClassP name tys) = do
  kis <- mapM oldPromoteType tys
  let sName = singClassName name
  return $ ClassP sName (map kindParam kis)
singPred (EqualP _ty1 _ty2) =
  fail "Singling of type equality constraints not yet supported"

singClause :: Quasi q => ExpTable -> [Int] -> Clause -> q Clause
singClause vars proxyCount (Clause pats (NormalB exp) []) = do
  (sPats, vartbl) <- evalForPair $ mapM (singPat Parameter) pats
  let vars' = Map.union vartbl vars
      patProxyMap = zip sPats proxyCount
                  -- assign proxy count to each pattern
      requiresProxy (p, n) = n > 0 && case p of {VarP _ -> True; _ -> False }
                  -- does a pattern represent variable that needs a Proxy ?
      onlyProxies = filter requiresProxy patProxyMap
                  -- filter out patterns that don't need a Proxy parameter
      proxyTable  = map (\(VarP name, n) -> (name, n)) onlyProxies
                  -- extract names of patterns
  sBody <- NormalB <$> singExp proxyTable vars' exp
  return $ Clause sPats sBody []
singClause _ _ (Clause _ (GuardedB _) _) =
  fail "Singling of guarded patterns not yet supported"
singClause _ _ (Clause _ _ (_:_)) =
  fail "Singling of <<where>> declarations not yet supported"

type ExpsQ q = QWithAux ExpTable q

-- we need to know where a pattern is to anticipate when
-- GHC's brain might explode
data PatternContext = LetBinding
                    | CaseStatement
                    | TopLevel
                    | Parameter
                    | Statement
                    deriving Eq

checkIfBrainWillExplode :: Quasi q => PatternContext -> ExpsQ q ()
checkIfBrainWillExplode CaseStatement = return ()
checkIfBrainWillExplode Statement = return ()
checkIfBrainWillExplode Parameter = return ()
checkIfBrainWillExplode _ =
  fail $ "Can't use a singleton pattern outside of a case-statement or\n" ++
         "do expression: GHC's brain will explode if you try. (Do try it!)"

-- convert a pattern, building up the lexical scope as we go
singPat :: Quasi q => PatternContext -> Pat -> ExpsQ q Pat
singPat _patCxt (LitP _lit) =
  fail "Singling of literal patterns not yet supported"
singPat patCxt (VarP name) =
  let new = if patCxt == TopLevel then singValName name else name in do
    addBinding name (VarE new)
    return $ VarP new
singPat patCxt (TupP pats) =
  singPat patCxt (ConP (tupleDataName (length pats)) pats)
singPat _patCxt (UnboxedTupP _pats) =
  fail "Singling of unboxed tuples not supported"
singPat patCxt (ConP name pats) = do
  checkIfBrainWillExplode patCxt
  pats' <- mapM (singPat patCxt) pats
  return $ ConP (singDataConName name) pats'
singPat patCxt (InfixP pat1 name pat2) = singPat patCxt (ConP name [pat1, pat2])
singPat _patCxt (UInfixP _ _ _) =
  fail "Singling of unresolved infix patterns not supported"
singPat _patCxt (ParensP _) =
  fail "Singling of unresolved paren patterns not supported"
singPat patCxt (TildeP pat) = do
  pat' <- singPat patCxt pat
  return $ TildeP pat'
singPat patCxt (BangP pat) = do
  pat' <- singPat patCxt pat
  return $ BangP pat'
singPat patCxt (AsP name pat) = do
  let new = if patCxt == TopLevel then singValName name else name in do
    pat' <- singPat patCxt pat
    addBinding name (VarE new)
    return $ AsP name pat'
singPat _patCxt WildP = return WildP
singPat _patCxt (RecP _name _fields) =
  fail "Singling of record patterns not yet supported"
singPat patCxt (ListP pats) = do
  checkIfBrainWillExplode patCxt
  sPats <- mapM (singPat patCxt) pats
  return $ foldr (\elt lst -> ConP sconsName [elt, lst]) (ConP snilName []) sPats
singPat _patCxt (SigP _pat _ty) =
  fail "Singling of annotated patterns not yet supported"
singPat _patCxt (ViewP _exp _pat) =
  fail "Singling of view patterns not yet supported"

singExp :: Quasi q => [(Name, Int)] -> ExpTable -> Exp -> q Exp
singExp _ vars (VarE name) = case Map.lookup name vars of
  Just exp -> return exp
  Nothing -> return (singVal name)
singExp _ _vars (ConE name) = return $ singDataCon name
singExp _ _vars (LitE lit) = singLit lit
singExp proxyTable vars (AppE exp1@(VarE var) exp2) = do
  let needsProxy = find (\(name, _) -> name == var) proxyTable
      -- check if this variable needs extra Proxy parameter
  exp1' <- singExp proxyTable vars exp1
  exp2' <- singExp proxyTable vars exp2
  case needsProxy of
    Nothing     -> return $ AppE exp1' exp2'
    Just (_, n) -> return $ AppE (loop n addProxyParam exp1') exp2'
      where addProxyParam exp = AppE exp (ConE proxyDataName)
            loop 0 _ a = a
            loop m f a = loop (m - 1) f (f a)
singExp proxyTable vars (AppE exp1 exp2) = do
  exp1' <- singExp proxyTable vars exp1
  exp2' <- singExp proxyTable vars exp2
  return $ AppE exp1' exp2'
singExp proxyTable vars (InfixE mexp1 exp mexp2) =
  case (mexp1, mexp2) of
    (Nothing, Nothing) -> singExp proxyTable vars exp
    (Just exp1, Nothing) -> singExp proxyTable vars (AppE exp exp1)
    (Nothing, Just _exp2) ->
      fail "Singling of right-only sections not yet supported"
    (Just exp1, Just exp2) -> singExp proxyTable vars (AppE (AppE exp exp1) exp2)
singExp _ _vars (UInfixE _ _ _) =
  fail "Singling of unresolved infix expressions not supported"
singExp _ _vars (ParensE _) =
  fail "Singling of unresolved paren expressions not supported"
singExp proxyTable vars (LamE pats exp) = do
  (pats', vartbl) <- evalForPair $ mapM (singPat Parameter) pats
  let vars' = Map.union vartbl vars -- order matters; union is left-biased
  exp' <- singExp proxyTable vars' exp
  return $ LamE pats' exp'
singExp _ _vars (LamCaseE _matches) =
  fail "Singling of case expressions not yet supported"
singExp proxyTable vars (TupE exps) = do
  sExps <- mapM (singExp proxyTable vars) exps
  sTuple <- singExp proxyTable vars (ConE (tupleDataName (length exps)))
  return $ foldl AppE sTuple sExps
singExp _ _vars (UnboxedTupE _exps) =
  fail "Singling of unboxed tuple not supported"
singExp proxyTable vars (CondE bexp texp fexp) = do
  exps <- mapM (singExp proxyTable vars) [bexp, texp, fexp]
  return $ foldl AppE (VarE sIfName) exps
singExp _ _vars (MultiIfE _alts) =
  fail "Singling of multi-way if statements not yet supported"
singExp _ _vars (LetE _decs _exp) =
  fail "Singling of let expressions not yet supported"
singExp _ _vars (CaseE _exp _matches) =
  fail "Singling of case expressions not yet supported"
singExp _ _vars (DoE _stmts) =
  fail "Singling of do expressions not yet supported"
singExp _ _vars (CompE _stmts) =
  fail "Singling of list comprehensions not yet supported"
singExp _ _vars (ArithSeqE _range) =
  fail "Singling of ranges not yet supported"
singExp proxyTable vars (ListE exps) = do
  sExps <- mapM (singExp proxyTable vars) exps
  return $ foldr (\x -> (AppE (AppE (ConE sconsName) x)))
                 (ConE snilName) sExps
singExp _ _vars (SigE _exp _ty) =
  fail "Singling of annotated expressions not yet supported"
singExp _ _vars (RecConE _name _fields) =
  fail "Singling of record construction not yet supported"
singExp _ _vars (RecUpdE _exp _fields) =
  fail "Singling of record updates not yet supported"

singLit :: Quasi q => Lit -> q Exp
singLit lit = SigE (VarE singMethName) <$> (AppT singFamily <$> (promoteLit_ lit))
