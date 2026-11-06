#!/usr/bin/env python3
"""Motivation figure: TPS vs active worker count (fixed N, oracle sweeps).

Left: TPC-C standard mix, 8 active-warehouse states (10 s x 2 runs).
Right: YCSB, 7 Zipf skews (10 s x 2 runs). Circles mark the best N.
Reads <bench>/oracle/results.csv; writes paper_figures/motivation_tps_vs_threads.png.
"""

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

import common as C
import plot_common as P

OUT = P.FIGURES
RAMP = ["#86b6ef", "#5598e7", "#3987e5", "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#0d366b"]
MARK = "osD^vP*X"


def tpcc_curves():
    curves = C.oracle_curve("tpcc")
    return {f"W={w}": curves[w] for w in sorted(curves, key=int)}


def ycsb_curves():
    curves = C.oracle_curve("ycsb")
    return {f"skew={s}": curves[s] for s in sorted(curves, key=float)}


def panel(ax, curves, title, fmt):
    P.style(ax)
    for i, (name, c) in enumerate(curves.items()):
        pts = sorted(c.items())
        color = RAMP[min(i, len(RAMP) - 1)]
        ax.plot([n for n, _ in pts], [t for _, t in pts], color=color, linewidth=1.8,
                marker=MARK[i % len(MARK)], markersize=3.5, markeredgecolor=P.SURFACE,
                markeredgewidth=0.5, label=name)
        bn, bt = max(pts, key=lambda p: p[1])
        ax.scatter([bn], [bt], s=70, facecolor="none", edgecolor=P.INK, linewidth=1.2, zorder=5)
    ax.set_title(title, fontsize=11, color=P.INK, loc="left")
    ax.set_xlabel("Active worker threads", color=P.INK2)
    ax.set_xticks([8, 16, 24, 32, 48, 64, 80, 96])
    ax.set_xlim(0, 100)
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(FuncFormatter(fmt))
    ax.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    ax.legend(frameon=False, fontsize=7.5, loc="upper center", bbox_to_anchor=(0.5, -0.17),
              ncol=4)


def main():
    OUT.mkdir(exist_ok=True)
    fig, (a, b) = plt.subplots(1, 2, figsize=(12, 4.8), facecolor=P.SURFACE)
    panel(a, tpcc_curves(), "TPC-C (standard mix), active warehouses W",
          lambda v, _: f"{v / 1e6:g}M" if v >= 1e6 else f"{v / 1e3:g}k")
    a.set_yticks([3e4, 5e4, 1e5, 2e5, 5e5, 1e6])
    a.set_ylabel("Throughput (committed TPS, log scale)", color=P.INK2)
    panel(b, ycsb_curves(), "YCSB (10k records, 50% read), Zipf skew",
          lambda v, _: f"{v / 1e6:g}M")
    b.set_yticks([5e5, 1e6, 2e6, 5e6])
    fig.suptitle("Throughput vs. active worker threads (circle = best fixed count)",
                 fontsize=12, color=P.INK, x=0.01, ha="left")
    fig.tight_layout()
    fig.savefig(OUT / "motivation_tps_vs_threads.png", dpi=160, facecolor=P.SURFACE)
    print(OUT / "motivation_tps_vs_threads.png")


if __name__ == "__main__":
    main()
