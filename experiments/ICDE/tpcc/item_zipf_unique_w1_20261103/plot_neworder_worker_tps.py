#!/usr/bin/env python3
"""Plot the W=1 New-Order worker sweep, using repeated runs where available."""

import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter


HERE = Path(__file__).resolve().parent


def read_rows(name):
    with (HERE / name / "results.csv").open(newline="") as stream:
        return list(csv.DictReader(stream))


def main():
    coarse = read_rows("neworder_w1_coarse_5s")
    repeated = read_rows("neworder_w1_refine_10s") + read_rows("neworder_w1_n1_10s")
    assert len(coarse) == 30 and len(repeated) == 28

    points = defaultdict(list)
    for row in coarse:
        points[(float(row["theta"]), int(row["workers"]))].append(row)
    for row in repeated:
        key = (float(row["theta"]), int(row["workers"]))
        points[key] = [entry for entry in repeated
                       if (float(entry["theta"]), int(entry["workers"])) == key]

    fig, ax = plt.subplots(figsize=(9, 5.5))
    for theta, color in [(0.0, "#1764ad"), (0.95, "#dd6b20")]:
        series = sorted((workers, rows) for (t, workers), rows in points.items()
                        if t == theta)
        assert len(series) == 17
        x = [workers for workers, _ in series]
        y = [statistics.mean(float(row["tps"]) for row in rows) for _, rows in series]
        ax.plot(x, y, color=color, linewidth=2.3, marker="o", markersize=5,
                label=f"Zipf θ={theta:g}")
        repeated_x = [workers for workers, rows in series if len(rows) == 2]
        repeated_y = [statistics.mean(float(row["tps"]) for row in rows)
                      for _, rows in series if len(rows) == 2]
        ax.scatter(repeated_x, repeated_y, s=62, color=color, zorder=4)
        coarse_x = [workers for workers, rows in series if len(rows) == 1]
        coarse_y = [float(rows[0]["tps"]) for _, rows in series if len(rows) == 1]
        ax.scatter(coarse_x, coarse_y, s=44, facecolors="white", edgecolors=color,
                   linewidths=1.7, zorder=4)

    ax.set(title="TPC-C New-Order only: item skew vs. thread count",
           xlabel="Active threads", ylabel="Committed transactions per second (TPS)",
           xlim=(0, 98), ylim=(0, 480000))
    ax.set_xticks([0, 8, 16, 24, 32, 48, 64, 80, 96])
    ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value / 1000:g}k"))
    ax.grid(True, alpha=0.25)
    ax.legend(loc="upper right")
    fig.text(0.5, 0.01,
             "Active warehouses=1 (DB=16), Item=100,000. Filled: 10 s × 2 mean; open: 5 s × 1.",
             ha="center", fontsize=9, color="#555555")
    fig.tight_layout(rect=(0, 0.035, 1, 1))
    fig.savefig(HERE / "neworder_w1_threads_vs_tps.png", dpi=200)
    fig.savefig(HERE / "neworder_w1_threads_vs_tps.svg")
    plt.close(fig)


if __name__ == "__main__":
    main()
