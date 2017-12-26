{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE NoImplicitPrelude    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Pretty where

import           Overture                                  hiding ((<+>))

import           Types

import Data.Text.Prettyprint.Doc (pretty, Doc, backslash, dot, pipe)
import          qualified Data.Text.Prettyprint.Doc as P
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Text.Prettyprint.Doc.Util            (putDocW)

import qualified Data.Text.Lazy                            as TL
import qualified Data.Text.Lazy.IO                         as TL

import           Control.Monad.Reader
import Data.String

type Out = Doc AnsiStyle
type OutM = PprM Out

liftOutM :: (Foldable t) => ([a] -> b) -> t (PprM a) -> PprM b
liftOutM f = map f . sequence . toList

vsep :: Foldable f => f OutM -> OutM
vsep = liftOutM P.vsep

vcat :: Foldable f => f OutM -> OutM
vcat = liftOutM P.vcat

group :: OutM -> OutM
group = map P.group

annotate = map . P.annotate

parens = map P.parens
angles = map P.angles
brackets = map P.brackets

braces :: OutM -> OutM
braces = map P.braces

align = map P.align
indent = map . P.indent

hsep = liftOutM P.hsep
sep = liftOutM P.sep

punctuate :: OutM -> PprM [Out] -> PprM [Out]
punctuate p os = P.punctuate <$> p <*> os

(<+>) = liftA2 (P.<+>)

globalIndentWidth :: Int
globalIndentWidth = 2

data PprEnv = PprEnv { _pprEnv_precedence :: Int }

precedence :: Lens' PprEnv Int
precedence = lens _pprEnv_precedence (\e prec -> e { _pprEnv_precedence = prec })

newtype PprM a = PprM { unPprM :: PprEnv -> a }
  deriving (Functor, Applicative, Monad, MonadReader PprEnv, Semigroup)

runPprM :: PprM a -> a
runPprM f = unPprM f iEnv
  where iEnv = PprEnv (-1)

assoc :: Int -> PprM a -> PprM a
assoc p = local (precedence .~ p)

class AnsiPretty a where
  -- | Pretty-print a value. The default implementation
  -- omits surrounding parens.
  ppr :: a -> Out
  ppr = runPprM . pprM

  pprM :: a -> OutM
  pprM = pure . ppr

wrapOn :: Bool -> (PprM a -> PprM a) -> PprM a -> PprM a
wrapOn c f = if c then f else id
{-# INLINE wrapOn #-}

above :: (PprM a -> PprM a) -> Int -> PprM a -> PprM a
above f p m = do
  outerPrec <- view precedence
  wrapOn (outerPrec >>> p) f (assoc (p + 1) m)

nowrap :: PprM a -> PprM a
nowrap = assoc (-1)

instance (a ~ Out) => IsString (PprM a) where fromString = pure . fromString

instance AnsiPretty Expr where pprM = pprExprM
instance AnsiPretty Alts where pprM = pprAltsM
instance AnsiPretty Tm where pprM = pprTmM
instance AnsiPretty Ty where pprM = pprTyM
instance AnsiPretty (Ty,Prin) where pprM = pprTyWithPrinM
instance AnsiPretty Nat where pprM = pprNatM
instance AnsiPretty Branch where pprM = pprBranchM
instance AnsiPretty Prin where pprM = pprPrinM
instance AnsiPretty Prop where pprM = pprPropM
instance AnsiPretty Sort where pprM = pprSortM
instance AnsiPretty Fact where pprM = pprFactM
instance AnsiPretty Spine where pprM = pprSpineM
instance AnsiPretty Ctx where pprM = pprCtxM
instance AnsiPretty Pat where pprM = pprPatM
instance AnsiPretty a => AnsiPretty (Vec a) where pprM = pprVecM
instance AnsiPretty Var   where pprM = pprVarM
instance AnsiPretty ExVar where pprM = pprExVarM
instance AnsiPretty UnVar where pprM = pprUnVarM
instance AnsiPretty Binop where pprM = pprBinM
instance AnsiPretty Polarity where pprM = pprPolarityM
instance AnsiPretty Text  where pprM = pure . pretty

a <-> b = vsep [a, b]
a <@> b = vcat [a, b]

id :: a -> a
id x = x

fmtSort = annotate (color Blue)

fmtUnVar :: OutM -> OutM
fmtUnVar = map (P.annotate (color Yellow))

fmtExVar = annotate (color Magenta)
fmtVar = id
fmtPrin = id
fmtPolarity = id
fmtBinop = id
fmtTy = id
fmtTm = id
fmtNat = id
fmtCtx = id
fmtPat = id
fmtPatWild = id
fmtExpr = id

fmtKw = annotate (color Green <> bold)
fmtRec = fmtKw
fmtMatch = fmtKw

fmtSynSym = annotate (color Green <> bold)
fmtAltPipe = fmtSynSym
fmtOrPatPipe = fmtSynSym
fmtLam = fmtSynSym
fmtLamArrow = fmtSynSym
fmtCaseArrow = fmtSynSym

fmtQuantifier = annotate (color Yellow)

pprPolarityM :: Polarity -> OutM
pprPolarityM = fmtPolarity . \case
  Positive -> "+"
  Negative -> "-"
  Nonpolar -> "0"

pprBinM :: Binop -> OutM
pprBinM = fmtBinop . \case
  OpArrow -> "->"
  OpSum   -> "+"
  OpProd  -> "×"

pprUnVarM :: UnVar -> OutM
pprUnVarM (UnSym s) = fmtUnVar (pprM s)

pprExVarM :: ExVar -> OutM
pprExVarM (ExSym s) = fmtExVar (pprM s <> "^")

pprVarM :: Var -> OutM
pprVarM (Sym s) = fmtVar (pprM s)

pprPrinM :: Prin -> OutM
pprPrinM = fmtPrin . \case
  Bang  -> "!"
  Slash -> "?"

pprTyWithPrinM :: (Ty, Prin) -> OutM
pprTyWithPrinM (ty, p) = parens (pprM p) <+> "" <> pprM ty

pprTyM :: Ty -> OutM
pprTyM = fmtTy . \case
  TyUnit     -> "Unit"
  TyUnVar un -> pprM un
  TyExVar ex -> pprM ex
  TyBinop l op r ->
    parens (parens (pprM op) <+> parens (pprM l) <+> parens (pprM r))
  TyForall s sort ty ->
    fmtQuantifier "∀" <> parens (pprM s <+> ":" <+> pprM sort) <+> pprM ty
  TyVec n v -> "Vec" <+> pprM n <+> pprM v

pprTmM :: Tm -> OutM
pprTmM = fmtTm . \case
  TmUnit         -> "Unit"
  TmUnVar un     -> pprM un
  TmExVar ex     -> pprM ex
  TmBinop l op r -> pprM l <+> pprM op <+> pprM r
  TmNat n        -> pprM n
  -- tm             -> pprM (tshow tm)

pprNatM :: Nat -> OutM
pprNatM = fmtNat . \case
  Zero   -> "Z"
  Succ n -> "S" <+> parens (pprM n)

pprSortM :: Sort -> OutM
pprSortM = fmtSort . \case
  Star -> "*"
  Nat  -> "Nat"

pprExprM :: Expr -> OutM
pprExprM = fmtExpr . \case
  EpUnit -> "Unit"
  EpLam var e ->
    fmtLam "\\" <> pprM var <+> fmtLamArrow "->" <+> parens (pprM e)
  EpRec var e        -> fmtRec "rec" <+> pprM var <+> parens (pprM e)
  EpAnn e   ty       -> align (parens (pprM e) <@> parens (pprM ty))
  EpVar s            -> pprM s
  EpApp  e (Spine s) -> pprM (Spine (e : s))
  EpProd l r         -> pprM l <+> pprM OpProd <+> pprM r
  EpCase e alts ->
    fmtMatch "case" <+> pprM e <+> "of" <+> indent globalIndentWidth (pprM alts)
  EpVec v -> pprM v
  -- e       -> parens (pprM (tshow e))

pprAltsM :: Alts -> OutM
pprAltsM (Alts bs) = hsep (map (\b -> fmtAltPipe "|" <+> pprM b) bs)

pprBranchM :: Branch -> OutM
pprBranchM (Branch p e) =
  pure (P.sep (P.punctuate "|" (map ppr p)))
    <+> "->"
    <+> pprM e

pprPatM :: Pat -> OutM
pprPatM = fmtPat . \case
  PatWild     -> fmtPatWild "_"
  PatUnit     -> "Unit"
  PatVar s    -> pprM s
  PatVec v    -> pprM v
  PatProd l r -> parens (pprM l <+> "*" <+> pprM r)
  PatInj  i p -> parens ((if i == InjL then "L" else "R") <+> pprM p)

pprVecM :: AnsiPretty a => Vec a -> OutM
pprVecM Empty          = "nil"
pprVecM (Cons x Empty) = pprM x
pprVecM (Cons x xs   ) = hsep [pprM x, "::", pprM xs]

pprCtxM :: Ctx -> OutM
pprCtxM (Ctx s) = align (sep (map pprM (toList s)))

pprPropM :: Prop -> OutM
pprPropM (Equation a b) = angles (pprM a <+> "=" <+> pprM b)

pprFactM :: Fact -> OutM
pprFactM f = brackets (go f)
 where
  go :: Fact -> OutM
  go = \case
    FcExEq ex sort tm   -> pprM ex <+> ":" <+> pprM sort <+> "=" <+> pprM tm
    FcUnSort un sort    -> pprM un <+> ":" <+> pprM sort
    FcExSort ex sort    -> pprM ex <+> ":" <+> pprM sort
    FcUnEq   un tm      -> pprM un <+> "=" <+> pprM tm
    FcUnMark   un       -> "▶" <> pprM un
    FcExMark   ex       -> "▶" <> pprM ex
    FcPropMark prop     -> "▶" <> pprM prop
    FcVarTy var ty prin -> pprM var <+> ":" <+> pprM ty <+> pprM prin

pprSpineM :: Spine -> OutM
pprSpineM (Spine s) = hsep (map pprM s)

pprRuleNameM :: RuleName -> OutM
pprRuleNameM (RuleName a) = pure (pretty a)

instance AnsiPretty RuleName where pprM = pprRuleNameM

pprJudgmentDM :: JudgmentD -> OutM
pprJudgmentDM = \case
  JRuleN r   -> pprM r
  JJudgN t   -> pprM t
  JCtx   ctx -> indent globalIndentWidth (pprM ctx)
  JExpr  ep  -> pprM ep

instance AnsiPretty JudgmentD where pprM = pprJudgmentDM

treeIndentWidth = globalIndentWidth

pprTreeM :: AnsiPretty a => Tree a -> OutM
pprTreeM = \case
  Leaf a  -> pprM a
  Rose as -> vsep (map (indent treeIndentWidth . pprM) as)

instance AnsiPretty a => AnsiPretty (Tree a) where pprM = pprTreeM

pprLogItemM :: AnsiPretty a => LogItem a -> OutM
pprLogItemM (LogItem d m) = pure (pretty d) <+> pure ":" <+> group (pprM m)

instance AnsiPretty a => AnsiPretty (LogItem a) where pprM = pprLogItemM
