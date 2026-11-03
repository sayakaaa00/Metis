#!/usr/bin/env python3
"""Compare the 73-point physical-first sweep with the historical sweep."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read_summary(path):
    rows = defaultdict(dict)
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            w = int(row["active_warehouses"])
            n = int(row["active_threads"])
            rows[w][n] = float(row["mean_tps"])
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--historical", type=Path, required=True)
    parser.add_argument("--physical-first", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    old = read_summary(args.historical)
    new = read_summary(args.physical_first)
    if old.keys() != new.keys() or any(old[w].keys() - new[w].keys() for w in old):
        raise ValueError("Historical W/N candidates are missing from the new sweep")
    args.output.mkdir(parents=True, exist_ok=True)

    fig, axes = plt.subplots(len(old), 1, figsize=(9, 13), sharex=True,
                             layout="constrained")
    with (args.output / "historical_comparison.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("active_warehouses", "active_threads", "historical_tps",
                         "physical_first_tps", "delta_percent"))
        for ax, w in zip(axes, sorted(old)):
            ns = sorted(old[w])
            ax.plot(ns, [old[w][n] / 1000 for n in ns], "o-", markersize=3.5,
                    label="historical socket 0 first")
            ax.plot(ns, [new[w][n] / 1000 for n in ns], "s-", markersize=3.5,
                    label="physical cores first")
            for n in ns:
                writer.writerow((w, n, old[w][n], new[w][n],
                                 round(100 * (new[w][n] / old[w][n] - 1), 2)))
            ax.axvline(48, color="gray", linestyle="--", linewidth=0.8)
            ax.set_ylabel("TPS (thousands)")
            ax.set_title(f"W={w}", loc="left")
            ax.grid(alpha=0.25)
    axes[0].legend(loc="best")
    axes[-1].set_xlabel("Active worker threads N")
    axes[-1].set_xticks(sorted({n for values in old.values() for n in values}))
    fig.suptitle("mimalloc TPC-C fixed workload: different binary revisions")
    fig.savefig(args.output / "tps_pin_order_historical.png", dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    main()
