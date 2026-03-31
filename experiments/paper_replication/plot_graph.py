import os
import sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt



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

        summary_path = os.path.join(target_dir, "summary.csv")
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

    
    plt.xlabel('Skew')
    plt.ylabel('Throughput (tps)')
    plt.title('Throughput vs Skew for Different Algorithms')
    plt.xticks(np.arange(0, 1.01, 0.1))
    plt.grid(True)
    plt.legend()
    plt.tight_layout()

    plt.savefig('throughput_vs_skew.png', dpi=300)
    plt.show()

    print("グラフは保存されました： throughput_vs_skew.png")


if __name__ == "__main__":
    main()
