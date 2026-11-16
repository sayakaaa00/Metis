#!/usr/bin/env python3
"""Evaluation: active thread count of Metis and hill climbing in the first 150 control periods
on static workloads. TPC-C: tpcc/fixed/logs (run 1). YCSB: Metis ycsb/fixed/logs, hill climbing
ycsb/hill_climbing_10ms_log (per-period samples).  Output: OUT/eval_static_time.pdf"""
import sys
from pathlib import Path
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import figcommon as P
from figcommon import series
from figcommon import curves

OUT = P.OUT / "eval_static_time.pdf"
PAT = r"\[(?:Throttle|TAM) sample\] bench_s=([\d.]+) active_threads=(\d+)"
H = P.DATA


def paths(bench, s, run="1"):
    if bench == "tpcc":
        return (P.first(H / f"tpcc/fixed/logs/metis_v2_{s}_run{run}.trace.log", H / f"tpcc/fixed/logs/metis_{s}_run{run}.trace.log"),
                H / f"tpcc/fixed/logs/hill_climbing_{s}_run{run}.trace.log")
    if s in ("0", "0.5"):
        return (H / f"ycsb/fixed/logs/metis_{s}_run{run}.trace.log",
                H / f"ycsb/hill_climbing_10ms_log/logs/hill_climbing_{s}_run{run}.trace.log")
    return (H / f"ycsb/fixed/logs/metis_{s}_run{run}.trace.log",
            H / f"ycsb/hill_climbing_10ms_log/logs/hill_climbing_{s}_run{run}.trace.log")


def main(run="1"):
    plt.rcParams.update({"font.size": 6.5, "axes.spines.top": False, "axes.spines.right": False})
    rows = [("tpcc", ["1", "2", "4", "8", "16"], 30, "$W$="),
            ("ycsb", ["0.8", "0.9", "0.95", "0.99", "0.999"], 5, "skew=")]
    fig, axes = plt.subplots(2, 5, figsize=(7.0, 2.4), sharey=True)
    for r, (bench, S, T, lab) in enumerate(rows):
        cur = curves(bench)
        for c in range(5):
            ax = axes[r][c]
            if c >= len(S):
                ax.axis("off"); continue
            s = S[c]
            best = max(cur[s], key=cur[s].get); top = cur[s][best]
            ns = [n for n in cur[s] if cur[s][n] >= 0.98 * top]
            ax.axhspan(min(ns), max(ns), color="#eb6834", alpha=0.18, lw=0, label="Within 98% of best")
            ax.axhline(best, color="#eb6834", ls="--", lw=0.8, label="Best")
            pm, ph = paths(bench, s, run)
            per = 0.2 if bench == "tpcc" else 0.01   # control period (s)
            for path, col, name, lw, z in ((ph, "#1baf7a", "Hill climbing", 0.8, 2), (pm, "#2a78d6", "Metis", 1.3, 3)):
                if bench == "ycsb" and name == "Metis":   # per-period decision log of Metis
                    x, y = series(path, r"\[MetisV2\] t=([\d.]+) active=(\d+)")
                else:
                    x, y = series(path, PAT)
                x = [t / per for t in x]
                ax.step(x, y, where="post", color=col, lw=lw, label=name, zorder=z)
            NP = 150; ax.set_xlim(0, NP); ax.set_ylim(0, 100); ax.set_yticks([0, 48, 96]); ax.set_xticks([0, NP])
            ax.set_title(f"{lab}{s}", fontsize=6.5, pad=2)
        axes[r][0].set_ylabel(("TPC-C" if bench == "tpcc" else "YCSB") + "\nActive threads")
    for ax_ in (axes[0][2], axes[1][2]): ax_.set_xlabel("Control periods", labelpad=1, x=1.1)
    h, l = axes[0][0].get_legend_handles_labels()
    order = [l.index(k) for k in ("Metis", "Hill climbing", "Best", "Within 98% of best")]
    fig.legend([h[i] for i in order], [l[i] for i in order], loc="upper center", ncol=4, frameon=False,
               fontsize=7, bbox_to_anchor=(0.5, 1.05))
    fig.tight_layout(w_pad=0.3, h_pad=0.6)
    fig.savefig(OUT, bbox_inches="tight"); fig.savefig(OUT.with_suffix(".png"), dpi=200, bbox_inches="tight")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "1")
