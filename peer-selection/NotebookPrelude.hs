{-| A prelude for an IHaskell Jupyter notebook. Intended to make it easy to:
    - Define and generate (pseudorandom) topologies
    - Show these topologies via graphviz
    - Compute various statistics on these topologies
    - Construct and display plots of those statistics
    Also exports the AWS module.
-}

module NotebookPrelude
  ( module Topo
  , module DeltaQ

  -- * Defining/generating topologies
  , module Gen
  , ethernet_bearer
  , path_of_length
  , cycle_of_length

  -- * Showing topologies.
  , showTopology
  , graphShowLabels

  -- * Computing statistics
  , module Stats
  , flatten_data

  -- * Plotting charts
  , module Chart
  , mk
  , chart_numeric_xy
  , showPlot
  , showPlot'

  -- * AWS data
  , module AWS
  ) where

-- Hide 'edge' because we use the 'edge' defined in DeltaQ.Topography.
import Algebra.Graph.Labelled.AdjacencyMap as Topo hiding (edge)
import Algebra.Graph.Labelled.AdjacencyMap.Viz as Topo
import Algebra.Graph.Labelled.AdjacencyMap.ShortestPath as Topo
-- For edge semigroups.
import Data.Semigroup as Topo (Last(..))

import DeltaQ.LinkRestriction as DeltaQ
import DeltaQ.SimpleGS as DeltaQ
import DeltaQ.TCP as DeltaQ
import DeltaQ.Topography as DeltaQ

import Data.Time.Clock as Gen (DiffTime)
import Data.List.NonEmpty as Gen (NonEmpty(..))
-- Useful as vertex types.
import Data.Word as Gen
import DeltaQ.Examples.Gen as Gen

import qualified Data.Text.Lazy as Text (pack, unpack)
import Data.GraphViz
import Data.GraphViz.Printing
import IHaskell.Display.Graphviz (Graphviz)
import qualified IHaskell.Display.Graphviz

import DeltaQ.Statistics as Stats
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map (elems)

import Control.Monad.Trans.State
import Graphics.Rendering.Chart.Easy as Chart
import DeltaQ.Examples.Charts as Chart

import DeltaQ.Examples.AWS as AWS

-- | Use 'ethernetR 1e9 1500' and given g/s.
-- Useful for expressing edges in a topology.
ethernet_bearer :: DiffTime -> DiffTime -> BearerCharacteristics
ethernet_bearer g s = Bearer (mkGS g s) (ethernetR 1e9 1500)

cycle_of_length :: DiffTime -> DiffTime -> Word -> AdjacencyMap (Last BearerCharacteristics) Word
cycle_of_length g v n = runIdentity (Gen.cycle (pure (edge (ethernet_bearer g v))) (0 :| [1..(n-1)]))

path_of_length :: DiffTime -> DiffTime -> Word -> AdjacencyMap (Last BearerCharacteristics) Word
path_of_length g v n = runIdentity (Gen.path (pure (edge (ethernet_bearer g v))) (0 :| [1..(n-1)]) (const pure))

-- TODO Working with randomness...
--
--   withRandomness :: Int -> Random a -> Random a
--   withRandomnessIO :: Random a -> IO a

-- | The @Graphviz@ type has an IHaskell display instance from
-- IHaskell.Display.Graphviz, so using showTopology will make it appear in
-- the notebook.
showTopology
  :: (Ord cl, Enum nl)
  => GraphvizParams Int nl el cl l
  -> AdjacencyMap el nl
  -> Graphviz
showTopology ps = IHaskell.Display.Graphviz.dot . Text.unpack . renderDot . toDot . toGraphvizDot ps

-- | Uses show instances for vertex and edge labels. Usage:
--
-- @showTopology graphShowLabels my_topology@
--
-- will quickly get you a picture of your topology.
graphShowLabels :: (Show nl, Show el) => GraphvizParams n nl el () nl
graphShowLabels = simpleGraphvizParams (Text.pack . show) (Text.pack . show)

-- | May be useful when you have the result of an all pairs shortest path
-- computation, but don't care about the vertex labels.
flatten_data :: Map a (Map b c) -> [c]
flatten_data outer = [ c | inner <- Map.elems outer, c <- Map.elems inner ]

-- | Useful for state-monad-lens style construction, which is actually quite
-- nice when working in an interactive notebook. You use the lens @.=@ to
-- alter the state, which starts as the @def@ default. Fits well with what
-- the Chart package exports.
mk :: Default d => State d () -> d
mk = flip execState def

-- | Give it a do-notation chart definition (via state-monad-lens style) and
-- it will render it in the notebook (Renderable has a display instance).
--
-- > chart_numeric_xy $ do
-- >   layout_title .= "Hello chart!"
-- >   showPlot $ mkPlot $ do
-- >     plot_lines_title .= "a line"
-- >     plot_lines_values .= [[(1,1),(2,2)]]
--
chart_numeric_xy :: EC (Layout Double Double) a -> Renderable ()
chart_numeric_xy = toRenderable

-- | For use in a state-monad-lens style chart layout description (see
-- 'chart_numeric_xy').
showPlot :: ToPlot p => p x y -> EC (Layout x y) ()
showPlot = plot . pure

showPlot' :: (ToPlot p, Default (p x y)) => State (p x y) () -> EC (Layout x y) ()
showPlot' = showPlot . mk