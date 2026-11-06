#!/usr/bin/env bash
# Regenerate every figure in paper_figures/ (and the summary tables) from the
# recorded results. Needs python3 with matplotlib.
set -euo pipefail
cd "$(dirname "$0")"
FIG=paper_figures
mkdir -p "$FIG"

# Motivation: TPS vs active threads (oracle sweeps).
python3 plot_motivation.py

# Fixed load: TPS per method (summary.csv: all methods and states, log scale).
python3 plot_compare.py --bench tpcc
python3 plot_compare.py --bench ycsb
python3 plot_compare.py --bench tpcc --exclude adatam --linear --exclude-states 96 \
  --out "$PWD/$FIG/fixed_tpcc_methods.png"
python3 plot_compare.py --bench ycsb --exclude adatam --linear \
  --out "$PWD/$FIG/fixed_ycsb_methods.png"

# Fixed load: active threads chosen by Metis (held-out states); "picked": one
# run per method with adaTAM overlaid.
python3 plot_threads.py --bench tpcc --exclude-states 96 --out "$PWD/$FIG/fixed_tpcc_threads.png"
python3 plot_threads.py --bench ycsb --exclude-states 0.999 --out "$PWD/$FIG/fixed_ycsb_threads.png"
python3 plot_threads.py --bench tpcc --exclude-states 96 --pick-runs --with-adatam \
  --out "$PWD/$FIG/fixed_tpcc_threads_picked.png"
python3 plot_threads.py --bench ycsb --exclude-states 0.999 --pick-runs --with-adatam \
  --out "$PWD/$FIG/fixed_ycsb_threads_picked.png"

# Dynamic load: active threads and interval TPS over time.
python3 plot_dynamic.py --bench tpcc --schedules D1,D2,D3 --outdir "$FIG" --prefix dynamic_tpcc_
python3 plot_dynamic.py --bench ycsb --schedules Y1,Y2 --outdir "$FIG" --prefix dynamic_ycsb_

# Reach time and transient loss of the dynamic runs; thread stability.
python3 convergence.py
