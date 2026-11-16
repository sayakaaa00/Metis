#!/usr/bin/env python3
"""Background: throughput vs. active thread count (oracle sweeps), TPC-C and YCSB.
Circles mark the best active thread count of each curve.
Data: tpcc/oracle, ycsb/oracle/skew_0.7-0.999.  plot_motivation_tps_vs_threads.py OUT.pdf"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, FixedLocator
import figcommon as P

plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                     "font.size": 8, "pdf.fonttype": 42})
KEEP = {"tpcc": [("W=1", "W = 1"), ("W=4", "W = 4"), ("W=32", "W = 32")],
        "ycsb": [("skew=0.7", "skew 0.7"), ("skew=0.9", "skew 0.9"), ("skew=0.999", "skew 0.999")]}
COLORS = ["#e8833a", "#2a9d5c", "#2a5fb0"]
MARK = "osD"
CURVES = {"tpcc": P.tpcc_curves_labeled(), "ycsb": P.ycsb_curves()}
TITLE = {"tpcc": "TPC-C (W: active warehouses)", "ycsb": "YCSB"}
fmt = FuncFormatter(lambda v, _: f"{v/1e6:g}M" if v >= 1e6 else f"{v/1e3:g}k")


def draw(ax, bench):
    for i, (key, lab) in enumerate(KEEP[bench]):
        pts = sorted(CURVES[bench][key].items())
        ax.plot([n for n, _ in pts], [t for _, t in pts], color=COLORS[i], lw=1.3, marker=MARK[i],
                ms=2.5, label=lab)
        bn, bt = max(pts, key=lambda p: p[1])
        ax.scatter([bn], [bt], s=40, facecolor="none", edgecolor="black", lw=0.9, zorder=5)
        # label next to the last point of the curve
        ax.annotate(lab, (pts[-1][0], pts[-1][1]), xytext=(4, 0), textcoords="offset points",
                    va="center", ha="left", fontsize=6.5, color=COLORS[i])
    ax.set_yscale("log")
    ax.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    ax.yaxis.set_major_locator(FixedLocator([3e4, 1e5, 3e5, 1e6, 3e6, 1e7]))
    lo, hi = ax.get_ylim(); ax.set_ylim(lo, hi * 1.3)
    ax.yaxis.set_major_formatter(fmt)
    ax.set_xticks([8, 24, 48, 72, 96]); ax.set_xlim(0, 108)
    ax.grid(axis="y", color="#e4e3df", lw=0.6); ax.set_axisbelow(True)
    for s in ("top", "right"): ax.spines[s].set_visible(False)
    ax.set_title(TITLE[bench], fontsize=8, pad=3)


fig, axes = plt.subplots(2, 1, figsize=(3.3, 2.35))
for ax, b in zip(axes, ("tpcc", "ycsb")): draw(ax, b)
axes[1].set_xlabel("Active thread count")
fig.supylabel("Throughput (txn/s, log scale)", fontsize=8, x=0.02)
fig.tight_layout(h_pad=1.0)
fig.savefig(sys.argv[1], bbox_inches="tight", pad_inches=0.02)
