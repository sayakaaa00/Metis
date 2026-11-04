#!/usr/bin/env python3
"""Dynamic-load time series: active threads (Metis v2-A, adaTAM) and interval
TPS (all methods) for each schedule, run 1. Writes <bench>/dynamic/<name>.png.

  plot_dynamic.py --bench tpcc|ycsb
"""
import argparse
import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

import dynamic as D
import plot_fixed as P

COLORS = {"metis_v2": ("Metis", "#2a78d6"), "adatam": ("adaTAM", "#1baf7a"),
          "silo_bo": ("Silo (backoff)", "#eda100"),
          "silo_nobo": ("Silo (no backoff)", "#e87ba4")}


def series(path, pattern):
    xs, ys = [], []
    if path is None or not path.exists():
        return xs, ys
    for line in path.read_text().splitlines():
        m = re.search(pattern, line)
        if m:
            xs.append(float(m[1]))
            ys.append(float(m[2]))
    return xs, ys


def phases(bench, sched):
    if bench == "tpcc":
        return [(int(x.split(":")[0]), x.split(":")[1]) for x in sched.split(",")]
    p = sched.split(",")
    return [(0, p[0])] + [(int(x.split(":")[0]), x.split(":")[1]) for x in p[1:]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", default="tpcc")
    ap.add_argument("--run", default="1")
    args = ap.parse_args()
    table = D.TPCC_SCHEDULES if args.bench == "tpcc" else D.YCSB_SCHEDULES
    oracle = P.tpcc_oracle() if args.bench == "tpcc" else P.ycsb_oracle()
    d = P.HERE / args.bench / "dynamic"
    label = "W" if args.bench == "tpcc" else "skew"
    for name, sched in table.items():
        ph = phases(args.bench, sched)
        fig, (a1, a2) = plt.subplots(2, 1, figsize=(11, 6.4), sharex=True,
                                     facecolor=P.SURFACE,
                                     gridspec_kw={"height_ratios": [1, 1.2]})
        for ax in (a1, a2):
            P.style(ax)
            for t, _ in ph[1:]:
                ax.axvline(t, color=P.GRID, linewidth=1, zorder=0)
        # oracle best N and oracle TPS per phase
        for i, (t, s) in enumerate(ph):
            t2 = ph[i + 1][0] if i + 1 < len(ph) else 60
            a1.hlines(oracle[s][0], t, t2, color=P.ORACLE, linestyle="--", linewidth=1.3,
                      label="oracle best N" if i == 0 else None)
            a2.hlines(oracle[s][1], t, t2, color=P.ORACLE, linestyle="--", linewidth=1.3,
                      label="oracle TPS" if i == 0 else None)
            if len(ph) <= 6:
                a1.text((t + t2) / 2, 99, f"{label}={s}", ha="center", va="bottom",
                        fontsize=8, color=P.INK2)
        for m, (title, color) in COLORS.items():
            log = d / "logs" / f"{name}_{m}_run{args.run}.log"
            trace = log.with_suffix(".trace.log")
            src = trace if trace.exists() else log
            if m in ("metis_v2", "adatam"):
                x, y = series(trace, r"\[TAM sample\] bench_s=([\d.]+) active_threads=(\d+)")
                a1.step(x, y, where="post", color=color, linewidth=1.6, label=title)
            x, y = series(src, r"\[TPS sample\] bench_s=([\d.]+) interval_tps=([\d.]+)")
            a2.plot(x, y, color=color, linewidth=1.3, label=title)
        a1.set_ylim(0, 104)
        a1.set_yticks([0, 24, 48, 72, 96])
        a1.set_ylabel("Active threads", color=P.INK2)
        a2.set_ylabel("Interval TPS (200 ms)", color=P.INK2)
        a2.set_xlabel("Time (s)", color=P.INK2)
        a2.set_ylim(bottom=0)
        a2.yaxis.set_major_formatter(FuncFormatter(
            lambda v, _: f"{v / 1e6:g}M" if v >= 1e6 else f"{v / 1e3:g}k"))
        a1.set_title(f"{args.bench.upper()} dynamic {name}: {sched}  (run {args.run})",
                     fontsize=11, color=P.INK, loc="left")
        a1.legend(frameon=False, fontsize=8, loc="upper right", ncol=3)
        a2.legend(frameon=False, fontsize=8, loc="upper center",
                  bbox_to_anchor=(0.5, -0.18), ncol=5)
        fig.tight_layout()
        fig.savefig(d / f"{name}.png", dpi=140, facecolor=P.SURFACE)
        plt.close(fig)
        print(d / f"{name}.png")


if __name__ == "__main__":
    main()
