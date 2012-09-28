{-# LANGUAGE TypeFamilies, GeneralizedNewtypeDeriving, DeriveGeneric, TupleSections #-}

module BayesStack.Models.Topic.CitationInfluence
  ( -- * Primitives
    NetData(..)
  , MState(..)
  , CitedUpdateUnit
  , CitingUpdateUnit
  , ItemSource(..)
  , CitedNode(..), CitedNodeItem(..)
  , CitingNode(..), CitingNodeItem(..)
  , Citing(..), Cited(..)
  , Item(..), Topic(..), Arc(..), NodeItem(..), Node(..)
  , setupNodeItems
    -- * Initialization
  , verifyNetData
  , ModelInit
  , randomInitialize
  , model
  , updateUnits
    -- * Diagnostics
  , modelLikelihood
  ) where

import           Debug.Trace

import           Prelude hiding (mapM_)

import           Data.Set (Set)
import qualified Data.Set as S

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M

import           Data.Foldable hiding (product)
import           Control.Applicative ((<$>), (<*>))
import           Control.Monad (when)                 
import           Control.Monad.Trans.State.Strict
import           Control.Monad.Trans.Writer.Strict

import           Data.Random
import           Data.Random.Lift (lift)
import           Data.Random.Distribution.Categorical (categorical)
import           Data.Number.LogFloat hiding (realToFrac)

import           BayesStack.Core.Types
import           BayesStack.Core.Gibbs
import           BayesStack.DirMulti
import           BayesStack.TupleEnum ()
import           BayesStack.Models.Topic.Types

import           GHC.Generics
import           Data.Serialize (Serialize)
import           Control.DeepSeq

data ItemSource = Shared | Own deriving (Show, Eq, Enum, Ord, Generic)
instance Serialize ItemSource
instance NFData ItemSource         
         
newtype Citing a = Citing a deriving (Show, Eq, Enum, Ord, Generic, NFData)
newtype Cited a = Cited a deriving (Show, Eq, Enum, Ord, Generic, NFData)
instance Serialize a => Serialize (Citing a)
instance Serialize a => Serialize (Cited a)
         
type CitingNode = Citing Node
type CitedNode = Cited Node
type CitingNodeItem = Citing NodeItem
type CitedNodeItem = Cited NodeItem

-- ^ A directed edge         
newtype Arc = Arc (CitingNode, CitedNode)
            deriving (Show, Eq, Ord, Generic)
instance Serialize Arc

-- ^ The citing node of an arc
citingNode :: Arc -> CitingNode
citingNode (Arc (a,_)) = a           

-- ^ The cited node of an arc
citedNode :: Arc -> CitedNode
citedNode (Arc (_,b)) = b

data NetData = NetData { dAlphaPsi           :: Double
                       , dAlphaLambda        :: Double
                       , dAlphaPhi           :: Double
                       , dAlphaOmega         :: Double
                       , dAlphaGammaShared   :: Double
                       , dAlphaGammaOwn      :: Double
                       , dArcs               :: Set Arc
                       , dItems              :: Set Item
                       , dTopics             :: Set Topic
                       , dCitedNodeItems     :: Map CitedNodeItem (CitedNode, Item)
                       , dCitingNodeItems    :: Map CitingNodeItem (CitingNode, Item)
                       }
              deriving (Show, Eq, Generic)
instance Serialize NetData
         
dCitingNodes :: NetData -> Set CitingNode
dCitingNodes = S.fromList . map fst . M.elems . dCitingNodeItems

dCitedNodes :: NetData -> Set CitedNode
dCitedNodes = S.fromList . map fst . M.elems . dCitedNodeItems
         
getCitingNodes :: NetData -> CitedNode -> Set CitingNode
getCitingNodes d n = S.map citingNode $ S.filter (\(Arc (_,cited))->cited==n) $ dArcs d

getCitedNodes :: NetData -> CitingNode -> Set CitedNode
getCitedNodes d n = S.map citedNode $ S.filter (\(Arc (citing,_))->citing==n) $ dArcs d
              
verifyNetData :: NetData -> [String]
verifyNetData d = execWriter $ do
    --when (dCitingNodes d /= dCitedNodes d)
    --    $ tell ["Citing nodes and cited nodes should be identical sets"]
    forM_ (dCitingNodes d) $ \n->
        when (S.null $ getCitedNodes d n)
        $ tell [show n++" is in dCitingNodeItems yet has no arcs"]
    forM_ (dCitedNodes d) $ \n->
        when (S.null $ getCitingNodes d n)
        $ tell [show n++" is in dCitedNodeItems yet has no arcs"]

type CitedModelInit = Map CitedNodeItem (Setting CitedUpdateUnit)
type CitingModelInit = Map CitingNodeItem (Setting CitingUpdateUnit)
data ModelInit = ModelInit CitedModelInit CitingModelInit
               deriving (Show)

randomInitializeCited :: NetData -> CitedModelInit -> RVar CitedModelInit
randomInitializeCited d init = execStateT doInit init
    where doInit = let unset = M.keysSet (dCitedNodeItems d) `S.difference` M.keysSet init
                   in mapM_ (randomInitCitedUU d) (S.toList unset)

modify' :: Monad m => (a -> a) -> StateT a m ()
modify' f = do x <- get
               put $! f x

randomInitCitedUU :: NetData -> CitedNodeItem -> StateT CitedModelInit RVar ()
randomInitCitedUU d ni = do
    t' <- lift $ randomElement $ toList $ dTopics d
    modify' $ M.insert ni t'

randomInitializeCiting :: NetData -> CitingModelInit -> RVar CitingModelInit
randomInitializeCiting d init = execStateT doInit init
    where doInit :: StateT CitingModelInit RVar ()
          doInit = let unset = M.keysSet (dCitingNodeItems d) `S.difference` M.keysSet init
                   in mapM_ (randomInitCitingUU d) (S.toList unset)
   
randomInitCitingUU :: NetData -> CitingNodeItem -> StateT CitingModelInit RVar ()
randomInitCitingUU d ni =
    let (n,_) = dCitingNodeItems d M.! ni
    in case getCitedNodes d n of
           a | S.null a -> do
               t <- lift $ randomElement $ toList $ dTopics d
               modify' $ M.insert ni $ OwnSetting t

           citedNodes -> do
               s <- lift $ randomElement [Shared, Own]
               c <- lift $ randomElement $ toList citedNodes
               when (c `S.notMember` dCitedNodes d) $ error "uh oh"
               t <- lift $ randomElement $ toList $ dTopics d
               modify' $ M.insert ni $
                   case s of Shared -> SharedSetting t c
                             Own    -> OwnSetting t

randomInitialize :: NetData -> RVar ModelInit
randomInitialize d =
    ModelInit <$> randomInitializeCited d M.empty <*> randomInitializeCiting d M.empty
                
model :: NetData -> ModelInit -> MState
model d (ModelInit citedInit citingInit) =
    let s = MState { -- Citing model
                     stPsis = let dist = symDirMulti (dAlphaPsi d) (toList $ dCitedNodes d)
                              in foldMap (\n->M.singleton n dist) $ dCitingNodes d
                   , stPhis = let dist = symDirMulti (dAlphaPhi d) (toList $ dItems d)
                              in foldMap (\t->M.singleton t dist) $ dTopics d
                   , stGammas = let dist = multinom [ (Shared, dAlphaGammaShared d)
                                                    , (Own, dAlphaGammaOwn d) ]
                                in foldMap (\t->M.singleton t dist) $ dCitingNodes d
                   , stOmegas = let dist = symDirMulti (dAlphaOmega d) (toList $ dTopics d)
                                in foldMap (\t->M.singleton t dist) $ dCitingNodes d
                   , stCiting = M.empty

                   -- Cited model
                   , stLambdas = let dist = symDirMulti (dAlphaLambda d) (toList $ dTopics d)
                                 in foldMap (\t->M.singleton t dist) $ dCitedNodes d
                   , stT' = M.empty
                   }

        initCitingUU :: CitingUpdateUnit -> State MState ()
        initCitingUU uu = do
            let err = error $ "CitationInference: Initial value for "++show uu++" not given\n"
                            ++show citingInit++"\n\n"
                            ++show (M.findMax citingInit, M.findMin citingInit)++"\n\n"
                            ++show (fst (M.findMax citingInit) == uuNI uu)++"\n\n"
                            ++show (M.lookup (uuNI uu) citingInit)
                            ++show (M.findWithDefault (error "hi") (uuNI uu) citingInit)
                s = maybe err id $ M.lookup (uuNI uu) citingInit
            modify' $ setCitingUU uu (Just s)

        initCitedUU :: CitedUpdateUnit -> State MState ()
        initCitedUU uu = do
            let err = error $ "CitationInference: Initial value for "++show uu++" not given"
                s = maybe err id $ M.lookup (uuNI' uu) citedInit
            modify' $ setCitedUU uu (Just s)

    in execState (do mapM_ initCitingUU $ citingUpdateUnits d
                     mapM_ initCitedUU $ citedUpdateUnits d
                 ) s

updateUnits :: NetData -> [WrappedUpdateUnit MState]
updateUnits d = map WrappedUU (citedUpdateUnits d)
             ++ map WrappedUU (citingUpdateUnits d)

data CitingSetting = OwnSetting !Topic
                   | SharedSetting !Topic !CitedNode
                   deriving (Show, Eq, Generic)
instance NFData CitingSetting
instance Serialize CitingSetting

data MState = MState { -- Citing model state
                       stGammas   :: Map CitingNode (Multinom ItemSource)
                     , stOmegas   :: Map CitingNode (Multinom Topic)
                     , stPsis     :: Map CitingNode (Multinom CitedNode)
                     , stPhis     :: Map Topic (Multinom Item)

                     , stCiting   :: Map CitingNodeItem CitingSetting

                     -- Cited model state
                     , stLambdas  :: Map CitedNode (Multinom Topic)

                     , stT'       :: Map CitedNodeItem Topic
                     }
            deriving (Show, Generic)
instance Serialize MState

modelLikelihood :: MState -> Probability
modelLikelihood model =
    product $ map likelihood (M.elems $ stGammas model)
           ++ map likelihood (M.elems $ stPhis model)
           ++ map likelihood (M.elems $ stLambdas model)
           ++ map likelihood (M.elems $ stOmegas model)
           ++ map likelihood (M.elems $ stPsis model)

-- Cited update unit (LDA-like)
data CitedUpdateUnit = CitedUpdateUnit { uuNI' :: CitedNodeItem
                                       , uuN'  :: CitedNode
                                       , uuX' :: Item
                                       }
                     deriving (Show, Generic)
instance Serialize CitedUpdateUnit

instance UpdateUnit CitedUpdateUnit where
    type ModelState CitedUpdateUnit = MState
    type Setting CitedUpdateUnit = Topic
    fetchSetting uu ms = maybe (error $ "Update unit "++show uu++" has no setting") id
                         $ M.lookup (uuNI' uu) (stT' ms)
    evolveSetting ms uu = categorical $ citedFullCond (setCitedUU uu Nothing ms) uu
    updateSetting uu _ s' = setCitedUU uu (Just s') . setCitedUU uu Nothing

citedProb :: MState -> CitedUpdateUnit -> Setting CitedUpdateUnit -> Double
citedProb st (CitedUpdateUnit {uuN'=n', uuX'=x'}) t =
    let lambda = stLambdas st M.! n'
        phi = stPhis st M.! t
    in realToFrac $ sampleProb lambda t * sampleProb phi x'

citedUpdateUnits :: NetData -> [CitedUpdateUnit]
citedUpdateUnits d =
    map (\(ni',(n',x'))->CitedUpdateUnit { uuNI'      = ni'
                                         , uuN'       = n'
                                         , uuX'       = x'
                                         }
        ) $ M.assocs $ dCitedNodeItems d
              
setCitedUU :: CitedUpdateUnit -> Maybe Topic -> MState -> MState
setCitedUU uu@(CitedUpdateUnit {uuN'=n', uuNI'=ni', uuX'=x'}) setting ms =
    let t' = maybe (fetchSetting uu ms) id setting
        set = maybe Unset (const Set) setting
    in ms { stLambdas = M.adjust (setMultinom set t') n' (stLambdas ms)
          , stPhis = M.adjust (setMultinom set x') t' (stPhis ms)
          , stT' = case setting of Just _  -> M.insert ni' t' $ stT' ms
                                   Nothing -> stT' ms
          }

citedFullCond ::MState -> CitedUpdateUnit -> [(Double, Topic)]
citedFullCond ms uu = do
    t <- M.keys $ stPhis ms
    return (citedProb ms uu t, t)


-- Citing Update unit (Shared Taste-like)
data CitingUpdateUnit = CitingUpdateUnit { uuNI    :: CitingNodeItem
                                         , uuN     :: CitingNode
                                         , uuX     :: Item
                                         , uuCites :: Set CitedNode
                                         }
                      deriving (Show, Generic)
instance Serialize CitingUpdateUnit

instance UpdateUnit CitingUpdateUnit where
    type ModelState CitingUpdateUnit = MState
    type Setting CitingUpdateUnit = CitingSetting
    fetchSetting uu ms = stCiting ms M.! uuNI uu
    evolveSetting ms uu = categorical $ citingFullCond (setCitingUU uu Nothing ms) uu
    updateSetting uu _ s' = setCitingUU uu (Just s') . setCitingUU uu Nothing

citingUpdateUnits :: NetData -> [CitingUpdateUnit]
citingUpdateUnits d =
    map (\(ni,(n,x))->CitingUpdateUnit { uuNI      = ni
                                       , uuN       = n
                                       , uuX       = x
                                       , uuCites = getCitedNodes d n
                                       }
        ) $ M.assocs $ dCitingNodeItems d
        
tr x = traceShow x x
citingProb :: MState -> CitingUpdateUnit -> Setting CitingUpdateUnit -> Double
citingProb st (CitingUpdateUnit {uuN=n, uuX=x}) setting =
    let gamma = stGammas st M.! n
        omega = stOmegas st M.! n
        psi = stPsis st M.! n
    in case setting of 
        SharedSetting t c -> let phi = stPhis st M.! t
                                 lambda = stLambdas st M.! c
                             in sampleProb gamma Shared
                              * sampleProb psi c
                              * sampleProb lambda t
                              * sampleProb phi x
        OwnSetting t      -> let phi = stPhis st M.! t
                             in sampleProb gamma Own
                              * sampleProb omega t
                              * sampleProb phi x

citingFullCond :: MState -> CitingUpdateUnit -> [(Double, Setting CitingUpdateUnit)]
citingFullCond ms uu = map (\s->(citingProb ms uu s, s)) $ citingDomain ms uu
            
citingDomain :: MState -> CitingUpdateUnit -> [Setting CitingUpdateUnit]
citingDomain ms uu = do
    s <- [Own, Shared]
    t <- M.keys $ stPhis ms
    case s of
        Shared -> do c <- S.toList $ uuCites uu
                     return $ SharedSetting t c
        Own    -> do return $ OwnSetting t

setCitingUU :: CitingUpdateUnit -> Maybe (Setting CitingUpdateUnit) -> MState -> MState
setCitingUU uu@(CitingUpdateUnit {uuNI=ni, uuN=n, uuX=x}) setting ms =
    let set = maybe Unset (const Set) setting
        ms' = case maybe (fetchSetting uu ms) id  setting of
            SharedSetting t c -> ms { stPsis = M.adjust (setMultinom set c) n $ stPsis ms
                                    , stLambdas = M.adjust (setMultinom set t) c $ stLambdas ms
                                    , stPhis = M.adjust (setMultinom set x) t $ stPhis ms
                                    , stGammas = M.adjust (setMultinom set Shared) n $ stGammas ms
                                    }
            OwnSetting t      -> ms { stOmegas = M.adjust (setMultinom set t) n $ stOmegas ms
                                    , stPhis = M.adjust (setMultinom set x) t $ stPhis ms
                                    , stGammas = M.adjust (setMultinom set Own) n $ stGammas ms
                                    }
    in ms' { stCiting = M.alter (const setting) ni $ stCiting ms' }
