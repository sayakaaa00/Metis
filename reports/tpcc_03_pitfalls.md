# TPC-C ③ 評価・実装の落とし穴と修正

最終更新 2026-11-03。TPC-C に移る過程で見つけ、修正した問題の一覧。論文の Methodology 節と ablation の根拠に使う。**A** はワークショップ版 Metis 自体の問題、**B** は測定環境とベンチマークの問題で、B は全方式に共通に効く。

## 一覧

| # | 区分 | 問題 | 影響の大きさ | 対策 |
|--:|:-:|---|---|---|
| 1 | A | 現在と同じ action を選べない（[tam.hh](../include/tam.hh) の `Metis_paper`） | 毎 trial 必ず action が変わる（変更率 100%）。YCSB でも最適値の周りで ±2 往復する | 同じ action の継続を許す（Metis-test） |
| 2 | A | 報酬の z-score の分母下限 50,000 TPS | TPC-C では 90〜100% の区間で分母が 50,000 に固定され、+5,000 TPS の改善でも報酬は +0.1 にしかならない。基準が移動平均なので、良い action を続けると報酬が 0 に戻る | 固定スケールの報酬にする。v2 では基準との比 |
| 3 | A | 特徴量の規模がばらばら（全部 1e6 で割っている） | 1 thread あたり TPS の特徴が TPC-C では YCSB の約 1/17 になり、正則化に埋もれる | 規模に依存しない特徴にする |
| 4 | A | action ごとに独立したモデルなので、候補 N の特徴が arm 内で定数になる | arm 間で学習データを共有できない | 共有線形モデルにする |
| 5 | A | 評価中も学習と探索が続く（`model_autosave=false` は保存を止めるだけ） | 「凍結したモデルで評価した」とは言えない | `learn=false`、α=0 を明示する |
| 6 | B | **TSC の換算ミス**（`clocks_per_us=2100`、実際は 2900 相当） | 区間 TPS が約 72% に縮んで記録される。30 秒の指定で実時間 41 秒走る。10 ms の制御周期は実際には約 7 ms | `--clocks_per_us=2900`。実時間との一致を確認済み |
| 7 | B | New-Order の insert 失敗のたびに、全 worker 共通の mutex を取って stdout へ書き出す | W=1 の学習 run で毎秒約 6 万行を出力 | `--tpcc_log_retry_conflicts=false` |
| 8 | B | **待機中の worker が `_mm_pause` で回り続ける** | 96 個作って 24 個を動かすと、24 個だけ作った場合より −22%。最高 N の位置がずれる | 50µs sleep |
| 9 | B | **先頭 N 個の worker で home warehouse が偏る**（`randomized_worker_affined`） | W=16・N=24 で 14 warehouse しか使わず、3 warehouse に 3 worker ずつ集中する。TPS −10% | 取引ごとに home を選ぶ `random_per_transaction`（現行） |
| 10 | B | **CPU 配置の順序**（socket0-first） | N=48 で socket0 の SMT sibling を使い、曲線に谷と二つ目の山ができる。physical-first にすると同じ N で +47〜63% | `--tpcc_pin_order=physical_first` |
| 11 | B | **allocator（glibc）** | 動的負荷の 60 秒平均が glibc で 132,478 TPS、mimalloc で 601,047 TPS。W=96 の区間では約 18 倍の差。モデルの判断にも波及する | 全方式で mimalloc を `LD_PRELOAD` |
| 12 | B | 止めた worker が TPC-C の retry ループから抜けない | action を変えてもすぐには効かず、次の trial の TPS が前の action の影響を受ける | RETRY のたびに active 数を確認（`METIS_TEST` のビルド） |
| 13 | B | W=1 の高競合でのメモリ寿命のバグ（Silo/TPC-C） | Segmentation fault、TPS が 0 のまま止まる | Stock の重複更新、Delivery の空 scan、未初期化ポインタ、abort した INSERT の即時解放をそれぞれ修正 |
| 14 | B | ERMIA / Cicada の GC | 通常の GC 間隔では実行時エラー、GC を遅らせるとメモリを使い切る。ERMIA は W=1 で 535 TPS | `gc_inter_us` などの設定を変えて回避したが、Silo と同じ条件にはなっていない。論文では扱いに注意 |
| 15 | B | 測定時間と反復回数 | W=16 で N=16 と 24 の順位が、5 秒の測定と 30 秒の測定で逆転した | 主要な比較は 20〜30 秒 × 3 run 以上、方式の順序を入れ替えて交互に測る |

## 詳細

### 8・9. 待機中の worker と home の偏り（同じバイナリで分解した実験）

W=16、標準ミックス、5 秒 × 2 run。

| 作る worker 数 | 動かす N | home の割当て | TPS |
|--:|--:|---|--:|
| 24 | 24 | worker に固定 | 466,533 |
| 96 | 24 | worker に固定 | 364,805（spin で −22%） |
| 96 | 24 | ランダムに固定 | 329,374（偏りでさらに −10%） |
| 96 | 24 | 均等化＋50µs sleep | 443,260（ほぼ回復） |

データ：[spin の比較](../experiments/ICDE/tpcc/metis_test/logs/fixed/balanced_prefix_baseline_20261026_073117/results.csv)。

### 10. CPU 配置の順序（同じバイナリ、15 秒 × 2 run）

| N | socket0-first の配置 | physical-first の配置 |
|--:|---|---|
| 24 | socket0 の物理コア 24 個 | 同じ |
| 48 | socket0 の物理コア 24 個 ＋ SMT 24 個 | 両 socket の物理コア 48 個 |
| 72 | 物理コア 48 個 ＋ SMT 24 個 | 同じ CPU の組（対応する worker の順だけ違う） |

N=48 での差：W=4/16/32 で +47.6/+63.2/+58.5%。図：[配置ごとの TPS](../experiments/ICDE/tpcc/metis_test/figures/mimalloc_pinning_order_ab_v1/tps_by_w.png)。

**ワークショップ版との関係**：ワークショップ版の「socket-aware order」は socket0-first にあたる。N≦24 では physical-first と同じ配置になるので、YCSB（最適値 14〜24）の結果とは矛盾しない。

### 11. allocator（同じモデル・同じ負荷の変化で、LD_PRELOAD の有無だけを変えた）

| 条件 | 60 秒平均 | W=96 区間 | W=32 区間 |
|---|--:|--:|--:|
| glibc | 132,478 | 95,357 | 57,542 |
| mimalloc | **601,047** | **1,758,149** | **764,834** |

データ：[区間別](../experiments/ICDE/tpcc/metis_test/figures/observed_dynamic_failure_v1/phase_metrics.csv)。

## 退避した資料

元の個別レポート、診断用スクリプト、JSON の全体は、2026-11-03 の整理の前に `reports_backup_20261103.tar.gz` に退避した（[README](README.md) を参照）。
