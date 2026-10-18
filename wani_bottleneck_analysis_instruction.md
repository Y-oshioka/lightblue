# Wani「どこが本当に遅いのか」を確定するための作業指示書
対象: lightblue / Wani  
作業環境: VS Code + WSL2  
目的: 高速化を実装する前に、Wani の遅さが「探索ノード数の爆発」なのか「1ノード当たりの処理の重さ」なのか、さらにどの関数・規則が時間を使っているのかを特定する。

---

## 0. 今回のゴール

今回の作業では **高速化そのものはまだ行わない**。

最終的に、少なくとも次のように言える状態を目指す。

> `conj_16` が遅い主因は、○○規則によって探索ノード数が増えているためである。  
> あるいは、探索ノード数ではなく△△関数の1回当たりの処理が重いためである。

同様に、JSeM の遅い実例（まず ID 374）についても、`found=False` のとき何が増えているのか、どの関数に時間が集中しているのかを確認する。

### 今回の主要な比較対象

| 問題 | 前回の結果 | 性質 |
|---|---:|---|
| `conj_14` | 約 1.18 s | Found |
| `conj_16` | 約 2.76 s | Found |
| `conj_18` | 約 8.98 s | Found |
| JSeM ID 374 | Wani 約 15.83 s | found=False |

前回の実験では `conj_n` は n の増加に伴って指数的に遅くなった。一方、JSeM の重い呼び出しは found=False に集中していた。

---

# 1. 最初に前回の作業を保全する

前回の資料では、以下の変更が未コミットだった可能性がある。

- `bench/Bench.hs`
- `package.yaml`
- `src/DTS/NaturalLanguageInference.hs`
- 計測手順書

**いきなり checkout / reset しないこと。**

## 1-1. VS Code で WSL 側の lightblue を開く

VS Code で `lightblue` のディレクトリを WSL 上から開く。統合ターミナルが Linux/WSL になっていることを確認する。

```bash
pwd
uname -a
```

## 1-2. 現在の Git 状態を確認

```bash
git status
git rev-parse --short HEAD
git branch --show-current
```

前回の基準版は `69b5e07` だった。

## 1-3. 念のため差分を退避

```bash
mkdir -p ~/wani-bench/runs
git diff > ~/wani-bench/runs/pre_bottleneck_analysis.patch
git status > ~/wani-bench/runs/pre_bottleneck_analysis_gitstatus.txt
```

未追跡ファイルもある場合は `git status` で名前を確認し、別途コピーしておく。

可能なら作業用ブランチを作成する。

```bash
git switch -c wani-bottleneck-analysis
```

前回の計測コードが正常に動くことを確認した後、計測基盤だけを一度コミットしておくのが望ましい。

---

# 2. 実験ディレクトリを作る

今回の結果を前回の結果と混ぜない。

```bash
RUN=~/wani-bench/runs/bottleneck_$(date +%Y%m%d)
mkdir -p "$RUN"/{baseline,rts,prof,counters,notes}
echo "$RUN"
```

環境情報を保存する。

```bash
{
  date
  uname -a
  stack --version
  git rev-parse HEAD
  nproc
  grep MemTotal /proc/meminfo
} > "$RUN/env.txt"
```

---

# 3. まず前回の結果を再現する

ここではコードを変更しない。

## 3-1. `wani-bench` が存在することを確認

VS Code の Explorer で `bench/Bench.hs` を開く。また、`package.yaml` で `wani-bench` の executable 定義を確認する。

VS Code の全文検索 `Ctrl+Shift+F` で以下を検索する。

```text
wani-bench
conj_n
chain_n
unprov_chain
```

## 3-2. ビルド

```bash
stack build
```

エラーが出た場合は、先に前回の環境との差を確認し、コード変更で無理に直さない。

## 3-3. 合成問題を再計測

既存の `wani-bench` が全問題を出力する設計なら、そのまま実行する。

```bash
stack run wani-bench > "$RUN/baseline/wani_bench.csv" 2> "$RUN/baseline/wani_bench.err"
```

現在の `package.yaml` で実行形式名の指定方法が異なる場合は、その定義に従う。

### 確認する値

`conj_14`, `conj_16`, `conj_18` の中央値が、前回の 1.18 s / 2.76 s / 8.98 s と大きく外れていないか確認する。

完全一致する必要はないが、桁や増加傾向が違う場合は、その時点で原因を確認する。

### ここでの終了条件

- `conj_n` の増加傾向を再現できた
- Found / NotFound / TimedOut の記録が正しい
- 結果を CSV として保存できた

**再現できるまで、次の高速化・プロファイルには進まない。**

---

# 4. Debug.Trace の影響を確認する

前回の資料では `searchProofWithIncrementalDepth` 周辺の `Debug.Trace` が計測に混入している可能性が指摘されている。

VS Code で `Ctrl+Shift+F`:

```text
Debug.Trace
D.trace
searchProofWithIncrementalDepth
```

を検索する。

1. まず Trace 有効のまま1回計測
2. Trace を無効化できるようにする
3. 同じ問題を再計測
4. 差が大きいか確認

Trace 無効化は「高速化」ではなく、**計測ノイズの除去**として扱う。

---

# 5. GC / メモリアロケーションが原因か確認する

まずコードを大きく改造せず、RTS 統計を取る。

```bash
stack run wani-bench -- +RTS -s -RTS 2> "$RUN/rts/rts_stats.txt"
```

実行方法は現在の executable 定義に合わせる。

## 見る項目

- Total time
- MUT time
- GC time
- %GC
- bytes allocated
- maximum residency

### 判断

- `%GC` が低い → 主因は探索アルゴリズム側の可能性が高い
- `%GC` が 30% 前後以上 → アロケーションやデータ構造のコストを優先して疑う

結果を `notes/gc_notes.md` に記録する。

---

# 6. 関数レベルのプロファイルを取る

**通常の時間計測とは別実行にする。**

プロファイルビルドは実行自体を遅くするため、プロファイル時の絶対秒数はベースラインと比較しない。

## 6-1. ビルド

```bash
stack build --profile
```

## 6-2. 実行

前回の手順書に従い、

```bash
stack run --profile -- +RTS -p -RTS
```

を基本とする。`wani-bench` を明示する必要がある構成なら、現在の Stack の executable 定義に合わせる。

終了後、生成された `*.prof` を確認する。

```bash
find . -name "*.prof" -o -name "*.hp"
```

生成された `.prof` を `$RUN/prof/` へコピーする。

## 6-3. `.prof` で見るもの

特に上位の `%time` と `%alloc` を確認する。

VS Code で以下の語を検索し、プロファイル上位の関数とソースを対応付ける。

```text
SigmaIntro
BackwardRules
typeCheck
searchProof
deduce
subGoal
```

`notes/profile_summary.md` に次の表を作る。

| 順位 | 関数 | %time | %alloc | 役割 | 気づいたこと |
|---|---|---:|---:|---|---|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |

**この時点ではまだ「原因確定」と言わない。**

---

# 7. 探索ノード数カウンタを入れる

ここが今回の中心作業。

前回の課題は、`conj_n` が遅いのは探索ノード数が爆発しているからなのか、それとも1ノード当たりが重いからなのかが分からなかったこと。

## 7-1. `Status` を探す

VS Code の `Ctrl+Shift+F`:

```text
data Status
WaniBase.Status
```

`src/DTS/Prover/Wani/` 以下の該当定義を開く。

## 7-2. 最低限追加したい計測値

実際の型・更新方法は現在のコードに合わせる。

最低限:

1. **探索ノード数**
2. **typecheck 呼び出し回数**

余裕があれば:

3. `SigmaIntro` を試した回数
4. 生成した subgoal / subgoal set の個数
5. 最大分岐数

最初から大量のカウンタを追加しすぎない。まず `nodes` と `typechecks` の2個でよい。

## 7-3. 「探索ノード」の定義を固定する

推奨定義:

> backward search が1つの証明状態（context + goal）を展開し、推論規則の適用候補を調べ始めた時点を1ノードと数える。

どこでインクリメントしたかを `notes/counter_definition.md` に明記する。

## 7-4. CSV に出す

最終的に `wani-bench` の出力に少なくとも以下を追加する。

```text
problem,trial,outcome,seconds,nodes,typechecks
```

---

# 8. `conj_n` をカウンタ付きで再計測する

対象:

```text
conj_10
conj_12
conj_14
conj_16
conj_18
```

各問題を3〜5回計測し、中央値を使う。保存先は `$RUN/counters/conj.csv`。

## 作る表

| n | median sec | nodes | typechecks | sec/node |
|---:|---:|---:|---:|---:|
| 10 | | | | |
| 12 | | | | |
| 14 | | | | |
| 16 | | | | |
| 18 | | | | |

## 判断基準

### A. nodes が時間と同様に急増し、sec/node はほぼ一定

→ **探索空間の爆発が主因**

次に調べる対象:
- `SigmaIntro`
- 生成 subgoal 数
- 分岐数
- 同じ/似た状態の再訪

### B. nodes はあまり増えないが sec/node が増える

→ **1ノード当たりの処理が重い**

次に調べる対象:
- typecheck
- substitution
- normalization
- term size
- allocation / GC

### C. nodes と sec/node の両方が増える

→ 両方が問題。プロファイル上位関数と組み合わせて主因を順位づけする。

---

# 9. JSeM ID 374 を「純 Wani」に近づけて調べる

前回の実文計測では、パイプライン全体の時間はパース支配だった。

したがって、**JSeM全体の実行時間を Wani の性能として扱わない。**

可能なら ID 374 の `ProofSearchQuery` を保存し、`wani-bench` から直接再生できるようにする。

```text
JSeM XML
  ↓ 一度だけ lightblue
ProofSearchQuery を保存
  ↓
wani-bench から繰り返し再生
```

これによりパーサを除外して、ID 374 の Wani だけを何度でも測れる。

最低限、ID 374 についても以下を取得する。

```text
seconds
nodes
typechecks
%GC
profile top functions
```

---

# 10. `conj_n` と ID 374 を比較する

最終的に次の表を作る。

| 指標 | conj_16 | JSeM 374 |
|---|---:|---:|
| outcome | Found | NotFound |
| median seconds | 約2.76s（前回） | 約15.83s（前回） |
| nodes | | |
| typechecks | | |
| sec/node | | |
| %GC | | |
| 最上位関数 | | |
| SigmaIntro比率 | | |

---

# 11. 「ボトルネック確定」の判定

以下のどれかまで言えれば、今回の目的は達成。

## パターン1: 連言分岐の探索爆発

> `conj_n` の時間増加と探索ノード数の増加が一致した。プロファイルでも `SigmaIntro` 周辺の処理が上位を占める。よって `conj_n` の主因は1ノードの重さではなく、連言に伴う探索状態数の増大である。

## パターン2: 失敗探索の探索爆発

> ID 374 の found=False 探索では、成功例より大幅に多くの探索ノードを訪問している。1ノード当たりの時間は大きく変わらない。よって主因は失敗探索での探索空間の走査である。

## パターン3: 1ノード当たりが重い

> 探索ノード数はそれほど増加していないが、typecheck 回数または1回当たりの処理時間が増えている。プロファイルでも型検査/正規化/置換の特定関数に時間が集中する。よって探索順ではなくノード内部処理が主因である。

---

# 12. この段階ではまだやらないこと

以下は、ボトルネックを確定するまで保留する。

- Neural Wani のような規則選択の実装
- メモ化 / tabling
- 枝刈りの変更
- 探索順序の変更
- `SigmaIntro` のアルゴリズム変更
- 型検査処理の最適化

理由: **原因を確定する前に高速化すると、「何が効いたのか」が分からなくなるため。**

---

# 13. 今回の成果物

最低限、以下を残す。

```text
bottleneck_YYYYMMDD/
├── env.txt
├── baseline/
│   ├── wani_bench.csv
│   └── wani_bench.err
├── rts/
│   └── rts_stats.txt
├── prof/
│   └── *.prof
├── counters/
│   ├── conj.csv
│   └── jsem374.csv
└── notes/
    ├── gc_notes.md
    ├── profile_summary.md
    ├── counter_definition.md
    └── conclusion.md
```

`conclusion.md` には必ず以下を書く。

1. どの問題を測ったか
2. Git hash
3. 実行条件
4. 探索ノード数
5. typecheck 回数
6. プロファイル上位関数
7. 「探索数の爆発」か「1ノードの重さ」か
8. 次に最適化すべき箇所を **1つだけ**

---

# 14. 作業順チェックリスト

- [ ] 前回の未コミット変更を保全した
- [ ] 作業ブランチを作った
- [ ] 前回の `conj_n` 結果を再現した
- [ ] Debug.Trace の影響を確認した
- [ ] `+RTS -s` で GC 統計を取った
- [ ] `+RTS -p` で関数プロファイルを取った
- [ ] 探索ノード数カウンタを追加した
- [ ] typecheck 回数カウンタを追加した
- [ ] `conj_10..18` を再計測した
- [ ] nodes と sec/node の増え方を比較した
- [ ] ID 374 を可能な限り純 Wani で再現した
- [ ] `conj_n` と ID 374 のボトルネックを比較した
- [ ] `conclusion.md` に原因と次の対象を1つ書いた

---

# 最重要ルール

## 高速化を先にしない

今回の目的は

> **「速くする」ことではなく、「どこを速くすべきかを証拠付きで決める」こと。**

次の研究段階へ進む条件は、

> 「この関数・この探索構造が、○○という測定結果からボトルネックである」

と説明できること。

それができてから、Neural Wani と重ならない高速化手法（例: 重複探索の削減、tabling、failure cache、インデックス化など）の選択に進む。
