#!/usr/bin/env python3
"""Fixed-load method comparison: TPS per state for every method plus the oracle.

  plot_compare.py --bench tpcc|ycsb
Writes <bench>/compare_fixed/tps_by_state.png (log y) and summary.csv.
"""
import argparse
import csv
import statistics
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

import plot_fixed as P

INK, INK2, GRID, SURFACE = P.INK, P.INK2, P.GRID, P.SURFACE
# Categorical palette in fixed order (dataviz reference palette).
SERIES = [("metis_v2", "Metis", "#2a78d6", "o"),
          ("adatam", "adaTAM", "#1baf7a", "s"),
          ("silo_bo", "Silo (backoff)", "#eda100", "D"),
          ("silo_nobo", "Silo (no backoff)", "#e87ba4", "v"),
          ("cicada", "Cicada", "#008300", "^"),
          ("ermia", "ERMIA", "#6250d6", "P")]
ORACLE = ("Oracle (best fixed N)", "#eb6834")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", default="tpcc")
    p.add_argument("--exclude", default="", help="comma-separated method keys to omit")
    p.add_argument("--out", default="tps_by_state.png")
    args = p.parse_args()
    excluded = set(filter(None, args.exclude.split(",")))
    d = P.HERE / args.bench / "compare_fixed"
    oracle = P.tpcc_oracle() if args.bench == "tpcc" else P.ycsb_oracle()
    data = defaultdict(list)
    with (d / "results.csv").open() as f:
        for r in csv.DictReader(f):
            if r["tps"]:
                data[(r["method"], r["state"])].append(float(r["tps"]))
    states = sorted({s for _, s in data}, key=float)
    label = "W" if args.bench == "tpcc" else "skew"
    xs = list(range(len(states)))

    fig, ax = plt.subplots(figsize=(9.5, 5.2), facecolor=SURFACE)
    P.style(ax)
    ax.plot(xs, [oracle[s][1] for s in states], color=ORACLE[1], linewidth=2,
            linestyle="--", marker="*", markersize=10, label=ORACLE[0], zorder=5)
    for key, name, color, marker in SERIES:
        if key in excluded:
            continue
        ys = [statistics.mean(data[(key, s)]) for s in states]
        lo = [y - min(data[(key, s)]) for y, s in zip(ys, states)]
        hi = [max(data[(key, s)]) - y for y, s in zip(ys, states)]
        ax.errorbar(xs, ys, yerr=[lo, hi], color=color, linewidth=2, marker=marker,
                    markersize=6, markeredgecolor=SURFACE, capsize=2, label=name,
                    zorder=6 if key == "metis_v2" else 4)
    ax.set_xticks(xs)
    ax.set_xticklabels([f"{label}={s}" for s in states])
    ax.set_yscale("log")
    lo_v = min(min(v) for v in data.values())
    hi_v = max(max(v) for v in data.values())
    ax.set_yticks([t for t in (2e2, 5e2, 1e3, 2e3, 5e3, 1e4, 2e4, 5e4, 1e5, 2e5, 5e5,
                               1e6, 2e6, 5e6, 1e7) if lo_v / 1.5 <= t <= hi_v * 1.5])
    ax.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    ax.yaxis.set_major_formatter(FuncFormatter(
        lambda v, _: f"{v / 1e6:g}M" if v >= 1e6 else f"{v / 1e3:g}k"))
    ax.set_ylabel("Throughput (committed TPS, log scale)", color=INK2)
    run_s = "30 s" if args.bench == "tpcc" else "10 s"
    ax.set_title(f"{args.bench.upper()} fixed load: all methods ({run_s} x 2 runs, "
                 "96 workers, physical-first)", fontsize=11, color=INK, loc="left")
    ax.legend(frameon=False, fontsize=8.5, loc="upper center",
              bbox_to_anchor=(0.5, -0.1), ncol=4)
    fig.tight_layout()
    fig.savefig(d / args.out, dpi=150, facecolor=SURFACE)

    with (d / "summary.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["state", "oracle_tps"] + [k for k, *_ in SERIES])
        for s in states:
            w.writerow([s, f"{oracle[s][1]:.0f}"] +
                       [f"{statistics.mean(data[(k, s)]):.0f}" for k, *_ in SERIES])
    print(d / args.out)


if __name__ == "__main__":
    main()
