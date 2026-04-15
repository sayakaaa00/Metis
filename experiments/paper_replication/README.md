# Silo + AdaTAM / LinUCBTAM 実験メモ

このディレクトリでは、Silo/YCSB ベンチマークに AdaTAM（Adaptive Thread Activity Management）、
LinUCBTAM（LinUCB ベースの TAM）、AdaBO を組み込んだ実験スクリプトを管理しています。

ここでは、主に以下の 2 系列のバイナリについて、ビルド構成と典型的な CLI 例をまとめます。

- `silo_with_TAM`   : AdaTAM / LinUCBTAM（スレッド数自動調整）付き Silo/YCSB
- `silo_with_backoff` : AdaBO（バックオフ）付き Silo/YCSB

---

## ビルド構成とバイナリパス

このリポジトリでは、用途に応じて **Debug+Sanitizer 用ビルド** と **Release（性能測定用）ビルド** を分けておくと便利です。

### Debug + Sanitizer ビルド（バグ検出・サニタイザ用）

- ビルドディレクトリ: `build/`
- 主なバイナリパス:
  - `build/silo/silo_with_TAM`
  - `build/silo/silo_with_backoff`
- 代表的な CMake 設定例（参考）:

```bash
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Debug \
  -DENABLE_SANITIZER=ON \
  -DENABLE_COVERAGE=OFF
```

- 特徴:
  - `-g` + AddressSanitizer / LeakSanitizer が有効。
  - バグ検出・検証には有用だが、オーバーヘッドが大きいため **性能測定には不向き**。

### Release ビルド（性能測定・論文用実験向け）

- ビルドディレクトリ: `build_release/`
- 主なバイナリパス:
  - `build_release/silo/silo_with_TAM`
  - `build_release/silo/silo_with_backoff`
- 代表的な CMake 設定例（参考）:

```bash
cmake -S . -B build_release \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SANITIZER=OFF \
  -DENABLE_COVERAGE=OFF
```

- 特徴:
  - 最適化（`-O3` 相当）され、サニタイザ無効。
  - **スループット評価やスキャン実験はこちらを利用することを推奨**。

> 以下の CLI 例では、性能測定を前提に Release 版のパス
> `build_release/silo/...` を用いています。Debug 版で試したい場合は、
> `build_release/` を `build/` に読み替えてください。

---

## `silo_with_TAM` の基本パラメータ

`silo_with_TAM` でよく使う gflags は以下の通りです（主要なものだけ抜粋）。

- スレッド数・時間・YCSB ワークロード
  - `--thread_num` : worker スレッド数
  - `--extime` : 実験時間 [秒]
  - `--ycsb_tuple_num` : YCSB の key 数
  - `--ycsb_max_ope` : 1 トランザクションあたりの操作数
  - `--ycsb_rratio` : read 割合 [%]
  - `--ycsb_zipf_skew` : Zipf スキュー（ホット度）
- ピニング
  - `--pin_threads` : NUMA-aware CPU ピニングを有効化するか（true/false）
- TAM 共通（AdaTAM / LinUCBTAM）
  - `--tam_update_period_us` : TAM の更新周期 [µs]
  - `--tam_min_threads` : active にするスレッド数の下限（0 のときは 1 に正規化）
  - `--tam_max_threads` : active にするスレッド数の上限（0 または thread_num より大きいときは thread_num に clamp）
  - `--tam_log_active_threads` : 更新周期ごとに active_threads を stderr にログ出力する
- AdaTAM 固有
  - `--ada_tam_enable` : AdaTAM を有効化するか（true/false）
  - `--ada_tam_step` : active thread 数を増減させるときのステップ幅
- LinUCBTAM 固有
  - `--linucb_tam_enable` : LinUCBTAM を有効化するか（true/false）
  - `--linucb_alpha` : UCB の探索係数（大きいほど探索寄り）
  - `--linucb_lambda` : 行列の正則化係数（A 行列の対角成分）

> 注意: `--ada_tam_enable` と `--linucb_tam_enable` を同時に true にすると
> `TamController` がエラーを出して abort します。必ずどちらか一方だけを有効にしてください。

---

## `silo_with_TAM` の典型的な実行例

### 1. ベースライン: TAM 無効・ピニング無効

AdaTAM も CPU ピニングも使わない、もっとも素朴なベースラインです。

```bash
./build_release/silo/silo_with_TAM \
  --thread_num=42 \
  --extime=60 \
  --ycsb_tuple_num=10000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.8 \
  --pin_threads=false
```

### 2. ピニングのみ有効（AdaTAM 無効）

プロセス／スレッドのアフィニティだけを制御したい場合の例です。

```bash
./build_release/silo/silo_with_TAM \
  --thread_num=42 \
  --extime=10 \
  --ycsb_tuple_num=10000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.8 \
  --pin_threads=true
```

- `--pin_threads=true` のとき:
  - `main()` で `setProcessAffinitySocket0IfFits(TotalThreadNum)` を呼び、thread_num がソケット0の論理 CPU 数以下であればプロセス全体をソケット0上の CPU に閉じ込めます。
  - 各 worker スレッドは `setThreadAffinity(thid)` により、`chooseSocketAwareCpu(thid)` で決まった CPU に pin されます。

### 3. AdaTAM 有効・ピニング無効

スレッド数の自動調整だけ試したい場合の例です。

```bash
./build_release/silo/silo_with_TAM \
  --thread_num=64 \
  --extime=10 \
  --ycsb_tuple_num=10000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.7 \
  --pin_threads=false \
  --ada_tam_enable=true \
  --tam_update_period_us=100000 \
  --tam_min_threads=4 \
  --tam_max_threads=30 \
  --ada_tam_step=2.0
```

- `--ada_tam_enable=true` のとき:
  - `worker()` 内で `g_tam.active_threads()` に基づいて、`thid >= active_threads` のスレッドはトランザクション実行を休止します。
  - リーダースレッド（thid=0）が一定周期ごとに committed tx 数を集計し、AdaTAM の gradient ベースロジックで active thread 数を増減します。

### 4. AdaTAM + ピニングの両方を有効

ピニングと AdaTAM を同時に有効にしたい場合の例です。

```bash
./build_release/silo/silo_with_TAM \
  --thread_num=64 \
  --extime=10 \
  --ycsb_tuple_num=10000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.8 \
  --pin_threads=true \
  --ada_tam_enable=true \
  --tam_update_period_us=1000 \
  --tam_min_threads=2 \
  --tam_max_threads=64 \
  --ada_tam_step=2.0 \
  --tam_log_active_threads=true

```

### 5. LinUCBTAM を有効にした例

LinUCBTAM は、最近のスループット・アボート率・スレッド数から状態ベクトルを作り、
複数の「スレッド数増減アクション」（例: -4, -2, 0, +2, +4）に対して LinUCB で UCB スコアを計算し、
もっとも期待報酬の高いアクションを選ぶことで active_threads を調整します。

```bash
./build_release/silo/silo_with_TAM \
  --thread_num=64 \
  --extime=10 \
  --ycsb_tuple_num=10000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.8 \
  --pin_threads=true \
  --linucb_tam_enable=true \
  --tam_update_period_us=1000 \
  --tam_min_threads=1 \
  --tam_max_threads=64 \
  --linucb_alpha=0.5 \
  --linucb_lambda=1.0 \
  --tam_log_active_threads=true
```

- `--tam_log_active_threads=true` にすると、AdaTAM 時は `[AdaTAM] ...`、
  LinUCBTAM 時は `[LinUCBTAM] ...` の形で active_threads とスループット指標が stderr に出力され、
  スレッド数探索の軌跡をデバッグ・可視化するのに便利です。

---

## `silo_without_backoff` の利用例

`silo_without_backoff` は、AdaTAM や AdaBO などの自動チューニング機構をいっさい使わず、
単純に `thread_num` や `ycsb_zipf_skew` だけを変えながらベースライン性能を測るためのバイナリです。

### 1. ベースライン: スレッド数だけを手動で変える

```bash
./build_release/silo/silo_without_backoff \
  --thread_num=42 \
  --extime=10 \
  --ycsb_tuple_num=10000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.8 \
  --pin_threads=true
```

- `thread_num` を変えながら何度か実行することで、「静的な最適スレッド数」を手動で探すことができます。
- このような探索を自動化したものが、後述の `scan_silo_optTAM.sh` です。
```

---

## `silo_with_backoff` の利用例

`silo_with_backoff` は、Cicada 由来の AdaBO バックオフを有効にした Silo/YCSB 実装です（`BACK_OFF=1`）。

- バイナリパス: `build/silo/silo_with_backoff`
- ほとんどの gflags は `silo_with_TAM` と共通です（`--thread_num`, `--extime`, `--ycsb_*` など）。
- 追加で AdaBO 関連の gflags を利用できます（`include/backoff.hh` 参照）。

主な AdaBO パラメータ:

- `--backoff_update_period_us` (uint64, デフォルト 5000)
  - バックオフ値を見直す周期 [µs]。
- `--backoff_step_us` (double, デフォルト 0.5)
  - バックオフ値を増減させるときのステップ幅 [µs]。

### 1. ベースライン: AdaBO 有効・ピニング無効

```bash
./build_release/silo/silo_with_backoff \
  --thread_num=30 \
  --extime=10 \
  --ycsb_tuple_num=1000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.7 \
  --pin_threads=false \
  --backoff_update_period_us=5000 \
  --backoff_step_us=0.5
```

### 2. ピニング有効で AdaBO を使う

```bash
./build_release/silo/silo_with_backoff \
  --thread_num=30 \
  --extime=10 \
  --ycsb_tuple_num=1000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.7 \
  --pin_threads=true \
  --backoff_update_period_us=5000 \
  --backoff_step_us=0.5
```

### 3. AdaBO パラメータを変えて挙動を見る

```bash
./build_release/silo/silo_with_backoff \
  --thread_num=30 \
  --extime=10 \
  --ycsb_tuple_num=1000 \
  --ycsb_max_ope=10 \
  --ycsb_rratio=50 \
  --ycsb_zipf_skew=0.7 \
  --pin_threads=false \
  --backoff_update_period_us=10000 \
  --backoff_step_us=1.0
```

参考までに、`silo_without_backoff` バイナリは同じコードベースで `BACK_OFF=0` にしたもので、AdaBO が完全に無効なバージョンです。

---
## 実験用 Bash スクリプトとの関係

- `experiments/paper_replication/scan_silo_optTAM.sh`
  - `silo_without_backoff` を TAM 無効のベースラインとして起動し、`thread_num` を 1〜64 でスイープして **静的な最適スレッド数** を skew ごとに探すスクリプトです。
  - すべての実験結果は `optTAM_scan_results` に記録されます。

- `experiments/paper_replication/scan_silo_optAdaTAM.sh`
  - `silo_with_TAM` を `--ada_tam_enable=true` で起動し、`tam_update_period_us` と `ada_tam_step` の組合せを
    グリッドサーチして AdaTAM のハイパーパラメータを調べるスクリプトです。
  - 結果は `optAdaTAM_scan_results` に出力されます。

- `experiments/paper_replication/scan_silo_optAdaBO.sh`
  - `silo_with_backoff` を対象に、`backoff_update_period_us` と `backoff_step_us` をスイープし、
    AdaBO バックオフのハイパーパラメータを探索するスクリプトです。
  - すべての結果は `adaBO_scan_results` に記録される。

- `experiments/paper_replication/compare_tam_sweep.sh`
  - 複数の `ycsb_zipf_skew` と複数回のリピートをまとめて走らせ、
    「各試行で AdaTAM と LinUCBTAM のどちらが何 % 優れていたか」を CSV に記録するスクリプトです。
  - 結果は `experiments/paper_replication/AdaTAM_vs_LinUCBTAM/tam_sweep_result_*.csv` として保存されます。


スクリプトを使わずに手でパラメータを試したくなった場合は、上記の CLI 例をベースにしつつ、
`thread_num` や `ycsb_zipf_skew` などを入れ替えてください。Debug/ASan で詳細に挙動を観察したい場合は、パスの `build_release/` を `build/` に差し替えてください。
