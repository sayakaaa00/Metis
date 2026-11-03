#!/usr/bin/env python3
"""Compare physical-first TPC-C fixed sweeps with 100k and 10k Items."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def read_summary(path):
    with path.open(newline="") as handle:
        return {(int(row["active_warehouses"]), int(row["active_threads"])): row
                for row in csv.DictReader(handle)}


def read_results(paths):
    grouped = defaultdict(dict)
    for path in paths:
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                key = (int(row["active_warehouses"]), int(row["active_threads"]))
                run = int(row["run"])
                if run in grouped[key]:
                    raise ValueError(f"Duplicate run: {key}, run={run}")
                grouped[key][run] = row
    for key, runs in grouped.items():
        if sorted(runs) != [1, 2]:
            raise ValueError(f"Incomplete runs: {key}, {sorted(runs)}")
    return grouped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--historical-summary", type=Path, required=True)
    parser.add_argument("--item10k-results", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    old = read_summary(args.historical_summary)
    new = read_results(args.item10k_results)
    old_pairs = {key for key in old if key[0] in (16, 32)}
    if set(new) != old_pairs:
        raise ValueError(f"Candidate mismatch: missing={old_pairs - set(new)}, "
                         f"extra={set(new) - old_pairs}")

    rows = []
    for (w, n), runs in sorted(new.items()):
        tps_values = [int(runs[i]["tps"]) for i in (1, 2)]
        abort_values = [float(runs[i]["abort_rate"]) for i in (1, 2)]
        old_row = old[(w, n)]
        old_tps = float(old_row["mean_tps"])
        new_tps = mean(tps_values)
        rows.append({
            "active_warehouses": w,
            "active_threads": n,
            "item100k_mean_tps": old_tps,
            "item100k_min_tps": old_row["min_tps"],
            "item100k_max_tps": old_row["max_tps"],
            "item100k_mean_abort_rate": old_row["mean_abort_rate"],
            "item10k_mean_tps": new_tps,
            "item10k_min_tps": min(tps_values),
            "item10k_max_tps": max(tps_values),
            "item10k_mean_abort_rate": round(mean(abort_values), 5),
            "tps_delta_percent": round(100 * (new_tps / old_tps - 1), 2),
            "abort_delta_percentage_points": round(
                100 * (mean(abort_values) - float(old_row["mean_abort_rate"])), 2),
        })
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / "comparison.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    fig, axes = plt.subplots(2, 1, figsize=(11, 8), layout="constrained")
    for ax, w in zip(axes, (16, 32)):
        subset = [row for row in rows if row["active_warehouses"] == w]
        x = [row["active_threads"] for row in subset]
        for prefix, label, color in (("item100k", "100,000 Items (previous)", "#3875b3"),
                                     ("item10k", "10,000 Items", "#d55e00")):
            y = [row[f"{prefix}_mean_tps"] / 1000 for row in subset]
            low = [(row[f"{prefix}_mean_tps"] - float(row[f"{prefix}_min_tps"])) / 1000
                   for row in subset]
            high = [(float(row[f"{prefix}_max_tps"]) - row[f"{prefix}_mean_tps"]) / 1000
                    for row in subset]
            ax.errorbar(x, y, yerr=[low, high], color=color, marker="o", markersize=3.5,
                        capsize=2, linewidth=1.6, label=label)
        ax.axvline(48, color="gray", linestyle="--", linewidth=0.9)
        ax.set_title(f"W={w}", loc="left")
        ax.set_ylabel("Committed TPS (thousands)")
        ax.grid(alpha=0.25)
        ax.legend()
    axes[-1].set_xticks((1, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96))
    axes[-1].set_xlabel("Active worker threads N")
    fig.suptitle("TPC-C: physical-first pinning, uniform homes, mimalloc\n"
                 "Previous 100k-Item and new 10k-Item sweeps (different binary revisions)")
    fig.savefig(args.output / "tps_item100k_vs_10k.png", dpi=170)
    plt.close(fig)

    fig, axes = plt.subplots(2, 1, figsize=(11, 7), layout="constrained")
    for ax, w in zip(axes, (16, 32)):
        subset = [row for row in rows if row["active_warehouses"] == w]
        ax.plot([row["active_threads"] for row in subset],
                [row["tps_delta_percent"] for row in subset],
                marker="o", color="#6a3d9a")
        ax.axhline(0, color="black", linewidth=0.8)
        ax.axvline(48, color="gray", linestyle="--", linewidth=0.9)
        ax.set_title(f"W={w}", loc="left")
        ax.set_ylabel("TPS change (%)")
        ax.grid(alpha=0.25)
    axes[-1].set_xticks((1, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96))
    axes[-1].set_xlabel("Active worker threads N")
    fig.suptitle("10,000 Items relative to previous 100,000-Item sweep")
    fig.savefig(args.output / "tps_delta_percent.png", dpi=170)
    plt.close(fig)

    for w in (16, 32):
        subset = [row for row in rows if row["active_warehouses"] == w]
        for prefix in ("item100k", "item10k"):
            winner = max(subset, key=lambda row: row[f"{prefix}_mean_tps"])
            print(f"W={w} {prefix} best N={winner['active_threads']} "
                  f"TPS={winner[f'{prefix}_mean_tps']:,.1f}")


if __name__ == "__main__":
    main()
