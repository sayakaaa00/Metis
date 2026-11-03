#!/usr/bin/env python3
"""Summarize pinned TPC-C A/B with physical-first versus socket0-first CPUs."""

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

from analyze_mimalloc_bimodal_pinning import parse_log


def write_csv(path, rows):
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=2)
    args = parser.parse_args()

    groups = defaultdict(dict)
    with args.results.open(newline="") as handle:
        for row in csv.DictReader(handle):
            key = (int(row["active_warehouses"]), int(row["active_threads"]),
                   row["pin_order"])
            run = int(row["run"])
            if run in groups[key]:
                raise ValueError(f"Duplicate {key}, run={run}")
            metrics = parse_log(Path(row["log"]))
            metrics["tps"] = int(row["tps"])
            groups[key][run] = metrics
    expected = set(range(1, args.runs + 1))
    if any(set(runs) != expected for runs in groups.values()):
        raise ValueError("Incomplete runs")

    summary = []
    for (w, n, order), runs in sorted(groups.items()):
        values = list(runs.values())
        tps_values = [row["tps"] for row in values]
        summary.append({
            "active_warehouses": w,
            "active_threads": n,
            "pin_order": order,
            "runs": len(values),
            "mean_tps": round(mean(tps_values), 1),
            "min_tps": min(tps_values),
            "max_tps": max(tps_values),
            "mean_attempts_per_second": round(mean(row["attempts_per_second"]
                                                   for row in values), 1),
            "mean_abort_fraction": round(mean(row["abort_fraction"]
                                               for row in values), 5),
            "mean_delivery_abort_share": round(mean(row["delivery_abort_share"]
                                                     for row in values), 5),
        })
    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "summary.csv", summary)

    paired = defaultdict(dict)
    for row in summary:
        paired[row["active_warehouses"], row["active_threads"]][row["pin_order"]] = row
    comparison = []
    for (w, n), modes in sorted(paired.items()):
        if set(modes) != {"socket0_first", "physical_first"}:
            raise ValueError(f"Incomplete pin orders for W={w}, N={n}")
        old = modes["socket0_first"]
        new = modes["physical_first"]
        comparison.append({
            "active_warehouses": w,
            "active_threads": n,
            "socket0_first_tps": old["mean_tps"],
            "physical_first_tps": new["mean_tps"],
            "physical_first_delta_percent": round(
                100 * (new["mean_tps"] / old["mean_tps"] - 1), 2),
            "socket0_first_abort_fraction": old["mean_abort_fraction"],
            "physical_first_abort_fraction": new["mean_abort_fraction"],
            "socket0_first_attempts_per_second": old["mean_attempts_per_second"],
            "physical_first_attempts_per_second": new["mean_attempts_per_second"],
        })
    write_csv(args.output / "comparison.csv", comparison)

    warehouses = sorted({row["active_warehouses"] for row in summary})
    fig, axes = plt.subplots(len(warehouses), 1, figsize=(9, 3.4 * len(warehouses)),
                             sharex=True, layout="constrained")
    if len(warehouses) == 1:
        axes = [axes]
    colors = {"socket0_first": "#4c78a8", "physical_first": "#f58518"}
    labels = {"socket0_first": "socket 0 first (old)",
              "physical_first": "physical cores first (new)"}
    for ax, w in zip(axes, warehouses):
        for order in ("socket0_first", "physical_first"):
            rows = [row for row in summary if row["active_warehouses"] == w
                    and row["pin_order"] == order]
            ns = [row["active_threads"] for row in rows]
            ys = [row["mean_tps"] / 1000 for row in rows]
            lower = [(row["mean_tps"] - row["min_tps"]) / 1000 for row in rows]
            upper = [(row["max_tps"] - row["mean_tps"]) / 1000 for row in rows]
            ax.errorbar(ns, ys, yerr=[lower, upper], marker="o", capsize=3,
                        color=colors[order], label=labels[order])
        ax.axvline(48, color="gray", linestyle="--", linewidth=0.8)
        ax.set_title(f"W={w}", loc="left")
        ax.set_ylabel("TPS (thousands)")
        ax.grid(alpha=0.25)
    axes[0].legend(loc="best")
    axes[-1].set_xlabel("Active pinned workers N")
    axes[-1].set_xticks(sorted({row["active_threads"] for row in summary}))
    fig.suptitle("mimalloc TPC-C: pinning order A/B (OS-default memory)")
    fig.savefig(args.output / "tps_by_w.png", dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    main()
