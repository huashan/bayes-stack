{-# LANGUAGE BangPatterns, GeneralizedNewtypeDeriving, StandaloneDeriving #-}

import           Prelude hiding (mapM)    

import           Options.Applicative    
import           Data.Monoid ((<>))                 

import           Data.Vector (Vector)    
import qualified Data.Vector.Generic as V    
import           Statistics.Sample (mean)       

import           Data.Traversable (mapM)                 
import qualified Data.Set as S
import           Data.Set (Set)
import qualified Data.Map as M

import           ReadData       
import           SerializeText
import qualified RunSampler as Sampler
import           BayesStack.DirMulti
import           BayesStack.Models.Topic.SharedTaste
import           BayesStack.UniqueKey

import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import           System.Directory (createDirectoryIfMissing)
import           System.FilePath.Posix ((</>))
import           Data.Serialize
import qualified Data.ByteString as BS
import           Text.Printf
       
import           Data.Random
import           System.Random.MWC                 
                 
data RunOpts = RunOpts { arcsFile        :: FilePath
                       , nodesFile       :: FilePath
                       , stopwords       :: Maybe FilePath
                       , nTopics         :: Int
                       , samplerOpts     :: Sampler.SamplerOpts
                       , hyperParams     :: HyperParams
                       }
     
data HyperParams = HyperParams
                   { alphaPsi         :: Double
                   , alphaLambda      :: Double
                   , alphaPhi         :: Double
                   , alphaOmega       :: Double
                   , alphaGammaShared :: Double
                   , alphaGammaOwn    :: Double
                   }
                 deriving (Show, Eq)

runOpts = RunOpts 
    <$> strOption  ( long "edges"
                  <> short 'e'
                  <> metavar "FILE"
                  <> help "File containing edges"
                   )
    <*> strOption  ( long "nodes"
                  <> short 'n'
                  <> metavar "FILE"
                  <> help "File containing nodes' items"
                   )
    <*> nullOption ( long "stopwords"
                  <> short 's'
                  <> metavar "FILE"
                  <> reader (Just . Just)
                  <> value Nothing
                  <> help "Stop words list"
                   )
    <*> option     ( long "topics"
                  <> short 't'
                  <> metavar "N"
                  <> value 20
                  <> help "Number of topics"
                   )
    <*> Sampler.samplerOpts
    <*> hyperOpts
    
hyperOpts = HyperParams
    <$> option     ( long "prior-psi"
                  <> value 1
                  <> help "Dirichlet parameter for prior on psi"
                   )
    <*> option     ( long "prior-lambda"
                  <> value 0.1
                  <> help "Dirichlet parameter for prior on lambda"
                   )
    <*> option     ( long "prior-phi"
                  <> value 0.1
                  <> help "Dirichlet parameter for prior on phi"
                   )
    <*> option     ( long "prior-omega"
                  <> value 0.1
                  <> help "Dirichlet parameter for prior on omega"
                   )
    <*> option     ( long "prior-gamma-shared"
                  <> value 0.9
                  <> help "Beta parameter for prior on gamma (shared)"
                   )
    <*> option     ( long "prior-gamma-own"
                  <> value 0.1
                  <> help "Beta parameter for prior on gamma (own)"
                   )
    
termsToItems :: M.Map Node [Term] -> (M.Map Node [Item], M.Map Item Term)
termsToItems = runUniqueKey' [Item i | i <- [0..]]
            . mapM (mapM getUniqueKey)

netData :: HyperParams -> M.Map Node [Item] -> Set Edge -> Int -> NetData
netData hp nodeItems edges nTopics = 
    NetData { dAlphaPsi         = alphaPsi hp
            , dAlphaLambda      = alphaLambda hp
            , dAlphaPhi         = alphaPhi hp
            , dAlphaOmega       = alphaOmega hp
            , dAlphaGammaShared = alphaGammaShared hp
            , dAlphaGammaOwn    = alphaGammaOwn hp
            , dEdges            = edges
            , dItems            = S.unions $ map S.fromList $ M.elems nodeItems
            , dTopics           = S.fromList [Topic i | i <- [1..nTopics]]
            , dNodeItems        = M.fromList
                                  $ zip [NodeItem i | i <- [0..]]
                                  $ do (n,items) <- M.assocs nodeItems
                                       item <- items
                                       return (n, item)
            }
            
opts = info runOpts
           (  fullDesc
           <> progDesc "Learn shared taste model"
           <> header "run-st - learn shared taste model"
           )

instance Sampler.SamplerModel MState where
    estimateHypers = id -- reestimate -- FIXME
    modelLikelihood = modelLikelihood
    summarizeHypers ms =  "" -- FIXME

main = do
    args <- execParser opts
    stopWords <- case stopwords args of
                     Just f  -> S.fromList . T.words <$> TIO.readFile f
                     Nothing -> return S.empty
    printf "Read %d stopwords\n" (S.size stopWords)

    edges <- S.map Edge <$> readEdges (arcsFile args)
    (nodeItems, itemMap) <- termsToItems
                            <$> readNodeItems stopWords (nodesFile args)

    let sweepsDir = Sampler.sweepsDir $ samplerOpts args
    createDirectoryIfMissing False sweepsDir
    BS.writeFile (sweepsDir </> "item-map") $ runPut $ put itemMap

    let termCounts = V.fromListN (M.size nodeItems)
                     $ map length $ M.elems nodeItems :: Vector Int
    printf "Read %d edges, %d items\n" (S.size edges) (M.size nodeItems)
    printf "Mean items per node:  %1.2f\n" (mean $ V.map realToFrac termCounts)
    
    withSystemRandom $ \mwc->do
    let nd = netData (hyperParams args) nodeItems edges 10
    BS.writeFile (sweepsDir </> "data") $ runPut $ put nd
    mInit <- runRVar (randomInitialize nd) mwc
    let m = model nd mInit
    Sampler.runSampler (samplerOpts args) m (updateUnits nd)
    return ()

