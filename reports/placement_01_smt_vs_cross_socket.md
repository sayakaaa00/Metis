# 配置の損の分解：SMT の共有と socket をまたぐこと（2026-11-03）

YCSB では socket0-first（socket をまたがず SMT を使う）が良く、TPC-C では physical-first（SMT を使わず socket をまたぐ）が良い。その原因を調べるため、active worker 数を N=24 に固定し、配置だけを変えて 2 つの損を別々に測った。

## 結論

- **SMT の損はどちらのベンチマークにもある**。TPC-C の方が大きい（YCSB は −12〜27%、TPC-C は −32〜37%）。
- **socket をまたぐ損は、hot な record の競合が強いときだけ大きい**。YCSB では skew とともに −24% → −53% と大きくなり、一様分布では −4% だけ。TPC-C では W によらず −2〜7%。
- N=48 では「SMT を使う」か「socket をまたぐ」かのどちらかを選ぶしかない。損の小さい方が良い配置になる。
  - 高 skew の YCSB：socket をまたぐ損（約 0.5 倍）が SMT の損（約 0.8 倍）より大きい → socket0-first。
  - TPC-C：SMT の損（約 0.65 倍）が socket をまたぐ損（約 0.95 倍）より大きい → physical-first。
- **一様分布の YCSB（1,000 万 tuple）は TPC-C と同じ傾向**になった（SMT 0.88 倍、socket またぎ 0.96 倍）。差の原因はベンチマークの種類ではなく、**hot な record をどれだけ多くの core で書き合うか**と、**1 回の取引の重さ**である。

## 結果（N=24、1S-phys を 1.00 とした TPS の比、10 秒 × 2 run）

| ワークロード | 1S-phys の TPS | 1S-SMT（SMT だけ） | 2S-phys（socket またぎだけ） | 2S-SMT（両方） |
|---|--:|--:|--:|--:|
| YCSB skew 0.7、10k tuple | 6,589,482 | 0.73 | 0.76 | 0.61 |
| YCSB skew 0.9、10k tuple | 2,911,806 | 0.79 | **0.47** | 0.47 |
| YCSB skew 0.99、10k tuple | 1,723,726 | 0.86 | **0.49** | 0.49 |
| YCSB 一様、1,000 万 tuple | 3,035,625 | 0.88 | 0.96 | 0.85 |
| TPC-C W=1 | 50,198 | **0.68** | 0.93 | 0.65 |
| TPC-C W=4 | 118,463 | **0.63** | 0.96 | 0.61 |
| TPC-C W=16 | 310,596 | **0.64** | 0.98 | 0.62 |
| TPC-C W=32 | 406,912 | **0.67** | 0.98 | 0.65 |

2 run の差は、最大でも 3.7%（YCSB skew 0.9 の 2S 配置）。

| 配置 | 使う CPU（active な 24 worker） |
|---|---|
| 1S-phys | socket0 の物理コア 24 個（CPU 0〜23） |
| 1S-SMT | socket0 の 12 コア × SMT 2（0〜11、48〜59） |
| 2S-phys | 両 socket の物理コア 12 + 12（0〜11、24〜35） |
| 2S-SMT | 両 socket の 6 コア × SMT 2（0〜5、48〜53、24〜29、72〜77） |

## 損の現れ方の違い（abort 率と 1 秒あたりの試行数）

試行数は commit と abort の合計を 1 秒あたりにした値（1S-phys を 1.00 とする）。

| ワークロード | 配置 | abort 率 | 試行数 |
|---|---|--:|--:|
| YCSB skew 0.9 | 1S-phys | 0.748 | 1.00 |
| | 1S-SMT | 0.716 | 0.70 |
| | 2S-phys | **0.828** | 0.69 |
| TPC-C W=16 | 1S-phys | 0.245 | 1.00 |
| | 1S-SMT | 0.233 | **0.63** |
| | 2S-phys | 0.242 | 0.97 |

- **socket をまたぐ（YCSB）**：abort 率が上がる。hot な record のキャッシュラインが socket の間を行き来するのに時間がかかり、取引が長引いて衝突が増えたと考えられる。
- **SMT（両方）**：abort 率は上がらず、むしろ少し下がる。下がるのは試行数で、1 回の試行が遅くなっている。sibling どうしが L1/L2 キャッシュと実行資源を取り合うため、と考えられる。

## 解釈

| | YCSB（10k tuple、高 skew） | TPC-C 標準ミックス |
|---|---|---|
| データの大きさ | 小さい。値は 4 byte で、全体がキャッシュに収まる | 約 30 GB（プロセスの常駐メモリ量） |
| 1 回の取引の重さ | 軽い。10 操作で、キャッシュ上で終わる | 重い。多くの record に触れ、insert や scan も含む |
| 性能を決めるもの | hot な record のキャッシュラインの移動時間 | 1 回の取引の実行時間（メモリの待ちと core の資源） |
| socket をまたぐ損 | 大きい。移動時間が取引時間の大部分を占める | 小さい。移動時間は取引時間のごく一部 |
| SMT の損 | 中くらい。高 skew ほど小さい（衝突待ちが支配的になるため） | 大きい |

- **TPC-C の W=1 でも socket をまたぐ損は −7% だけ**。競合は強いが、取引 1 回が長いので、キャッシュラインの移動にかかる時間は取引時間のごく一部にとどまる、と考えられる。
- **遠いメモリ（remote DRAM）へのアクセスとの区別**：DB はロード時に first-touch で置かれ、メモリ配置は OS 既定のままである。一様分布の YCSB（1,000 万 tuple）で socket をまたぐ損が −4% にとどまったので、remote DRAM へのアクセス自体の損は小さい。高 skew の YCSB の大きな損は、hot なキャッシュラインの coherence によるものと考えられる。
- **限界**：この KVM ゲストでは PMU が使えず、キャッシュミスや coherence の通信量を直接は測れない。上の解釈は TPS・abort 率・試行数からの推定である。

## 論文への示唆

- ワークショップ版の「socket-aware な配置」は、**hot な record を書き合う高競合のワークロード**では正しい。
- 一般には「socket をまたぐ損」と「SMT を共有する損」のどちらが大きいかで、最適な配置が変わる。前者は競合の強さに、後者は取引の重さに依存する。
- 配置の順序はベンチマークごとの設定値（YCSB は socket0-first、TPC-C は physical-first）として固定する。配置の選択まで学習の対象にするのは、今後の課題とする。

## データと再実行

- [全結果](../experiments/ICDE/placement_diagnosis_20261103/results.csv)、[設定とバイナリの SHA-256](../experiments/ICDE/placement_diagnosis_20261103/config.json)、[実行スクリプト](../experiments/ICDE/placement_diagnosis_20261103/run.py)
- 配置は環境変数 `CCBENCH_PIN_CPU_LIST`（worker i を列の i 番目の CPU に pin する）で指定した。実装は [cpu.hh](../include/cpu.hh) の `explicitPinCpu`。設定しなければ従来の動作は変わらない。
