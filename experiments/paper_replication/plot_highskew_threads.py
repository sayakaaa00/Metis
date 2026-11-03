#!/usr/bin/env python3
import os
import sys

import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter


def format_tps_as_1e6(x, pos):
    """Format y ticks as 0.5×10⁶ style."""
    return f"{x / 1e6:.1f}×10⁶"


def main():
    # デフォルトの入力 CSV: optTAM_scan_results/highskew_avg_pinned_tuple_10000_release.csv
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_csv = os.path.join(
        script_dir,
        "optTAM_scan_results",
        "highskew_avg_pinned_tuple_10000_release.csv",
    )

    if len(sys.argv) >= 2:
        csv_path = sys.argv[1]
    else:
        csv_path = default_csv

    if not os.path.isfile(csv_path):
        print(f"入力 CSV が見つかりません: {csv_path}")
        sys.exit(1)

    df = pd.read_csv(csv_path)
    required = {"skew", "thread", "mean_throughput_tps"}
    if not required.issubset(df.columns):
        print(f"CSV に必要な列がありません: {csv_path} (必要: {required})")
        sys.exit(1)

    # skew ごとにグラフを作成
    for skew, g in df.groupby("skew"):
        g = g.sort_values("thread")

        # この skew における最大 throughput の点を特定
        best_idx = g["mean_throughput_tps"].idxmax()
        best_row = g.loc[best_idx]
        best_thread = int(best_row["thread"])
        best_tps = best_row["mean_throughput_tps"]

        plt.figure(figsize=(8, 5))
        plt.plot(g["thread"], g["mean_throughput_tps"], marker="o", label="throughput")

        plt.xlabel("Thread", fontsize=18, fontweight="bold")
        plt.ylabel("Throughput (tps)", fontsize=18, fontweight="bold", rotation=90)

        ax = plt.gca()
        ax.yaxis.set_major_formatter(FuncFormatter(format_tps_as_1e6))

        # 最大 throughput の点をハイライトし、thread 数を明示
        plt.scatter([best_thread], [best_tps], color="red", zorder=3, label=f"best thread = {best_thread}")
        plt.annotate(
            f"best={best_thread}",
            xy=(best_thread, best_tps),
            xytext=(5, 5),
            textcoords="offset points",
            fontsize=10,
            color="red",
        )

        plt.title(f"Skew = {skew}", fontsize=18, fontweight="bold")
        plt.grid(True)
        plt.legend()
        plt.tight_layout()

        out_name = f"highskew_thread_vs_throughput_skew{skew}.png"
        out_path = os.path.join(script_dir, out_name)
        plt.savefig(out_path, dpi=300)
        print(f"グラフを保存しました: {out_path}")

        # 対話環境で見たいときだけコメントアウトを外す
        # plt.show()
        plt.close()


if __name__ == "__main__":
    main()
