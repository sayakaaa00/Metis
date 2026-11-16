#!/usr/bin/env python3
"""Evaluation: throughput over time on the dynamic TPC-C workload D1 (W 16 -> 1 -> 4), and the
ratios quoted in the text. Data: tpcc/dynamic/logs (Metis run 2, the other methods run 1).
  plot_eval_dynamic_tps_tpcc.py [OUT.pdf]   (writes OUT_legend.pdf too)"""
import re, sys, statistics as st
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import figcommon as P

plt.rcParams.update({"font.family": "serif", "font.serif": ["DejaVu Serif"],
                     "font.size": 8, "xtick.labelsize": 7, "ytick.labelsize": 7,
                     "pdf.fonttype": 42})  # tick/period labels 7 pt, axis labels 8 pt, as in eval_dynamic_tps.pdf
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else P.OUT / "eval_dynamic_tps_tpcc.pdf"
D = P.DATA / "tpcc" / "dynamic"
# (label, color, log, line width, zorder) -- colors follow the YCSB figure
# Schedule and Metis run via env: TPCC_SCHED (default D1), METIS_RUN (default 1).
import os
SCHED = os.environ.get("TPCC_SCHED", "D1")
METIS_RUN = os.environ.get("METIS_RUN", "2")   # the paper figure uses Metis run 2
_mlog = next((p for p in (D / "logs" / f"{SCHED}_metis_v2_run{METIS_RUN}.trace.log",
                          D / "logs" / f"{SCHED}_metis_run{METIS_RUN}.trace.log")
              if p.exists()), None)
SRC = [("Metis", "#2a78d6", _mlog or Path("/nonexistent"), 1.6, 6),
       ("Silo-BO", "#eda100", D / "logs" / f"{SCHED}_silo_cbo_tuned_run1.log", 0.9, 3),
       ("Silo", "#e87ba4", D / "logs" / f"{SCHED}_silo_nobo_run1.log", 0.9, 2),
       ("Cicada", "#008300", D / "logs" / f"{SCHED}_cicada_run1.log", 0.9, 2),
       ("ERMIA", "#6250d6", D / "logs" / f"{SCHED}_ermia_run1.log", 0.9, 2)]
# Silo/Metis log "[TPS sample]"; Cicada/ERMIA (tpcc_runtime::ScheduledControlLoop) log "[TPC-C interval]".
# METIS_ONLY_BASELINES=1: draw only Metis, Silo-BO, Silo (no Cicada/ERMIA).
import os
if os.environ.get("METIS_ONLY_BASELINES"):
    SRC = [x for x in SRC if x[0] not in ("Cicada", "ERMIA")]
PAT = re.compile(r"(?:\[TPS sample\] bench_s=([\d.]+) interval_tps=|\[TPC-C interval\] bench_s=([\d.]+) active_warehouses=\d+ tput=)([\d.]+)")
oracle = P.tpcc_oracle()
_ph = [(int(x.split(":")[0]), x.split(":")[1]) for x in P.TPCC_SCHEDULES[SCHED].split(",")]
PH = [(t0, t1, w) for (t0, w), t1 in zip(_ph, [p[0] for p in _ph[1:]] + [60])]

fig, ax = plt.subplots(figsize=(3.35, 1.85))
series, handles = {}, []
for name, color, path, lw, z in SRC:
    if not path.exists():
        print("missing, skipped:", name, path, file=sys.stderr)
        continue
    pts = [(float(a or b), float(v)) for a, b, v in PAT.findall(path.read_text())]
    series[name] = pts
    h, = ax.plot([t for t, _ in pts], [v for _, v in pts], color=color, lw=lw, label=name, zorder=z)
    handles.append(h)
top = max(oracle[w][1] for _, _, w in PH)
for i, (t0, t1, w) in enumerate(PH):
    h = ax.hlines(oracle[w][1], t0, t1, colors="#eb6834", linestyles="--", lw=1.0,
                  label="Oracle" if i == 0 else None, zorder=7)
    if i == 0:
        handles.append(h)
    if t0 > 0:
        ax.axvline(t0, color="#999999", lw=0.6, ls=":")
    ax.text((t0 + t1) / 2, top * 1.15, f"$W$ = {w}", ha="center", va="bottom", fontsize=7, color="#555555")
ax.set_xlim(0, 60); ax.set_ylim(0, top * 1.27)
ax.yaxis.set_major_locator(matplotlib.ticker.MultipleLocator(50e3 if top < 250e3 else 100e3))
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: "0" if v == 0 else f"{v/1e3:.0f}K"))
ax.set_ylabel("Throughput (txn/s)")
ax.set_xlabel("Time (s)")
ax.grid(axis="y", color="#e4e3df", lw=0.6); ax.set_axisbelow(True)
for sp in ("top", "right"): ax.spines[sp].set_visible(False)
fig.tight_layout()
fig.savefig(OUT, bbox_inches="tight", pad_inches=0.02)
print(OUT)

# separate legend, framed, as in eval_dynamic_tps_legend.pdf
lf = plt.figure(figsize=(3.0, 0.3))
leg = lf.legend(handles=handles, labels=[h.get_label() for h in handles], loc="center",
                ncol=len(handles), frameon=True, fontsize=7, handlelength=1.6, columnspacing=0.9,
                edgecolor="#888888", fancybox=True)
lf.savefig(OUT.with_name(OUT.stem + "_legend.pdf"), bbox_inches=leg.get_window_extent().transformed(
    lf.dpi_scale_trans.inverted()).expanded(1.03, 1.15))

# numbers for the text
mean = {k: st.mean(v for _, v in s) for k, s in series.items()}
per = {k: [st.mean(v for t, v in s if t0 < t <= t1) for t0, t1, _ in PH] for k, s in series.items()}
print("whole run: " + ", ".join(f"Metis/{k} = {mean['Metis']/mean[k]:.2f}" for k in mean if k != "Metis"))
for i, (_, _, w) in enumerate(PH):
    print(f"W={w}: Metis/oracle = {per['Metis'][i]/oracle[w][1]:.2f}; " +
          ", ".join(f"{k}/oracle = {per[k][i]/oracle[w][1]:.2f}, Metis/{k} = {per['Metis'][i]/per[k][i]:.2f}"
                    for k in per if k != "Metis"))
