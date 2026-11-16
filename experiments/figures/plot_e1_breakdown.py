#!/usr/bin/env python3
"""Introduction: worker time on committed / aborted transactions and abort rate vs. YCSB skew
(Silo, 96 worker threads, instrumented binary ycsb_silo_breakdown).
Data: ycsb/breakdown/results.csv.  plot_e1_breakdown.py OUT.pdf"""
import csv, statistics, sys
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, FixedLocator
import figcommon as P
plt.rcParams.update({"font.family": "serif", "font.serif": ["Times", "Nimbus Roman", "DejaVu Serif"],
                     "font.size": 8, "pdf.fonttype": 42})
rows = [r for r in csv.DictReader((P.DATA / "ycsb" / "breakdown" / "results.csv").open())
        if r["binary"] == "breakdown"]
g = defaultdict(list)
for r in rows: g[r["skew"]].append(r)
skews = sorted(g, key=float)
share = {k: [] for k in ("committed", "aborted", "waiting", "other")}
tps, abort = [], []
for s in skews:
    f = lambda k: sum(float(r[k]) for r in g[s])
    span = f("span_cycles"); c = f("committed_cycles"); a = f("aborted_cycles")
    w = f("wait_committed_cycles") + f("wait_aborted_cycles")
    share["committed"].append((c - f("wait_committed_cycles")) / span)
    share["aborted"].append((a - f("wait_aborted_cycles")) / span)
    share["waiting"].append(w / span)
    share["other"].append(1 - (c + a) / span)
    tps.append(statistics.mean(float(r["tps"]) for r in g[s]))
    abort.append(statistics.mean(float(r["abort_rate"]) for r in g[s]))
    print(f"skew {s}: " + " ".join(f"{k}={share[k][-1]:.3f}" for k in share) + f" tps={tps[-1]:,.0f} abort={abort[-1]:.3f}")
fig, ax = plt.subplots(figsize=(3.4, 2.0))
xs = range(len(skews)); bottom = [0.0] * len(skews)
COL = {"committed": ("#2ca02c", "Committed work"), "aborted": ("#d62728", "Aborted work"),
       "waiting": ("#ff9f1c", "Waiting"), "other": ("#c8c8c8", "Other")}
for k, (c, lab) in COL.items():
    ax.bar(xs, [v * 100 for v in share[k]], bottom=[b * 100 for b in bottom], color=c, width=0.65, label=lab)
    bottom = [b + v for b, v in zip(bottom, share[k])]
for x, a in zip(xs, abort):
    ax.text(x, 101.5, f"{a*100:.0f}%", ha="center", va="bottom", fontsize=5.8, color="#444444")
ax.set_xticks(list(xs)); ax.set_xticklabels(skews, fontsize=7); ax.set_xlabel("YCSB (access skew)")
ax.set_ylabel("Worker-thread time (%)"); ax.set_ylim(0, 112); ax.set_yticks([0, 25, 50, 75, 100])
for sp in ("top",): ax.spines[sp].set_visible(False)
bx = ax.twinx()
bx.plot(list(xs), tps, color="black", marker="o", ms=3, lw=1.2, label="Throughput")
bx.set_yscale("log"); bx.set_ylim(2e5, 4e7)
bx.yaxis.set_major_locator(FixedLocator([5e5, 1e6, 5e6, 1e7]))
bx.yaxis.set_minor_formatter(FuncFormatter(lambda v, _: ""))
bx.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v/1e6:g}M"))
bx.set_ylabel("Throughput (txn/s, log)")
for sp in ("top",): bx.spines[sp].set_visible(False)
h1, l1 = ax.get_legend_handles_labels(); h2, l2 = bx.get_legend_handles_labels()
fig.legend(h1 + h2, l1 + l2, loc="upper center", ncol=5, frameon=False, fontsize=6.3,
           bbox_to_anchor=(0.5, 1.02), handlelength=1.2, columnspacing=0.7, handletextpad=0.3)
fig.tight_layout(rect=(0, 0, 1, 0.9))
fig.savefig(sys.argv[1], bbox_inches="tight", pad_inches=0.02)
print(sys.argv[1])
