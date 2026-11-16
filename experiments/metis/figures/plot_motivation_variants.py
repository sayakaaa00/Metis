#!/usr/bin/env python3
"""Background: throughput vs. active thread count (oracle sweeps), TPC-C and YCSB.
Data: tpcc/oracle, ycsb/oracle/skew_0.7-0.999.  plot_motivation_variants.py 6 OUT.pdf (paper: layout 6)"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, FixedLocator
import figcommon as P

plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                     "font.size": 8, "pdf.fonttype": 42})
V = int(sys.argv[1])
KEEP = {"tpcc": [("W=1", "W = 1"), ("W=4", "W = 4"), ("W=32", "W = 32")],
        "ycsb": [("skew=0.7", "skew 0.7"), ("skew=0.9", "skew 0.9"), ("skew=0.999", "skew 0.999")]}
COLORS = ["#e8833a", "#2a9d5c", "#2a5fb0"]
MARK = "osD"
CURVES = {"tpcc": P.tpcc_curves_labeled(), "ycsb": P.ycsb_curves()}
TITLE = {"tpcc": "TPC-C (W: active warehouses)", "ycsb": "YCSB"}
fmt = FuncFormatter(lambda v, _: f"{v/1e6:g}M" if v >= 1e6 else f"{v/1e3:g}k")


def draw(ax, bench, log, legend, best_mark=None):
    for i, (key, lab) in enumerate(KEEP[bench]):
        pts = sorted(CURVES[bench][key].items())
        ax.plot([n for n, _ in pts], [t for _, t in pts], color=COLORS[i], lw=1.3, marker=MARK[i],
                ms=2.5, label=lab)
        bn, bt = max(pts, key=lambda p: p[1])
        ax.scatter([bn], [bt], s=40, facecolor="none", edgecolor="black", lw=0.9, zorder=5)
        if legend == "direct":
            ax.annotate(lab, (pts[-1][0], pts[-1][1]), xytext=(4, 0), textcoords="offset points",
                        va="center", ha="left", fontsize=6.5, color=COLORS[i])
        if best_mark == "text":
            ax.annotate(f"{bn}", (bn, bt), xytext=(0, 5), textcoords="offset points",
                        ha="center", va="bottom", fontsize=6.5, fontweight="bold")
        if best_mark == "vline":
            ax.axvline(bn, color=COLORS[i], lw=0.8, ls=":", zorder=1)
    if log:
        ax.set_yscale("log")
        ax.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
        ax.yaxis.set_major_locator(FixedLocator([3e4, 1e5, 3e5, 1e6, 3e6, 1e7]))
        lo, hi = ax.get_ylim(); ax.set_ylim(lo, hi * (1.8 if best_mark == "text" else 1.3))
    else:
        ax.set_ylim(bottom=0)
    ax.yaxis.set_major_formatter(fmt)
    ax.set_xticks([8, 24, 48, 72, 96]); ax.set_xlim(0, 100 if legend != "direct" else 108)
    ax.grid(axis="y", color="#e4e3df", lw=0.6); ax.set_axisbelow(True)
    for s in ("top", "right"): ax.spines[s].set_visible(False)
    if legend == "row":   # title on the left, legend entries on the same line
        ax.text(0.0, 1.03, TITLE[bench], transform=ax.transAxes, ha="left", va="bottom", fontsize=8)
        ax.legend(frameon=False, fontsize=6.5, handlelength=1.4, ncol=3, columnspacing=0.8,
                  handletextpad=0.4, loc="lower right", bbox_to_anchor=(1.0, 0.98), borderaxespad=0)
    else:
        ax.set_title(TITLE[bench], fontsize=8, pad=3)


fig, axes = plt.subplots(2, 1, figsize=(3.3, 2.35))
opts = {5: dict(log=True, legend="row"),
        6: dict(log=True, legend="direct"),
        7: dict(log=True, legend="direct", best_mark="text"),
        8: dict(log=True, legend="row", best_mark="vline"),
        9: dict(log=False, legend="direct")}[V]
for ax, b in zip(axes, ("tpcc", "ycsb")): draw(ax, b, **opts)
axes[1].set_xlabel("Active thread count")
fig.supylabel("Throughput (txn/s, log scale)" if opts["log"] else "Throughput (txn/s)", fontsize=8, x=0.02)
fig.tight_layout(h_pad=1.0)
fig.savefig(sys.argv[2], bbox_inches="tight", pad_inches=0.02)
