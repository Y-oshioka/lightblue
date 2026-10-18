{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

-- | wani 単体計測ドライバ（wani計測ハーネス構築手順.txt レイヤーB の実装）
--   lightblue リポジトリ内に置き、本体と同じレゾルバ (lts-18.28 / GHC 8.10.7) でビルドする。
--   実行:  stack run wani-bench > runs/base_<githash>.csv 2> log.txt
module Main where

import qualified DTS.Prover.Wani.Prove as Wani  -- wani 本体
import qualified DTS.QueryTypes as QT           -- ProofSearchSetting
import qualified DTS.DTTdeBruijn as U           -- DTT 構文木 (Preterm / ProofSearchQuery)

import qualified Data.Text.Lazy as T
import qualified ListT as ListT

import Control.Exception (try, evaluate, SomeException)
import Control.Monad (forM_)
import System.Timeout (timeout)
import GHC.Clock (getMonotonicTime)          -- 単調時計
import Text.Printf (printf)
import System.IO (hSetBuffering, stdout, BufferMode(LineBuffering))
import System.Environment (getArgs)

--------------------------------------------------------------------------------
-- 計測フレーム
--------------------------------------------------------------------------------

data Problem = Problem
  { probId    :: String
  , probDepth :: Int
  , probQuery :: U.ProofSearchQuery
  }

data Outcome = Found Int | NotFound | TimedOut | Crashed String

showOutcome :: Outcome -> String
showOutcome o = case o of
  Found n   -> "Found" ++ show n
  NotFound  -> "NotFound"
  TimedOut  -> "TimedOut"
  Crashed _ -> "Crashed"

-- | wani 内部の maxTime (ms) は外部 timeout より大きくしておく。
--   こうすると時間切れは常に外部 timeout が先に検出し、
--   TimedOut と NotFound が混ざらない。
mkSetting :: Int -> QT.ProofSearchSetting
mkSetting depth = QT.defaultProofSearchSetting
  { QT.maxDepth    = Just depth
  , QT.maxTime     = Just 100000  -- 100 秒 (ms) ≫ 外部 timeout 30 秒
  , QT.logicSystem = Just QT.Intuitionistic
  }

-- | ★遅延評価対策: prove' は ListT IO を返す。ListT.toList が IO の中で
--   探索を最後まで駆動する。length でリストの spine を強制評価して確定させる。
runProve :: QT.ProofSearchSetting -> U.ProofSearchQuery -> IO Int
runProve setting q = do
  results <- ListT.toList (Wani.prove' setting q)
  evaluate (length results)

measureOnce :: Int -> Problem -> IO (Outcome, Double)
measureOnce timeoutMicro p = do
  let setting = mkSetting (probDepth p)
  t0 <- getMonotonicTime
  r  <- try (timeout timeoutMicro (runProve setting (probQuery p)))
  t1 <- getMonotonicTime
  let dt = t1 - t0
  pure $ case r of
    Left (e :: SomeException) -> (Crashed (show e), dt)
    Right Nothing             -> (TimedOut, dt)
    Right (Just n)
      | n > 0     -> (Found n, dt)
      | otherwise -> (NotFound, dt)

--------------------------------------------------------------------------------
-- 問題ジェネレータ（手順書 3-3: パラメータ n で難易度を振るスケーラブル問題族）
--------------------------------------------------------------------------------

con :: String -> U.Preterm
con = U.Con . T.pack

atom :: String -> (T.Text, U.Preterm)
atom s = (T.pack s, U.Type)

-- (0) 較正用: 自明な問題 p ⊢ p（ほぼ0秒で Found になるべき）
trivial :: Problem
trivial = Problem "trivial" 3 (U.ProofSearchQuery [atom "p"] [con "p"] (con "p"))

-- (0') 較正用: 証明不能な問題 p ⊢ q（NotFound になるべき）
unprovable :: Problem
unprovable = Problem "unprovable" 3
  (U.ProofSearchQuery [atom "p", atom "q"] [con "p"] (con "q"))

-- (1) 含意チェーン: p1, p1→p2, ..., p(n-1)→pn ⊢ pn （証明長が n に比例）
chain :: Int -> Problem
chain n = Problem ("chain_" ++ show n) (n + 5) (U.ProofSearchQuery sig ctx goal)
  where
    sig  = [ atom ("p" ++ show i) | i <- [1..n] ]
    ctx  = con "p1"
         : [ U.Pi (con ("p" ++ show i)) (con ("p" ++ show (i+1))) | i <- [1..n-1] ]
    goal = con ("p" ++ show n)

-- (2) ダミー前提: 固定長チェーン(n=3)に無関係な前提を m 個混ぜる（前提数に対する爆発）
dummies :: Int -> Problem
dummies m = Problem ("dummy_" ++ show m) 8 (U.ProofSearchQuery sig ctx goal)
  where
    base    = 3
    sigCh   = [ atom ("p" ++ show i) | i <- [1..base] ]
    sigDum  = [ atom ("d" ++ show i) | i <- [1..m] ]
    sig     = sigCh ++ sigDum
    ctxDum  = [ con ("d" ++ show i) | i <- [1..m] ]
    ctxCh   = con "p1"
            : [ U.Pi (con ("p" ++ show i)) (con ("p" ++ show (i+1))) | i <- [1..base-1] ]
    ctx     = ctxDum ++ ctxCh          -- 無関係な前提を先に積む
    goal    = con ("p" ++ show base)

-- (2') 含意ダミー: 固定長チェーン(n=3)に「適用できるが無駄な」含意 p1→d_i を
--      m 個混ぜる。原子ダミー(2)と違い探索を実際に分岐させる
dummiesPi :: Int -> Problem
dummiesPi m = Problem ("dummypi_" ++ show m) 8 (U.ProofSearchQuery sig ctx goal)
  where
    base    = 3 :: Int
    sigCh   = [ atom ("p" ++ show i) | i <- [1..base] ]
    sigDum  = [ atom ("d" ++ show i) | i <- [1..m] ]
    sig     = sigCh ++ sigDum
    ctxDum  = [ U.Pi (con "p1") (con ("d" ++ show i)) | i <- [1..m] ]
    ctxCh   = con "p1"
            : [ U.Pi (con ("p" ++ show i)) (con ("p" ++ show (i+1))) | i <- [1..base-1] ]
    ctx     = ctxDum ++ ctxCh
    goal    = con ("p" ++ show base)

-- (4) 証明不能チェーン: 出発点 p1 のないチェーン。ゴールに到達できず
--     探索空間を（深さ上限まで）全部舐める最悪ケース。NotFound の速度を測る
unprovChain :: Int -> Problem
unprovChain n = Problem ("unprov_chain_" ++ show n) 8 (U.ProofSearchQuery sig ctx goal)
  where
    sig  = [ atom ("p" ++ show i) | i <- [1..n] ]
    ctx  = [ U.Pi (con ("p" ++ show i)) (con ("p" ++ show (i+1))) | i <- [1..n-1] ]
    goal = con ("p" ++ show n)

-- (3) 結合子ミックス: Σ(∧)の入れ子。p ⊢ p∧p∧...∧p（SigmaIntro の分岐コスト）
conj :: Int -> Problem
conj n = Problem ("conj_" ++ show n) (n + 3) (U.ProofSearchQuery sig ctx goal)
  where
    sig  = [ atom "p" ]
    ctx  = [ con "p" ]
    goal = nest n
    nest :: Int -> U.Preterm
    nest 1 = con "p"
    nest k = U.Sigma (con "p") (nest (k-1))

problems :: [Problem]
problems =
     [trivial, unprovable]
  ++ map chain       [2,4,6,8,10,15,20]
  ++ map dummies     [0,2,4,8,16]
  ++ map dummiesPi   [0,2,4,8,16]
  ++ map conj        [2,4,6,8,10,12,14,16,18,20]
  ++ map unprovChain [2,4,6,8]

--------------------------------------------------------------------------------

-- | 引数で問題IDを指定するとその問題だけ実行する（例: stack run wani-bench conj_20）
main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  let selected = if null args then problems
                 else filter (\p -> probId p `elem` args) problems
      trials = 3                     -- 同一問題の反復回数（ばらつき推定）
      tmo    = 30 * 10 ^ (6 :: Int)  -- 30 秒（マイクロ秒）
  putStrLn "id,trial,outcome,seconds"
  forM_ selected $ \p ->
    forM_ [1 .. trials] $ \k -> do
      (out, dt) <- measureOnce tmo p
      printf "%s,%d,%s,%.4f\n" (probId p) (k :: Int) (showOutcome out) dt
