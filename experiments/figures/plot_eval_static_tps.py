#!/usr/bin/env python3
"""Evaluation: throughput per control period of Metis and hill climbing in the same runs as
plot_eval_static_time.py.  Output: OUT/eval_static_tps.pdf"""
import re
import sys
from pathlib import Path
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import figcommon as P
from plot_eval_static_time import paths
from figcommon import curves

OUT = P.OUT / "eval_static_tps.pdf"
NP = 150
MET = re.compile(r"\[MetisV2\] t=([\d.]+) active=\d+ tps=([\d.]+)")
# Hill-climbing decision lines. The logs recorded for the paper (data/) carry
# the controller's earlier tag "[AdaTAM]"; current builds write "[HillClimbing]".
ADA = re.compile(r"\[(?:HillClimbing|AdaTAM)\] active_threads=\d+ committed_txs=\d+ tput=([\d.]+)")


def metis_series(path, per):
    pts = {}
    for t, v in MET.findall(path.read_text()):
        pts[float(t)] = float(v)
    ts = sorted(pts)
    t0 = ts[0]
    return [t - t0 + per for t in ts], [pts[t] for t in ts]


def hc_series(path, per):
    ys = [float(v) for v in ADA.findall(path.read_text())]
    return [(k + 1) * per for k in range(len(ys))], ys


def main(run="1"):
    plt.rcParams.update({"font.size": 6.5, "axes.spines.top": False, "axes.spines.right": False})
    rows = [("tpcc", ["1", "2", "4", "8", "16"], 0.2, 1e3, "k", "$W$="),
            ("ycsb", ["0.8", "0.9", "0.95", "0.99", "0.999"], 0.01, 1e6, "M", "skew=")]
    fig, axes = plt.subplots(2, 5, figsize=(7.0, 2.5))
    for r, (bench, S, per, unit, ul, lab) in enumerate(rows):
        cur = curves(bench)
        for c, s in enumerate(S):
            ax = axes[r][c]
            top = max(cur[s].values()) / unit
            ax.axhline(top, color="#eb6834", ls="--", lw=0.8, label="Best fixed", zorder=4)
            pm, ph = paths(bench, s, run)
            for (x, y), col, name, lw, z in ((hc_series(ph, per), "#1baf7a", "Hill climbing", 0.6, 2),
                                             (metis_series(pm, per), "#2a78d6", "Metis", 0.9, 3)):
                ax.plot(x, [v / unit for v in y], color=col, lw=lw, label=name, zorder=z)
            T = NP * per
            ax.set_xlim(0, T); ax.set_xticks([0, T / 2, T])
            ax.set_xticklabels([f"{v:g}" for v in (0, T / 2, T)])
            ax.set_ylim(0, top * 1.35)
            ax.set_title(f"{lab}{s}", fontsize=6.5, pad=2)
        axes[r][0].set_ylabel(("TPC-C" if bench == "tpcc" else "YCSB") + f"\nThroughput\n({ul} txn/s)")
    for ax_ in (axes[0][2], axes[1][2]): ax_.set_xlabel("Time (s)", labelpad=1)
    h, l = axes[0][0].get_legend_handles_labels()
    order = [l.index(k) for k in ("Metis", "Hill climbing", "Best fixed")]
    fig.legend([h[i] for i in order], [l[i] for i in order], loc="upper center", ncol=3, frameon=False,
               fontsize=7, bbox_to_anchor=(0.5, 1.05))
    fig.tight_layout(w_pad=0.3, h_pad=0.6)
    fig.savefig(OUT, bbox_inches="tight"); fig.savefig(OUT.with_suffix(".png"), dpi=200, bbox_inches="tight")
    print(OUT)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "1")
