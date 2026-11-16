#!/usr/bin/env python3
"""Background: YCSB throughput of Silo with a fixed backoff duration.
Data: ycsb/<DIR>/results.csv (paper: DIR = backoff_constant, skews 0,0.7,0.95).
  plot_backoff_sensitivity.py OUT.pdf [DIR] [SKEWS]"""
import csv, statistics, sys
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, FixedLocator
import figcommon as P

SRC = P.DATA / "ycsb" / (sys.argv[2] if len(sys.argv) > 2 else "backoff_constant") / "results.csv"
SKEWS = (sys.argv[3] if len(sys.argv) > 3 else "0.6,0.7,0.99").split(",")
PAL = [("#1f77b4", "o"), ("#2ca02c", "s"), ("#9467bd", "D"), ("#d62728", "^")]
STYLE = {s: PAL[i] for i, s in enumerate(SKEWS)}
plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                     "font.size": 8, "pdf.fonttype": 42})
data = defaultdict(list)
with SRC.open() as f:
    for r in csv.DictReader(f):
        data[(r["skew"], float(r["backoff_us"]))].append(float(r["tps"]))
fig, ax = plt.subplots(figsize=(3.4, 2.1))
for skew, (c, m) in STYLE.items():
    xs = sorted(b for s, b in data if s == skew)
    ys = [statistics.mean(data[(skew, b)]) for b in xs]
    lo = [y - min(data[(skew, b)]) for y, b in zip(ys, xs)]
    hi = [max(data[(skew, b)]) - y for y, b in zip(ys, xs)]
    ax.errorbar(xs, ys, yerr=[lo, hi], color=c, marker=m, ms=3.5, lw=1.3, capsize=1.5,
                label=f"skew = {skew}")
    best = max(range(len(xs)), key=lambda i: ys[i])
    ax.plot(xs[best], ys[best], marker=m, ms=8, mfc="none", mec=c, mew=1.2)
    print(f"skew {skew}: best backoff = {xs[best]:g} us, tps = {ys[best]:,.0f}; "
          + ", ".join(f"{x:g}:{y/1e6:.2f}M" for x, y in zip(xs, ys)))
ax.set_xscale("symlog", linthresh=1, linscale=0.5)
ticks = [0, 1, 10, 100, 1000]
ax.xaxis.set_major_locator(FixedLocator(ticks))
ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
ax.set_xlabel(r"Backoff duration ($\mu$s, log scale)")
ax.set_ylabel("Throughput\n(txn/s, log scale)")
ax.set_yscale("log"); ax.set_ylim(top=2.6e7)
ax.yaxis.set_major_locator(FixedLocator([0.5e6, 1e6, 2e6, 5e6, 1e7]))
ax.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v/1e6:g}M"))
ax.grid(axis="y", color="#e4e3df", lw=0.6); ax.set_axisbelow(True)
for s in ("top", "right"): ax.spines[s].set_visible(False)
ax.legend(frameon=False, ncol=3, loc="upper center", bbox_to_anchor=(0.5, 1.38), handlelength=1.8)
fig.tight_layout()
fig.savefig(sys.argv[1], bbox_inches="tight", pad_inches=0.02)
print(sys.argv[1])
