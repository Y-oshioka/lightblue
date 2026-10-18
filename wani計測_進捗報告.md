# wani 計算速度 計測プロジェクト 進捗報告

- 対象: lightblue 内蔵の証明器 **wani**（`src/DTS/Prover/Wani/`）
- 版: lightblue master `69b5e07`（GHC 8.10.7 / lts-18.28）
- 日付: 2026-07-10
- 参照: `wani計測ハーネス構築手順.txt`（本報告と対で更新済み）

この報告は手順書の2層構成（レイヤーA=パイプライン層 / レイヤーB=証明器単体層）に沿って
「何を作り」「何が分かり」「speed向上のために次に何をすべきか」を述べる。

---

## 0. 要約（現在地）

| 手順書の項目 | 状態 |
|---|---|
| レイヤーB: wani単体の計測ハーネス | ✅ 構築・計測済み |
| レイヤーA: JSeM実文パイプライン | ✅ 動作確認済み（形態素解析器を自前ビルド） |
| wani単体の計時インストルメント | ✅ 実装・計測済み |
| 遅い事例の**網羅的**収集 | ⬜ 未（今回は試運転=先頭12問のみ） |
| 改善版との**比較**プロトコル | ⬜ 未（ベースラインは取得済み） |

**中心的発見（両層で一致）**:
wani の律速は **「証明を見つけられない肯定側の探索（found=False）」** で、
探索空間を上限深さまで舐めるために秒オーダーになる。
証明が存在するケース（found=True）は一貫して高速（≤0.04s）。

---

## 1. 環境（手順書1章）

- OS: WSL2 (Linux) / 8 cores / 16GB
- ビルド: stack 3.7.1, GHC 8.10.7（lightblue本体）
- 形態素解析器: **juman++ 2.0.0-rc4 を自前ビルド**（`~/.local/bin/jumanpp`）
  - Debian の apt `juman` は連接行列が空（`jumandic.mat`=7B, `JUMAN.connect`=0B）で
    全入力が EOS になる**不良品**。使用不可と判明したため jumanpp に切替。
  - cmake は pip 版、公式リリース（モデル同梱316MB）を sudo 無しで `~/.local` に導入。
- JSeM データ: `~/JSeM/data/v1.0/`（23カテゴリ・全2万問超）
- 環境スナップショット: `~/wani-bench/runs/env_20260710.txt`

> ハマりどころ: 環境変数 `LIGHTBLUE` は**末尾スラッシュ必須**
> （lightblue が Juman.dic を `$LIGHTBLUE ++ "src/..."` で開くため）。

---

## 2. レイヤーB：wani単体の計測（手順書2章）＝高速化研究の主戦場

### 作ったもの
- `bench/Bench.hs`（lightblue内の実行ファイル `wani-bench`）。
  `Wani.prove'` を直接呼び、`ListT.toList`＋`evaluate (length …)` で
  遅延評価を潰してから `getMonotonicTime` で計時。
- パラメータ `n` で難易度を振るスケーラブル問題族:
  - `chain_n`（含意チェーン, 深さ方向）
  - `dummy_m` / `dummypi_m`（無関係な前提の混入, 前提数方向）
  - `conj_n`（Σ(∧)の入れ子, 結合子分岐）
  - `unprov_chain_n`（証明不能, 探索失敗の最悪ケース）

### 結果（中央値・3試行, `~/wani-bench/runs/base_69b5e07_..._v2.csv`）
| 問題族 | 伸び方 | 代表値 |
|---|---|---|
| `chain_n` | ほぼ線形（健全） | n=20 で 0.09s |
| `dummy_m` / `dummypi_m` | ほぼ一定（健全） | m=16 で 数ms |
| `unprov_chain_n` | 数十ms（刈り込み有効） | n=8 で 0.03s |
| **`conj_n`** | **指数爆発** | n=12:0.27s → 14:1.2s → 16:2.8s → 18:9.0s → 20:TimedOut(>30s) |

→ **Σ導入（SigmaIntro）の分岐処理が第一のボトルネック候補**。
   含意チェーン・無関係前提・証明失敗の刈り込みは健全だった。

---

## 3. レイヤーA：JSeM実文パイプライン（手順書3章）＝事例収集用

### 動作確認
`日本語文 → juman++ → CCG構文解析 → DTS意味表示 → wani → Yes/No判定` が
実文で通ることを確認（Prediction が Ground truth と一致する例あり）。

動作コマンド:
```
export PATH="$HOME/.local/bin:$PATH"; export LIGHTBLUE=/home/yrlim/DTS/lightblue/
./lightblue jp -m jumanpp jsem --jsemid <id> -f <xml> -b 5 --maxdepth 5 --maxtime 8000 -s text
```

### 判明した重要事実
**レイヤーAの実時間はパース支配**であり、そのままでは wani 速度の指標にならない。
- 単純文でも約6秒（大半は起動時の辞書ロード）。
- `--noInference`（推論なし）でもタイムアウトする問題がある＝遅さはパーサ由来。
- 1問が「複数パース木 × 正/負の証明探索」を回すため、個々のwaniが速くても累積で timeout。

→ 手順書の設計（「レイヤーAは事例収集、速度の主指標はレイヤーB」）を実測で裏付けた。

---

## 4. wani単体の計時インストルメント（手順書3章(3)）

パイプライン全体の時間から **wani だけ**を切り出すため、
`src/DTS/NaturalLanguageInference.hs` の証明探索駆動点（`trawlParseResult`）を計時。
1呼び出しごとに stderr へ1行 TSV を出力:
```
WANI_TIME <pos|neg> sec=.. found=.. sig=.. premises=.. goalchars=..
```
収集: `~/wani-bench/scripts/collect_wani_times.sh`
整形: `~/wani-bench/scripts/make_report.py` → `wani_layerA_report.md`

### 結果（★これは「試運転」レベルのサンプル。5章参照）
対象: Plurals.xml **先頭12問**（ID 370–381）, beam3。
- wani 呼び出し **47回**、中央値 **0.096s**、最大 **15.8s**。
- 1秒超の重い呼び出しは **10回（21%）** だが、**総wani時間の92%**を占める。
- 重い呼び出しは**全て pos かつ found=False**。found=True は全て ≤0.04s。

| JSeM-ID | tag | 秒 | found |
|---|---|---|---|
| 374 | pos | 15.83 | False |
| 372 | pos | 10.14 | False |
| 373 | pos | 9.45 | False |

→ レイヤーBの `unprovable`/`conj` 系の爆発と**同じ構造**が実文でも観測された。

---

## 5. 今回の計測の限界（重要・自己批判）

**「先頭12問」は手順書の言う "試運転" に相当するだけで、速度検証の方法ではない。**
手順書の該当記述:
- 3章: 「目的は網羅的な時間計測ではなく『遅い・失敗する事例のID一覧』を作ること。1問1回でよい。」
- 3章: 「※最初は head -20 … で試運転。」
- 2章: 速度検証は**レイヤーBのn振りベースライン**が本体、JSeM実例は「答え合わせ」。

今回の12問は「1カテゴリ・先頭・パースが軽そう」で選んでおり、
JSeM全体の代表ではない。よって「実文にも秒オーダーの重いwani呼び出しが実在する」ことの
**実証**としては有効だが、「全体の何%が遅い」等の**統計的主張はできない**。

---

## 6. 今後すべきこと：waniの計算速度を「比較」するために

高速化は「改善版が本当に速いか」を数字で言えて初めて意味を持つ。
そのための計測・比較基盤として、次を優先度順に行う。

### A. 計測の信頼性を固める（最優先・比較の土台）
1. **ベースラインの固定**: 版ごとに `git hash + env.txt + CSV` を必ず残す（手順書1章）。
   計測は**中央値**（GC外れ値対策）、同一問題**3〜5回**でばらつき確認。
2. **比較プロトコルの確立**: 「同一ハーネス・同一問題セットで、waniの版だけを変える」。
   改善前後で `base_<hash>.csv` を並べ、問題ごとに中央値の比を出す（A/B比較表）。
   → これが無いと「速くなった」が言えない。

### B. 「なぜ遅いか」を切り分ける（改善対象の特定）
3. **探索ノード数カウンタの導入**: `WaniBase.Status` に探索ノード/typecheck回数の
   カウンタを足し、`conj_n` や found=False の爆発が
   「ノード数の爆発」か「1ノードが重い」かを切り分ける（時間だけでは分からない）。
4. **プロファイル取得**: `stack build --profile` → `+RTS -p` で `conj_14〜16` と
   実文の遅い事例（374等）の**関数別内訳**を取る。`+RTS -s` で %GC も確認
   （30%超ならアロケーションが先）。※時間計測とは別実行で（プロファイルは数倍遅い）。

### C. 対象問題を「正しく」集める（手順書に沿う）
5. **レイヤーAを網羅的に走査**して**遅い・失敗する事例のIDリスト**を作る
   （1問1回, 全カテゴリからランダムサンプリング。先頭N問はやめる）。
   wani計時0件（パース未到達）の問題は別集計にし、「waniに到達した問題」で母数を作る。
6. **遅い実例をレイヤーBへ移植**（「答え合わせ」）。
   `ProofSearchQuery` は `Generic`/`Store` を derive しているので、
   遅い事例のクエリをダンプ→`wani-bench` で読み込めば、**パースを排除した純wani**で
   何度でも再現計測できる（現状はstderr計時で代用中）。

### D. 具体的な高速化ターゲット（仮説）
7. **found=False（証明失敗）の肯定側探索の刈り込み**。両層で律速。
   探索が深さ上限まで舐めるのを、失敗の早期検出・メモ化・枝刈りで抑える。
8. **SigmaIntro の分岐コスト**（`BackwardRules.hs`）。`conj_n` の指数爆発の震源。
9. **`Debug.Trace` の常時出力**（`searchProofWithIncrementalDepth` の `D.trace`）が
   オーバーヘッドになっていないか。計測前に切れるようにする。

### 比較の最終形（目標）
> 「版 X→Y で、問題族 `conj_n` の中央値が n=16 で 2.8s→??s、
>  JSeM遅い事例10件の合計wani時間が 64s→??s に短縮」——のように、
> **同一問題セット・中央値・git hash付き**で改善を言える状態にする。

---

## 7. 成果物一覧

| 種別 | パス |
|---|---|
| 計測ハーネス手順書 | `lightblue/wani計測ハーネス構築手順.txt` |
| 本進捗報告 | `lightblue/wani計測_進捗報告.md` |
| レイヤーB ドライバ | `lightblue/bench/Bench.hs`（exe: `wani-bench`） |
| 計時インストルメント | `lightblue/src/DTS/NaturalLanguageInference.hs`（`timeProofSearch`） |
| レイヤーA 収集スクリプト | `~/wani-bench/scripts/run_jsem.sh`, `collect_wani_times.sh` |
| レポート生成 | `~/wani-bench/scripts/make_report.py` |
| レイヤーB 結果 | `~/wani-bench/runs/base_69b5e07_..._v2.csv` |
| レイヤーA 結果 | `~/wani-bench/runs/wani_layerA.tsv`, `..._meta.csv`, `..._report.md` |
| 環境記録 | `~/wani-bench/runs/env_20260710.txt` |

> 注: `bench/Bench.hs`・`package.yaml`・`NaturalLanguageInference.hs`・手順書 の
> 変更は未コミット（ワーキングツリー）。ベースライン確定時にコミット推奨。
