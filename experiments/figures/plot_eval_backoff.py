#!/usr/bin/env python3
"""Evaluation: Silo with the best fixed backoff vs. Silo with the best fixed active thread count.
Data as in plot_eval_static.py.  Output: OUT/eval_backoff.pdf"""
from pathlib import Path
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import figcommon as P
from plot_eval_static import data

OUT = P.OUT / "eval_backoff.pdf"
BARS = [("bfb", "Silo (best fixed backoff)", "#8c6d00"), ("oracle", "Silo (best fixed active thread count)", "#eb6834")]


def main():
    plt.rcParams.update({"font.size": 7, "axes.spines.top": False, "axes.spines.right": False})
    fig, axes = plt.subplots(2, 1, figsize=(3.4, 2.9))
    for ax, bench, xl in zip(axes, ("tpcc", "ycsb"), ("Number of accessed warehouses $W$ (TPC-C)", "Access skew (YCSB)")):
        S, D = data(bench)
        x = np.arange(len(S)); w = 0.36
        for j, (k, lab, c) in enumerate(BARS):
            ax.bar(x + (j - 0.5) * w, [D[k][s] / 1e6 for s in S], w * 0.92, color=c, label=lab, zorder=2)
        ax.set_xticks(x); ax.set_xticklabels(S); ax.set_xlim(-0.6, len(S) - 0.4)
        ax.set_xlabel(xl, labelpad=1); ax.set_ylabel("Throughput (M txn/s)")
        ax.grid(axis="y", color="#dddddd", lw=0.5, zorder=0)
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper center", ncol=2, frameon=False, fontsize=6.5, bbox_to_anchor=(0.55, 1.07),
               columnspacing=1.0, handlelength=1.5)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(OUT, bbox_inches="tight"); fig.savefig(OUT.with_suffix(".png"), dpi=200, bbox_inches="tight")


if __name__ == "__main__":
    main()
