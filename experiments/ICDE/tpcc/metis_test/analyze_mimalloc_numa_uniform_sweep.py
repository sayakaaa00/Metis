#!/usr/bin/env python3
"""Summarize a fixed-thread sweep and compare empirical TPS with R(W)."""

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D


def reward_scale(w):
    return 400000 * (-math.expm1(-w / 16)) / (-math.expm1(-1))


def write_csv(path, columns, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--memory-policy-label", default="")
    parser.add_argument("--plot-title", default="")
    parser.add_argument("--boundary-label", default="socket 0 limit (48 CPUs)")
    parser.add_argument("--extra-xticks", type=int, nargs="*", default=[])
    parser.add_argument("--no-winner-labels", action="store_true",
                        help="Show best and near-best markers without text labels")
    args = parser.parse_args()

    grouped = defaultdict(dict)
    for path in args.results:
        with path.open(newline="") as handle:
            for row in csv.DictReader(handle):
                key = (int(row["active_warehouses"]), int(row["active_threads"]))
                run = int(row["run"])
                if run in grouped[key]:
                    raise ValueError(f"Duplicate result: {key}, run={run}")
                grouped[key][run] = row
    incomplete = [(key, sorted(runs)) for key, runs in grouped.items()
                  if sorted(runs) != list(range(1, args.runs + 1))]
    if incomplete:
        raise ValueError(f"Incomplete results: {incomplete[:10]}")

    summary = []
    for (w, n), runs in sorted(grouped.items()):
        tps = [int(row["tps"]) for row in runs.values()]
        abort = [float(row["abort_rate"]) for row in runs.values()]
        summary.append({
            "active_warehouses": w,
            "active_threads": n,
            "runs": len(tps),
            "mean_tps": round(mean(tps), 1),
            "min_tps": min(tps),
            "max_tps": max(tps),
            "mean_abort_rate": round(mean(abort), 5),
            "reward_scale_old": round(reward_scale(w), 1),
            "mean_reward_old_scale": round(mean(tps) / reward_scale(w), 4),
        })
    write_csv(args.output / "summary.csv", list(summary[0]), summary)

    by_w = defaultdict(list)
    for row in summary:
        by_w[row["active_warehouses"]].append(row)
    best = []
    for w, rows in sorted(by_w.items()):
        winner = max(rows, key=lambda row: row["mean_tps"])
        coarse = max((row for row in rows if row["active_threads"] in
                      (8, 16, 24, 32, 48, 64, 96)),
                     key=lambda row: row["mean_tps"])
        best.append({
            "active_warehouses": w,
            "best_measured_threads": winner["active_threads"],
            "best_mean_tps": winner["mean_tps"],
            "best_min_tps": winner["min_tps"],
            "best_max_tps": winner["max_tps"],
            "old_reward_scale": winner["reward_scale_old"],
            "best_tps_div_old_scale": winner["mean_reward_old_scale"],
            "best_coarse_threads": coarse["active_threads"],
            "best_coarse_mean_tps": coarse["mean_tps"],
            "coarse_loss_percent": round(100 * (1 - coarse["mean_tps"] /
                                                winner["mean_tps"]), 2),
            "within_2_percent_threads": " ".join(
                str(row["active_threads"]) for row in rows
                if row["mean_tps"] >= winner["mean_tps"] * 0.98),
            "tested_candidates": " ".join(str(row["active_threads"]) for row in rows),
        })
    write_csv(args.output / "best_by_w.csv", list(best[0]), best)

    plt.rcParams.update({"font.size": 10})
    fig, axes = plt.subplots(len(by_w), 1, figsize=(9, 2.8 * len(by_w)),
                             sharex=True, layout="constrained")
    if len(by_w) == 1:
        axes = [axes]
    for ax, (w, rows) in zip(axes, sorted(by_w.items())):
        x = [row["active_threads"] for row in rows]
        y = [row["mean_tps"] / 1000 for row in rows]
        low = [(row["mean_tps"] - row["min_tps"]) / 1000 for row in rows]
        high = [(row["max_tps"] - row["mean_tps"]) / 1000 for row in rows]
        ax.errorbar(x, y, yerr=[low, high], marker="o", capsize=3,
                    linewidth=1.4, label=f"W={w}")
        ax.axvline(48, color="gray", linestyle="--", linewidth=0.8)
        ax.set_ylabel("TPS (thousands)")
        ax.set_title(f"Active home warehouses W={w}", loc="left")
        ax.grid(alpha=0.25)
    axes[-1].set_xlabel("Active worker threads N")
    axes[-1].set_xticks(sorted({1, 8, 16, 24, 32, 40, 48, 56,
                               64, 72, 80, 88, 96, *args.extra_xticks}))
    title = args.plot_title or "TPC-C fixed workload: mimalloc, NUMA-priority workers, uniform homes"
    if args.memory_policy_label and not args.plot_title:
        title += f" ({args.memory_policy_label})"
    fig.suptitle(title)
    fig.savefig(args.output / "tps_by_threads.png", dpi=170)
    plt.close(fig)

    for scale in ("linear", "log"):
        fig, ax = plt.subplots(figsize=(10, 6), layout="constrained")
        label_offsets = {
            1: (35, 5), 4: (20, 12), 16: (-72, -30),
            32: (-72, 13), 96: (-150, -27),
            8: (20, 12), 14: (-80, -24), 24: (20, 12),
            64: (-130, -25), 128: (-160, -25),
        }
        for w, rows in sorted(by_w.items()):
            x = [row["active_threads"] for row in rows]
            y = [row["mean_tps"] / 1000 for row in rows]
            lower = [row["min_tps"] / 1000 for row in rows]
            upper = [row["max_tps"] / 1000 for row in rows]
            line, = ax.plot(x, y, marker="o", markersize=4,
                            linewidth=1.8, label=f"W={w}")
            ax.fill_between(x, lower, upper, color=line.get_color(), alpha=0.12)
            winner = max(rows, key=lambda row: row["mean_tps"])
            near = [row for row in rows
                    if row["mean_tps"] >= winner["mean_tps"] * 0.98]
            ax.scatter([row["active_threads"] for row in near],
                       [row["mean_tps"] / 1000 for row in near],
                       s=115, facecolors="none", edgecolors=line.get_color(),
                       linewidths=1.5, zorder=4)
            ax.scatter([winner["active_threads"]],
                       [winner["mean_tps"] / 1000],
                       marker="*", s=210, color=line.get_color(),
                       edgecolors="black", linewidths=0.7, zorder=5)
            best_tps = math.floor(winner["mean_tps"] + 0.5)
            offset = ((35, -25) if w == 96 and winner["active_threads"] < 88
                      else label_offsets[w])
            if not args.no_winner_labels:
                ax.annotate(f"W={w}: N={winner['active_threads']}, {best_tps:,} TPS",
                            xy=(winner["active_threads"], winner["mean_tps"] / 1000),
                            xytext=offset, textcoords="offset points",
                            fontsize=8.5, fontweight="bold",
                            bbox={"boxstyle": "round,pad=0.25", "fc": "white",
                                  "ec": line.get_color(), "alpha": 0.9},
                            arrowprops={"arrowstyle": "-", "color": line.get_color(),
                                        "lw": 0.8})
        ax.axvline(48, color="gray", linestyle="--", linewidth=1,
                   label=args.boundary_label)
        ax.set_xlim(0, 98)
        ax.set_xticks(sorted({1, 8, 10, 16, 20, 24, 32, 48, 64, 72, 80, 96,
                              *args.extra_xticks}))
        ax.set_xlabel("Active worker threads N")
        ax.set_ylabel("TPS (thousands)")
        ax.set_title(title)
        ax.grid(alpha=0.25)
        if scale == "log":
            ax.set_yscale("log")
        else:
            ax.set_ylim(bottom=0)
        handles, labels = ax.get_legend_handles_labels()
        handles += [
            Line2D([], [], marker="o", linestyle="None", markerfacecolor="none",
                   markeredgecolor="black", markersize=9),
            Line2D([], [], marker="*", linestyle="None", markerfacecolor="gold",
                   markeredgecolor="black", markersize=13),
        ]
        labels += ["within 2% of measured best", "measured best"]
        ax.legend(handles, labels, loc="upper left", ncol=2, fontsize=8.5)
        fig.savefig(args.output / f"tps_all_warehouses_{scale}.png", dpi=170)
        plt.close(fig)

    for row in best:
        print(f"W={row['active_warehouses']:>2} best measured N={row['best_measured_threads']:>2} "
              f"TPS={row['best_mean_tps']:>10,.1f} "
              f"TPS/R(W)={row['best_tps_div_old_scale']:.3f}")


if __name__ == "__main__":
    main()
