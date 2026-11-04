#!/usr/bin/env python3
"""Plots for Metis v2 fixed-load leave-one-out evaluation.

  plot_fixed.py --bench tpcc --variant A

Figure 1 (threads_over_time.png): active threads vs time per state, both runs,
with the oracle's 98% band and best N.
Figure 2 (tps_vs_oracle.png): TPS per state for Metis v2 (mean of runs, range as
error bars) and the fixed-N oracle (best measured fixed N).
"""
import argparse
import os
import csv
import json
import re
import statistics
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

ROOT = Path(__file__).resolve().parents[3]
# METIS_V2_ROOT points the plots at an alternative results tree (e.g. versions/P).
HERE = Path(os.environ.get("METIS_V2_ROOT", str(Path(__file__).resolve().parent)))
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
METIS, ORACLE = "#2a78d6", "#eb6834"  # categorical slots 1 and 2
BAND = "#f6d8cb"


def tpcc_oracle():
    data = json.loads((ROOT / "experiments/ICDE/tpcc/metis_test/logs/fixed/"
                       "standard_oracle_8states_20261103/oracle_summary.json").read_text())
    return {s: (v["best"], v["tps"], v["near98"]) for s, v in data.items()}


def ycsb_oracle():
    acc = defaultdict(lambda: defaultdict(list))
    path = ROOT / "experiments/ICDE/ycsb/oracle_physical_first_20261103/results.csv"
    with path.open() as f:
        for r in csv.DictReader(f):
            acc[r["skew"]][int(r["threads"])].append(float(r["throughput_tps"]))
    out = {}
    for s, ns in acc.items():
        m = {n: statistics.mean(v) for n, v in ns.items()}
        best = max(m, key=m.get)
        out[s] = (best, m[best], [n for n in sorted(m) if m[n] >= 0.98 * m[best]])
    return out


def trace(path):
    # Prefer benchmark-clock samples (same time base as the dynamic figures).
    body = path.read_text()
    tam = re.findall(r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)", body)
    if tam:
        return [0.0] + [float(a) for a, _ in tam], [96] + [int(n) for _, n in tam]
    ts, ns = [0.0], [96]
    for line in body.splitlines():
        m = re.match(r"\[MetisV2\] t=([\d.]+) active=(\d+)", line)
        if m:
            ts.append(float(m[1]))
            ns.append(int(m[2]))
    return ts, ns


def style(ax):
    ax.set_facecolor(SURFACE)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bench", default="tpcc")
    p.add_argument("--variant", default="A")
    p.add_argument("--source", choices=["loo", "compare"], default="loo",
                   help="loo: run.py fixed eval; compare: compare.py (final) metis_v2 runs")
    p.add_argument("--exclude-states", default="", help="comma-separated states to omit")
    args = p.parse_args()
    excluded = set(filter(None, args.exclude_states.split(",")))
    d = HERE / args.bench / args.variant
    if args.source == "compare":
        d = HERE / args.bench / "compare_fixed"
    oracle = tpcc_oracle() if args.bench == "tpcc" else ycsb_oracle()
    label = "W" if args.bench == "tpcc" else "skew"
    rows = defaultdict(list)
    if args.source == "compare":
        with (d / "results.csv").open() as f:
            for r in csv.DictReader(f):
                if r["method"] == "metis_v2" and r["tps"]:
                    rows[r["state"]].append(float(r["tps"]))
    else:
        with (d / "fixed.csv").open() as f:
            for r in csv.DictReader(f):
                rows[r["state"]].append(float(r["tps"]))
    states = sorted((s for s in rows if s not in excluded), key=float)

    # Figure 1: threads over time.
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
        for run, ls in ((1, "-"), (2, ":")):
            t = (d / "logs" / f"metis_v2_{s}_run{run}.trace.log" if args.source == "compare"
                 else d / "fixed" / f"state_{s}_run{run}.trace.log")
            if t.exists():
                x, y = trace(t)
                ax.step(x, y, where="post", color=METIS, linewidth=1.6, linestyle=ls,
                        label=f"Metis, run {run}")
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
    fig.legend(handles, labels, loc="lower center", ncol=4, frameon=False, fontsize=9)
    fig.suptitle(f"{args.bench.upper()} fixed load, held-out state: active threads chosen by "
                 "Metis", fontsize=12, color=INK, x=0.01, ha="left")
    fig.tight_layout(rect=(0, 0.06, 1, 1))
    suffix = "_final" if args.source == "compare" else ""
    out1 = d / f"threads_over_time{suffix}.png"
    fig.savefig(out1, dpi=150, facecolor=SURFACE)
    plt.close(fig)

    # Figure 2: TPS per state.
    fig, ax = plt.subplots(figsize=(8.5, 4.6), facecolor=SURFACE)
    style(ax)
    xs = list(range(len(states)))
    mean = [statistics.mean(rows[s]) for s in states]
    lo = [m - min(rows[s]) for m, s in zip(mean, states)]
    hi = [max(rows[s]) - m for m, s in zip(mean, states)]
    orc = [oracle[s][1] for s in states]
    ax.plot(xs, orc, color=ORACLE, linewidth=2, marker="s", markersize=7,
            markeredgecolor=SURFACE, label="Oracle (best fixed N)", zorder=3)
    ax.errorbar(xs, mean, yerr=[lo, hi], color=METIS, linewidth=2, marker="o",
                markersize=7, markeredgecolor=SURFACE, capsize=3,
                label="Metis (held-out, mean of runs)", zorder=4)
    for x, m, o in zip(xs, mean, orc):
        ax.annotate(f"{m / o:.2f}", (x, max(m, o)), xytext=(0, 8), textcoords="offset points",
                    ha="center", fontsize=8, color=INK2)
    ax.set_xticks(xs)
    ax.set_xticklabels([f"{label}={s}" for s in states])
    ax.set_yscale("log")
    ticks = [t for t in (2e4, 5e4, 1e5, 2e5, 5e5, 1e6, 2e6, 5e6, 1e7)
             if min(mean + orc) / 1.5 <= t <= max(mean + orc) * 1.5]
    ax.set_yticks(ticks)
    ax.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
    ax.yaxis.set_major_formatter(FuncFormatter(
        lambda v, _: f"{v / 1e6:.1f}M" if v >= 1e6 else f"{v / 1e3:.0f}k"))
    ax.set_ylabel("Throughput (committed TPS, log scale)", color=INK2)
    ax.set_title(f"{args.bench.upper()} fixed load: Metis vs oracle "
                 "(label = Metis / oracle)", fontsize=11, color=INK, loc="left")
    ax.legend(frameon=False, fontsize=9, loc="upper left")
    fig.tight_layout()
    out2 = d / f"tps_vs_oracle{suffix}.png"
    fig.savefig(out2, dpi=150, facecolor=SURFACE)
    print(out1)
    print(out2)


if __name__ == "__main__":
    main()
