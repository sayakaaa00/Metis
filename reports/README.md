# 実験レポート目次

最終更新 2026-11-03。Metis full paper 用の実験記録。生データ・図・スクリプトは `experiments/ICDE/` 以下にあり、各レポートからリンクしている。

| ファイル | 内容 | まず見るところ |
|---|---|---|
| [tpcc_01_conditions_and_oracle.md](tpcc_01_conditions_and_oracle.md) | TPC-C の実験条件の定義、固定 N の性能曲線（oracle）、条件を変えたときの最高 N、商品 Zipf | 「固定 N の掃引：標準条件」の表 |
| [tpcc_02_metis_models.md](tpcc_02_metis_models.md) | Metis モデルの変遷、現行の Metis-test-SMT の固定負荷・動的負荷の結果、adaTAM や他の方式との比較 | 「要点」と「固定負荷」の表 |
| [tpcc_03_pitfalls.md](tpcc_03_pitfalls.md) | ワークショップ版 Metis の問題と、測定環境・ベンチマークの問題（15 項目） | 冒頭の一覧表（論文の Methodology 節と ablation の根拠） |
| [ycsb_01_dynamic_comparison.md](ycsb_01_dynamic_comparison.md) | YCSB の動的 skew 負荷での Metis-paper・adaTAM・Silo の比較（2026-10-28、旧 CPU 配置） | 全 60 秒の TPS の表 |
| [ycsb_02_oracle.md](ycsb_02_oracle.md) | YCSB の固定 N の性能曲線（oracle）と CPU 配置の A/B（2026-11-03、TPC-C と条件をそろえた） | 「要点」と結果の表 |

## 現在の状況（2026-11-03）

- **YCSB の oracle 測定**：完了（[ycsb_02](ycsb_02_oracle.md)）。最高 N は skew 0.7〜0.999 で 24→12。YCSB は socket をまたぐと大きく損をし、TPC-C とは逆に socket0-first の配置の方が良い。skew 0.7 だけは socket0-first で測り直しが必要。
- **TPC-C の状態空間のパイロット**：完了。ミックスは標準だけに絞り、W=1/2/3/4/8/16/32/96 の 8 状態（最高 N は 8/10/16/20/48/48/48/80）を使う案（[①](tpcc_01_conditions_and_oracle.md)の「状態空間のパイロット」）。
- **次の段階**：W を使わない Metis v2（v2-A は probe なしで直前の trial との比を報酬にする。v2-B は 96 で probe した値との比を報酬にする）を実装し、go / no-go を判定する。

## 整理の記録

2026-11-03 に、個別レポート 40 本と診断用スクリプトを4 本に集約した。元のファイルはすべて `/home/ubuntu/reports_backup_20261103.tar.gz` に退避してある（`tar xzf` で `reports/` 以下に展開される）。
