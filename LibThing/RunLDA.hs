{-# LANGUAGE OverlappingInstances, DeriveDataTypeable #-}

import BayesStack.Core
import BayesStack.Models.Topic.LDA
import LibThing.Data

import Data.List ((\\), nub, sort)

import Data.Set (Set)
import qualified Data.Set as S
  
import Data.EnumMap (EnumMap)
import qualified Data.EnumMap as EM

import Data.Map (Map)
import qualified Data.Map as M

import Data.Sequence (Seq)
import qualified Data.Sequence as SQ

import Control.Monad.IO.Class
import qualified Control.Monad.Trans.State as S
import Control.Monad.Trans.Class (lift)
import Control.Monad
  
import Data.Random
import System.Random.MWC (GenIO, withSystemRandom)

import System.IO

import Control.Concurrent

import qualified Data.ByteString as BS
import Data.Serialize

import Data.Number.LogFloat hiding (realToFrac)
import Text.Printf
  
import System.Console.CmdArgs

data LibThingLDA = LibThingLDA { theta :: Double
                               , phi :: Double
                               , topics :: Int
                               , sweeps_dir :: FilePath
                               } deriving (Show, Data, Typeable)

libThingLDA = LibThingLDA { theta = 0.1 &= help "Alpha theta"
                          , phi = 0.1 &= help "Alpha phi"
                          , topics = 10 &= help "Number of topics"
                          , sweeps_dir = "sweeps" &= help "Directory to place sweep dumps in" &= opt "sweeps"
                          }


serializeState :: LDAModel -> FilePath -> ModelMonad ()
serializeState model fname =
  do s <- getModelState model
     liftIO $ BS.writeFile fname $ runPut $ put s

reestimateParams model =
  do liftIO $ putStrLn "Parameter estimation"
     alphas <- mapM getShared $ mThetas model
     let alphas' = reestimatePriors alphas
     mapM_ (\(u,lambda)->setShared (mThetas model EM.! u) lambda) $ EM.toList alphas'

     alphas <- mapM getShared $ mPhis model
     let alphas' = reestimateSymPriors alphas
     mapM_ (\(t,phi)->setShared (mPhis model EM.! t) phi) $ EM.toList alphas'

main = withSystemRandom $ runModel run
run = 
  do args <- liftIO $ cmdArgs libThingLDA
     (userTags, wordMap) <- liftIO readTags
     let d = LDAData { ldaAlphaTheta = theta args
                     , ldaAlphaPhi = phi args
                     , ldaNodes = S.fromList $ nub $ sort $ map fst userTags
                     , ldaItems = S.fromList $ nub $ sort $ map snd userTags
                     , ldaTopics = S.empty
                     , ldaNodeItems = setupNodeItems userTags
                     }
     liftIO $ putStrLn "Finished creating network"

     init <- liftRVar $ randomInitialize d
     (ius, model) <- model d init
  
     liftIO $ putStrLn "Starting inference"
     let gibbsUpdate :: Int -> S.StateT LogFloat ModelMonad ()
         gibbsUpdate sweepN =
           do l <- lift $ likelihood model
              lastMax <- S.get
              when (l > lastMax) $ do lift $ serializeState model $ printf "%s/%05d" (sweeps_dir args) sweepN
                                      S.put l
              liftIO $ putStr $ printf "Sweep %d: %f\n" sweepN (logFromLogFloat l :: Double)
              lift $ concurrentGibbsUpdate 10 ius

     S.runStateT (forM_ [0..] gibbsUpdate) 0
 
