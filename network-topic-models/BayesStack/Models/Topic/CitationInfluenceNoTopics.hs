{-# LANGUAGE TypeFamilies, GeneralizedNewtypeDeriving, DeriveGeneric, TupleSections, RecordWildCards, TemplateHaskell, RankNTypes, FlexibleContexts #-}

module BayesStack.Models.Topic.CitationInfluenceNoTopics
  ( -- * Primitives
    NetData
  , dArcs, dItems, dNodeItems, dCitingNodes, dCitedNodes
  , netData
  , MState
  , stGammas, stOmegas, stPsis, stCiting, stLambdas
  , CitingUpdateUnit
  , ItemSource(..)
  , CitedNode(..), CitedNodeItem(..)
  , CitingNode(..), CitingNodeItem(..)
  , Citing(..), Cited(..)
  , Item(..), Topic(..), NodeItem(..), Node(..), Arc(..)
  , setupNodeItems
    -- * Initialization
  , verifyNetData, cleanNetData
  , ModelInit
  , randomInitialize
  , model
  , updateUnits
    -- * Diagnostics
  , modelLikelihood
  ) where

import qualified Data.Vector as V
import Statistics.Sample (mean)

import           Prelude hiding (mapM_, sum)
import           Data.Maybe (fromMaybe)

import           Control.Lens hiding (Setting)
import           Data.Set (Set)
import qualified Data.Set as S

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M

import           Data.EnumMap (EnumMap)
import qualified Data.EnumMap as EM
                 
import           Data.Foldable hiding (product)
import           Control.Applicative ((<$>), (<*>))
import           Control.Monad (when)
import           Control.Monad.Trans.State.Strict
import           Control.Monad.Trans.Writer.Strict

import           Data.Random
import           Data.Random.Lift (lift)
import           Data.Random.Distribution.Categorical (categorical)
import           Numeric.Log hiding (sum)

import           BayesStack.Types
import           BayesStack.Gibbs
import qualified BayesStack.Dirichlet as Dir
import           BayesStack.Dirichlet (Dirichlet, Precision(..))
import qualified BayesStack.Multinomial as Multi
import           BayesStack.Multinomial (Multinom)
import           BayesStack.TupleEnum ()
import           BayesStack.Models.Topic.Types

import           GHC.Generics (Generic)
import           Data.Binary (Binary)
import qualified Data.Binary as B                 
import           Control.DeepSeq

at' :: At m => Index m -> IndexedLens' (Index m) m (IxValue m)
at' i = at i . _fromMaybe
  where _fromMaybe = iso (fromMaybe $ error "at': Unexpected Nothing") Just

data ItemSource = Shared | Own deriving (Show, Eq, Enum, Ord, Generic)
instance Binary ItemSource
instance NFData ItemSource

newtype Citing a = Citing a deriving (Show, Eq, Enum, Ord, Generic, NFData)
newtype Cited a = Cited a deriving (Show, Eq, Enum, Ord, Generic, NFData)
instance Binary a => Binary (Citing a)
instance Binary a => Binary (Cited a)

type CitingNode = Citing Node
type CitedNode = Cited Node
type CitingNodeItem = Citing NodeItem
type CitedNodeItem = Cited NodeItem

-- ^ A directed edge
data Arc = Arc { citingNode :: !CitingNode, citedNode :: !CitedNode }
            deriving (Show, Eq, Ord, Generic)
instance Binary Arc

data HyperParams = HyperParams { _alphaPsi            :: !Double
                               , _alphaLambda         :: !Double
                               , _alphaOmega          :: !Double
                               , _alphaGammaShared    :: !Double
                               , _alphaGammaOwn       :: !Double
                               }
                 deriving (Show, Generic)
instance Binary HyperParams
makeLenses ''HyperParams         
         
data NetData = NetData { _dArcs               :: !(Set Arc)
                       , _dItems              :: !(Map Item Double)
                       , _dNodeItems          :: !(Map NodeItem (Node, Item))
                       , _dCitingNodes        :: !(Map CitingNode (Set CitedNode))
                         -- ^ Maps each citing node to the set of nodes cited by it
                       , _dCitedNodes         :: !(Map CitedNode (Set CitingNode))
                         -- ^ Maps each cited node to the set of nodes citing it
                       }
              deriving (Show, Generic)
instance Binary NetData
makeLenses ''NetData         

netData :: Set Arc -> Map Item Double -> Map NodeItem (Node,Item) -> NetData
netData arcs items nodeItems =
    NetData { _dArcs         = arcs
            , _dItems        = items
            , _dNodeItems    = nodeItems
            , _dCitingNodes  = M.unionsWith S.union
                               $ map (\(Arc a b)->M.singleton a $ S.singleton b)
                               $ S.toList arcs
            , _dCitedNodes   = M.unionsWith S.union
                               $ map (\(Arc a b)->M.singleton b $ S.singleton a)
                               $ S.toList arcs
            }

dCitingNodeItems :: NetData -> Map CitingNodeItem (CitingNode, Item)
dCitingNodeItems nd =
    M.mapKeys Citing
    $ M.map (\(n,i)->(Citing n, i))
    $ M.filter (\(n,i)->Citing n `M.member` (nd^.dCitingNodes))
    $ nd^.dNodeItems

itemsOfCitingNode :: NetData -> CitingNode -> [Item]
itemsOfCitingNode d (Citing u) =
    map snd $ M.elems $ M.filter (\(n,_)->n==u) $ d^.dNodeItems

connectedNodes :: Set Arc -> Set Node
connectedNodes arcs =
    S.map ((\(Cited n)->n) . citedNode) arcs `S.union` S.map ((\(Citing n)->n) . citingNode) arcs

cleanNetData :: NetData -> NetData
cleanNetData d =
    let nodesWithItems = S.fromList $ map fst $ M.elems $ d^.dNodeItems
        nodesWithArcs = connectedNodes $ d^.dArcs
        keptNodes = nodesWithItems `S.intersection` nodesWithArcs
        keepArc (Arc (Citing citing) (Cited cited)) =
            citing `S.member` keptNodes && cited `S.member` keptNodes
        go = do dArcs %= S.filter keepArc
                dNodeItems %= M.filter (\(n,i)->n `S.member` keptNodes)
    in execState go d

verifyNetData :: (Node -> String) -> NetData -> [String]
verifyNetData showNode d = execWriter $ do
    let nodesWithItems = S.fromList $ map fst $ M.elems $ d^.dNodeItems
    forM_ (d^.dArcs) $ \(Arc (Citing citing) (Cited cited))->do
        when (cited `S.notMember` nodesWithItems)
            $ tell [showNode cited++" has arc yet has no items"]
        when (citing `S.notMember` nodesWithItems)
            $ tell [showNode citing++" has arc yet has no items"]

-- Citing Update unit (Shared Taste-like)
data CitingUpdateUnit = CitingUpdateUnit { _uuNI    :: CitingNodeItem
                                         , _uuN     :: CitingNode
                                         , _uuX     :: Item
                                         , _uuCites :: Set CitedNode
                                         , _uuItemWeight :: Double
                                         }
                      deriving (Show, Generic)
instance Binary CitingUpdateUnit
makeLenses ''CitingUpdateUnit

citingUpdateUnits :: NetData -> [CitingUpdateUnit]
citingUpdateUnits d =
    map (\(ni,(n,x))->CitingUpdateUnit { _uuNI      = ni
                                       , _uuN       = n
                                       , _uuX       = x
                                       , _uuCites   = d^.dCitingNodes . at' n
                                       , _uuItemWeight = (d ^. dItems . at' x)
                                       }
        ) $ M.assocs $ dCitingNodeItems d

updateUnits :: NetData -> [WrappedUpdateUnit MState]
updateUnits d = map WrappedUU (citingUpdateUnits d)

-- | Model State            
data CitingSetting = OwnSetting
                   | SharedSetting !CitedNode
                   deriving (Show, Eq, Generic)
instance Binary CitingSetting
instance NFData CitingSetting where
    rnf (OwnSetting)      = ()
    rnf (SharedSetting c) = rnf c `seq` ()

data MState = MState { -- Citing model state
                       _stGammas   :: !(Map CitingNode (Multinom Int ItemSource))
                     , _stOmegas   :: !(Map CitingNode (Multinom Int Item))
                     , _stPsis     :: !(Map CitingNode (Multinom Int CitedNode))

                     , _stCiting   :: !(Map CitingNodeItem CitingSetting)

                     -- Cited model state
                     , _stLambdas  :: !(Map CitedNode (Multinom Int Item))
                     }
            deriving (Show, Generic)
makeLenses ''MState         
instance Binary MState

-- | Model initialization            
type ModelInit = Map CitingNodeItem (Setting CitingUpdateUnit)

modify' :: Monad m => (a -> a) -> StateT a m ()
modify' f = do x <- get
               put $! f x

randomInitializeCiting :: NetData -> ModelInit -> RVar ModelInit
randomInitializeCiting d init = execStateT doInit init
    where doInit :: StateT ModelInit RVar ()
          doInit = let unset = M.keysSet (dCitingNodeItems d) `S.difference` M.keysSet init
                   in mapM_ (randomInitCitingUU d) (S.toList unset)

randomInitCitingUU :: NetData -> CitingNodeItem -> StateT ModelInit RVar ()
randomInitCitingUU d cni@(Citing ni) =
    let (n,_) = d ^. dNodeItems . at' ni
    in case d ^. dCitingNodes . at' (Citing n) of
           a | S.null a -> do
               modify' $ M.insert cni OwnSetting

           citedNodes -> do
               s <- lift $ randomElement [Shared, Own]
               c <- lift $ randomElement $ toList citedNodes
               modify' $ M.insert cni $
                   case s of Shared -> SharedSetting c
                             Own    -> OwnSetting

randomInitialize :: NetData -> RVar ModelInit
randomInitialize d = randomInitializeCiting d M.empty

emptyModel :: HyperParams -> NetData -> MState
emptyModel hp d =           
    MState { -- Citing model
             _stPsis = let dist n = case d ^. dCitingNodes . at' n . to toList of
                                        []    -> M.empty
                                        nodes -> M.singleton n
                                                 $ Multi.fromPrecision nodes (hp^.alphaPsi)
                       in foldMap dist citingNodes
           , _stGammas = let dist = Multi.fromConcentrations
                                      [ (Shared, hp^.alphaGammaShared)
                                      , (Own, hp^.alphaGammaOwn) ]
                         in foldMap (\t->M.singleton t dist) citingNodes
           , _stOmegas = let dist = Multi.fromPrecision (M.keys $ d^.dItems)
                                                        (hp^.alphaOmega) 
                         in foldMap (\t->M.singleton t dist) citingNodes
           , _stCiting = M.empty

           -- Cited model
           , _stLambdas = let dist = Multi.fromPrecision (M.keys $ d^.dItems)
                                                         (hp^.alphaLambda)
                          in foldMap (\n->M.singleton n dist) $ M.keys $ d^.dCitedNodes
           }
  where citingNodes = M.keys $ d ^. dCitingNodes

model :: HyperParams -> NetData -> ModelInit -> MState
model hp d citingInit =
    let initCitingUU :: CitingUpdateUnit -> State MState ()
        initCitingUU uu = do
            let err = error $ "CitationInference: Initial value for "++show uu++" not given\n"
                s = maybe err id $ M.lookup (uu^.uuNI) citingInit
            modify' $ setCitingUU uu (Just s)

    in execState (do forM_ (M.elems $ d^.dNodeItems) $ \(n,x)->do
                        stLambdas %= M.adjust (Multi.increment x) (Cited n)
                     mapM_ initCitingUU $ citingUpdateUnits d
                 ) $ emptyModel hp d

modelLikelihood :: MState -> Probability
modelLikelihood model = 
    product (model ^.. stGammas  . folded . to likelihood)
  * product (model ^.. stLambdas . folded . to likelihood)
  * product (model ^.. stOmegas  . folded . to likelihood)
  * product (model ^.. stPsis    . folded . to likelihood)

instance UpdateUnit CitingUpdateUnit where
    type ModelState CitingUpdateUnit = MState
    type Setting CitingUpdateUnit = CitingSetting
    fetchSetting uu ms = ms ^. stCiting . at' (uu^.uuNI)
    evolveSetting ms uu = categorical $ citingFullCond (setCitingUU uu Nothing ms) uu
    updateSetting uu _ s' = setCitingUU uu (Just s') . setCitingUU uu Nothing

citingProb :: MState -> CitingUpdateUnit -> Setting CitingUpdateUnit -> Double
citingProb st (CitingUpdateUnit {_uuN=n, _uuX=x}) setting =
    let gamma = st ^. stGammas . at' n
        omega = st ^. stOmegas . at' n
        psi = st ^. stPsis . at' n
    in case setting of
        SharedSetting c   -> let lambda = st ^. stLambdas . at' c
                             in Multi.sampleProb gamma Shared
                              * Multi.sampleProb psi c
                              * Multi.sampleProb lambda x
        OwnSetting        ->  Multi.sampleProb gamma Own
                            * Multi.sampleProb omega x

citingFullCond :: MState -> CitingUpdateUnit -> [(Double, Setting CitingUpdateUnit)]
citingFullCond ms uu = map (\s->(citingProb ms uu s, s)) $ citingDomain ms uu

citingDomain :: MState -> CitingUpdateUnit -> [Setting CitingUpdateUnit]
citingDomain ms uu = do
    s <- [Own, Shared]
    case s of
        Shared -> do c <- uu ^. uuCites . to S.toList
                     return $ SharedSetting c
        Own    -> do return $ OwnSetting

setCitingUU :: CitingUpdateUnit -> Maybe (Setting CitingUpdateUnit) -> MState -> MState
setCitingUU uu@(CitingUpdateUnit {_uuNI=ni, _uuN=n, _uuX=x}) setting ms = execState go ms
  where
    set = maybe Multi.Unset (const Multi.Set) setting
    go = case maybe (fetchSetting uu ms) id setting of
           SharedSetting c    -> do stPsis .    at' n %= Multi.set set c
                                    stLambdas . at' c %= Multi.set set x
                                    stGammas .  at' n %= Multi.set set Shared
                                    stCiting .  at ni .= setting

           OwnSetting         -> do stOmegas .  at' n %= Multi.set set x
                                    stGammas .  at' n %= Multi.set set Own
                                    stCiting .  at ni .= setting

-- | The subset of state contained in @Stored@ along with @NetData@ is enough
-- to reconstitute an @MState@
data Stored = Stored { sAlphaPsi    :: Precision CitedNode
                     , sAlphaGamma  :: Dirichlet ItemSource
                     , sAlphaOmega  :: Dirichlet Item
                     , sAlphaLambda :: Dirichlet Item
                     , sAssignments :: Map CitingNodeItem CitingSetting
                     }
            deriving (Show, Eq, Generic)
instance Binary Stored

storedFromState :: NetData -> MState -> Stored
storedFromState nd ms =
    Stored (Precision $ Dir.precision $ prior $ ms^.stPsis)
           (prior $ ms^.stGammas)
           (prior $ ms^.stOmegas)
           (prior $ ms^.stLambdas)
           (ms^.stCiting)
  where prior :: Map a (Multinom n b) -> Dirichlet b
        prior = Multi.prior . head . M.elems

{-
stateFromStored :: NetData -> Stored -> MState
stateFromStored nd s =
    MState { -- Citing model
             _stPsis = 
    (Multi.fromPrior $ sAlphaGamma s)
             (Multi.fromPrior $ sAlphaOmega s)
             (Multi.fromPrior $ sAlphaPsi s)
             (Multi.fromPrior $ sAlphaLambda s)
             (sAssignments s)
   -} 