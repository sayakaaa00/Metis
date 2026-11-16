#!/usr/bin/env python3
"""Evaluation: throughput per contention level on static workloads (TPC-C W, YCSB skew).
Metis: tpcc/fixed/results_metis.csv (min8 leave-one-out models), ycsb/fixed/results_metis.csv
(min6 leave-one-out models over 9 skews). Baselines: <bench>/fixed/results.csv; ERMIA on TPC-C:
tpcc/fixed/ermia_3s. Best fixed backoff: <bench>/backoff_constant.  Output: OUT/eval_static.pdf"""
import csv, statistics as st
from collections import defaultdict
from pathlib import Path
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import figcommon as P

D_ = P.DATA
OUT = P.OUT / "eval_static.pdf"
SER = [("oracle", "Oracle", "#eb6834", "*", "-"), ("metis", "Metis", "#2a78d6", "o", "-"),
       ("hill_climbing", "Hill climbing", "#1baf7a", "s", "-"),
       ("bfb", "Silo (best fixed backoff)", "#8c6d00", "D", "-"),
       ("silo_cbo_tuned", "Silo (adaptive backoff)", "#eda100", "^", "-"),
       ("silo_nobo", "Silo", "#e87ba4", "v", "-"),
       ("cicada", "Cicada", "#008300", "^", "-"), ("ermia", "ERMIA", "#6250d6", "P", "-")]


def mean_by(path, key, val="tps", filt=lambda r: True):
    d = defaultdict(list)
    for r in csv.DictReader(open(path)):
        if r[val] and filt(r):
            d[key(r)].append(float(r[val]))
    return {k: st.mean(v) for k, v in d.items()}


def data(bench):
    S = (["1", "2", "3", "4", "8", "16", "32", "96"] if bench == "tpcc" else
         ["0", "0.5", "0.7", "0.8", "0.85", "0.9", "0.95", "0.99", "0.999"])
    D = defaultdict(dict)
    base = mean_by(D_ / bench / "fixed/results.csv", lambda r: (r["method"], r["state"]))
    for m in ("hill_climbing", "silo_cbo_tuned", "silo_nobo", "cicada", "ermia"):
        if bench == "tpcc" and m == "ermia":   # TPC-C ERMIA: tpcc/fixed/ermia_3s (below)
            continue
        for s in S:
            D[m][s] = base[(m, s)]
    if bench == "tpcc":
        o = P.tpcc_oracle(); D["oracle"] = {s: o[s][1] for s in S}
        mt = mean_by(D_ / "tpcc/fixed/results_metis.csv", lambda r: r["state"])
        bo = mean_by(D_ / "tpcc/backoff_constant/results.csv", lambda r: (r["state"], r["backoff_us"]))
    else:
        o = P.ycsb_oracle()
        low = mean_by(P.YCSB_ORACLE_LOW,
                      lambda r: (r["skew"], r["threads"]), val="throughput_tps")
        D["oracle"] = {s: (o[s][1] if s in o else max(v for k, v in low.items() if k[0] == s)) for s in S}
        mt = mean_by(D_ / "ycsb/fixed/results_metis.csv", lambda r: r["state"])
        bo = mean_by(D_ / "ycsb/backoff_constant/results.csv", lambda r: (r["skew"], r["backoff_us"]))
    if bench == "tpcc":   # ERMIA on TPC-C: 3-s runs (tpcc/fixed/ermia_3s)
        er = mean_by(D_ / "tpcc/fixed/ermia_3s/results.csv", lambda r: r["W"])
        D["ermia"] = {s: er[s] for s in S}
    D["metis"] = {s: mt[s] for s in S}
    D["bfb"] = {s: max(v for k, v in bo.items() if k[0] == s) for s in S}
    return S, D


def main():
    plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                         "font.size": 8, "pdf.fonttype": 42, "axes.spines.top": False, "axes.spines.right": False})
    fig, axes = plt.subplots(2, 1, figsize=(3.4, 3.6))
    for ax, bench, xl in zip(axes, ("tpcc", "ycsb"),
                             ("Number of accessed warehouses $W$ (TPC-C)", "Access skew (YCSB)")):
        S, D = data(bench)
        x = range(len(S))
        for k, lab, c, mk, ls in SER:
            if k in ("hill_climbing", "silo_cbo_tuned", "bfb", "oracle"):
                continue
            if k == "metis":   # emphasize Metis: thicker line, larger markers, drawn on top
                ax.plot(x, [D[k][s] / 1e6 for s in S], color=c, marker=mk, ls=ls, lw=1.2, ms=3.8,
                        mec="white", mew=0.5, label=lab, zorder=6)
            else:
                ax.plot(x, [D[k][s] / 1e6 for s in S], color=c, marker=mk, ls=ls, lw=1.0,
                        ms=3.0, alpha=0.85, label=lab, zorder=2)
        ax.set_yscale("log"); ax.set_xticks(list(x)); ax.set_xticklabels(S)
        ax.set_xlabel(xl); ax.grid(axis="y", color="#e4e3df", lw=0.6); ax.set_axisbelow(True)
    for a_ in axes: a_.set_ylabel("Throughput (M txn/s)")
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper center", ncol=len(l), frameon=False, fontsize=6,
               bbox_to_anchor=(0.53, 1.03), handlelength=1.6, columnspacing=0.7, handletextpad=0.4)
    fig.tight_layout(rect=(0, 0, 1, 0.95))
    fig.savefig(OUT, bbox_inches="tight"); fig.savefig(OUT.with_suffix(".png"), dpi=200, bbox_inches="tight")


if __name__ == "__main__":
    main()
