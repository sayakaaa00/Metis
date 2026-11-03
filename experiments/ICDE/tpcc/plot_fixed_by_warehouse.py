#!/usr/bin/env python3
"""Plot per-method TPC-C throughput separately for each fixed warehouse load."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


METHODS = (
    ("silo_without_backoff", "Silo\nno backoff"),
    ("silo_with_backoff", "Silo\nbackoff"),
    ("cicada", "Cicada"),
    ("ermia", "ERMIA"),
    ("observed_metis", "Metis-test"),
)
WAREHOUSES = (1, 4, 16, 32, 96)


def read_results(path):
    results = defaultdict(dict)
    with path.open(newline="") as source:
        for row in csv.DictReader(source):
            key = (int(row["warehouse"]), row["method"])
            run = int(row["run"])
            if run in results[key]:
                raise ValueError(f"Duplicate run: {key}, {run}")
            results[key][run] = int(row["tps"])
    for warehouse in WAREHOUSES:
        for method, _ in METHODS:
            if set(results[warehouse, method]) != {1, 2}:
                raise ValueError(f"Expected two runs for W={warehouse}, {method}")
    return results


def plot_one(axis, warehouse, results, compact=False):
    colors = plt.get_cmap("tab10").colors
    all_values = [tps for method, _ in METHODS
                  for tps in results[warehouse, method].values()]
    low, high = min(all_values) / 1000, max(all_values) / 1000
    span = high - low
    bottom = max(0, low - span * .12)
    top = high + span * .20
    best = max(METHODS, key=lambda item:
               mean(results[warehouse, item[0]].values()))[0]
    for index, (method, _) in enumerate(METHODS):
        values_tps = [results[warehouse, method][run] for run in (1, 2)]
        values = [value / 1000 for value in values_tps]
        average_tps = mean(values_tps)
        average = average_tps / 1000
        color = colors[index]
        axis.scatter((index - .075, index + .075), values,
                     color=color, alpha=.7, s=30 if compact else 42,
                     zorder=3)
        axis.vlines(index, min(values), max(values), color=color,
                    linewidth=2, zorder=2)
        axis.hlines(average, index - .18, index + .18, color=color,
                    linewidth=3, zorder=4)
        axis.text(index, max(values) + span * .035, f"{average_tps:,.0f}",
                  ha="center", va="bottom", fontsize=7 if compact else 9,
                  weight="bold" if method == best else "normal")
    axis.set_ylim(bottom, top)
    axis.set_xticks(range(len(METHODS)), [label for _, label in METHODS],
                    fontsize=7 if compact else 9)
    axis.set_ylabel("Throughput (thousand TPS)")
    axis.set_title(f"W={warehouse}: fixed active home warehouses",
                   weight="bold")
    axis.grid(axis="y", alpha=.25)
    axis.set_axisbelow(True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixed-csv", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    results = read_results(args.fixed_csv)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for warehouse in WAREHOUSES:
        fig, axis = plt.subplots(figsize=(9, 5.5))
        plot_one(axis, warehouse, results)
        fig.text(.5, .015,
                 "Dots: individual 15 s runs  |  horizontal mark: mean  |  line: run range",
                 ha="center", fontsize=9)
        fig.tight_layout(rect=(0, .04, 1, 1))
        fig.savefig(args.output_dir / f"fixed_w{warehouse}.png", dpi=180)
        plt.close(fig)
    fig, axes = plt.subplots(3, 2, figsize=(15, 14))
    for warehouse, axis in zip(WAREHOUSES, axes.flat):
        plot_one(axis, warehouse, results, compact=True)
    axes.flat[-1].axis("off")
    fig.suptitle("TPC-C fixed loads under mimalloc: two 15 s runs per method",
                 fontsize=16)
    fig.text(.5, .02,
             "Dots: individual runs  |  horizontal mark: mean  |  line: run range"
             "  |  each panel has its own TPS scale",
             ha="center", fontsize=10)
    fig.tight_layout(rect=(0, .04, 1, .975))
    fig.savefig(args.output_dir / "fixed_by_warehouse_overview.png", dpi=180)
    plt.close(fig)


if __name__ == "__main__":
    main()
