#!/usr/bin/env python3
"""Plot total committed TPS for the W=1 standard TPC-C mix by item skew."""

import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter


HERE = Path(__file__).resolve().parent
SOURCE = HERE / "standard_w1_total_coarse_5s" / "results.csv"
THETAS = (0.0, 0.7, 0.8, 0.95)
WORKERS = (1, 2, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 20, 24, 32, 48, 72, 96)


def main():
    with SOURCE.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    assert len(rows) == len(THETAS) * len(WORKERS)
    values = {}
    for row in rows:
        assert int(row["seconds"]) == 5 and int(row["run"]) == 1
        assert all(int(row[f"{kind}_commits"]) > 0 for kind in
                   ("NewOrder", "Payment", "OrderStatus", "Delivery", "StockLevel"))
        key = (float(row["theta"]), int(row["workers"]))
        assert key not in values
        values[key] = int(row["tps"])
    assert set(values) == {(theta, workers) for theta in THETAS for workers in WORKERS}

    fig, ax = plt.subplots(figsize=(9, 5.5))
    colors = ("#1764ad", "#22a06b", "#9b59b6", "#dd6b20")
    for theta, color in zip(THETAS, colors):
        ax.plot(WORKERS, [values[theta, workers] for workers in WORKERS],
                marker="o", markersize=4, linewidth=2, color=color,
                label=f"Zipf θ={theta:g}")
    ax.set(title="TPC-C standard mix: total TPS vs. thread count",
           xlabel="Active threads", ylabel="Total committed TPS (all transaction types)",
           xlim=(0, 98), ylim=(0, None))
    ax.set_xticks((0, 8, 16, 24, 32, 48, 64, 80, 96))
    ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value / 1000:g}k"))
    ax.grid(True, alpha=0.25)
    ax.legend(loc="best")
    fig.text(0.5, 0.01,
             "DB=1, active W=1, Item=100,000, mix=45/43/4/4/4. Each point: one 5 s run.",
             ha="center", fontsize=9, color="#555555")
    fig.tight_layout(rect=(0, 0.035, 1, 1))
    fig.savefig(HERE / "standard_w1_total_tps_vs_threads.png", dpi=200)
    fig.savefig(HERE / "standard_w1_total_tps_vs_threads.svg")
    plt.close(fig)


if __name__ == "__main__":
    main()
