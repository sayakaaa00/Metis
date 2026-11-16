#!/usr/bin/env python3
"""Evaluation: throughput over time on the dynamic YCSB workload Y1 (skew 0.7 -> 0.95 -> 0.8).
Data: ycsb/dynamic/logs (run 1; Cicada run 2, as run 1 stops committing at 38 s).
  plot_eval_dynamic_tps.py [OUT.pdf]"""
import re, sys
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import figcommon as P

plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                     "font.size": 8, "pdf.fonttype": 42})
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else P.OUT / "eval_dynamic_tps.pdf"
D = P.DATA / "ycsb" / "dynamic"
# (label, color, log, line width, zorder) -- colors follow plot_eval_static.py
SRC = [("Metis", "#2a78d6", P.first(D / "logs" / "Y1_metis_v2_run1.trace.log", D / "logs" / "Y1_metis_run1.trace.log"), 1.4, 6),
       ("Silo (adaptive backoff)", "#eda100", D / "logs" / "Y1_silo_cbo_tuned_run1.log", 0.9, 3),
       ("Silo", "#e87ba4", D / "logs" / "Y1_silo_nobo_run1.log", 0.9, 2),
       # Cicada run 1 stalls (0 commits from 38 s to the end); run 2 is the first run without a stall.
       ("Cicada", "#008300", D / "logs" / "Y1_cicada_run2.log", 0.9, 2),
       ("ERMIA", "#6250d6", D / "logs" / "Y1_ermia_run1.log", 0.9, 2)]
PAT = re.compile(r"\[TPS sample\] bench_s=([\d.]+) interval_tps=([\d.]+)")
oracle = P.ycsb_oracle()
PH = [(0, 20, "0.7"), (20, 40, "0.95"), (40, 60, "0.8")]

fig, ax = plt.subplots(figsize=(3.5, 1.75))
for name, color, path, lw, z in SRC:
    if not path.exists():
        print("missing, skipped:", name, path, file=sys.stderr)
        continue
    xs, ys = [], []
    for line in path.read_text().splitlines():
        m = PAT.search(line)
        if m:
            xs.append(float(m[1])); ys.append(float(m[2]) / 1e6)
    ax.plot(xs, ys, color=color, lw=lw, label=name, zorder=z)
for i, (t0, t1, s) in enumerate(PH):
    ax.hlines(oracle[s][1] / 1e6, t0, t1, colors="#eb6834", linestyles="--", lw=1.0,
              label="Oracle" if i == 0 else None, zorder=7)
    if t0 > 0:
        ax.axvline(t0, color="#999999", lw=0.6, ls=":")
    ax.text((t0 + t1) / 2, 7.3, f"skew {s}", ha="center", va="bottom", fontsize=6.5, color="#555555")
ax.set_xlim(0, 60); ax.set_ylim(0, 8.0)
ax.set_ylabel("Throughput\n(M txn/s)")
ax.set_xlabel("Time (s)")
ax.grid(axis="y", color="#e4e3df", lw=0.6); ax.set_axisbelow(True)
for sp in ("top", "right"): ax.spines[sp].set_visible(False)
ax.legend(frameon=False, fontsize=6.3, ncol=3, loc="lower center", bbox_to_anchor=(0.5, 1.08),
          handlelength=1.6, columnspacing=0.9)
fig.tight_layout()
fig.savefig(OUT, bbox_inches="tight", pad_inches=0.02)
print(OUT)
