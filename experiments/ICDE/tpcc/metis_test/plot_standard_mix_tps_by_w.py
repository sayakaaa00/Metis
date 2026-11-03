#!/usr/bin/env python3
"""TPC-C standard mix: TPS versus active worker count, one line per active W.

Left panel: low-W pilot (2026-11-03, 10 s x 2 runs).
Right panel: earlier full sweep (15 s x 2 runs) for W = 16/32/64/96.
Both use Item=100k, DB 96 warehouses, 96 workers, physical-first pinning,
mimalloc, and per-transaction uniform home selection.
"""
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

HERE = Path(__file__).resolve().parent
PILOT = HERE / "logs/fixed/contention_space_pilot_20261103/standard_lowW/results.csv"
SWEEP = HERE / "figures/mimalloc_physical_first_uniform_v1/all10/summary.csv"
OUT = HERE / "logs/fixed/contention_space_pilot_20261103/standard_tps_by_w.png"

# Ordinal single-hue (blue) ramp from the dataviz reference palette; light end
# no lighter than step 250 so every line clears 2:1 on the light surface.
LOW_W = {1: "#86b6ef", 2: "#5598e7", 3: "#3987e5", 4: "#2a78d6",
         6: "#256abf", 8: "#184f95", 12: "#0d366b"}
HIGH_W = {16: "#6da7ec", 32: "#2a78d6", 64: "#1c5cab", 96: "#0d366b"}
MARKERS = "osD^vP*X"
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"


def load_pilot():
    data = defaultdict(lambda: defaultdict(list))
    with PILOT.open() as stream:
        for row in csv.DictReader(stream):
            data[int(row["active_warehouses"])][int(row["active_threads"])].append(
                float(row["tps"]))
    return {w: {n: statistics.mean(v) for n, v in ns.items()} for w, ns in data.items()}


def load_sweep():
    data = defaultdict(dict)
    with SWEEP.open() as stream:
        for row in csv.DictReader(stream):
            data[int(row["active_warehouses"])][int(row["active_threads"])] = float(
                row["mean_tps"])
    return data


def panel(ax, data, colors, title):
    ends = []
    for i, (w, color) in enumerate(colors.items()):
        points = sorted(data[w].items())
        xs = [n for n, _ in points]
        ys = [t for _, t in points]
        ax.plot(xs, ys, color=color, linewidth=2, marker=MARKERS[i % len(MARKERS)],
                markersize=5, markeredgecolor=SURFACE, markeredgewidth=0.8,
                label=f"W={w}", zorder=3)
        best_n, best_t = max(points, key=lambda p: p[1])
        ax.scatter([best_n], [best_t], s=110, facecolor="none", edgecolor=INK,
                   linewidth=1.4, zorder=4)
        ends.append([ys[-1], w, xs[-1]])
    # Direct labels at line ends, nudged apart so they never overlap.
    top = max(max(d.values()) for w, d in data.items() if w in colors)
    gap = 0.045 * top
    ends.sort()
    for i in range(1, len(ends)):
        ends[i][0] = max(ends[i][0], ends[i - 1][0] + gap)
    for y, w, x in ends:
        ax.annotate(f"W={w}", (x, y), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=9, color=INK2)
    ax.axvline(48, color=INK2, linestyle=":", linewidth=1, zorder=1)
    ax.text(48, 1.0, " 48 physical cores", transform=ax.get_xaxis_transform(),
            va="top", ha="left", fontsize=8, color=INK2)
    ax.set_title(title, fontsize=11, color=INK, loc="left")
    ax.set_xlabel("Active worker threads N", color=INK2)
    ax.set_xlim(0, 106)
    ax.set_xticks([8, 16, 24, 32, 48, 64, 80, 96])
    ax.set_ylim(bottom=0)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v / 1000:,.0f}k"))
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9)
    ax.legend(frameon=False, fontsize=8, loc="upper center",
              bbox_to_anchor=(0.5, -0.17), ncol=len(colors))


def main():
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.0), facecolor=SURFACE)
    for ax in axes:
        ax.set_facecolor(SURFACE)
    panel(axes[0], load_pilot(), LOW_W, "High contention: W = 1–12 (10 s × 2 runs)")
    panel(axes[1], load_sweep(), HIGH_W, "Lower contention: W = 16–96 (15 s × 2 runs)")
    axes[0].set_ylabel("Throughput (committed TPS)", color=INK2)
    fig.suptitle("TPC-C standard mix: throughput vs. active workers (circle = best N)",
                 fontsize=12, color=INK, x=0.01, ha="left")
    fig.tight_layout()
    fig.savefig(OUT, dpi=160, facecolor=SURFACE)
    print(OUT)


if __name__ == "__main__":
    main()
