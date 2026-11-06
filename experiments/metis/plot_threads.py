#!/usr/bin/env python3
"""Fixed load, held-out states: active threads chosen by Metis over time.

  plot_threads.py --bench tpcc|ycsb [--exclude-states 96] [--with-adatam]
                  [--pick-runs] [--out NAME.png]

One panel per state with the oracle's best N and its 98% band. By default both
runs of Metis are drawn; --pick-runs draws one run per method (Metis: settled N
closest to the best on the oracle curve; adaTAM: lower-TPS run).
Reads <bench>/compare_fixed/; writes <bench>/compare_fixed/NAME.png.
"""
import argparse
import csv
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

import common as C
from plot_common import ADATAM, BAND, INK, INK2, METIS, ORACLE, SURFACE, pick_runs, style, trace

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", default="tpcc")
    p.add_argument("--exclude-states", default="", help="comma-separated states to omit")
    p.add_argument("--with-adatam", action="store_true",
                   help="overlay adaTAM (tuned) traces")
    p.add_argument("--out", default="threads_over_time.png")
    p.add_argument("--pick-runs", action="store_true",
                   help="one run per method (Metis: settled N closest to best; "
                        "adaTAM: lower-TPS run)")
    args = p.parse_args()
    excluded = set(filter(None, args.exclude_states.split(",")))
    d = C.HERE / args.bench / "compare_fixed"
    picked = pick_runs(d, args.bench) if args.pick_runs else {}
    if picked:
        print("picked runs:", {f"{m}:{s}": r for (m, s), r in sorted(picked.items())})

    def runs_for(method, s):
        if picked:
            return ((picked[(method, s)], "-"),)
        return ((1, "-"), (2, ":"))

    def run_label(name, run):
        if not picked:
            return f"{name}, run {run}"
        return ("Metis (run with N closest to best)" if name == "Metis"
                else "adaTAM (lower-TPS run)")
    oracle = C.oracle(args.bench)
    label = "W" if args.bench == "tpcc" else "skew"
    rows = defaultdict(list)
    with (d / "results.csv").open() as f:
        for r in csv.DictReader(f):
            if r["method"] == "metis" and r["tps"]:
                rows[r["state"]].append(float(r["tps"]))
    states = sorted((s for s in rows if s not in excluded), key=float)

    cols = 4 if len(states) > 6 else 3
    nrows = (len(states) + cols - 1) // cols
    fig, axes = plt.subplots(nrows, cols, figsize=(13, 3.0 * nrows), sharex=True,
                             sharey=True, facecolor=SURFACE)
    axes = axes.ravel()
    for ax, s in zip(axes, states):
        style(ax)
        best, _, near = oracle[s]
        ax.axhspan(min(near), max(near), color=BAND, zorder=0,
                   label="oracle: within 98% of best")
        ax.axhline(best, color=ORACLE, linewidth=1.2, linestyle="--", label="oracle best N")
        if args.with_adatam:
            for run, ls in runs_for("adatam", s):
                t = d / "logs" / f"adatam_{s}_run{run}.trace.log"
                if t.exists():
                    x, y = trace(t)
                    ax.step(x, y, where="post", color=ADATAM, linewidth=1.2, linestyle=ls,
                            alpha=0.9, label=run_label("adaTAM", run), zorder=2)
        for run, ls in runs_for("metis", s):
            t = d / "logs" / f"metis_{s}_run{run}.trace.log"
            if t.exists():
                x, y = trace(t)
                ax.step(x, y, where="post", color=METIS, linewidth=1.6, linestyle=ls,
                        label=run_label("Metis", run), zorder=3)
        ax.set_title(f"{label} = {s}", fontsize=10, color=INK, loc="left")
        ax.set_ylim(0, 100)
        ax.set_yticks([0, 24, 48, 72, 96])
    for ax in axes[len(states):]:
        ax.set_visible(False)
    for ax in axes[(nrows - 1) * cols:]:
        ax.set_xlabel("Time (s)", color=INK2)
    for i in range(nrows):
        axes[i * cols].set_ylabel("Active threads", color=INK2)
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center",
               ncol=4 if picked else (6 if args.with_adatam else 4),
               frameon=False, fontsize=9)
    who = "Metis and adaTAM" if args.with_adatam else "Metis"
    fig.suptitle(f"{args.bench.upper()} fixed load, held-out state: active threads chosen by "
                 f"{who}", fontsize=12, color=INK, x=0.01, ha="left")
    fig.tight_layout(rect=(0, 0.06, 1, 1))
    out = d / args.out
    fig.savefig(out, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    print(out)


if __name__ == "__main__":
    main()
