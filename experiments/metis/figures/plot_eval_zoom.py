#!/usr/bin/env python3
"""Evaluation: active thread count of Metis and hill climbing on dynamic workloads (whole run and
the first 60 control periods of each period). TPC-C D11 (W 2 -> 8 -> 1), YCSB Y4 (skew 0.99 -> 0.5
-> 0.95; Metis with --metis_recheck_physical=false). Data: <bench>/dynamic_hill_climbing/logs.
  plot_eval_zoom.py [RUN]   Output: OUT/eval_dynamic.pdf"""
import sys
from collections import defaultdict
from pathlib import Path
import statistics as st
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import figcommon as P
from figcommon import series
from figcommon import curves

OUT = P.OUT / "eval_dynamic.pdf"
ZOOM = 60
TOP_SHRINK = 0.2   # inches removed from the height of the top (time) panel
METIS_WTOP_YCSB = 0.1   # YCSB top panel: Metis mean of 10 periods, hill climbing mean of 5 periods
YMAX = {"tpcc": 100, "ycsb": 100}
PAT = r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)"
BLOCKS = [("tpcc", "TPC-C", "D11", 0.2, 0.2, [(0, "2"), (20, "8"), (40, "1")], "$W$="),
          ("ycsb", "YCSB", "Y4", 0.01, 0.05, [(0, "0.99"), (20, "0.5"), (40, "0.95")], "skew=")]
MC = {"metis_v2": ("Metis", "#2a78d6", 1.4, 3), "adatam": ("Hill climbing", "#1baf7a", 0.9, 2)}


def binned(x, y, w):
    b = defaultdict(list)
    for t, v in zip(x, y):
        b[int(t / w + 1e-9)].append(v)
    ks = sorted(b)
    return [k * w for k in ks], [st.mean(b[k]) for k in ks]


def best_band(cur, s):
    best = max(cur[s], key=cur[s].get); top = cur[s][best]
    ns = [n for n in cur[s] if cur[s][n] >= 0.98 * top]
    return best, min(ns), max(ns)


def main(run="1"):
    plt.rcParams.update({"font.size": 7, "axes.spines.top": False, "axes.spines.right": False})
    fig = plt.figure(figsize=(7.0, 2.9))
    outer = fig.add_gridspec(1, 2, wspace=0.18)
    for b, (bench, title, name, per, wtop, ph, lab) in enumerate(BLOCKS):
        g = outer[b].subgridspec(3, 3, height_ratios=[0.3, 0.55, 1], hspace=1.0, wspace=0.28)
        cur = curves(bench)
        d = P.DATA / bench / "dynamic_hill_climbing" / "logs"
        # YCSB: Metis run without the physical-core re-measurement (E12, user decision 2026-11-10).
        mfile = {"metis_v2": "metis_v2_norephys" if bench == "ycsb" else "metis_v2", "adatam": "adatam"}
        tr = {m: series(P.first(d / f"{name}_{mfile[m]}_run{run}.trace.log",
                                d / f"{name}_{mfile[m].replace('metis_v2', 'metis')}_run{run}.trace.log"), PAT)
              for m in MC}
        tops = [(fig.add_subplot(g[0:2, :]), (0, 112), [0, 48, 96])]
        # Shrink only the top panel: raise its lower edge by TOP_SHRINK inches (bottom panels unchanged).
        pos = tops[0][0].get_position(); dy = TOP_SHRINK / fig.get_figheight()
        tops[0][0].set_position([pos.x0, pos.y0, pos.width, pos.height - dy])   # lower its top edge
        for k, (top, ylim, yt) in enumerate(tops):
            for i, (t0, s) in enumerate(ph):
                t1 = ph[i + 1][0] if i + 1 < len(ph) else 60
                best, lo, hi = best_band(cur, s)
                top.fill_between([t0, t1], lo, hi, color="#eb6834", alpha=0.18, lw=0, label="Within 98% of best" if i == 0 else None)
                top.hlines(best, t0, t1, color="#eb6834", ls="--", lw=0.9, label="Best" if i == 0 else None, zorder=4)
                if k == 0:
                    top.text((t0 + t1) / 2, ylim[1] - (0 if bench == "tpcc" else 0), f"{lab}{s}", ha="center", va="bottom",
                             fontsize=6.5, color="#555555", clip_on=False)
                top.add_patch(Rectangle((t0, 0), ZOOM * per, 100, fill=False, ec="#888888", lw=0.6, ls=":", zorder=5))
                if i:
                    top.axvline(t0, color="#bbbbbb", lw=0.6, zorder=0)
            for m, (lbl, c, lw, z) in MC.items():
                w_ = METIS_WTOP_YCSB if (bench == "ycsb" and m == "metis_v2") else wtop
                x, y = binned(*tr[m], w_)
                top.step(x, y, where="post", color=c, lw=lw, label=lbl, zorder=z)
            top.set_xlim(0, 60); top.set_ylim(*ylim); top.set_yticks(yt)
        top = tops[0][0]
        top.set_title(f"{title} ({lab}{' → '.join(s for _, s in ph)})".replace("$W$=", "W: ").replace("skew=", "skew: "),
                      fontsize=7.5, loc="left", pad=9)
        tops[-1][0].set_xlabel("Time (s)", labelpad=1)
        if b == 0:
            top.set_ylabel("Active threads")
        for i, (t0, s) in enumerate(ph):
            ax = fig.add_subplot(g[2, i])
            best, lo, hi = best_band(cur, s)
            ax.axhspan(lo, hi, color="#eb6834", alpha=0.18, lw=0); ax.axhline(best, color="#eb6834", ls="--", lw=0.9)
            for m, (lbl, c, lw, z) in MC.items():
                x, y = tr[m]
                pts = [((t - t0) / per, v) for t, v in zip(x, y) if t0 <= t < t0 + ZOOM * per]
                ax.step([p[0] for p in pts], [p[1] for p in pts], where="post", color=c, lw=lw, zorder=z)
            ax.set_xlim(0, ZOOM); ax.set_ylim(0, YMAX[bench]); ax.set_xticks([0, 30, 60])
            ax.set_yticks([0, 48, 96])
            if i:
                ax.set_yticklabels([])
            elif b == 0:
                ax.set_ylabel("Active threads")
            ax.set_title(f"{lab}{s}", fontsize=6.5, pad=2)
            ax.set_xlabel("Control periods" if i == 1 else "", labelpad=1)
    h, l = fig.axes[0].get_legend_handles_labels()
    order = [l.index(k) for k in ("Metis", "Hill climbing", "Best", "Within 98% of best")]
    fig.legend([h[i] for i in order], [l[i] for i in order], loc="upper center", ncol=4, frameon=False,
               fontsize=7, bbox_to_anchor=(0.5, 1.06 - TOP_SHRINK / fig.get_figheight()))
    fig.savefig(OUT, bbox_inches="tight"); fig.savefig(OUT.with_suffix(".png"), dpi=200, bbox_inches="tight")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "1")
