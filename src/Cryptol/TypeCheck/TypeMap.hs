-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2014 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE Safe #-}
{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances, FlexibleInstances #-}
module Cryptol.TypeCheck.TypeMap
  ( TypeMap, TypesMap, TrieMap(..)
  , insertTM, insertWithTM
  ) where

import           Cryptol.TypeCheck.AST

import qualified Data.Map as Map
import           Data.Map (Map)
import           Data.Maybe(fromMaybe,maybeToList)
import           Control.Monad((<=<))
import           Data.List(sortBy)
import           Data.Ord(comparing)

class TrieMap m k | m -> k where
  emptyTM  :: m a
  lookupTM :: k -> m a -> Maybe a
  alterTM  :: k -> (Maybe a -> Maybe a) -> m a -> m a
  toListTM :: m a -> [(k,a)]

insertTM :: TrieMap m k => k -> a -> m a -> m a
insertTM t a = alterTM t (\_ -> Just a)

insertWithTM :: TrieMap m k => (a -> a -> a) -> k -> a -> m a -> m a
insertWithTM f t new = alterTM t $ \mb -> Just $ case mb of
                                                   Nothing  -> new
                                                   Just old -> f old new

data List m a  = L { nil  :: Maybe a
                   , cons :: m (List m a)
                   }

instance TrieMap m a => TrieMap (List m) [a] where
  emptyTM = L { nil = Nothing, cons = emptyTM }

  lookupTM k =
    case k of
      []     -> nil
      x : xs -> lookupTM xs <=< lookupTM x . cons

  alterTM k f m =
    case k of
      []    -> m { nil = f (nil m) }
      x:xs  -> m { cons = alterTM x (updSub xs f) (cons m) }

  toListTM m =
    [ ([], v)  | v <- maybeToList (nil m) ] ++
    [ (x:xs,v) | (x,m1) <- toListTM (cons m), (xs,v) <- toListTM m1 ]


instance Ord a => TrieMap (Map a) a where
  emptyTM  = Map.empty
  lookupTM = Map.lookup
  alterTM  = flip Map.alter
  toListTM = Map.toList


type TypesMap = List TypeMap

data TypeMap a = TM { tvar :: Map TVar a
                    , tcon :: Map TCon   (List TypeMap a)
                    , trec :: Map [Name] (List TypeMap a)
                    }

instance TrieMap TypeMap Type where
  emptyTM = TM { tvar = emptyTM, tcon = emptyTM, trec = emptyTM }

  lookupTM ty =
    case ty of
      TUser _ _ t -> lookupTM t
      TVar x      -> lookupTM x . tvar
      TCon c ts   -> lookupTM ts <=< lookupTM c . tcon
      TRec fs     -> let (xs,ts) = unzip $ sortBy (comparing fst) fs
                     in lookupTM ts <=< lookupTM xs . trec

  alterTM ty f m =
    case ty of
      TUser _ _ t -> alterTM t f m
      TVar x      -> m { tvar = alterTM x f (tvar m) }
      TCon c ts   -> m { tcon = alterTM c (updSub ts f) (tcon m) }
      TRec fs     -> let (xs,ts) = unzip $ sortBy (comparing fst) fs
                     in m { trec = alterTM xs (updSub ts f) (trec m) }

  toListTM m =
    [ (TVar x,           v) | (x,v)   <- toListTM (tvar m) ] ++
    [ (TCon c ts,        v) | (c,m1)  <- toListTM (tcon m)
                            , (ts,v)  <- toListTM m1 ] ++
    [ (TRec (zip fs ts), v) | (fs,m1) <- toListTM (trec m)
                            , (ts,v)  <- toListTM m1 ]

updSub :: TrieMap m k => k -> (Maybe a -> Maybe a) -> Maybe (m a) -> Maybe (m a)
updSub k f = Just . alterTM k f . fromMaybe emptyTM

instance Show a => Show (TypeMap a) where
  showsPrec p xs = showsPrec p (toListTM xs)

