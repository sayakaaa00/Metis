#!/usr/bin/env python3
"""Summarize paired TPC-C worker-pinning A/B measurements."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def write_csv(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=2)
    args = parser.parse_args()

    raw = defaultdict(dict)
    with args.results.open(newline="") as handle:
        for row in csv.DictReader(handle):
            key = (int(row["active_warehouses"]), int(row["active_threads"]))
            mode = row["pin_workers"]
            run = int(row["run"])
            if mode not in ("true", "false") or (mode, run) in raw[key]:
                raise ValueError(f"Invalid or duplicate result: {key}, {mode}, {run}")
            raw[key][mode, run] = row
    expected = {(mode, run) for mode in ("true", "false")
                for run in range(1, args.runs + 1)}
    for key, values in raw.items():
        if set(values) != expected:
            raise ValueError(f"Incomplete A/B pair: {key}, {set(values)}")

    summary = []
    for (w, n), rows in sorted(raw.items()):
        on = [int(rows["true", run]["tps"]) for run in range(1, args.runs + 1)]
        off = [int(rows["false", run]["tps"]) for run in range(1, args.runs + 1)]
        abort_on = [float(rows["true", run]["abort_rate"])
                    for run in range(1, args.runs + 1)]
        abort_off = [float(rows["false", run]["abort_rate"])
                     for run in range(1, args.runs + 1)]
        result = {
            "active_warehouses": w,
            "active_threads": n,
            "pin_on_mean_tps": round(mean(on), 1),
            "pin_off_mean_tps": round(mean(off), 1),
            "pin_on_min_tps": min(on),
            "pin_on_max_tps": max(on),
            "pin_off_min_tps": min(off),
            "pin_off_max_tps": max(off),
            "pin_gain_pct": round(100 * (mean(on) / mean(off) - 1), 2),
            "pin_gain_run1_pct": round(100 * (on[0] / off[0] - 1), 2),
            "pin_gain_run2_pct": round(100 * (on[1] / off[1] - 1), 2),
            "pin_on_abort_rate": round(mean(abort_on), 5),
            "pin_off_abort_rate": round(mean(abort_off), 5),
        }
        summary.append(result)
    write_csv(args.output / "summary.csv", summary)

    by_w = defaultdict(list)
    for row in summary:
        by_w[row["active_warehouses"]].append(row)
    best = []
    for w, rows in sorted(by_w.items()):
        on = max(rows, key=lambda row: row["pin_on_mean_tps"])
        off = max(rows, key=lambda row: row["pin_off_mean_tps"])
        best.append({
            "active_warehouses": w,
            "pin_on_best_n": on["active_threads"],
            "pin_on_best_mean_tps": on["pin_on_mean_tps"],
            "pin_off_best_n": off["active_threads"],
            "pin_off_best_mean_tps": off["pin_off_mean_tps"],
            "best_gain_pct": round(100 * (on["pin_on_mean_tps"] /
                                          off["pin_off_mean_tps"] - 1), 2),
            "tested_candidates": " ".join(str(row["active_threads"]) for row in rows),
        })
    write_csv(args.output / "best_by_w.csv", best)

    fig, axes = plt.subplots(len(by_w), 1, figsize=(9, 2.7 * len(by_w)),
                             layout="constrained")
    if len(by_w) == 1:
        axes = [axes]
    for ax, (w, rows) in zip(axes, sorted(by_w.items())):
        x = [row["active_threads"] for row in rows]
        for mode, label, color in (("pin_on", "NUMA-priority pinning", "tab:blue"),
                                   ("pin_off", "OS scheduler", "tab:orange")):
            y = [row[f"{mode}_mean_tps"] / 1000 for row in rows]
            low = [(row[f"{mode}_mean_tps"] - row[f"{mode}_min_tps"]) / 1000
                   for row in rows]
            high = [(row[f"{mode}_max_tps"] - row[f"{mode}_mean_tps"]) / 1000
                    for row in rows]
            ax.errorbar(x, y, yerr=[low, high], marker="o", capsize=3,
                        linewidth=1.5, color=color, label=label)
        ax.axvline(48, color="gray", linestyle="--", linewidth=0.8)
        margin = max(2, (max(x) - min(x)) * 0.07)
        ax.set_xlim(min(x) - margin, max(x) + margin)
        ax.set_xticks(x)
        ax.set_title(f"W={w}", loc="left")
        ax.set_ylabel("TPS (thousands)")
        ax.set_xlabel("Active worker threads N")
        ax.grid(alpha=0.25)
    axes[0].legend(loc="best")
    fig.suptitle("TPC-C mimalloc: NUMA-priority pinning vs OS scheduling")
    fig.savefig(args.output / "pinning_tps_by_w.png", dpi=170)
    plt.close(fig)

    for row in summary:
        print(f"W={row['active_warehouses']:>2} N={row['active_threads']:>2} "
              f"on={row['pin_on_mean_tps']:>10,.1f} "
              f"off={row['pin_off_mean_tps']:>10,.1f} "
              f"on/off={row['pin_gain_pct']:+.2f}%")


if __name__ == "__main__":
    main()
