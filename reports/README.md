# 実験レポート目次

最終更新 2026-11-03。Metis full paper 用の実験記録。生データ・図・スクリプトは `experiments/ICDE/` 以下にあり、各レポートからリンクしている。

| ファイル | 内容 | まず見るところ |
|---|---|---|
| [handoff_placement_action.md](handoff_placement_action.md) | 別の session への引き継ぎ：配置（CPU pin の順序）も action にして学習する Metis の設計案と、守ること | 節 0 |
| **[paper_01_experiments_and_figures.md](paper_01_experiments_and_figures.md)** | **論文に載せる実験・図・表のまとめ（確定版）。ストーリー、Metis の構成、実験環境、結果、注記、Limitations** | **まずここを見る** |
| [tpcc_01_conditions_and_oracle.md](tpcc_01_conditions_and_oracle.md) | TPC-C の実験条件の定義、固定 N の性能曲線（oracle）、条件を変えたときの最高 N、商品 Zipf | 「固定 N の掃引：標準条件」の表 |
| [tpcc_02_metis_models.md](tpcc_02_metis_models.md) | Metis モデルの変遷、現行の Metis-test-SMT の固定負荷・動的負荷の結果、adaTAM や他の方式との比較 | 「要点」と「固定負荷」の表 |
| [tpcc_03_pitfalls.md](tpcc_03_pitfalls.md) | ワークショップ版 Metis の問題と、測定環境・ベンチマークの問題（15 項目） | 冒頭の一覧表（論文の Methodology 節と ablation の根拠） |
| [metis_v2_01_tpcc_loo.md](metis_v2_01_tpcc_loo.md) | Metis v2（W を使わない）の TPC-C 固定負荷、評価する状態を除いて学習。v2-A・B1・B2 の比較と go の判定 | 結果の表 |
| [metis_v2_02_fixed_comparison.md](metis_v2_02_fixed_comparison.md) | 固定負荷での方式比較（v2-A、adaTAM、Silo、Cicada、ERMIA）、TPC-C と YCSB | 「結論」と 2 つの表 |
| [ycsb_01_dynamic_comparison.md](ycsb_01_dynamic_comparison.md) | YCSB の動的 skew 負荷での Metis-paper・adaTAM・Silo の比較（2026-10-28、旧 CPU 配置） | 全 60 秒の TPS の表 |
| [placement_01_smt_vs_cross_socket.md](placement_01_smt_vs_cross_socket.md) | YCSB と TPC-C で良い配置順が逆になる原因（N=24 で SMT の損と socket またぎの損を分解） | 「結論」と結果の表 |
| [ycsb_02_oracle.md](ycsb_02_oracle.md) | YCSB の固定 N の性能曲線（oracle）と CPU 配置の A/B（2026-11-03、TPC-C と条件をそろえた） | 「要点」と結果の表 |

## 現在の状況（2026-11-03）

- **YCSB の oracle 測定**：完了（[ycsb_02](ycsb_02_oracle.md)）。最高 N は skew 0.7〜0.999 で 24→12。YCSB は socket をまたぐと大きく損をし、TPC-C とは逆に socket0-first の配置の方が良い。skew 0.7 だけは socket0-first で測り直しが必要。
- **TPC-C の状態空間のパイロット**：完了。ミックスは標準だけに絞り、W=1/2/3/4/8/16/32/96 の 8 状態（最高 N は 8/10/16/20/48/48/48/80）を使う案（[①](tpcc_01_conditions_and_oracle.md)の「状態空間のパイロット」）。
- **Metis v2**：TPC-C の 8 状態で go の判定（[metis_v2_01](metis_v2_01_tpcc_loo.md)）。v2-A が幾何平均 1.002・最小 0.978 で主役。YCSB でも基準を満たした。固定負荷の方式比較（[metis_v2_02](metis_v2_02_fixed_comparison.md)）では v2-A が両方で最良。次は動的負荷。

## 整理の記録

2026-11-03 に、個別レポート 40 本と診断用スクリプトを4 本に集約した。元のファイルはすべて `/home/ubuntu/reports_backup_20261103.tar.gz` に退避してある（`tar xzf` で `reports/` 以下に展開される）。
