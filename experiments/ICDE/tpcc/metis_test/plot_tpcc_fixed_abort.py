#!/usr/bin/env python3
"""Plot abort rate against active worker count for a fixed TPC-C sweep."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--title", required=True)
    args = parser.parse_args()

    by_w = defaultdict(list)
    with args.summary.open(newline="") as handle:
        for row in csv.DictReader(handle):
            by_w[int(row["active_warehouses"])].append(row)
    fig, ax = plt.subplots(figsize=(10, 6), layout="constrained")
    for w, rows in sorted(by_w.items()):
        rows.sort(key=lambda row: int(row["active_threads"]))
        ax.plot([int(row["active_threads"]) for row in rows],
                [100 * float(row["mean_abort_rate"]) for row in rows],
                marker="o", markersize=4, linewidth=1.8, label=f"W={w}")
    ax.axvline(48, color="gray", linestyle="--", linewidth=0.9,
               label="all 48 physical cores occupied")
    ax.set_xticks((1, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96))
    ax.set_xlim(0, 98)
    ax.set_ylim(0, 100)
    ax.set_xlabel("Active worker threads N")
    ax.set_ylabel("Abort rate (% of transaction attempts)")
    ax.set_title(args.title)
    ax.grid(alpha=0.25)
    ax.legend()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    main()
