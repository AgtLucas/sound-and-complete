{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies, DeriveGeneric, DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE FlexibleContexts #-}

module Types where

import Overture 

import Data.Sequence (Seq)
import qualified Data.Sequence as S
import GHC.Exts (IsList)

--
-- Representations of types and terms for algorithmic typing.
--

newtype Var   = Sym   Text deriving (Show, Ord, Eq, Generic, Data)

newtype UnVar = UnSym Text deriving (Show, Ord, Eq, Generic, Data)
newtype ExVar = ExSym Text deriving (Show, Ord, Eq, Generic, Data)

-- | Subtyping polarity
data Polarity = Positive | Negative | Nonpolar deriving (Show, Ord, Eq, Generic, Data)

-- | Expressions
data Expr
  = EpVar   Var
  | EpUnit
  | EpLam   Var   Expr
  | EpRec   Var   Expr
  | EpApp   Expr  Spine
  | EpAnn   Expr  Ty
  | EpProd  Expr  Expr
  | EpInj   Inj   Expr
  | EpCase  Expr  Alts
  | EpVec   (Vec Expr)
  deriving (Eq, Generic, Data)

instance Plated Expr 

data Inj = InjL | InjR
  deriving (Show, Ord, Eq, Generic, Data)

pattern EpInjL :: Expr -> Expr
pattern EpInjL e = EpInj InjL e

pattern EpInjR :: Expr -> Expr
pattern EpInjR e = EpInj InjR e

newtype Spine = Spine [Expr]
  deriving (Eq, Generic, Data, IsList)

newtype Alts = Alts [Branch]
  deriving (Eq, Generic, Data, IsList)

-- | Patterns
data Pat
  = PatWild  -- not shown in Figure 1
  | PatUnit  -- not shown in Figure 1
  | PatVar   Var
  | PatProd  Pat   Pat
  | PatInj   Inj   Pat
  | PatVec   (Vec Pat)
  deriving (Eq, Generic, Data)

data Branch = Branch [Pat] Expr
  deriving (Eq, Generic, Data)

data Binop    = OpArrow | OpSum | OpProd    deriving (Show, Ord, Eq, Generic, Data)
data Nat      = Zero    | Succ Nat          deriving (Show, Ord, Eq, Generic, Data)

newtype Vec  a  = Vec [a]         deriving (Show, Ord, Eq, Generic, Data, IsList)

deriving instance Functor Vec 
deriving instance Foldable Vec 
instance AsEmpty (Vec a) where
  _Empty = prism' (const Nil) (\case
    Nil -> Just ()
    _ -> Nothing)

pattern Nil <- Vec []
  where Nil = Vec []

pattern Cons x xs = Vec (x : xs)

-- | Terms
data Tm
  = TmUnit
  | TmUnVar   UnVar
  | TmExVar   ExVar
  | TmBinop   Tm Binop Tm
  | TmNat     Nat
  | TmVec     (Vec Expr)
  deriving (Eq, Generic, Data)

pattern TmSum :: Tm -> Tm -> Tm
pattern TmSum l r = TmBinop l OpSum r

pattern TmProd :: Tm -> Tm -> Tm
pattern TmProd l r = TmBinop l OpProd r

pattern TmArrow :: Tm -> Tm -> Tm
pattern TmArrow l r = TmBinop l OpArrow r

instance Plated Tm

instance HasTerms Tm where
  terms f = 
    \case
      TmBinop a op b -> TmBinop <$> terms f a <*> pure op <*> terms f b
      -- TmVec ty -> TmVec <$> terms f n <*> terms f ty
      o -> pure o

class HasTerms a where
  terms :: Traversal' a Tm

-- | Propositions (equality constraints)
data Prop = Equation Tm Tm
  deriving (Eq, Generic, Data)

instance HasTerms Prop where
  terms f (Equation x y) = Equation <$> f x <*> f y

data Sort  = Star | Nat
  deriving (Eq, Generic, Data)

-- | Types
data Ty
  = TyUnit
  | TyUnVar   UnVar
  | TyExVar   ExVar
  | TyArrow   Ty    Ty
  | TySum     Ty    Ty
  | TyProd    Ty    Ty
  | TyForall  UnVar Sort Ty
  | TyExists  UnVar Sort Ty
  | TyImplies Prop  Ty
  | TyWith    Ty    Prop
  | TyVec     Tm   Ty
  deriving (Eq, Generic, Data)

instance Plated Ty

instance HasTerms Ty where
  terms f = 
    \case
      TyForall u s ty -> TyForall <$> pure u <*> pure s <*> terms f ty
      TyExists u s ty -> TyExists <$> pure u <*> pure s <*> terms f ty
      TyBinop a op b -> TyBinop <$> terms f a <*> pure op <*> terms f b
      TyImplies eq ty -> TyImplies <$> terms f eq <*> terms f ty
      TyWith ty eq -> TyWith <$> terms f ty <*> terms f eq
      TyVec n ty -> TyVec <$> terms f n <*> terms f ty
      o -> pure o

pattern TyBinop :: Ty -> Binop -> Ty -> Ty
pattern TyBinop left op right <- (binopOfType -> Just (left, op, right))
  where TyBinop = binopType

binopOfType :: Ty -> Maybe (Ty, Binop, Ty)
binopOfType (TyArrow a b) = Just (a, OpArrow, b)
binopOfType (TySum   a b) = Just (a, OpSum,   b)
binopOfType (TyProd  a b) = Just (a, OpProd,  b)
binopOfType _             = Nothing

binopType :: Ty -> Binop -> Ty -> Ty
binopType a OpArrow b = TyArrow a b
binopType a OpSum   b = TySum a b
binopType a OpProd  b = TyProd a b

-- | Principalities.
data Prin 
  = Bang  -- ^ principal
  | Slash -- ^ nonprincipal
  deriving (Eq)

-- | Elements of the context, representing units of knowledge
-- possessed by the typechecker.
data Fact
  -- sort judgments
  = FcUnSort   UnVar Sort
  | FcExSort   ExVar Sort
  -- equality judgments
  | FcUnEq     UnVar      Tm
  | FcExEq     ExVar Sort Tm
  -- markers
  | FcUnMark   UnVar
  | FcExMark   ExVar
  | FcPropMark Prop
  -- variable types (with principality)
  | FcVarTy    Var   Ty   Prin
  deriving (Eq)

data VarSort = Univ | Extl

pattern FcMark v s <- (markOfFact -> Just (v, s))
  where FcMark = markFact

markOfFact (FcUnMark (UnSym s)) = Just (Univ, s)
markOfFact (FcExMark (ExSym s)) = Just (Extl, s)
markOfFact _                    = Nothing

markFact Univ s = FcUnMark (UnSym s)
markFact Extl s = FcExMark (ExSym s)

sortOfFact (FcUnSort (UnSym s) _) = Just (Univ, s)
sortOfFact (FcExSort (ExSym s) _) = Just (Extl, s)
sortOfFact _                      = Nothing

newtype TcCtx = TcCtx (Seq Fact)
  deriving (Monoid, Semigroup)

-- | A possibly-inconsistent context
-- This is isomorphic to Maybe TcCtx.
data PICtx
  = ConCtx TcCtx
  -- ^ A consistent context.
  | Bottom
  -- ^ Inconsistency.

(|>) :: TcCtx -> Fact -> TcCtx
TcCtx c |> f = TcCtx (c S.|> f)

data JudgmentItem
  = JCtx TcCtx
  | JPrin Prin
  | JExpr Expr
  | JTy Ty
  | JTm Tm
  | JAlts Alts
  | JJudgN Text
  | JRuleN RuleName
  | Pre PreData
  | JMatchedRule Rule
  | JMsg Judgment Text
  | Post PostData

data PreData
  = PreTypeWF TcCtx Ty
  | PreInfer TcCtx Expr
  | PreCheck TcCtx Expr Ty Prin
  | PreSpine TcCtx Spine Ty Prin
  | PreSpineRecover TcCtx Spine Ty Prin
  | PreMatch TcCtx Alts [Ty] Ty Prin
  | PreElimeq TcCtx Tm Tm Sort
  | PreSubtype TcCtx Polarity Ty Ty

data PostData
  = PostCheck TcCtx
  | PostInfer Ty Prin TcCtx
  | PostSpine Ty Prin TcCtx
  | PostSpineRecover Ty Prin TcCtx
  | PostMatch TcCtx
  | PostElimeq PICtx
  | PostSubtype TcCtx

newtype RuleName = RuleName Text

data Rule
  = RuleCheck CheckRule
  | RuleInfer InferRule
  | RuleSpine SpineRule
  | RuleSpineRecover SpineRecoverRule
  | RuleMatch MatchRule
  | RuleMatchAssuming MatchAssumingRule
  | RuleElimeq ElimeqRule
  | RuleSubtype SubtypeRule
  | RuleFail Judgment

data SpineRule
  = REmptySpine 
  | RArrowSpine 
  | RForallSpine 
  | RImpliesSpine
  deriving Show

data SpineRecoverRule 
  = RSpinePass 
  | RSpineRecover 
  deriving Show

data CheckRule 
  = RUnitIntro
  | RUnitIntro_Extl 
  | RForallIntro 
  | RArrowIntro 
  | RArrowIntro_Extl
  | RProdIntro
  | RProdIntro_Extl
  | RSumIntro Inj
  | RSumIntro_Extl Inj
  | RCase 
  | RRec
  | RSub
  deriving Show

data InferRule 
  = RVar 
  | RArrowE 
  | RAnno
  deriving Show

data MatchRule
  = RMatchEmpty
  | RMatchSeq 
  | RMatchBase 
  | RMatchUnit
  | RMatchExists
  | RMatchWith
  | RMatchProd
  | RMatchInj Inj
  | RMatchNeg
  | RMatchWild
  | RMatchNil 
  | RMatchCons
  deriving Show

data MatchAssumingRule
  = RMatchBottom
  | RMatchUnify
  deriving Show

data ElimeqRule
  = RElimeqUVarRefl
  | RElimeqZero
  | RElimeqSucc
  | RElimeqUvarL
  | RElimeqUvarR
  | RElimeqUvarLBottom
  | RElimeqUvarRBottom
  | RElimeqUnit
  | RElimeqBin
  | RElimeqBinBot
  | RElimeqClash
  deriving Show

data SubtypeRule
  = REquiv
  | RForallL 
  | RExistsL 
  | RMinusPlusL 
  | RPlusMinusL
  | RForallR 
  | RExistsR 
  | RMinusPlusR 
  | RPlusMinusR
  deriving Show

data Tree a = Leaf a | Rose [Tree a]

data LogItem a = LogItem { _logItem_depth :: Int, _logItem_message :: a }

data Judgment
  = JInfer
  | JCheck
  | JSpine
  | JSpineRecover 
  | JMatch 
  | JMatchAssuming
  | JTypeWF
  | JElimeq
  | JSubtype
  deriving Show
