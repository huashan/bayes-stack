{-# LANGUAGE OverlappingInstances #-}

import BayesStack.Core
import BayesStack.UniqueKey
import BayesStack.Models.LDA

import Data.List ((\\))

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
  
import Data.List
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Function (on)
import Data.Char (toLower)
  
import Data.Random
import System.Random.MWC (GenIO, withSystemRandom)

import System.IO

import Control.Concurrent

import qualified Data.ByteString as BS
import Data.Serialize

import Data.Number.LogFloat hiding (realToFrac)
import Text.Printf
  
import Data.Hashable
import Text.CSV

topics = S.fromList $ map Topic [1..10]

serializeState :: LDAModel -> FilePath -> ModelMonad ()
serializeState model fname =
  do s <- getModelState model
     liftIO $ BS.writeFile fname $ runPut $ put s

main = withSystemRandom $ runModel run
run = 
  do let topics = [Topic i | i <- [0..10]]
     (d, wordMap) <- liftIO getTags
     liftIO $ putStrLn "Finished creating network"
     (ius, model) <- model d
  
     liftIO $ putStrLn "Starting inference"
     let gibbsUpdate :: Int -> S.StateT LogFloat ModelMonad ()
         gibbsUpdate sweepN =
           do l <- lift $ likelihood model
              lastMax <- S.get
              --when (l > lastMax) $ do lift $ serializeState model $ printf "sweeps/%05d" sweepN
              --                        S.put l
              liftIO $ putStr $ printf "Sweep %d: %f\n" sweepN (logFromLogFloat l :: Double)
              lift $ concurrentGibbsUpdate 10 ius

     S.runStateT (forM_ [0..] gibbsUpdate) 0
 
maybeRead :: Read a => String -> Maybe a
maybeRead = fmap fst . listToMaybe . filter (null . snd) . reads 

getTags :: IO (LDAData, Map Item String)
getTags =
  do f <- parseCSVFromFile "tags_for_users.csv"
     let csv = either (error . show) id f
         records = mapMaybe (\rec -> do a <- maybeRead $ rec !! 0
                                        return (a, map toLower $ rec !! 6))
                   $ tail csv
         (userTags, wordMap) = runUniqueKey $ forM records $ \(n,i) -> do k <- uniqueKey Item i
                                                                          return (Node n, k)
     let d = LDAData { ldaAlphaTheta = 0.1
                     , ldaAlphaPhi = 0.1
                     , ldaNodes = S.fromList $ nub $ sort $ map fst userTags
                     , ldaItems = S.fromList $ nub $ sort $ map snd userTags
                     , ldaTopics = topics
                     , ldaNodeItems = SQ.fromList userTags
                     }
     return (d, wordMap)

