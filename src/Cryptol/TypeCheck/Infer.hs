-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2014 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Assumes that the `NoPat` pass has been run.

{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
#if __GLASGOW_HASKELL__ >= 706
{-# LANGUAGE RecursiveDo #-}
#else
{-# LANGUAGE DoRec, RecursiveDo #-}
#endif
{-# LANGUAGE Safe #-}
module Cryptol.TypeCheck.Infer where

import           Cryptol.Prims.Syntax(ECon(..))
import           Cryptol.Prims.Types(typeOf)
import           Cryptol.Parser.Position
import qualified Cryptol.Parser.AST as P
import qualified Cryptol.Parser.Names as P
import           Cryptol.TypeCheck.AST
import           Cryptol.TypeCheck.Monad
import           Cryptol.TypeCheck.Solve
import           Cryptol.TypeCheck.Kind(checkType,checkSchema,checkTySyn,
                                          checkNewtype)
import           Cryptol.TypeCheck.Instantiate
import           Cryptol.TypeCheck.Depends
import           Cryptol.TypeCheck.Subst (listSubst,apSubst,fvs,(@@))
import           Cryptol.TypeCheck.Solver.FinOrd(noFacts,OrdFacts)
import           Cryptol.TypeCheck.Solver.Eval(simpType)
import           Cryptol.TypeCheck.Solver.InfNat(genLog)
import           Cryptol.TypeCheck.Defaulting(tryDefault)
import           Cryptol.Utils.Panic(panic)
import           Cryptol.Utils.PP

import qualified Data.Map as Map
import           Data.Map (Map)
import qualified Data.Set as Set
import           Data.Either(partitionEithers)
import           Data.Maybe(mapMaybe)
import           Data.List(partition)
import           Data.Graph(SCC(..))
import           Data.Traversable(forM)
import           Control.Monad(when,zipWithM)

-- import Cryptol.Utils.Debug

inferModule :: P.Module -> InferM Module
inferModule m =
  inferDs (P.mDecls m) $ \ds1 ->
    do simplifyAllConstraints
       ts <- getTSyns
       nts <- getNewtypes
       return Module { mName    = thing (P.mName m)
                     , mExports = P.modExports m
                     , mImports = map thing (P.mImports m)
                     , mTySyns  = Map.mapMaybe onlyLocal ts
                     , mNewtypes = Map.mapMaybe onlyLocal nts
                     , mDecls   = ds1
                     }
  where
  onlyLocal (IsLocal, x)    = Just x
  onlyLocal (IsExternal, _) = Nothing

desugarLiteral :: Bool -> P.Literal -> InferM P.Expr
desugarLiteral fixDec lit =
  do l <- curRange
     let named (x,y)  = P.NamedInst
                        P.Named { name = Located l (Name x), value = P.TNum y }
         demote fs    = P.EAppT (P.ECon ECDemote) (map named fs)

     return $ case lit of

       P.ECNum num info ->
         demote $ [ ("val", num) ] ++ case info of
           P.BinLit n    -> [ ("bits", 1 * toInteger n) ]
           P.OctLit n    -> [ ("bits", 3 * toInteger n) ]
           P.HexLit n    -> [ ("bits", 4 * toInteger n) ]
           P.CharLit     -> [ ("bits", 8 :: Integer) ]
           P.DecLit
            | fixDec     -> if num == 0
                              then [ ("bits", 0)]
                              else case genLog num 2 of
                                     Just (x,_) -> [ ("bits", x + 1) ]
                                     _          -> []
            | otherwise  -> [ ]
           P.PolyLit _n  -> [ ]

       P.ECString s ->
          P.ETyped (P.EList [ P.ELit (P.ECNum (fromIntegral (fromEnum c))
                            P.CharLit) | c <- s ])
                   (P.TSeq P.TWild (P.TSeq (P.TNum 8) P.TBit))


-- | Infer the type of an expression with an explicit instantiation.
appTys :: P.Expr -> [Located (Maybe QName,Type)] -> InferM (Expr, Type)
appTys expr ts =
  case expr of
    P.EVar x ->
      do res <- lookupVar x
         case res of
           ExtVar s   -> instantiateWith (EVar x) s ts
           CurSCC e t -> instantiateWith e (Forall [] [] t) ts

    P.ELit l -> do e <- desugarLiteral False l
                   appTys e ts

    P.ECon ec -> let s1 = typeOf ec
                 in instantiateWith (ECon ec) s1 ts

    P.EAppT e fs ->
      do ps <- mapM inferTyParam fs
         appTys e (ps ++ ts)

    -- Here is an example of why this might be useful:
    -- f ` { x = T } where type T = ...
    P.EWhere e ds ->
      inferDs ds $ \ds1 -> do (e1,t1) <- appTys e ts
                              return (EWhere e1 ds1, t1)
         -- XXX: Is there a scoping issue here?  I think not, but check.

    P.ELocated e r ->
      inRange r (appTys e ts)

    P.ETuple    {} -> mono
    P.ERecord   {} -> mono
    P.ESel      {} -> mono
    P.EList     {} -> mono
    P.EFromTo   {} -> mono
    P.EComp     {} -> mono
    P.EApp      {} -> mono
    P.EIf       {} -> mono
    P.ETyped    {} -> mono
    P.ETypeVal  {} -> mono
    P.EFun      {} -> mono

  where mono = do (e',t) <- inferE expr
                  instantiateWith e' (Forall [] [] t) ts


inferTyParam :: P.TypeInst -> InferM (Located (Maybe QName, Type))
inferTyParam (P.NamedInst param) =
  do let loc = srcRange (P.name param)
     t <- inRange loc $ checkType (P.value param) Nothing
     return $ Located loc (Just (mkUnqual (thing (P.name param))), t)

inferTyParam (P.PosInst param) =
  do t   <- checkType param Nothing
     rng <- case getLoc param of
              Nothing -> curRange
              Just r  -> return r
     return Located { srcRange = rng, thing = (Nothing, t) }

checkTypeOfKind :: P.Type -> Kind -> InferM Type
checkTypeOfKind ty k = checkType ty (Just k)


-- | We use this when we want to ensure that the expr has exactly
-- (syntactically) the given type.
checkE :: P.Expr -> Type -> InferM Expr
checkE e tGoal =
  do (e1,t) <- inferE e
     checkHasType e1 t tGoal

-- | Infer the type of an expression, and translate it to a fully elaborated
-- core term.
inferE :: P.Expr -> InferM (Expr, Type)
inferE expr =
  case expr of
    P.EVar x ->
      do res <- lookupVar x
         case res of
           ExtVar s   -> instantiateWith (EVar x) s []
           CurSCC e t -> return (e, t)

    P.ELit l -> inferE =<< desugarLiteral False l

    P.ECon ec -> let s1 = typeOf ec
                 in instantiateWith (ECon ec) s1 []

    P.ETuple es ->
      do (es',ts') <- unzip `fmap` mapM inferE es
         return (ETuple es', tTuple ts')

    P.ERecord fs ->
      do (xs,es,ts) <- fmap unzip3 $ forM fs $ \f ->
            do (e',t) <- inferE (P.value f)
               return (thing (P.name f), e', t)
         return (ERec (zip xs es), tRec (zip xs ts))

    P.ESel e l ->
      do (e',t) <- inferE e
         let src = case l of
                     RecordSel x _ -> text "type of field" <+> quotes (pp x)
                     TupleSel x _  -> text "type of" <+> ordinal x
                                                     <+> text "tuple field"
                     ListSel _ _   -> text "type of sequence element"
         b <- newType src KType
         f <- newHasGoal l t b
         return (f e', b)

    P.EList [] ->
      do a <- newType (text "element type of empty sequence") KType
         return (EList [] a, tSeq (tNum (0::Int)) a)

    P.EList (e:es) ->
      do (e',t) <- inferE e
         es'    <- mapM (`checkE` t) es
         let n = length (e':es')
         return (EList (e':es') t, tSeq (tNum n) t)

    P.EFromTo t1 Nothing Nothing ->
      do rng <- curRange
         bit <- newType (text "bit-width of enumeration sequnce") KNum
         fstT <- checkTypeOfKind t1 KNum
         let totLen = tNum (2::Int) .^. bit
             lstT   = totLen .-. tNum (1::Int)

         appTys (P.ECon ECFromTo)
           [ Located rng (Just (mkUnqual (Name x)), y)
           | (x,y) <- [ ("first",fstT), ("last", lstT), ("bits", bit) ]
           ]

    P.EFromTo t1 mbt2 mbt3 ->
      do l <- curRange
         let (c,fs) =
               case (mbt2, mbt3) of

                 (Nothing, Nothing) -> tcPanic "inferE"
                                        [ "EFromTo _ Nothing Nothing" ]
                 (Just t2, Nothing) ->
                    (ECFromThen, [ ("next", t2) ])

                 (Nothing, Just t3) ->
                    (ECFromTo, [ ("last", t3) ])

                 (Just t2, Just t3) ->
                    (ECFromThenTo, [ ("next",t2), ("last",t3) ])


         inferE $ P.EAppT (P.ECon c)
                [ P.NamedInst P.Named { name = Located l (Name x), value = y }
                | (x,y) <- ("first",t1) : fs
                ]

    P.EComp e mss ->
      do (mss', dss, ts) <- unzip3 `fmap` zipWithM inferCArm [ 1 .. ] mss
         w      <- smallest ts
         ds     <- combineMaps dss
         (e',t) <- withMonoTypes ds (inferE e)
         let ty = tSeq w t
         return (EComp ty e' mss', ty)

    P.EAppT e fs ->
      appTys e =<< mapM inferTyParam fs

    P.EApp fun@(dropLoc -> P.EApp (dropLoc -> P.ECon c) _)
           arg@(dropLoc -> P.ELit l)
      | c `elem` [ ECShiftL, ECShiftR, ECRotL, ECRotR, ECAt, ECAtBack ] ->
        do newArg <- do l1 <- desugarLiteral True l
                        return $ case arg of
                                   P.ELocated _ pos -> P.ELocated l1 pos
                                   _ -> l1
           inferE (P.EApp fun newArg)

    P.EApp e1 e2 ->
      do (e2',t1) <- inferE e2
         tR <- newType (text "result of function application") KType
         e1' <- checkE e1 (tFun t1 tR)
         return (EApp e1' e2', tR)

    P.EIf e1 e2 e3 ->
      do e1'      <- checkE e1 tBit
         (e2',tR) <- inferE e2
         e3'      <- checkE e3 tR
         return (EIf e1' e2' e3', tR)

    P.EWhere e ds ->
      inferDs ds $ \ds1 -> do (e1,ty) <- inferE e
                              return (EWhere e1 ds1, ty)

    P.ETyped e t ->
      do tSig <- checkTypeOfKind t KType
         e1   <- checkE e tSig
         return (e1,tSig)

    P.ETypeVal t ->
      do l <- curRange
         inferE (P.EAppT (P.ECon ECDemote)
                  [P.NamedInst
                   P.Named { name = Located l (Name "val"), value = t }])

    P.EFun ps e -> inferFun (text "anonymous function") ps e

    P.ELocated e r  -> inRange r (inferE e)



checkHasType :: Expr -> Type -> Type -> InferM Expr
checkHasType e inferredType givenType =
  do ps <- unify givenType inferredType
     case ps of
       [] -> return e
       _  -> newGoals CtExactType ps >> return (ECast e givenType)


checkFun :: P.LQName -> [P.Pattern] -> P.Expr -> Type -> InferM Expr
checkFun name ps e tGoal =
  do (e1,t) <- inferFun fun ps e
     checkHasType e1 t tGoal
  where
  fun = pp (thing name)

-- | Infer the type of a function.  This is in a separate function
-- because it is used in multiple places (expressions, bindings)
inferFun :: Doc -> [P.Pattern] -> P.Expr -> InferM (Expr, Type)
inferFun _ [] e = inferE e
inferFun desc ps e =
  inNewScope $
  do let descs = [ text "type of" <+> ordinal n <+> text "argument"
                     <+> text "of" <+> desc
                                                      | n <- [ 1 :: Int .. ] ]
     largs     <- zipWithM inferP descs ps
     ds        <- combine largs
     (e1,tRes) <- withMonoTypes ds (inferE e)
     let args = [ (x, thing t) | (x,t) <- largs ]
         ty   = foldr tFun tRes (map snd args)
     return (foldr (\(x,t) b -> EAbs x t b) e1 args, ty)


{-| The type the is the smallest of all -}
smallest :: [Type] -> InferM Type
smallest []   = newType (text "length of list comprehension") KNum
smallest [t]  = return t
smallest ts   = do a <- newType (text "length of list comprehension") KNum
                   newGoals CtComprehension [ a =#= foldr1 tMin ts ]
                   return a


checkP :: Doc -> P.Pattern -> Type -> InferM (Located QName)
checkP desc p tGoal =
  do (x, t) <- inferP desc p
     ps <- unify tGoal (thing t)
     case ps of
       [] -> return (Located (srcRange t) x)
       _  -> tcPanic "checkP" [ "Unexpected constraints:", show ps ]

{-| Infer the type of a pattern.  Assumes that the pattern will be just
a variable. -}
inferP :: Doc -> P.Pattern -> InferM (QName, Located Type)
inferP desc pat =
  case pat of

    P.PVar x0 ->
      do a   <- newType desc KType
         let x = thing x0
         return (mkUnqual x, x0 { thing = a })

    P.PTyped p t ->
      do tSig <- checkTypeOfKind t KType
         ln   <- checkP desc p tSig
         return (thing ln, ln { thing = tSig })

    _ -> tcPanic "inferP" [ "Unexpected pattern:", show pat ]



-- | Infer the type of one match in a list comprehension.
inferMatch :: P.Match -> InferM (Match, QName, Located Type, Type)
inferMatch (P.Match p e) =
  do (x,t) <- inferP (text "XXX:MATCH") p
     n     <- newType (text "sequence length of comprehension match") KNum
     e'    <- checkE e (tSeq n (thing t))
     return (From x (thing t) e', x, t, n)

inferMatch (P.MatchLet b)
  | P.bMono b =
  do a <- newType (text "`let` binding in comprehension") KType
     b1 <- checkMonoB b a
     return (Let b1, dName b1, Located (srcRange (P.bName b)) a, tNum (1::Int))

  | otherwise = tcPanic "inferMatch"
                      [ "Unexpected polymorphic match let:", show b ]

-- | Infer the type of one arm of a list comprehension.
inferCArm :: Int -> [P.Match] -> InferM
              ( [Match]
              , Map QName (Located Type)-- defined vars
              , Type                    -- length of sequence
              )

inferCArm _ [] = do n <- newType (text "lenght of empty comprehension") KNum
                                                    -- shouldn't really happen
                    return ([], Map.empty, n)
inferCArm _ [m] =
  do (m1, x, t, n) <- inferMatch m
     return ([m1], Map.singleton x t, n)

inferCArm armNum (m : ms) =
  do (m1, x, t, n)  <- inferMatch m
     (ms', ds, n') <- withMonoType (x,t) (inferCArm armNum ms)
     -- XXX: Well, this is just the lenght of this sub-sequence
     let src = text "length of" <+> ordinal armNum <+>
                                  text "arm of list comprehension"
     sz <- newType src KNum
     newGoals CtComprehension [ sz =#= (n .*. n') ]
     return (m1 : ms', Map.insertWith (\_ old -> old) x t ds, sz)


inferBinds :: Bool -> [P.Bind] -> InferM [Decl]
inferBinds isRec binds =
  mdo let exprMap = Map.fromList [ (x,inst (EVar x) (dDefinition b))
                                 | b <- genBs, let x = dName b ] -- REC.

          inst e (ETAbs x e1)     = inst (ETApp e (TVar (tpVar x))) e1
          inst e (EProofAbs _ e1) = inst (EProofApp e) e1
          inst e _                = e




      ((doneBs, genCandidates), cs) <-
        collectGoals $

        {- Guess type is here, because while we check user supplied signatures
           we may generate additional constraints. For example, `x - y` would
           generate an additional constraint `x >= y`. -}
        do (newEnv,todos) <- unzip `fmap` mapM (guessType exprMap) binds
           let extEnv = if isRec then withVarTypes newEnv else id

           extEnv $
             do let (sigsAndMonos,noSigGen) = partitionEithers todos
                genCs <- sequence noSigGen
                done  <- sequence sigsAndMonos
                simplifyAllConstraints
                return (done, genCs)
      genBs <- generalize genCandidates cs -- RECURSION
      return (doneBs ++ genBs)


{- | Come up with a type for recursive calls to a function, and decide
     how we are going to be checking the binding.
     Returns: (Name, type or schema, computation to check binding)

     The `exprMap` is a thunk where we can lookup the final expressions
     and we should be careful not to force it.
-}
guessType :: Map QName Expr -> P.Bind ->
              InferM ( (QName, VarType)
                     , Either (InferM Decl)    -- no generalization
                              (InferM Decl)    -- generalize these
                     )
guessType exprMap b@(P.Bind { .. }) =
  case bSignature of

    Just s ->
      do s1 <- checkSchema s
         return ((name, ExtVar (fst s1)), Left (checkSigB b s1))

    Nothing
      | bMono ->
         do t <- newType (text "defintion of" <+> quotes (pp name)) KType
            let schema = Forall [] [] t
            return ((name, ExtVar schema), Left (checkMonoB b t))

      | otherwise ->

        do t <- newType (text "definition of" <+> quotes (pp name)) KType
           let noWay = tcPanic "guessType" [ "Missing expression for:" ,
                                                                show name ]
               expr  = Map.findWithDefault noWay name exprMap

           return ((name, CurSCC expr t), Right (checkMonoB b t))
  where
  name = thing bName


-- | Try to evaluate the inferred type of a mono-binding
simpMonoBind :: OrdFacts -> Decl -> Decl
simpMonoBind m d =
  case dSignature d of
    Forall [] [] t ->
      let t1 = simpType m t
      in if t == t1 then d else d { dSignature  = Forall [] [] t1
                                  , dDefinition = ECast (dDefinition d) t1
                                  }
    _ -> d


-- | The inputs should be declarations with monomorphic types
-- (i.e., of the form `Forall [] [] t`).
generalize :: [Decl] -> [Goal] -> InferM [Decl]

{- This may happen because we have monomorphic bindings.
In this case we may get some goal, due to the monomorphic bindings,
but the group of components is empty. -}
generalize [] gs0 =
  do addGoals gs0
     return []


generalize bs0 gs0 =
  do gs <- forM gs0 $ \g -> applySubst g

     -- XXX: Why would these bindings have signatures??
     bs1 <- forM bs0 $ \b -> do s <- applySubst (dSignature b)
                                return b { dSignature = s }

     ordM <- case assumedOrderModel noFacts (map goal gs) of
                Left (ordModel,p) ->
                  do mapM_ recordError
                            [ UnusableFunction n p | n <- map dName bs1]
                     return ordModel
                Right (ordModel,_) -> return ordModel

     let bs = map (simpMonoBind ordM) bs1

     let goalFVS g  = Set.filter isFreeTV $ fvs $ goal g
         inGoals    = Set.unions $ map goalFVS gs
         inSigs     = Set.filter isFreeTV $ fvs $ map dSignature bs
         candidates = Set.union inGoals inSigs


     asmpVs <- varsWithAsmps



     let gen0          = Set.difference candidates asmpVs
         stays g       = any (`Set.member` gen0) $ Set.toList $ goalFVS g
         (here0,later) = partition stays gs

     -- Figure our what might be ambigious
     let (maybeAmbig, ambig) = partition ((KNum ==) . kindOf)
                             $ Set.toList
                             $ Set.difference gen0 inSigs

     when (not (null ambig)) $ recordError $ AmbiguousType $ map dName bs

     let (as0,here1,defSu,ws) = tryDefault maybeAmbig here0
     mapM_ recordWarning ws
     let here = map goal here1

     let as     = as0 ++ Set.toList (Set.difference inSigs asmpVs)
         asPs   = [ TParam { tpUnique = x, tpKind = k, tpName = Nothing }
                                                   | TVFree x k _ _ <- as ]
     totSu <- getSubst
     let
         su     = listSubst (zip as (map (TVar . tpVar) asPs)) @@ defSu @@ totSu
         qs     = map (apSubst su) here

         genE e = foldr ETAbs (foldr EProofAbs (apSubst su e) qs) asPs
         genB d = d { dDefinition = genE (dDefinition d)
                    , dSignature  = Forall asPs qs
                                  $ apSubst su $ sType $ dSignature d
                    }

     addGoals later
     return (map genB bs)




checkMonoB :: P.Bind -> Type -> InferM Decl
checkMonoB b t =
  inRangeMb (getLoc b) $
  do e1 <- checkFun (P.bName b) (P.bParams b) (P.bDef b) t
     let f = thing (P.bName b)
     return Decl { dName = f
                 , dSignature = Forall [] [] t
                 , dDefinition = e1
                 , dPragmas = P.bPragmas b
                 }

-- XXX: Do we really need to do the defaulting business in two different places?
checkSigB :: P.Bind -> (Schema,[Goal]) -> InferM Decl
checkSigB b (Forall as asmps0 t0, validSchema) =
  inRangeMb (getLoc b) $
  withTParams as $
  do (e1,cs0) <- collectGoals $
                do e1 <- checkFun (P.bName b) (P.bParams b) (P.bDef b) t0
                   () <- simplifyAllConstraints  -- XXX: using `asmps` also...
                   return e1
     cs <- applySubst cs0

     let letGo qs c  = Set.null (qs `Set.intersection` fvs (goal c))

         splitPreds qs n ps =
           let (l,n1) = partition (letGo qs) ps
           in if null n1
                then (l,n)
                else splitPreds (fvs (map goal n1) `Set.union` qs) (n1 ++ n) l

         (later0,now) = splitPreds (Set.fromList (map tpVar as)) [] cs

     asmps1 <- applySubst asmps0

     defSu1 <- proveImplication (P.bName b) as asmps1 (validSchema ++ now)
     let later = apSubst defSu1 later0
         asmps = apSubst defSu1 asmps1

     -- Now we check for any remaining variables that are not mentioned
     -- in the environment.  The plan is to try to default these to something
     -- reasonable.
     do let laterVs = fvs (map goal later)
        asmpVs <- varsWithAsmps
        let genVs   = laterVs `Set.difference` asmpVs
            (maybeAmbig,ambig) = partition ((== KNum) . kindOf)
                                           (Set.toList genVs)
        when (not (null ambig)) $ recordError
                                $ AmbiguousType [ thing (P.bName b) ]

        let (_,_,defSu2,ws) = tryDefault maybeAmbig later
        mapM_ recordWarning ws
        extendSubst defSu2

     addGoals later

     su <- getSubst
     let su' = defSu1 @@ su
         t   = apSubst su' t0
         e2  = apSubst su' e1

     return Decl
        { dName       = thing (P.bName b)
        , dSignature  = Forall as asmps t
        , dDefinition = foldr ETAbs (foldr EProofAbs e2 asmps) as
        , dPragmas    = P.bPragmas b
        }

inferDs :: FromDecl d => [d] -> ([DeclGroup] -> InferM a) -> InferM a
inferDs ds continue = checkTyDecls =<< orderTyDecls (mapMaybe toTyDecl ds)
  where
  checkTyDecls (TS t : ts) =
    do t1 <- checkTySyn t
       withTySyn t1 (checkTyDecls ts)

  checkTyDecls (NT t : ts) =
    do t1 <- checkNewtype t
       withNewtype t1 (checkTyDecls ts)

  -- We checked all type synonyms, now continue with value-level definitions:
  checkTyDecls [] = checkBinds [] $ orderBinds $ mapMaybe toBind ds


  checkBinds decls (CyclicSCC bs : more) =
     do bs1 <- inferBinds True bs
        foldr (\b m -> withVar (dName b) (dSignature b) m)
              (checkBinds (Recursive bs1 : decls) more)
              bs1

  checkBinds decls (AcyclicSCC c : more) =
    do [b] <- inferBinds False [c]
       withVar (dName b) (dSignature b) $
         checkBinds (NonRecursive b : decls) more

  -- We are done with all value-level definitions.
  -- Now continue with anything that's in scope of the declarations.
  checkBinds decls [] = continue (reverse decls)


tcPanic :: String -> [String] -> a
tcPanic l msg = panic ("[TypeCheck] " ++ l) msg


