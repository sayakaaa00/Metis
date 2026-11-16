#!/usr/bin/env python3
"""Introduction: YCSB throughput of Silo vs. active thread count at skew 0 and 0.9.
Data: ycsb/oracle/skew_0_0.5_0.9.  plot_tps_vs_threads_lowhigh.py [OUTDIR]
Writes OUTDIR/tps_vs_threads_skew{0,0.9}.pdf and tps_vs_threads_lowhigh.pdf."""
import csv, sys
from collections import defaultdict
from pathlib import Path
import matplotlib
import figcommon as P
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SRC = P.YCSB_ORACLE_LOW
out = Path(sys.argv[1]) if len(sys.argv) > 1 else P.OUT
plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                     "font.size": 8, "pdf.fonttype": 42})
d = defaultdict(list)
for r in csv.DictReader(SRC.open()):
    d[(r["skew"], int(r["threads"]))].append(float(r["throughput_tps"]))
for skew, label in [("0", "low contention (skew 0)"), ("0.9", "high contention (skew 0.9)")]:
    ns = sorted(n for s, n in d if s == skew)
    ys = [sum(d[(skew, n)]) / len(d[(skew, n)]) / 1e6 for n in ns]
    fig, ax = plt.subplots(figsize=(3.4, 1.7))
    ax.plot(ns, ys, color="#1f77b4", marker="v", ms=3, lw=1.2, label="Silo")
    ax.set_xlabel("Active thread count")
    ax.set_ylabel("Throughput (M txn/s)")
    ax.set_xlim(0, 100); ax.set_xticks([8, 16, 24, 32, 48, 64, 80, 96])
    ax.set_ylim(bottom=0)
    ax.set_title(f"YCSB, {label}", fontsize=8)
    ax.grid(alpha=0.3, lw=0.5)
    fig.tight_layout()
    fig.savefig(out / f"tps_vs_threads_skew{skew}.pdf")
    fig.savefig(out / f"tps_vs_threads_skew{skew}.png", dpi=200)
    print(skew, f"peak {max(ys):.2f}M at {ns[ys.index(max(ys))]}, at 96: {ys[-1]:.2f}M")

# Combined two-panel version for the paper (Introduction).
fig, axes = plt.subplots(1, 2, figsize=(3.4, 1.45))
for ax, skew, title in [(axes[0], "0", "(a) Skew 0"),
                        (axes[1], "0.9", "(b) Skew 0.9")]:
    ns = sorted(n for s, n in d if s == skew)
    ys = [sum(d[(skew, n)]) / len(d[(skew, n)]) / 1e6 for n in ns]
    ax.plot(ns, ys, color="#1f77b4", marker="v", ms=2.2, lw=1.0)
    ax.set_xlim(0, 100); ax.set_xticks([0, 24, 48, 72, 96]); ax.set_ylim(bottom=0)
    ax.set_xlabel("Active thread count")
    ax.set_title(title, fontsize=7)
    ax.grid(alpha=0.3, lw=0.5)
axes[0].set_ylabel("Throughput\n(M txn/s)")
fig.tight_layout(pad=0.3, w_pad=0.8)
fig.savefig(out / "tps_vs_threads_lowhigh.pdf")
fig.savefig(out / "tps_vs_threads_lowhigh.png", dpi=200)
