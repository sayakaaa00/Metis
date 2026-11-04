#!/usr/bin/env python3
"""Compare Metis versions P (no physical-core anchor) and RA (3-interval recheck
+ anchor) with tuned adaTAM: TPS/oracle per state (fixed) and per schedule
(dynamic), plus the curve position of the committed N in TPC-C fixed runs.
Writes versions/compare_P_RA.png."""
import csv, json, re, statistics
from collections import defaultdict
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import plot_fixed as P
import convergence as CV
import dynamic as D

BASE = Path(__file__).resolve().parent / "versions"
SER = [("P", "Metis version P", "#86b6ef"), ("RA", "Metis version RA", "#1c5cab"),
       ("ada", "adaTAM (tuned)", "#1baf7a")]
ORC = {"tpcc": P.tpcc_oracle(), "ycsb": P.ycsb_oracle()}
CURVE = json.loads((P.ROOT / "experiments/ICDE/tpcc/metis_test/logs/fixed/"
                    "standard_oracle_8states_20261103/oracle_summary.json").read_text())


def load(ver, bench, kind, method):
    d = defaultdict(list)
    with (BASE / ver / bench / kind / "results.csv").open() as f:
        for r in csv.DictReader(f):
            if r["method"] == method and r["tps"]:
                d[r["state"] if kind == "compare_fixed" else r["schedule"]].append(float(r["tps"]))
    return {k: statistics.mean(v) for k, v in d.items()}


def curve_q(w, n):
    c = {int(k): v for k, v in CURVE[w]["curve"].items()}
    ks = sorted(c)
    if n in c:
        return c[n] / CURVE[w]["tps"]
    lo = max(k for k in ks if k < n); hi = min(k for k in ks if k > n)
    return (c[lo] + (c[hi] - c[lo]) * (n - lo) / (hi - lo)) / CURVE[w]["tps"]


def committed_q(ver, w):
    out = []
    for run in "12":
        t = (BASE / ver / "tpcc/compare_fixed/logs" / f"metis_v2_{w}_run{run}.trace.log").read_text()
        xs = [int(n) for s, n in re.findall(r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)", t)
              if float(s) > 10]
        out.append(curve_q(w, max(set(xs), key=xs.count)))
    return out


def bars(ax, labels, series, title, ylim):
    P.style(ax)
    n = len(series)
    width = 0.8 / n
    for i, (name, color, vals) in enumerate(series):
        xs = [j + (i - (n - 1) / 2) * width for j in range(len(labels))]
        ax.bar(xs, vals, width=width * 0.92, color=color, label=name, zorder=3)
    ax.axhline(1.0, color=P.ORACLE, linestyle="--", linewidth=1.2, zorder=4)
    ax.set_xticks(range(len(labels)))
    ax.set_xticklabels(labels, fontsize=8)
    ax.set_ylim(*ylim)
    ax.set_title(title, fontsize=10, color=P.INK, loc="left")


def main():
    fig, axes = plt.subplots(2, 2, figsize=(13, 8), facecolor=P.SURFACE)
    # TPC-C fixed
    st = ["1", "2", "3", "4", "8", "16", "32", "96"]
    ser = []
    for key, name, color in SER:
        vals = load("RA" if key == "ada" else key, "tpcc", "compare_fixed",
                    "adatam" if key == "ada" else "metis_v2")
        ser.append((name, color, [vals[s] / ORC["tpcc"][s][1] for s in st]))
    bars(axes[0][0], [f"W={s}" for s in st], ser, "TPC-C fixed load: TPS / oracle", (0.8, 1.06))
    axes[0][0].set_ylabel("TPS / oracle", color=P.INK2)
    # YCSB fixed
    sy = ["0.7", "0.8", "0.85", "0.9", "0.95", "0.99", "0.999"]
    ser = []
    for key, name, color in SER:
        vals = load("RA" if key == "ada" else key, "ycsb", "compare_fixed",
                    "adatam" if key == "ada" else "metis_v2")
        ser.append((name, color, [vals[s] / ORC["ycsb"][s][1] for s in sy]))
    bars(axes[0][1], [f"skew={s}" for s in sy], ser, "YCSB fixed load: TPS / oracle", (0.8, 1.06))
    # Dynamic
    sch = [("tpcc", "D1"), ("tpcc", "D2"), ("tpcc", "D3"), ("ycsb", "Y1"), ("ycsb", "Y2")]
    ser = []
    for key, name, color in SER:
        vals = []
        for b, s in sch:
            table = D.TPCC_SCHEDULES if b == "tpcc" else D.YCSB_SCHEDULES
            ph = CV.phases(b, table[s])
            o = sum(ORC[b][x][1] * ((ph[i + 1][0] if i + 1 < len(ph) else 60) - t)
                    for i, (t, x) in enumerate(ph)) / 60
            v = load("RA" if key == "ada" else key, b, "dynamic",
                     "adatam" if key == "ada" else "metis_v2")
            vals.append(v[s] / o)
        ser.append((name, color, vals))
    bars(axes[1][0], [s for _, s in sch], ser, "Dynamic load: TPS / oracle (60 s x 2 runs)", (0.8, 1.06))
    axes[1][0].set_ylabel("TPS / oracle", color=P.INK2)
    # Committed-N quality (TPC-C fixed): worse of the two runs
    sq = ["1", "2", "3", "4", "8", "16", "32"]
    ser = [(name, color, [min(committed_q(key, s)) for s in sq])
           for key, name, color in SER if key != "ada"]
    bars(axes[1][1], [f"W={s}" for s in sq], ser,
         "TPC-C: oracle-curve TPS at the committed N (worse of 2 runs)", (0.8, 1.06))
    handles, labels = axes[0][0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=3, frameon=False, fontsize=9)
    fig.suptitle("Metis version P (no anchor) vs version RA (3-interval recheck + physical-core anchor)",
                 fontsize=12, color=P.INK, x=0.01, ha="left")
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(BASE / "compare_P_RA.png", dpi=140, facecolor=P.SURFACE)
    print(BASE / "compare_P_RA.png")


if __name__ == "__main__":
    main()
