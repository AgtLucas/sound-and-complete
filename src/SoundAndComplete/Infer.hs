{-# OPTIONS_GHC -Wall -Wno-deprecations -Wno-unused-matches -Wno-unused-local-binds #-}
-- for now ^^^
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell #-}

module SoundAndComplete.Infer where

--------------------------------------------------------------------------------
-- [Glossary]
--
-- WT: "working theory", what I think something does
--
--------------------------------------------------------------------------------
-- [Links]
--
-- 1. "Sound and Complete", "current paper", "sequel", "DK 2016"
--
--    Dunfield and Krishnaswami 2016, "Sound and Complete Bidirectional
--    Typechecking for Higher-rank Polymorphism and Indexed Types".
--    Link: <https://www.cl.cam.ac.uk/~nk480/bidir.pdf>
--
-- 2. "Complete and Easy", "original paper", "DK 2013"
--
--    Dunfield and Krishnaswami 2013, "Complete and Easy Bidirectional
--    Typechecking for Higher-rank Polymorphism".
--    <https://arxiv.org/pdf/1601.05106.pdf>
--
--------------------------------------------------------------------------------
-- [Notes]
--
-- 1. Even () cannot synthesize its own type:
--
--    >>> typecheck (infer (Ctx S.Empty) EpUnit)
--
--    fails. We need to add a synthesis rule for it, mimicking the one from
--    Complete and Easy.
--
--    >>> typecheck (check (Ctx S.Empty) EpUnit TyUnit Slash)

import Overture hiding (set, pred, sum, un, op, (|>), left, right, (<+>))

import Data.Sequence (Seq, pattern (:|>))
import qualified Data.Sequence as S

import qualified Data.Text.Lazy as T

import SoundAndComplete.Types

import Safe

--
-- Typechecker environments
--

-- | Typechecker state
data TcState  = TcState
  { -- _tcState_context :: Ctx,
    _tcState_fresh_counter :: Int
  }
   deriving (Show, Eq)

initialContext :: Ctx
initialContext = Ctx S.empty

initialState :: TcState
initialState = TcState 1

-- | Typechecker configuration
data TcConfig = TcConfig { }
  deriving (Show, Eq)

initialConfig :: TcConfig
initialConfig = TcConfig

-- | Like @MonadReader@'s @local@, but for @State@.
slocal :: MonadState s m => (s -> s) -> m a -> m a
slocal f ma = do
  oldState <- get
  modify f
  res <- ma
  put oldState
  pure res

-- | The typechecking monad.

newtype TcM a
  = TcM { runTcM :: ExceptT Text
                      (ReaderT TcConfig
                        (WriterT' [Text]
                          (State TcState))) a }
  deriving newtype
   ( Functor
   , Applicative
   , Monad
   , MonadError  Text
   , MonadReader TcConfig
   , MonadWriter [Text]
   , MonadState  TcState
   )

-- lctx :: Lens' TcState (Seq Fact)
-- lctx = lens (\(_tcState_context -> Ctx c) -> c) (\t c -> t { _tcState_context = Ctx c })

counter :: Lens' TcState Int
counter = lens _tcState_fresh_counter (\t c -> t { _tcState_fresh_counter = c })

typecheck :: Show a => TcM a -> IO ()
typecheck action = do
  case result of
    Left err -> do
      putTextLn "Error while typechecking: "
      putTextLn err
    Right res -> do
      putTextLn "Typechecked successfully; result: "
      print res

  putTextLn ""

  putTextLn "Typechecker log:"
  traverse_ putTextLn tcLog

  putTextLn ""

  putTextLn "Final typechecker state:"
  print finalState

  putTextLn "Done.\n---"

  where
    ((result, tcLog), finalState)
      = action
      & runTcM
      & runExceptT
      & (runReaderT ?? initialConfig)
      & runWriterT'
      & (runState ?? initialState)

-- | Filter a context for a fact that satisfies a predicate.
factWith :: (Fact -> Bool) -> Ctx -> Maybe Fact
factWith pred (Ctx s)
  = s
  & S.filter pred
  & toList
  & headMay

-- | Search the context for a fact that solves an existential variable, and
-- return the sort contained in the fact.
solvedExVarSort :: Ctx -> ExVar -> Maybe Sort
solvedExVarSort ctx ex
  | Just (FcExEq _ sort _) <- factWith (solvedExVarSort' ex) ctx
  = Just sort
  | otherwise = Nothing
  where
    solvedExVarSort' e1 (FcExEq e2 _ _) = e1 == e2
    solvedExVarSort' _   _              = False

-- | Search the context for a fact that tells what sort an existential variable
-- has.
exVarSort :: Ctx -> ExVar -> Maybe Sort
exVarSort ctx ex
  | Just (FcExSort _ sort) <- factWith (exVarSort' ex) ctx
  = Just sort
  | otherwise = Nothing
  where
    exVarSort' e1 (FcExSort e2 _) = e1 == e2
    exVarSort' _   _              = False

-- | Search the context for a fact that tells what sort a universal variable
-- has.
unVarSort :: Ctx -> UnVar -> Maybe Sort
unVarSort ctx un
  | Just (FcUnSort _ sort) <- factWith (unVarSort' un) ctx
  = Just sort
  | otherwise = Nothing
  where
    unVarSort' e1 (FcUnSort e2 _) = e1 == e2
    unVarSort' _   _              = False

-- | Given a context, find the sort of a monotype.
--
-- Note [TmNat sort-checking]
--------------------------------------------------------------------------------
-- For the TmNat branch, we know the sort "by type" since
-- my embedding of TmZero and TmSucc as TmNat Nat gives
-- us this for free. :)

termSort :: Ctx -> Tm -> TcM Sort
termSort ctx = \case

  ------------------------------------------------------------------------------
  -- [Rule: ZeroSort] and [Rule: SuccSort]
  ------------------------------------------------------------------------------

  TmNat _ -> pure Nat

  ------------------------------------------------------------------------------
  -- [Rule: UnitSort]
  --
  -- Unit is a *-sorted type.
  ------------------------------------------------------------------------------

  TmUnit -> pure Star

  ------------------------------------------------------------------------------
  -- [Rule: BinSort]
  ------------------------------------------------------------------------------

  TmBinop l _ r
    -> do lsort <- termSort ctx l
          rsort <- termSort ctx r
          case (lsort, rsort) of
            (Star, Star) -> pure Star
            _ -> throwError "lol"

  ------------------------------------------------------------------------------
  -- [Rule: VarSort] (universal variable case)
  ------------------------------------------------------------------------------

  TmUnVar un -> do
    case unVarSort ctx un of
      Just s -> pure s
      _ -> throwError "boom"

  TmExVar ex -> do

  -- Now we're trying to find what sort an existential variable has. There are
  -- two kinds of fact our context can contain that tell us this:

  ------------------------------------------------------------------------------
  -- [Rule: VarSort] (existential variable case)
  --
  -- This is an FcExSort judgment.
  ------------------------------------------------------------------------------

    case exVarSort ctx ex of
      Just sort -> pure sort

  ------------------------------------------------------------------------------
  -- [Rule: SolvedVarSort]
  --
  -- The other is an FcExEq judgment.
  --
  -- This is the case where the existential variable has actually been "solved"
  -- to some other type, so we can get the sort from there.
  ------------------------------------------------------------------------------

      _ -> case solvedExVarSort ctx ex of
             Just sort -> pure sort
             _ -> unimplemented

  _ -> throwError "This shouldn't happen"

-- | Check if a proposition is well-formed in a context.
propWF :: Ctx -> Prop -> TcM Bool
propWF ctx (Equation a b) = do

  ------------------------------------------------------------------------------
  -- [Rule: EqProp]
  ------------------------------------------------------------------------------

  sa <- termSort ctx a
  sb <- termSort ctx b
  case sa of
    Nat -> case sb of
      Nat -> pure True
      _ -> throwError "lol"
    _ -> throwError "lol"

typeWF :: Ctx -> Ty -> TcM Bool
typeWF ctx ty

  -- [Rule: VarWF] (universal case)

  | TyUnVar un <- ty
  = do
      sun <- termSort ctx (TmUnVar un)
      case sun of
        Star -> pure True
        _ -> throwError "lol"

  -- [Rule: VarWF] (existential case)
  -- and
  -- [Rule: SolvedVarWF]

  | TyExVar ex <- ty
  = do
      termSort ctx (TmExVar ex) >>= \case
        Star -> pure True
        _ -> throwError "lol"

  -- [Rule: UnitWF]

  | TyUnit <- ty
  = pure True

  ------------------------------------------------------------------------------
  -- [Rule: BinWF]
  --
  -- A type with a binary connective joining two types is well-formed if both
  -- components are.
  ------------------------------------------------------------------------------

  | TyBinop a _ b <- ty
  = do
      awf <- typeWF ctx a
      bwf <- typeWF ctx b
      pure (awf && bwf)

  ------------------------------------------------------------------------------
  -- [Rule: ForallWF]
  --
  -- Add a fact to the context that says what sort a forall's "variable" has,
  -- and check the "body" of the forall in this new context.
  ------------------------------------------------------------------------------

  | TyForall alpha kappa a <- ty
  = typeWF (ctx |> FcUnSort alpha kappa) a

  ------------------------------------------------------------------------------
  -- [Rule: ExistsWF]
  --
  -- Add a fact to the context that says what sort an existential type's
  -- "variable" has, and check the "body" in this new context.
  ------------------------------------------------------------------------------

  | TyExists alpha kappa a <- ty
  = typeWF (ctx |> FcUnSort alpha kappa) a

  ------------------------------------------------------------------------------
  -- [Rule: ImpliesWF]
  --
  -- An implies-type is well-formed if both the proposition and the type it
  -- comprises are.
  ------------------------------------------------------------------------------

  | TyImplies pr a <- ty
  = liftA2 (&&) (propWF ctx pr) (typeWF ctx a)

  ------------------------------------------------------------------------------
  -- [Rule: WithWF]
  --
  -- Ditto: a with-type is well-formed if both the proposition and the type it
  -- comprises are.
  ------------------------------------------------------------------------------

  | TyWith a pr <- ty
  = liftA2 (&&) (propWF ctx pr) (typeWF ctx a)

  | otherwise
  = unimplemented

prinTypeWF :: Ctx -> Ty -> Prin -> Bool
prinTypeWF = unimplemented

ctxWF :: Ctx -> Bool
ctxWF (Ctx s)

  ------------------------------------------------------------------------------
  -- [Rule: EmptyCtx]
  ------------------------------------------------------------------------------

  | S.Empty <- s
  = True

  ------------------------------------------------------------------------------
  -- [Rule: MarkerCtx]
  ------------------------------------------------------------------------------

  | s' :|> m@(FcMark {}) <- s
  , m `notElem` s'
  = True

  | otherwise
  = False

checkedIntroForm :: Expr -> Bool
checkedIntroForm = \case
  EpUnit   -> True
  EpLam{}  -> True
  EpProd{} -> True
  EpInj{}  -> True
  EpVec{}  -> True
  _        -> False

-- | The notation from the paper, for the sake of completeness.
-- Prefer 'checkedIntroForm'.
chkI :: Expr -> Bool
chkI = checkedIntroForm

-- | Substitute a context into a type.
substituteCtx :: Ctx -> Ty -> Ty
substituteCtx ctx = transformOn terms subTm 
-- \case
--   TyUnVar un -> unimplemented
--   TyExVar ex -> unimplemented
--   TyUnit -> TyUnit
--   TyBinop l op r -> TyBinop (sub l) op (sub r)
--   TyWith typ (Equation a b)
--     -> TyWith (sub typ) (Equation (subTm a) (subTm b))
--   TyImplies (Equation a b) typ
--     -> TyImplies (Equation (subTm a) (subTm b)) (sub typ)
--   TyForall un sort typ -> TyForall un sort (sub typ)
--   TyExists un sort typ -> TyExists un sort (sub typ)
  -- _ -> unimplemented
  -- TODO implement hole substitution

  where
    -- sub :: Ty -> Ty
    -- sub   = substituteCtx   ctx

    subTm :: Tm -> Tm
    subTm = substituteCtxTm ctx

-- | Substitute a context into a term or monotype.
substituteCtxTm :: Ctx -> Tm -> Tm
substituteCtxTm = unimplemented

-- | Assume a hypothesis is true in a given context, and return either an
-- updated context or (in case the context becomes inconsistent) @Bottom@.
assumeHypo :: Ctx -> Prop -> PICtx
assumeHypo = unimplemented

checkProp :: Ctx -> Prop -> Ctx
checkProp = unimplemented

-- | Check that two monotypes are equal, possibly modifying the
-- context.
checkEq :: Ctx -> Tm -> Tm -> Ctx
checkEq = unimplemented

-- | Unify two terms or monotypes, taking context ctx = \Gamma to
-- either a modified context \Delta or inconsistency.
unify :: Ctx -> Tm -> Tm -> TcM (Maybe Sort, PICtx)
unify ctx a b

  -- [Rule: ElimeqUVarRefl]

  | TmUnVar{} <- a
  , a == b
  = do sort <- termSort ctx a
       pure (Just sort, ConCtx ctx)

  -- [Rule: ElimeqUnit]

  | TmUnit <- a
  , TmUnit <- b
  = pure (Just Star, ConCtx ctx)

  -- [Rule: ElimeqZero]

  | TmNat Zero <- a
  , TmNat Zero <- b
  = pure (Just Nat, ConCtx ctx)

  -- [Rule: ElimeqSucc]

  | TmNat (Succ sigma) <- a
  , TmNat (Succ tau)   <- b
  = do
      (sort, ctx')   <- unify ctx (TmNat sigma) (TmNat tau)
      case sort of
        Just Nat -> pure (Just Nat, ConCtx ctx)
        _ -> throwError "lol"

  -- [Rule: ElimeqClash]

  | headConClash a b
  = pure (Nothing, Bottom)

  | otherwise
  = unimplemented

headConClash :: Tm -> Tm -> Bool
headConClash a b
  | TmNat  Zero    <- a
  , TmNat (Succ _) <- b
  = True

  | TmNat (Succ _) <- a
  , TmNat  Zero    <- b
  = True

  | TmBinop{} <- a
  , TmUnit <- b
  = True

  | TmUnit <- a
  , TmBinop{} <- b
  = True

  | TmBinop _ op1 _ <- a
  , TmBinop _ op2 _ <- b
  = op1 /= op2

  | otherwise
  = False

-- | Check two propositions for equivalence.
propEquiv :: Ctx -> Prop -> Prop -> (Ctx, Bool)
propEquiv = unimplemented

-- | Check two types for equivalence.
typeEquiv :: Ctx -> Ty -> Ty -> (Ctx, Bool)
typeEquiv = unimplemented

-- | Given a context and a polarity p, check if a type is a p-subtype of
-- another.
checkSubtype :: Ctx -> Polarity -> Ty -> Ty -> Ctx
checkSubtype ctx p a b = unimplemented

-- | Instantiate an existential variable.
instExVar :: Ctx -> ExVar -> Tm -> Sort -> Ctx
instExVar = unimplemented

-- | Try to find a fact in the context that tells us what type and principality
-- a variable has, or, failing that, return Nothing.
varTyPrin :: Ctx -> Var -> Maybe (Ty, Prin)
varTyPrin ctx ex
  | Just (FcVarTy _ ty prin) <- factWith (varTyPrin' ex) ctx
  = Just (ty, prin)
  | otherwise = Nothing
  where
    varTyPrin' e1 (FcVarTy e2 _ _) = e1 == e2
    varTyPrin' _   _              = False

-- | Try to find a fact in the context. If this succeeds, create a "hole" and
-- return an ordered pair of the pieces of the context to the left and the
-- piece to the right.
hole :: Fact -> Ctx -> Maybe (Ctx, Ctx)
hole mem (Ctx ctx)
  | mem `notElem` ctx = Nothing
  | (left, r) <- S.breakl (== mem) ctx
  , right     <- S.drop 1 r
  = Just (Ctx left, Ctx right)

-- | Given two contexts and a fact, join them up, with the fact in the middle.
fill :: Ctx -> Fact -> Ctx -> Ctx
fill (Ctx l) f (Ctx r) = Ctx ((l S.|> f) <> r)

-- | Find the "polarity" of a type. Polarities are mainly (only?) used for the
-- subtyping judgment.
polarity :: Ty -> Polarity
polarity = unimplemented

-- | Turn A into [a^/a]A -- or, as I like to think of
-- it, A[a -> a^], read "A with a going to a^".
--
-- Reading a^ out loud is left as an exercise for the intrepid reader.
existentializeTy
  :: UnVar -- A
  -> Ty    -- a^
  -> Ty    -- [a^/a] A
existentializeTy u1@(UnSym sym) ty =
  case ty of
    TyUnVar u2
      | u1 == u2     -> TyExVar (ExSym sym)
    TyBinop l op r   -> TyBinop (extlTy l) op (extlTy r)
    TyForall un s a  -> TyForall un s (extlTy a)
    TyExists un s a  -> TyExists un s (extlTy a)
    TyImplies prop a -> TyImplies prop (extlTy a)
    TyWith a prop    -> TyWith (extlTy a) prop
    _ -> ty

  where extlTy = existentializeTy u1

-- | Does what it says on the tin. This is used by exactly one algorithmic
-- typing rule.
notACase :: Expr -> Bool
notACase = \case
  EpCase {} -> False
  _         -> True

--------------------------------------------------------------------------------
-- Pretty-printing
--------------------------------------------------------------------------------

pprUnVar :: UnVar -> Text
pprUnVar (UnSym s) = s <> "^"

pprExVar :: ExVar -> Text
pprExVar (ExSym s) = s <> "^"

(<+>) a b = a <> " " <> b

pprTy :: Ty -> Text
pprTy = \case
  TyUnit -> "Unit"
  TyUnVar un -> pprUnVar un
  TyExVar ex -> pprExVar ex
  TyBinop l op r  -> pprTy l <+> pprBin op <+> pprTy r
  TyForall s sort ty -> "∀" <> pprUnVar s <> ". " <> pprTy ty
  ty -> tshow ty

pprTm :: Tm -> Text
pprTm = \case
  TmUnit -> "Unit"
  TmUnVar un -> pprUnVar un
  TmExVar ex -> pprExVar ex
  TmBinop l op r  -> pprTm l <+> pprBin op <+> pprTm r
  tm -> tshow tm

pprBin :: Binop -> Text
pprBin OpArrow = "->"
pprBin OpSum = "+"
pprBin OpProd = "×"

pprSort :: Sort -> Text
pprSort = tshow

pprFact' :: Fact -> Text
pprFact' = \case
  FcUnSort un sort -> pprUnVar un <> " : " <> pprSort sort
  FcExSort ex sort -> pprExVar ex <> " : " <> pprSort sort
  FcUnEq un tm -> pprUnVar un <> " = " <> pprTm tm
  FcExEq ex sort tm ->
    pprExVar ex <> " : " <> pprSort sort <> " = " <> pprTm tm
  FcUnMark un -> "▶" <> pprUnVar un
  FcExMark ex -> "▶" <> pprExVar ex
  FcPropMark prop -> "▶" <> pprProp prop
  FcVarTy var ty prin -> pprVar var <> " : " <> pprTy ty <+> pprPrin prin

pprFact :: Fact -> Text
pprFact f = "[" <> pprFact' f <> "]"

pprVar :: Var -> Text
pprVar (Sym s) = s

pprExpr :: Expr -> Text
pprExpr = \case
  EpVar var -> pprVar var
  EpUnit -> "Unit"
  EpLam var e -> "λ" <> pprVar var <> ". "  <> pprExpr e
  EpAnn e ty -> pprExpr e <> " : " <> pprTy ty
  e -> tshow e

pprPrin :: Prin -> Text
pprPrin Bang = "!"
pprPrin Slash = "?"

pprCtx :: Ctx -> Text
pprCtx (Ctx s) = s & toList & map pprFact & T.unwords

pprProp :: Prop -> Text
pprProp (Equation a b) = "<" <> pprTm a <> " = " <> pprTm b <> ">"

tell' :: Text -> TcM ()
tell' x = tell [x]

-- | The type-checking wrapper function. For now, this just logs a bit of
-- data and calls out to the *real* type-checking function.
check :: Ctx -> Expr -> Ty -> Prin -> TcM Ctx
check ctx ep ty prin = do
  tell [""]
  tell ["Checking "]
  tell ["expression: " <> pprExpr ep]
  tell ["against type: " <> pprTy ty]
  tell ["with principality: " <> pprPrin prin]
  tell ["in context: " <> pprCtx ctx]
  check' ctx ep ty prin

-- | The function that actually does all the type-checking.
check'
  :: Ctx      -- ^ context representing knowledge before attempting the typecheck
  -> Expr     -- ^ expression to be checked
  -> Ty       -- ^ type to be checked against
  -> Prin     -- ^ are we claiming the type is principal?
  -> TcM Ctx  -- ^ an updated context, representing what we know after said attempt

check' ctx ep ty prin

  ------------------------------------------------------------------------------
  -- [Rule: UnitIntro]
  --
  -- Introduction form for checking () against the Unit type.
  ------------------------------------------------------------------------------

  | EpUnit <- ep
  , TyUnit <- ty
  = do
      tell' "UnitIntro"
      pure ctx

  ------------------------------------------------------------------------------
  -- [Rule: UnitIntro-Extl]
  --
  -- Introduction form for checking () against an unknown type.
  ------------------------------------------------------------------------------

  | EpUnit      <- ep
  , TyExVar ex  <- ty
  , Just (l, r) <- hole (FcExSort ex Star) ctx
  = do tell' "UnitIntro-Extl"
       pure (fill l (FcExEq ex Star TmUnit) r)

  ------------------------------------------------------------------------------
  -- [Rule: WithIntro]
  --
  -- A With form is only valid if the proposition `prop` attached to the type
  -- `a` is true in the current context.  On encountering one, we
  --
  --   1. check if the proposition is true in the current context `ctx`,
  --
  -- which gives us an updated context `theta` with possibly-new information.
  -- We then
  --
  --   2. update the type by substituting this context in, and
  --   3. check the expression against this updated type.
  ------------------------------------------------------------------------------

  | notACase ep
  , TyWith a prop <- ty
  , theta         <- checkProp ctx prop -- 1.
  = do tell' "WithIntro"
       let ty' = substituteCtx theta a  -- 2.
       check theta ep ty' prin          -- 3.

  ------------------------------------------------------------------------------
  -- [Rule: ForallIntro]
  --
  -- α : κ => alpha : k
  -- ν     => nu
  -- A     => a
  ------------------------------------------------------------------------------

  | nu <- ep
  , checkedIntroForm nu
  , TyForall alpha k a  <- ty
  , alpha'k             <- FcUnSort alpha k
  = do tell' "ForallIntro"
       ctx' <- check (ctx |> alpha'k) nu a prin
       let Just (delta, theta) = hole alpha'k ctx'
       pure delta

  -----------------------------------------------------------------------------
  -- ImpliesIntro* rules
  --
  -- These match "implies" types. We are given a proposition (which is roughly
  -- an equality between two monotypes, similar to Haskell's a ~ b) and a type.
  --
  -- To check an expression against a type of this form, we
  --
  --   1. incorporate the proposition into what we already know, the context
  --      `ctx`
  --   2. see whether it remains consistent or not:
  --   3. if it does, we get an updated context `theta` in which to evaluate
  --      the type-check, so we incorporate this new knowledge into the type
  --      and recheck accordingly
  --   4. if not, check whether the expression we're checking is a "checked
  --      intro form". if it isn't, bail (TODO: why?)
  -----------------------------------------------------------------------------

  | nu <- ep
  , TyImplies prop a     <- ty
  , Bang                 <- prin
  , markP                <- FcPropMark prop
  = let ctx' = assumeHypo (ctx |> markP) prop in  -- 1.
    case ctx' of                                  -- 2.

  -----------------------------------------------------------------------------
  -- [Rule: ImpliesIntro]
  --
  -- Our assumption of the hypothesis left our context consistent (i.e. it
  -- broke nothing), so we continue with the extra knowledge it gave us.
  -----------------------------------------------------------------------------

      ConCtx theta -> do -- 3.
         outputCtx <- check theta nu (substituteCtx theta a) Bang
         tell' "ImpliesIntro"
         case hole markP outputCtx of
           Just (delta, delta') -> do
             pure delta
           Nothing -> throwError "lol"

  -----------------------------------------------------------------------------
  -- [Rule: ImpliesIntroBottom]
  --
  -- The hypothesis implied an inconsistency in the context!
  -- This is checked, among other things, by seeing if we have a
  -- head-constructor clash (using @headConClash@, the implementation of the
  -- #-judgment from the paper), which is why I guess we need
  -- @checkedIntroForm@ here.
  -----------------------------------------------------------------------------

      Bottom | checkedIntroForm nu -> do -- 4.
             tell' "ImpliesIntroBottom"
             pure ctx
      _ -> do
        throwError "lol"

  -----------------------------------------------------------------------------
  -- [Rule: ArrowIntro]
  --
  -- xap => x : A p
  -----------------------------------------------------------------------------

  | p                   <- prin
  , EpLam x e           <- ep
  , TyArrow a b         <- ty
  , xap                 <- FcVarTy x a p
  = do
      tell' "ArrowIntro"
      out <- check (ctx |> xap) e b p
      case hole xap out of
        Just (delta, theta) -> pure delta
        _ -> throwError "lol"

  -----------------------------------------------------------------------------
  -- [Rule: ArrowIntro-Extl]
  --
  -- WT: using Slash because unspecified principality.
  -----------------------------------------------------------------------------

  | p                    <- Slash
  , EpLam x e            <- ep
  , TyExVar ex@a'        <- ty
  , Just Star            <- exVarSort ctx ex
  , Just (left, right)   <- hole (FcExSort ex Star) ctx
  = do
      tell' "ArrowIntro-Extl"
      a'1 <- freshEx
      a'2 <- freshEx

      let xa'1  = FcVarTy x (TyExVar a'1) Slash
          a'eq  = FcExEq a' Star (TmArrow (TmExVar a'1) (TmExVar a'2))
          a'1s  = FcExSort a'1 Star
          a'2s  = FcExSort a'2 Star
          ctx'  = left <> Ctx [a'1s, a'2s, a'eq] <> right
          ctx'' = ctx' |> xa'1

      out <- check ctx'' e (TyExVar a'2) Slash
      case hole xa'1 out of
        Just (delta, _) -> pure delta
        _ -> throwError "lol"

  -----------------------------------------------------------------------------
  -- SumIntroₖ
  --
  -- Introduction form for checking a sum expression against a sum type.
  --
  -- We match on the head constructor of the type, deferring the "which
  -- side am I injecting into" check to a case statement.
  -----------------------------------------------------------------------------

  | EpInj inj e     <- ep
  , TySum a1 a2     <- ty
  = case inj of
      InjL -> check ctx e a1 prin
      InjR -> check ctx e a2 prin

  ------------------------------------------------------------------------------
  -- [Rule: SumIntro-Extlₖ]
  --
  -- Introduction form for checking a sum expression against an unknown type.
  ------------------------------------------------------------------------------

  | EpInj inj e <- ep
  , TyExVar a'  <- ty
  = unimplemented

  -- TODO
  -- should we add, e.g. an EpInj case here that catches everything falling
  -- through? or is there a legitimate reason for sum expressions to fall
  -- to other cases? (subtyping is the last rule, remember)

  ------------------------------------------------------------------------------
  -- [Rule: ProdIntro]
  --
  -- Introduction form for known product types.
  ------------------------------------------------------------------------------

  | EpProd e1 e2    <- ep
  , TyProd a1 a2    <- ty
  = do tell' "ProdIntro"
       theta <- check ctx   e1 a1 prin
       check theta e2 (substituteCtx theta a2) prin

  ------------------------------------------------------------------------------
  -- [Rule: ProdIntro-Extl]
  --
  -- Introduction form for unsolved-for product types.
  ------------------------------------------------------------------------------

  | p                    <- Slash
  , EpProd e1 e2         <- ep
  , TyExVar ex@a'        <- ty
  , Just Star            <- exVarSort ctx ex
  , Just (left, right)   <- hole (FcExSort ex Star) ctx
  = do
      tell' "ProdIntro-Extl"
      a'1 <- freshEx
      a'2 <- freshEx

      let a'eq  = FcExEq a' Star (TmExVar a'1 `TmArrow` TmExVar a'2)
          a'1s  = FcExSort a'1 Star
          a'2s  = FcExSort a'2 Star
          ctx'  = left <> Ctx [a'1s, a'2s, a'eq] <> right

      delta <- check ctx' ep (TyExVar a'1) Slash
      pure delta

  ------------------------------------------------------------------------------
  -- [Rule: Case]
  --
  -- Case expressions, which are pattern vectors with bodies of some given type.
  ------------------------------------------------------------------------------

  ------------------------------------------------------------------------------
  -- [Rule: Sub]
  --
  -- Subtype checking.
  --
  -- This does not take the principality @prin@ supplied to @check@ into account
  -- since p is left free in [Rule: Sub] in the paper.
  --
  -- I've moved this rule to the end since it doesn't really match on either
  -- the expression or the type, so other things should "fall through" to this.
  ------------------------------------------------------------------------------

  | e <- ep
  , b <- ty
  , polB <- polarity b
  = do tell' "Sub"
       (a, q, theta) <- infer ctx e
       pure (checkSubtype theta polB a b)

  | otherwise
  = throwError "this shouldn't happen"

-- | Given a context and an expression, infer its type, a principality for it,
-- and an updated context.
infer :: Ctx -> Expr -> TcM (Ty, Prin, Ctx)
infer ctx ep = case ep of

  ------------------------------------------------------------------------------
  -- [Rule: Var]
  --
  -- Variable expressions (e.g. the "x" in \x -> body).
  --
  -- These can have their types inferred if the context contains an FcVarTy fact
  -- that tells us its type (principality included).
  ------------------------------------------------------------------------------

  EpVar var | Just (ty, prin) <- varTyPrin ctx var
    -> pure (substituteCtx ctx ty, prin, ctx)

  ------------------------------------------------------------------------------
  -- [Rule: Anno]
  --
  -- Type-annotated expressions.
  --
  -- The type is inferred by checking the type of the expression against the
  -- annotation.
  ------------------------------------------------------------------------------

  EpAnn e a | prinTypeWF ctx a Bang
    -> do delta <- check ctx e (substituteCtx ctx a) Bang
          pure (substituteCtx delta a, Bang, delta)

  ------------------------------------------------------------------------------
  -- [Rule: ArrowE]
  --
  -- Infer the type of a spine application, recovering principality where
  -- possible.
  ------------------------------------------------------------------------------

  EpApp e spine | Spine [_] <- spine
    -> do (a, p, theta) <- infer ctx e
          (c, q, delta) <- inferSpineRecover theta spine a p
          pure (c, q, delta)


  _ -> throwError "infer: impossible"

freshHint :: Text -> TcM Text
freshHint hint = do
  n <- counter <+= 1
  pure (hint <> tshow n)

fresh :: TcM Text
fresh = freshHint "a"

freshEx :: TcM ExVar
freshEx = ExSym <$> fresh

-- | The free existential variables in a type.
freeExtls :: Ty -> [ExVar]
freeExtls = unimplemented

-- | A synonym for @freeExtls@ matching the notation from the paper.
fev :: Ty -> [ExVar]
fev = freeExtls

noFreeExtls :: Ty -> Bool
noFreeExtls = null . freeExtls

hasFreeExtls :: Ty -> Bool
hasFreeExtls = not . noFreeExtls

unToEx :: UnVar -> ExVar
unToEx (UnSym sym) = ExSym sym

exToUn :: ExVar -> UnVar
exToUn (ExSym sym) = UnSym sym

-- | Infer the type of a spine application. This form does not attempt to
-- recover principality in the synthesized type.
--
-- I read the output (C, q, Δ) as "q-type C with output context Δ".
--
-- For example,
-- (Bang, TyUnit, Ctx Empty) = "the principal type () with empty output context"

inferSpine
  :: Ctx        -- ^ input context
  -> Spine      -- ^ spine being applied upon (ugh)
  -> Ty         -- ^ type of expression applied to the spine
  -> Prin       -- ^ principality of aforesaid expression
  -> TcM ( Ty   --   inferred type of application
         , Prin --   inferred principality of application
         , Ctx  --   output context
         )      -- ^ judgment

inferSpine ctx sp ty p

  ------------------------------------------------------------------------------
  -- [Rule: ForallSpine]
  --
  -- The principality is omitted in the "top" rule (the not-consequent), so per
  -- the "sometimes omitted" note in [Figure: Syntax of declarative types and
  -- constructs], I'm assuming that means it's nonprincipal.
  ------------------------------------------------------------------------------

  | TyForall alpha k a <- ty
  , Spine (e : s)      <- sp
  , alpha'             <- unToEx alpha
  = do (c, q, delta)   <- inferSpine (ctx |> FcExSort alpha' k) sp
                                     (existentializeTy alpha a) Slash
       pure (c, q, delta)

  ------------------------------------------------------------------------------
  -- [Rule: ImpliesSpine]
  --
  -- In context Γ, applying e to a spine of type P ⊃ A synthesizes (C, q, Δ)
  -- if Γ tells us that the proposition P holds. (WT)
  --
  -- Questions:
  -- Are we matching on sp to check that the spine is nonempty?
  ------------------------------------------------------------------------------

  | TyImplies prop a <- ty
  , Spine (e : s) <- sp
  , theta <- checkProp ctx prop
  = do (c, q, delta) <- inferSpine theta sp (substituteCtx theta a) p
       pure (c, q, delta)

  ------------------------------------------------------------------------------
  -- [Rule: EmptySpine]
  --
  -- Applying an expression to an empty spine is trivial.
  -- Return everything unchanged.
  ------------------------------------------------------------------------------

  | Spine [] <- sp
  = pure (ty, p, ctx)

  ------------------------------------------------------------------------------
  -- [Rule: ArrowSpine]
  --
  -- I think this is the main function type-inferring judgment.
  ------------------------------------------------------------------------------

  | TyArrow a b <- ty
  , Spine (e : s') <- sp
  , s <- Spine s'
  = do -- match the "function" against the input type a
       theta <- check ctx e a p
       -- match the "argument" against the output type b
       (c, q, delta) <- inferSpine theta s (substituteCtx theta b) p
       pure (c, q, delta)

  ------------------------------------------------------------------------------
  -- [Rule: Spine-Extl]
  ------------------------------------------------------------------------------

  | TyExVar ex <- ty
  , Spine (e : s') <- sp
  = unimplemented

  | otherwise
  = unimplemented

-- | Infer the type of a spine application. Additionally, this form
-- attempts to recover principality in the output type.

inferSpineRecover :: Ctx -> Spine -> Ty -> Prin -> TcM (Ty, Prin, Ctx)
inferSpineRecover ctx s a p = do

  ------------------------------------------------------------------------------
  -- [Rule: SpineRecover]
  --
  -- Upgrade a suitable nonprincipal type with no free existential
  -- tyvars into a principal type.
  ------------------------------------------------------------------------------

  res1 <- inferSpine ctx s a Bang
  case res1 of
    (c, Slash, delta) | noFreeExtls c -> pure (c, Bang, delta)
    _ -> do

  ------------------------------------------------------------------------------
  -- [Rule: SpinePass]
  --
  -- WT: guessing "pass" is for "pass the principality inferred by
  -- inferSpine through"
  ------------------------------------------------------------------------------

      res2 <- inferSpine ctx s a p
      case res2 of
        res@(c, q, delta)
          | p == Slash || q == Bang || hasFreeExtls c
          -> pure res
        _ -> throwError "is this even possible?"

checkBranches :: Ctx -> Alts -> [Ty] -> Ty -> Prin -> Ctx
checkBranches = unimplemented

--------------------------------------------------------------------------------
-- [Coverage checking]
--
-- The paper has two coverage-checking judgments:
--
-- 1. Γ   ⊢ Π covers [A..]
-- 2. Γ/P ⊢ Π covers [A..]
--
-- which are implemented and explained in @coverageCheck@ and
-- @coverageCheckAssuming@ respectively. See the documentation for those to
-- know what they do.
--------------------------------------------------------------------------------

-- | This implements the first of the two coverage-checking judgments, written
--
--   Γ   ⊢ Π covers [A..]
--
-- in the paper. This means that, in context Γ, the patterns Π cover the
-- types in [A..].

coverageCheck :: Ctx -> Alts -> [Ty] -> Bool
coverageCheck ctx alts tys

  ------------------------------------------------------------------------------
  -- [Rule: CoversEmpty]
  ------------------------------------------------------------------------------

  | [] <- tys
  , Alts (Branch [] e : _) <- alts
  = True

  ------------------------------------------------------------------------------
  -- [Rule: CoversVar]
  ------------------------------------------------------------------------------

  ------------------------------------------------------------------------------
  -- [Rule: CoversUnit]
  ------------------------------------------------------------------------------

  ------------------------------------------------------------------------------
  -- [Rule: CoversProd]
  ------------------------------------------------------------------------------

  ------------------------------------------------------------------------------
  -- [Rule: CoversSum]
  ------------------------------------------------------------------------------

  ------------------------------------------------------------------------------
  -- [Rule: CoversExists]
  ------------------------------------------------------------------------------

  | otherwise
  = unimplemented

-- | This implements the second of the two coverage-checking judgments, which
-- takes a proposition into account.
--
--   Γ/P ⊢ Π covers [A..]
--
-- This means that, in context Γ, the patterns Π cover the types in [A..]
-- assuming the proposition P.

coverageCheckAssuming :: Ctx -> Prop -> Alts -> [Ty] -> Bool
coverageCheckAssuming ctx prop alts tys

  ------------------------------------------------------------------------------
  -- [Rule: CoversEq]
  ------------------------------------------------------------------------------

  ------------------------------------------------------------------------------
  -- [Rule: CoversEqBot]
  ------------------------------------------------------------------------------

  | otherwise
  = unimplemented

lam :: Text -> Expr -> Expr
lam v = EpLam (Sym v)

ann :: Expr -> Ty -> Expr
ann = EpAnn

tyUniv :: Text -> Ty
tyUniv s = TyUnVar (UnSym s)

tyExtl :: Text -> Ty
tyExtl s = TyExVar (ExSym s)

ty_unit_to_unit :: Ty
ty_unit_to_unit = TyUnit `TyArrow` TyUnit

