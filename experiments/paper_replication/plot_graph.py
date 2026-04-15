import os
import sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter



def main():
    if len(sys.argv) < 2:
        print("Usage: python3 plot_graph.py <dir1> <dir2> <dir3> ...")
        sys.exit(1)

    results_dir = sys.argv[1:]

    plt.figure(figsize=(10, 6))
    plotted = False

    for target_dir in results_dir:
        if not os.path.isdir(target_dir):
            print(f"ディレクトリが存在しないためスキップします： {target_dir}")
            continue

        summary_path = os.path.join(target_dir, "summary_compare_v1.csv")
        if not os.path.isfile(summary_path):
            print(f"summary.csvが見つかりませんでした： {summary_path}")
            continue

        try:
            df = pd.read_csv(summary_path)
        except Exception as e:
            print(f"summary.csvの読み込みに失敗しました： {summary_path} ({e})")
            continue

        if "skew" not in df.columns or "throughput_tps" not in df.columns:
            print(f"summary.csvに必要な列がありません： {summary_path}")
            continue

        plot_df = df[["skew", "throughput_tps"]].copy()
        plot_df["skew"] = pd.to_numeric(plot_df["skew"], errors='coerce')
        plot_df["throughput_tps"] = pd.to_numeric(plot_df["throughput_tps"], errors='coerce')
        plot_df = plot_df.dropna().sort_values("skew")

        if plot_df.empty:
            print(f"有効なデータがありませんでした： {summary_path}")
            continue   

        label = os.path.basename(os.path.normpath(target_dir))
        plt.plot(plot_df["skew"], plot_df["throughput_tps"], marker='o', label=label)
        plotted = True

        print(f"使用したファイル： {summary_path}")

    if not plotted:
        print("グラフにできるデータがありませんでした。")
        sys.exit(1)

    
    # 軸ラベルを太字・より大きめのフォントにし、y 軸ラベルは縦方向に表示
    plt.xlabel('Skew', fontsize=25, fontweight='bold')
    plt.ylabel('Throughput (tps)', fontsize=25, fontweight='bold', rotation=90)

    # Y 軸の数値を 0.5×10⁶ のような表記にする（10 の右上に 6）
    def y_axis_formatter(x, pos):
        # x は tps（たとえば 500000 など）なので、10⁶ で正規化して表示
        return f"{x / 1e6:.1f}×10⁶"

    plt.gca().yaxis.set_major_formatter(FuncFormatter(y_axis_formatter))
    plt.xticks(np.arange(0.7, 1.00, 0.05))
    plt.grid(True)
    # 凡例の文字も大きめに
    plt.legend(fontsize=15)
    plt.tight_layout()

    plt.savefig('throughput_vs_skew.png', dpi=300)
    plt.show()

    print("グラフは保存されました： throughput_vs_skew.png")


if __name__ == "__main__":
    main()
