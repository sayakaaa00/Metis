#!/usr/bin/env python3
"""Compare fixed TPC-C TPS curves with and without node 0 memory binding."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

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


def read_pin_ab(path):
    runs = defaultdict(list)
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            if row["pin_workers"] == "true":
                key = int(row["active_warehouses"]), int(row["active_threads"])
                runs[key].append(int(row["tps"]))
    result = defaultdict(dict)
    for (w, n), values in runs.items():
        if len(values) != 2:
            raise ValueError(f"Expected two pinned runs for W={w}, N={n}")
        result[w][n] = mean(values)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument("--os-default", type=Path)
    sources.add_argument("--pin-ab-results", type=Path)
    parser.add_argument("--node0", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--comparison-note", default="")
    args = parser.parse_args()

    baseline = (read_pin_ab(args.pin_ab_results) if args.pin_ab_results
                else read_summary(args.os_default))
    node0 = read_summary(args.node0)
    if baseline.keys() - node0.keys():
        raise ValueError("Warehouse sets differ")
    args.output.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(len(baseline), 1, figsize=(9, 13),
                             sharex=True, layout="constrained")
    with (args.output / "comparison.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("active_warehouses", "active_threads", "os_default_tps",
                         "node0_tps", "node0_vs_os_default_percent"))
        for ax, w in zip(axes, sorted(baseline)):
            ns = sorted(baseline[w].keys() & node0[w].keys())
            if not ns:
                raise ValueError(f"No matched candidates for W={w}")
            os_values = [baseline[w][n] for n in ns]
            node_values = [node0[w][n] for n in ns]
            ax.plot(ns, [value / 1000 for value in os_values], "o-",
                    label="OS default memory", linewidth=1.5, markersize=3.5)
            ax.plot(ns, [value / 1000 for value in node_values], "s-",
                    label="node 0 memory binding", linewidth=1.5, markersize=3.5)
            ax.axvline(48, color="gray", linestyle="--", linewidth=0.8)
            ax.set_title(f"W={w}", loc="left")
            ax.set_ylabel("TPS (thousands)")
            ax.grid(alpha=0.25)
            for n in ns:
                writer.writerow((w, n, baseline[w][n], node0[w][n],
                                 round(100 * (node0[w][n] / baseline[w][n] - 1), 2)))
    axes[0].legend(loc="best")
    axes[-1].set_xlabel("Active worker threads N")
    axes[-1].set_xticks(sorted({n for rows in baseline.values() for n in rows}))
    title = "mimalloc TPC-C fixed workload: pinned workers, uniform homes"
    if args.comparison_note:
        title += f" ({args.comparison_note})"
    fig.suptitle(title)
    fig.savefig(args.output / "tps_node0_vs_os_default.png", dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    main()
