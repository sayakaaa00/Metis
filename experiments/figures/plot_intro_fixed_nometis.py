#!/usr/bin/env python3
"""Introduction: YCSB throughput of Silo, Cicada, and ERMIA (all worker threads) and of Silo
with the best active thread count, skew 0.7-0.999.
Data: ycsb/fixed/results.csv, ycsb/oracle.  plot_intro_fixed_nometis.py OUT.pdf"""
import csv, statistics, sys
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import figcommon as P

SERIES = [
          ("silo_nobo", "Silo", "#e87ba4", "v"),
          ("cicada", "Cicada", "#008300", "^"),
          ("ermia", "ERMIA", "#6250d6", "P")]
SHOW_BACKOFF = False
plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                     "font.size": 8, "pdf.fonttype": 42})
fig, ax0 = plt.subplots(1, 1, figsize=(3.4, 1.9))
axes = [ax0]
for ax, bench, title in [(ax0, "ycsb", "YCSB (access skew)")]:
    oracle = P.tpcc_oracle() if bench == "tpcc" else P.ycsb_oracle()
    data = defaultdict(list)
    with (P.DATA / bench / "fixed" / "results.csv").open() as f:
        for r in csv.DictReader(f):
            if r["tps"] and r["state"] in oracle:   # skew 0.7-0.999
                data[(r["method"], r["state"])].append(float(r["tps"]))
    states = sorted({s for _, s in data}, key=float)  # TPC-C W=96 included as the low-contention case
    xs = range(len(states))
    ax.plot(xs, [oracle[s][1] for s in states], color="#eb6834", lw=1.4, marker="*", ms=6,
            label="Silo (best thread count)", zorder=4)
    bo = defaultdict(lambda: defaultdict(list))
    for r in csv.DictReader((P.DATA / "ycsb" / "backoff_constant" / "results.csv").open()):
        bo[r["skew"]][float(r["backoff_us"])].append(float(r["tps"]))
    bfb = {s: max(statistics.mean(v) for v in bo[s].values()) for s in bo}
    # skew 0.85 has no fixed-backoff data yet (planned in E2): leave a gap instead of interpolating
    if SHOW_BACKOFF:  # removed from Fig. 1 on 2026-11-10 (user request)
        ax.plot(list(xs), [bfb.get(s, float("nan")) for s in states], color="#8c564b", marker="s", ms=3.5, lw=1.4,
                label="Silo (best backoff)", zorder=4)
    for key, name, color, m in SERIES:
        ys = [statistics.mean(data[(key, s)]) for s in states]
        ax.plot(xs, ys, color=color, marker=m, ms=4, lw=1.4, label=name, zorder=5 if key == "metis_v2" else 3)
    print("oracle/silo", {s: round(oracle[s][1]/statistics.mean(data[("silo_nobo", s)]),2) for s in states}, "best n", {s: oracle[s][0] for s in states})
    ax.set_xticks(list(xs)); ax.set_xticklabels(states); ax.set_xlabel(title)
    ax.set_ylim(0, 9.2e6); ax.set_yticks([0, 2e6, 4e6, 6e6, 8e6])
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: "0" if v == 0 else f"{v/1e6:g}M" if v >= 1e6 else f"{v/1e3:g}k"))
    ax.grid(axis="y", color="#e4e3df", lw=0.6); ax.set_axisbelow(True)
    for s in ("top", "right"): ax.spines[s].set_visible(False)
h, l = axes[0].get_legend_handles_labels()
ax0.legend(h, l, loc="upper center", bbox_to_anchor=(0.57, 1.02), ncol=2, frameon=False,
           fontsize=6.5, labelspacing=0.25, borderaxespad=0.1, handlelength=1.6, columnspacing=0.8, handletextpad=0.4)
ax0.set_ylabel("Throughput\n(txn/s)")
fig.tight_layout()
fig.savefig(sys.argv[1], bbox_inches="tight", pad_inches=0.02)
print(sys.argv[1])
