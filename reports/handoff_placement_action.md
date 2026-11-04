# 引き継ぎ：配置（CPU pin の順序）も action にして学習する Metis（2026-11-04）

別の session で進める作業の引き継ぎ資料。この資料だけで作業を始められるように書いてある。論文本体は、別の session で「今の Metis（版 RA、配置は physical-first に固定）」で書き進めている。

## 0. 守ること（最重要）

1. **論文版のコードと結果を変えない**。
   - [include/metis_v2.hh](../include/metis_v2.hh) の既定値と挙動。
   - `experiments/ICDE/metis_v2/` 以下の `results.csv`、`logs/`、`paper_figures/`、`models/`。
   - 新しい実装は、新しいファイル（例：`include/metis_v3.hh`）と新しいフラグ（例：`--metis_v3_enable`）、新しい出力先（例：`experiments/ICDE/metis_v3/`）で行う。
   - 既存の共通ファイル（`include/cpu.hh`、`common/runner.hh`、`include/tam.hh`、`include/tpcc.hh`）を変更するときは、新しいフラグが無効なら従来の動作がまったく変わらないようにする。
2. **ビルドのたびに既存のバイナリが置き換わる**ことに注意。論文版のバイナリ（`build_release/silo/tpcc_metis_test`、`ycsb_metis_paper`）を再ビルドする変更を入れたら、論文版の動作が変わっていないことを確認する。必要なら、新しい CMake ターゲット（例：`tpcc_metis_v3`、`ycsb_metis_v3`）を足す。
3. **測定は他の session と同時に走らせない**。マシンは 1 台（96 論理 CPU）。論文を書いている session は原則として測定しないが、測定を始める前に `pgrep -af "build_release"` で他のベンチマークが動いていないことを確認する。
4. リポジトリの規約は [CLAUDE.md](../CLAUDE.md) と `docs/` を参照（コーディング規約、`tx.read` の戻り値の確認など）。

## 1. 目的

今の Metis は active thread 数 N だけを選び、worker の配置は physical-first（socket0 の物理コア → socket1 の物理コア → SMT sibling）に固定している。しかし、最適な配置はワークロードによって逆になる。

| | 良い配置 | 根拠 |
|---|---|---|
| YCSB（10k record、高 skew） | socket0-first（socket0 の物理コア → socket0 の SMT → socket1） | N>24 で physical-first より +4〜89%（[ycsb_02_oracle.md](ycsb_02_oracle.md)） |
| TPC-C（標準ミックス） | physical-first | N=48 で socket0-first より +47〜63%（[tpcc_03_pitfalls.md](tpcc_03_pitfalls.md) #10） |

原因の分析（[placement_01_smt_vs_cross_socket.md](placement_01_smt_vs_cross_socket.md)、N=24 で配置だけを変えた 2×2 の実験）：

- SMT を共有する損は、どちらのベンチマークにもある（YCSB −12〜27%、TPC-C −32〜37%）。取引が重いほど大きい。
- socket をまたぐ損は、hot な record を書き合う競合が強いときだけ大きい（YCSB の skew 0.9〜0.99 で −51〜53%、一様分布で −4%、TPC-C で −2〜7%）。
- N=48 では「SMT を使う」か「socket をまたぐ」かのどちらかを選ぶしかなく、損の小さい方が良い配置になる。

**目標**：同じモデルが、YCSB の高競合では socket0-first、TPC-C では physical-first を自分で選ぶ。（N, 配置）の組を action にして学習する。

## 2. 今の Metis（版 RA）の要点

詳細は [paper_01_experiments_and_figures.md](paper_01_experiments_and_figures.md) の節 2。実装は [include/metis_v2.hh](../include/metis_v2.hh)（クラス `MetisV2`、variant A）。

- **モデル**：log(T(a)/T(c)) ≈ θᵀ[(φ(a) − φ(c)) ⊗ ψ(c)]。全候補（8〜96 の 2 刻み、45 個）で 1 つの θ を共有するリッジ回帰。
  - φ(n)（5 次元）：log(n/96)、n/96、(n/96)²、socket をまたぐ割合、SMT の割合。
  - ψ(c)（4 次元）：1、R、R²、c/96。R は c での abort 率。
  - socket をまたぐ割合と SMT の割合は、physical-first を前提に計算している（`MetisV2::phi`）。
- **学習**：状態ごとに N を一様ランダムに選び、移るたびに 1 サンプル。状態ごとの A, b を保存し、[merge_models.py](../experiments/ICDE/metis_v2/merge_models.py) で足し合わせる。
- **評価時の流れ**：予測で移る（最大 5 回）→ ±4・±2 の局所探索（最大 4 回）→ 上位 3 個を 3 区間ずつ測り直す（最良が物理コア数を超えていれば物理コア数も候補に加える）→ 確定して保持 → 負荷の変化を検出したら探索をやり直す。
- **制御周期**：TPC-C 200 ms、YCSB 10 ms。

## 3. 設計案（B：配置も action にする）

### 3.1 特徴量を「使う CPU 資源」で表す

今の φ は、thread 数そのものではなく「使っている CPU 資源」で表しているので、配置ごとに次の 2 つを計算すれば、同じ θ のまま両方の配置を予測できる。このマシンでは、socket あたり物理コア S=24、物理コア P=48、論理 CPU N=96。

| N の範囲 | physical-first：socket をまたぐ割合 / SMT の割合 | socket0-first：socket をまたぐ割合 / SMT の割合 |
|---|---|---|
| 1〜24 | 0 / 0 | 0 / 0 |
| 25〜48 | (n−24)/24 / 0 | 0 / (n−24)/48 |
| 49〜72 | 1 / (n−48)/48 | (n−48)/24 / 24/48 |
| 73〜96 | 1 / (n−48)/48 | 1 / (24+(n−72))/48 |

- 上の式は案。実際の CPU の割当て（`include/cpu.hh` の `chooseSocketAwareCpu` と `choosePhysicalFirstCpu`）から、各 n で「socket1 にいる worker の割合」と「SMT sibling を共有している worker の割合」を数えて作るのが確実。
- ψ との直積で、「abort 率が高い（競合が強い）ほど socket をまたぐ損が大きい」といった関係を学べる。

### 3.2 action と探索

- action を（N, 配置）にする。N≦24 では 2 つの配置は同じ CPU を使うので、重複を除く（ログ上は physical-first として扱う）。
- 探索の流れ（予測 → 局所探索 → 測り直し → 確定）は、組に対してそのまま使える。局所探索では、N の ±4・±2 に加えて「同じ N で配置だけを変える」移動も候補に入れる。

### 3.3 実行中に配置を切り替える仕組み（新規実装が必要）

- 全体の配置を表す atomic 変数（例：`g_pin_order`）を用意する。
- 各 worker は、次の取引を始める前（runner の worker ループと、TPC-C の retry の合間）に、自分が適用している配置と全体の配置を比べる。違っていれば `sched_setaffinity` で自分を pin し直す。
- 参考：worker を任意の CPU 列に pin する診断用の仕組み（環境変数 `CCBENCH_PIN_CPU_LIST`、`include/cpu.hh` の `explicitPinCpu`）がすでにある。
- 切り替え直後は、thread が socket をまたいで移動してキャッシュが冷えるので、一時的な損が出る。安定待ちの区間を長めに取る必要があるかもしれない。

## 4. 必要な測定

| 測定 | 中身 | マシン時間の目安 |
|---|---|---|
| 両方の配置の oracle | YCSB：既存の physical-first の掃引（[oracle_physical_first_20261103](../experiments/ICDE/ycsb/oracle_physical_first_20261103/results.csv)）に、socket0-first の掃引を足す（N=24〜72 を中心に）。差が大きく出る状態として skew 0.5・0.6 も足す。TPC-C：8 状態で、socket0-first の N=24〜72 を足す | 約 30〜40 分 |
| 学習 | TPC-C 8 状態と YCSB の skew 群で、（N, 配置）をランダムに選んで学習 | 約 40 分 |
| 評価 | 評価する状態を除いて学習したモデルで、固定負荷。加えて、配置の切り替えが効く動的負荷（例：YCSB の skew 0.6 → 0.95 → 0.6） | 約 40 分 |

測定のスクリプトは、[experiments/ICDE/metis_v2/](../experiments/ICDE/metis_v2) の `run.py`・`compare.py`・`dynamic.py`・`merge_models.py`・`plot_*.py` を複製して `experiments/ICDE/metis_v3/` に置き、出力先を分けて使うと早い。

## 5. 成功の基準と期限

- **成功の基準**：
  1. YCSB の高競合の状態で、最高 N が 24 を超える場合に socket0-first を選ぶ。
  2. TPC-C では physical-first を選ぶ。
  3. どちらの固定負荷でも、「両方の配置の oracle のうち良い方」に対して 0.95 以上。
- **期限**：2 日（2026-11-05 まで）で上の基準に届かなければ打ち切り、論文の Limitations で「配置の選択は今後の課題」とする。

## 6. 関連する資料

- 実験の全体像と論文の構成：[paper_01_experiments_and_figures.md](paper_01_experiments_and_figures.md)
- 配置の損の分解：[placement_01_smt_vs_cross_socket.md](placement_01_smt_vs_cross_socket.md)
- YCSB の oracle と配置の A/B：[ycsb_02_oracle.md](ycsb_02_oracle.md)
- TPC-C の条件と oracle：[tpcc_01_conditions_and_oracle.md](tpcc_01_conditions_and_oracle.md)
- 評価・実装の落とし穴（CPU 配置の順序は #10）：[tpcc_03_pitfalls.md](tpcc_03_pitfalls.md)
