#!/usr/bin/env python3
"""YCSB fixed-N oracle: TPS vs active workers per skew, and pin-order A/B."""
import csv
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

HERE = Path(__file__).resolve().parent
PF = HERE / "oracle_physical_first_20261103/results.csv"
S0 = HERE / "oracle_socket0_first_ab_20261103/results.csv"
OUT = HERE / "oracle_physical_first_20261103/tps_by_skew.png"
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
# Ordinal blue ramp (dataviz reference palette, steps 250..700).
SKEW_COLORS = {"0.7": "#86b6ef", "0.8": "#5598e7", "0.85": "#3987e5",
               "0.9": "#2a78d6", "0.95": "#1c5cab", "0.99": "#184f95",
               "0.999": "#0d366b"}
MARKERS = "osD^vP*X"


def load(path):
    data = defaultdict(lambda: defaultdict(list))
    with path.open() as stream:
        for row in csv.DictReader(stream):
            data[row["skew"]][int(row["threads"])].append(float(row["throughput_tps"]))
    return {s: {n: statistics.mean(v) for n, v in ns.items()} for s, ns in data.items()}


def style(ax, title):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, fontsize=11, color=INK, loc="left")
    ax.set_xlabel("Active worker threads N", color=INK2)
    ax.set_xticks([8, 16, 24, 32, 48, 64, 80, 96])
    ax.set_ylim(bottom=0)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v / 1e6:.1f}M"))
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9)
    ax.axvline(24, color=INK2, linestyle=":", linewidth=1, zorder=1)
    ax.text(24, 1.0, " 24 = one socket's physical cores", transform=ax.get_xaxis_transform(),
            va="top", ha="left", fontsize=8, color=INK2)


def main():
    pf, s0 = load(PF), load(S0)
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.0), facecolor=SURFACE)
    ax = axes[0]
    ends = []
    for i, (skew, color) in enumerate(SKEW_COLORS.items()):
        pts = sorted(pf[skew].items())
        ax.plot([n for n, _ in pts], [t for _, t in pts], color=color, linewidth=2,
                marker=MARKERS[i], markersize=4, markeredgecolor=SURFACE,
                markeredgewidth=0.6, label=f"skew {skew}", zorder=3)
        bn, bt = max(pts, key=lambda p: p[1])
        ax.scatter([bn], [bt], s=100, facecolor="none", edgecolor=INK, linewidth=1.3, zorder=4)
        ends.append([pts[-1][1], skew, pts[-1][0]])
    style(ax, "Physical-first pinning, all skews (10 s × 2 runs)")
    ax.set_xlim(0, 108)
    ax.set_ylabel("Throughput (committed TPS)", color=INK2)
    ax.legend(frameon=False, fontsize=8, loc="upper center",
              bbox_to_anchor=(0.5, -0.17), ncol=4)

    ax = axes[1]
    for i, skew in enumerate(["0.7", "0.8", "0.9"]):
        color = SKEW_COLORS[skew]
        a = sorted((n, t) for n, t in pf[skew].items() if n <= 56)
        b = sorted(s0[skew].items())
        ax.plot([n for n, _ in a], [t for _, t in a], color=color, linewidth=2,
                marker=MARKERS[i], markersize=4, label=f"skew {skew}, physical-first")
        ax.plot([n for n, _ in b], [t for _, t in b], color=color, linewidth=2,
                linestyle="--", marker=MARKERS[i], markersize=4, markerfacecolor=SURFACE,
                label=f"skew {skew}, socket0-first")
    style(ax, "Pin order A/B for N ≥ 24 (dashed = socket0-first)")
    ax.set_xlim(6, 58)
    ax.set_xticks([8, 16, 24, 32, 40, 48, 56])
    ax.legend(frameon=False, fontsize=8, loc="upper center",
              bbox_to_anchor=(0.5, -0.17), ncol=3)
    fig.suptitle("YCSB (10k tuples, 10 ops, 50% read): throughput vs. active workers "
                 "(circle = best N)", fontsize=12, color=INK, x=0.01, ha="left")
    fig.tight_layout()
    fig.savefig(OUT, dpi=160, facecolor=SURFACE)
    print(OUT)


if __name__ == "__main__":
    main()
