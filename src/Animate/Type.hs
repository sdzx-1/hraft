{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use camelCase" #-}

module Animate.Type where

import Animate.S
import Animate.Utils
import Control.Monad (forM_)
import Control.Monad.Class.MonadTime
import Data.IORef
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Tuple (swap)
import Graphics.Gloss
import Graphics.Gloss.Interface.IO.Animate
import Raft.Type hiding (Candidate, Follower, Leader, Role)
import Test.QuickCheck (Arbitrary (arbitrary), Gen, generate)

main :: IO ()
main = do
  env <- generate (arbitrary :: Gen Env)
  print env
  -- let env = tenv
  let hdls = concatMap trans $ runCreateAll env
      nodeNums = length $ nodeIds env
      nodes = mkNodes nodeNums
      nodeConnectSet = Set.fromList $ ft [0 .. nodeNums - 1]

  nodeConnectSet_ref <- newIORef nodeConnectSet
  actions_ref <- newIORef hdls
  nodeState_map_ref <- newIORef nodes
  alive_node_set_ref <- newIORef (Set.fromList $ Map.keys nodes)
  animateIO
    (InWindow "Nice Window" (1000, 1200) (10, 10))
    white
    ( prodNextFrame
        nodes
        nodeConnectSet
        actions_ref
        nodeState_map_ref
        nodeConnectSet_ref
        alive_node_set_ref
        . (/ 1)
    )
    (\_ -> pure ())

splitLessThanActions
  :: Float
  -> [Action s]
  -> [Action s]
  -> ([Action s], [Action s])
splitLessThanActions _ ls [] = (ls, [])
splitLessThanActions dt ls (x : xs) =
  if getActionTime x <= dt
    then splitLessThanActions dt (x : ls) xs
    else (ls, x : xs)

prodNextFrame
  :: Map Id NodeState
  -> Set (Int, Int)
  -> IORef [Action Int]
  -> IORef (Map Id NodeState)
  -> IORef (Set (Id, Id))
  -> IORef (Set Id)
  -> Float
  -> IO Picture
prodNextFrame
  nodes
  nodeConnectSet
  actions_ref
  nodeState_map_ref
  nodeConnectSet_ref
  alive_node_set_ref
  t = do
    actions <- readIORef actions_ref
    case actions of
      [] -> pure $ text "finish"
      _ -> do
        let (ls', gs) = splitLessThanActions t [] actions
            ls = reverse ls'
        forM_ ls $ \action -> do
          case action of
            Action _ (nid, h) -> do
              let updateNodeState_map nid' uf = do
                    nodeState_map <- readIORef nodeState_map_ref
                    let nodestate = fromJust $ Map.lookup nid' nodeState_map
                    writeIORef nodeState_map_ref (Map.insert nid' (uf nodestate) nodeState_map)
              case h of
                FollowerTimeoutToCandidate -> updateNodeState_map nid (\ns -> ns{role = Candidate})
                FollowerRecvMsg{} -> updateNodeState_map nid (\ns -> ns{role = Follower})
                CandidateElectionSuccess{} -> updateNodeState_map nid (\ns -> ns{role = Leader})
                LeaderToFollowerAtAP{} -> updateNodeState_map nid (\ns -> ns{role = Follower})
                LeaderToFollowerAtRV{} -> updateNodeState_map nid (\ns -> ns{role = Follower})
                UpdateTermAndVotedFor term vf ->
                  updateNodeState_map nid (\ns -> ns{term = term, votedFor = vf})
                _ -> pure ()
            NetworkChangeAction _ k@(NetworkChange ps _ _) -> do
              print k
              writeIORef nodeConnectSet_ref nodeConnectSet
              writeIORef alive_node_set_ref (Set.fromList $ Map.keys nodes)
              let clist = getPart ps
              forM_ clist $ \p -> modifyIORef' nodeConnectSet_ref (Set.delete (swap p) . Set.delete p)
            NodeRestartAction _ k@(NodeRestart nids _) -> do
              print k
              writeIORef nodeConnectSet_ref nodeConnectSet
              writeIORef alive_node_set_ref (Set.fromList $ Map.keys nodes)
              forM_ nids $ \(NodeId nid) -> do
                modifyIORef' alive_node_set_ref (Set.delete nid)
                forM_ (Map.keys nodes) $ \p -> modifyIORef' nodeConnectSet_ref (Set.delete (nid, p) . Set.delete (p, nid))

        writeIORef actions_ref gs
        nodeState_map <- readIORef nodeState_map_ref
        nodeConnectSet' <- readIORef nodeConnectSet_ref
        alive_node_set <- readIORef alive_node_set_ref
        pure
          ( pictures
              [ renderNodeCommectSet nodeState_map nodeConnectSet'
              , rr alive_node_set nodeState_map
              , translate 0 350 $ scale 0.3 0.3 $ text $ show t
              ]
          )

-- >>> nodeConnectMap

renderNodeCommectSet :: Map Id NodeState -> Set (Id, Id) -> Picture
renderNodeCommectSet m nc = pictures $ renderNodeCommectSet' (Set.toList nc) m

renderNodeCommectSet' :: [(Id, Id)] -> Map Id NodeState -> [Picture]
renderNodeCommectSet' [] _ = []
renderNodeCommectSet' ((s, e) : xs) m =
  let sp = fromJust $ Map.lookup s m
      ep = fromJust $ Map.lookup e m
   in line [position sp, position ep] : renderNodeCommectSet' xs m

timeToFloat :: Time -> Float
timeToFloat (Time t) = realToFrac t

color_follower, color_leader, color_candidate :: Color
color_follower = black
color_leader = red
color_candidate = blue

getActionTime :: Action s -> Float
getActionTime (Action t _) = t
getActionTime (NetworkChangeAction t _) = t
getActionTime (NodeRestartAction t _) = t

data Action s
  = Action Float (Id, HandleTracer' s)
  | NetworkChangeAction Float NetworkChange
  | NodeRestartAction Float NodeRestart
  deriving (Show)

trans :: NTracer s -> [Action s]
trans (N2 (IdWrapper i (TimeWrapper t h))) = [Action (timeToFloat t) (i, h)]
trans (N4 (TimeWrapper t h)) = [NetworkChangeAction (timeToFloat t) h]
trans (N5 (TimeWrapper t h)) = [NodeRestartAction (timeToFloat t) h]
trans _ = []

data Role = Follower | Candidate | Leader

data NodeState = NodeState
  { nodeId :: Id
  , role :: Role
  , position :: Point
  , term :: Term
  , votedFor :: Maybe Id
  }

mkNodes :: Int -> Map Id NodeState
mkNodes len =
  let r = 300
      pat = 2 * pi / fromIntegral len
   in Map.fromList
        [ ( i
          , NodeState
              i
              Follower
              ( r * sin (pat * fromIntegral i)
              , r * cos (pat * fromIntegral i)
              )
              0
              Nothing
          )
        | i <- [0 .. len - 1]
        ]

roleToColor :: Role -> Color
roleToColor Follower = color_follower
roleToColor Candidate = color_candidate
roleToColor Leader = color_leader

rr :: Set Id -> Map Id NodeState -> Picture
rr alive_node_set m =
  let ls = Map.toList m
   in pictures $
        map
          ( \(_, ns) ->
              renderNodeState alive_node_set ns
          )
          ls

renderNodeState :: Set Id -> NodeState -> Picture
renderNodeState alive_node_set NodeState{nodeId, role, position = (x, y), term, votedFor} =
  translate x y $
    pictures
      [ if Set.member nodeId alive_node_set
          then color (roleToColor role) $ circleSolid 10
          else blank
      , translate 10 0 $ scale 0.2 0.2 $ text $ show nodeId
      , translate 10 (-20) $ scale 0.2 0.2 $ text $ "term: " ++ show term
      , translate 10 (-40) $ scale 0.2 0.2 $ text $ "vote: " ++ show votedFor
      ]
