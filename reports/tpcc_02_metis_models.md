# TPC-C ② Metis モデルの変遷と評価結果

最終更新 2026-11-03。実験条件は [① 条件と oracle](tpcc_01_conditions_and_oracle.md)、各段階で直した問題は [③ 落とし穴](tpcc_03_pitfalls.md) を参照。

## 要点

- 現在の最良モデル **Metis-test-SMT** は、同時に測った最良のベースライン（96 worker 固定の Silo）に対して、固定負荷で W=1〜32 は +21〜63%、W=64/96 は同等（±0.3%）。動的負荷では +16〜35%。
- ただし **W（active warehouse 数）を特徴量に入れ、報酬の分母に固定 N 掃引の実測値 R(W) を埋め込んでいる**。W を知らない v2 に置き換える予定。
- **W=32/64 では最高 N=48 を選べず**、64 または 96 を選ぶ。
- **adaTAM との比較は旧条件でしか行っていない**。旧条件では勝ち負けが混在した。現行条件ではまだ比較していない。

## モデルの系譜

| 名前（コード上） | 主な特徴 | TPC-C での結果 | 状態 |
|---|---|---|---|
| `Metis_paper`（ワークショップ版） | action ごとに独立した LinUCB が 45 個、報酬は移動平均の z-score、10 ms 周期、現在と同じ action は選べない | W=16（未学習）の評価で 238,543 TPS。低い N をほぼ選べない | YCSB では使用。TPC-C では失敗（[③-1〜5](tpcc_03_pitfalls.md)） |
| Metis-test（W=16 だけで学習） | 共有線形モデル、7 候補、200 ms 周期、報酬 TPS/400k | 学習した W=16 自体の評価では 24 を維持（30 秒 × 3 run で平均 361,410 TPS） | 同じ状態内での学習だけ確認 |
| Metis-test warehouse-aware | 特徴量に W・coverage・集中度を入れ、報酬は TPS/S(W) | 未学習 W の評価（旧条件）：W=1/4/16/32/96 で 40k/123k/332k/602k/639k TPS | 下の SMT 版に置き換え |
| Metis-test observed-load | W を使わない。96 で probe し、abort 率 a から `k/a` に最も近い N を選ぶ（係数 k は 1 つだけ） | 旧条件の 6 区間動的負荷で 622,181 TPS（Silo-BO より +2.06%） | v2-B の土台 |
| Metis-test（45 候補） | 候補を 8〜96 の 2 刻みに細かくした | 動的負荷の性能は改善しなかった | 採用せず |
| 報酬の再校正版 | 分母を実測の R(W) に変更 | W=16 の主な選択が 64→48、W=32 が 96→64 に改善 | 下の SMT 版に置き換え |
| **Metis-test-SMT**（現行） | 上に SMT の 2 特徴（`N>48` の指標、SMT を使う割合）を追加。14 次元 | 下表 | 現在の最良。ただし W と R(W) を使う |

## Metis-test-SMT：固定負荷（評価する W を学習から除く leave-one-out）

標準条件、30 秒 × 2 run、5 方式を同じ時期に測定。評価中は学習しない。比較方式は 96 worker 固定。

| W | Metis-SMT | 選んだ N | 固定 N の最高値（N） | Silo backoff なし | Silo backoff あり | Cicada | ERMIA |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | **55,153** | 8 | 54,350（8） | 31,908 | 34,161 | 37,111 | 535 |
| 4 | **125,627** | 24 | 125,190（24） | 73,064 | 76,918 | 63,422 | 3,523 |
| 8 | **215,725** | 48 | 218,271（48） | 133,314 | 140,052 | 94,315 | 6,363 |
| 16 | **386,650** | 48 | 389,051（48） | 251,033 | 260,646 | 154,685 | 13,257 |
| 32 | **551,253** | **64** | 598,057（48） | 452,941 | 455,014 | 229,699 | 25,730 |
| 64 | **720,217** | **96** | 779,349（48） | 719,852 | 707,690 | 300,752 | 50,924 |
| 96 | 880,150 | 96 | 880,461（80） | **882,543** | 865,841 | 359,707 | 78,920 |

- 固定 N の最高値は、別の時期に 15 秒で測った値（[①](tpcc_01_conditions_and_oracle.md)）。
- W=32/64 で選択を誤る理由：W=32 だけで学習したモデルは 48 を選ぶが、W=32 を除いて学習したモデルでは score(64)>score(48) になる。SMT 特徴の係数が全 W で共通なので、「W=32/64 では SMT が損、W=96 では得」という違いを表せない。W=64 で N=48 を観測したのは 4 回だけ。
- ERMIA の値は異常に低く、実装か GC 設定の問題が疑われる。論文には載せない。
- 図：[TPS](../experiments/ICDE/tpcc/metis_test/figures/physical_first_item100k_aware_smt_loo_v1/fixed_protocol_tps.png)、[選んだ N の推移](../experiments/ICDE/tpcc/metis_test/figures/physical_first_item100k_aware_smt_loo_v1/fixed_held_out_active_threads.png)。データ：[全 70 run](../experiments/ICDE/tpcc/metis_test/logs/eval/physical_first_item100k_aware_smt_loo_v1/fixed/results.csv)、[モデル](../experiments/ICDE/tpcc/metis_test/models/physical_first_item100k_aware_smt_loo_v1/all/model.txt)。

## Metis-test-SMT：動的負荷

標準条件、各 W を 20 秒ずつ、60 秒 × 2 run。**全 W で学習したモデル**を使うので、未学習の負荷への汎化を試す実験ではない。

| W の推移 | Metis-SMT | Silo（高い方） | 差 | 選んだ N |
|---|--:|--:|--:|---|
| 16→32→4 | **356,628** | 264,437 | +34.9% | 48→64→24 |
| 16→96→4 | **464,591** | 401,311 | +15.8% | 48→96→24 |

図：[選んだ N](../experiments/ICDE/tpcc/metis_test/figures/physical_first_item100k_aware_smt_loo_v1/dynamic_active_threads.png)、[TPS](../experiments/ICDE/tpcc/metis_test/figures/physical_first_item100k_aware_smt_loo_v1/dynamic_protocol_tps.png)。

## adaTAM との比較（すべて旧条件：home を worker に固定、旧 CPU 配置）

現行条件では未比較。旧条件での結果も、現行条件に当てはめてはいけない。

| 実験 | Metis-test | adaTAM | 勝った方 |
|---|--:|--:|---|
| 固定負荷 W=1 / 4 / 16 / 32 / 96（15 秒 × 2 run） | 51.9k / 181k / 498k / 831k / 1,666k | 43.8k / 156k / 498k / 851k / 1,667k | W=1/4 は Metis（+18%/+16%）、W=32 は adaTAM（+2.3%）、残りは同等 |
| 動的 16→4→32（observed-load 版） | 494,374 | **508,536** | adaTAM |
| 動的 4→1→16（aware 版、glibc 環境で学習） | 233,606 | **244,242** | adaTAM |

- 固定負荷の時間ごとの選択：adaTAM は 96 から 2 ずつ動き、W=1/4/16/32 では N の高い方の周辺を行き来した。Metis は約 0.6 秒で決まった値に移った。
- データ：[固定負荷](../experiments/ICDE/tpcc/metis_adatam_mimalloc_fixed_v1)、[16→4→32](../experiments/ICDE/tpcc/metis_adatam_dynamic_16_4_32_v1)、[4→1→16](../experiments/ICDE/tpcc/metis_adatam_dynamic_4_1_16_aware_mimalloc_v2)。

## 旧条件での方式比較（参考）

home を worker に固定、旧 CPU 配置、mimalloc、6 区間の動的負荷（16→1→96→4→32→16、各 10 秒）。

| 方式 | 平均 TPS |
|---|--:|
| Metis-test（mimalloc 環境で再学習） | **622,181**（3 run） |
| Silo backoff あり | 609,628（3 run） |
| Metis-test（glibc 環境で学習したモデル） | 600,746 |
| Silo backoff なし | 597,170 |
| Cicada | 517,436（GC 設定が他と違う） |
| ERMIA | 296,566 |

W=96 の区間だけは Silo backoff ありが高かった。データ：[protocol_comparison_mimalloc_final_v1](../experiments/ICDE/tpcc/protocol_comparison_mimalloc_final_v1)。

## 再実行の手順

```bash
cmake --build build_release --target tpcc_metis_test_smt -j 8
bash experiments/ICDE/tpcc/metis_test/physical_first_item100k_smt_train.sh
bash experiments/ICDE/tpcc/metis_test/physical_first_item100k_smt_fixed.sh
# 動的負荷：experiments/ICDE/tpcc/metis_adatam_dynamic_16_4_32.sh に METIS_BINARY・METIS_MODEL・SCHEDULE などを指定
```
