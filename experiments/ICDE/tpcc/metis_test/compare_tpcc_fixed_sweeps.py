#!/usr/bin/env python3
"""Compare two fixed-thread TPC-C sweep summaries at matching (W, N)."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read_summary(path):
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    return {(int(row["active_warehouses"]), int(row["active_threads"])): row
            for row in rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--left-summary", type=Path, required=True)
    parser.add_argument("--right-summary", type=Path, required=True)
    parser.add_argument("--left-label", required=True)
    parser.add_argument("--right-label", required=True)
    parser.add_argument("--warehouses", type=int, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    left = read_summary(args.left_summary)
    right = read_summary(args.right_summary)
    warehouses = set(args.warehouses)
    left_keys = {key for key in left if key[0] in warehouses}
    right_keys = {key for key in right if key[0] in warehouses}
    if left_keys != right_keys:
        raise ValueError(f"Candidate mismatch: left only={left_keys - right_keys}, "
                         f"right only={right_keys - left_keys}")
    if not left_keys:
        raise ValueError("No matching candidates")

    rows = []
    for key in sorted(left_keys):
        a, b = left[key], right[key]
        old_tps = float(a["mean_tps"])
        new_tps = float(b["mean_tps"])
        rows.append({
            "active_warehouses": key[0],
            "active_threads": key[1],
            "left_mean_tps": old_tps,
            "left_min_tps": a["min_tps"],
            "left_max_tps": a["max_tps"],
            "left_mean_abort_rate": a["mean_abort_rate"],
            "right_mean_tps": new_tps,
            "right_min_tps": b["min_tps"],
            "right_max_tps": b["max_tps"],
            "right_mean_abort_rate": b["mean_abort_rate"],
            "right_vs_left_tps_percent": round(100 * (new_tps / old_tps - 1), 2),
            "right_vs_left_abort_pp": round(100 *
                                             (float(b["mean_abort_rate"]) -
                                              float(a["mean_abort_rate"])), 2),
        })
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / "comparison.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    by_w = defaultdict(list)
    for row in rows:
        by_w[row["active_warehouses"]].append(row)
    fig, axes = plt.subplots(len(by_w), 1, figsize=(10, 3.6 * len(by_w)),
                             sharex=True, layout="constrained")
    if len(by_w) == 1:
        axes = [axes]
    for ax, (w, subset) in zip(axes, sorted(by_w.items())):
        x = [row["active_threads"] for row in subset]
        for prefix, label, color in (("left", args.left_label, "#3875b3"),
                                     ("right", args.right_label, "#d55e00")):
            y = [row[f"{prefix}_mean_tps"] / 1000 for row in subset]
            low = [(row[f"{prefix}_mean_tps"] - float(row[f"{prefix}_min_tps"])) / 1000
                   for row in subset]
            high = [(float(row[f"{prefix}_max_tps"]) - row[f"{prefix}_mean_tps"]) / 1000
                    for row in subset]
            ax.errorbar(x, y, yerr=[low, high], marker="o", markersize=3.5,
                        color=color, capsize=2, linewidth=1.5, label=label)
        ax.axvline(48, color="gray", linestyle="--", linewidth=0.9)
        ax.set_title(f"Active home warehouses W={w}", loc="left")
        ax.set_ylabel("Committed TPS (thousands)")
        ax.grid(alpha=0.25)
        ax.legend()
    axes[-1].set_xticks((1, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96))
    axes[-1].set_xlabel("Active worker threads N")
    fig.suptitle("TPC-C fixed workload: physical-first pinning, mimalloc, uniform homes")
    fig.savefig(args.output / "tps_comparison.png", dpi=170)
    plt.close(fig)

    fig, axes = plt.subplots(len(by_w), 1, figsize=(10, 3.3 * len(by_w)),
                             sharex=True, layout="constrained")
    if len(by_w) == 1:
        axes = [axes]
    for ax, (w, subset) in zip(axes, sorted(by_w.items())):
        ax.plot([row["active_threads"] for row in subset],
                [row["right_vs_left_tps_percent"] for row in subset],
                marker="o", color="#6a3d9a")
        ax.axhline(0, color="black", linewidth=0.8)
        ax.axvline(48, color="gray", linestyle="--", linewidth=0.9)
        ax.set_title(f"W={w}", loc="left")
        ax.set_ylabel("TPS change (%)")
        ax.grid(alpha=0.25)
    axes[-1].set_xticks((1, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96))
    axes[-1].set_xlabel("Active worker threads N")
    fig.suptitle(f"{args.right_label} relative to {args.left_label}")
    fig.savefig(args.output / "tps_delta_percent.png", dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    main()
