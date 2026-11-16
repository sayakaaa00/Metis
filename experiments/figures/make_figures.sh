#!/usr/bin/env bash
# Regenerate the paper's figures from the measured results.
#   experiments/figures/make_figures.sh
# Data: $METIS_DATA (default: experiments/data/, the Metis-data submodule; set it to
# $METIS_OUT to plot new runs). Output: $METIS_FIG_OUT (default:
# experiments/results/figures). Needs python3 with matplotlib and numpy.
# The figures as they appear in the paper are in Metis-data (experiments/data/figures).
# The paper splits some figures into one PDF per benchmark plus a legend;
# that layout is made in Tatzhiro/MySQL-Metis-experiments.
set -euo pipefail
cd "$(dirname "$0")"
OUT=${METIS_FIG_OUT:-$(cd .. && pwd)/results/figures}
export METIS_FIG_OUT=$OUT
mkdir -p "$OUT"
python3 plot_intro_fixed_nometis.py "$OUT/intro_fixed_nometis.pdf"       # Introduction
python3 plot_tps_vs_threads_lowhigh.py "$OUT"                             # Introduction
python3 plot_breakdown_vs_skew.py "$OUT/breakdown_vs_skew.pdf"            # Introduction
python3 plot_backoff_sensitivity.py "$OUT/backoff_sensitivity.pdf" backoff_constant 0,0.7,0.95  # Background
python3 plot_motivation_tps_vs_threads.py "$OUT/motivation_tps_vs_threads.pdf"  # Background
python3 plot_eval_static.py                                              # Evaluation: static workloads
python3 plot_eval_static_time.py                                         # Evaluation: hill climbing (static)
python3 plot_eval_static_tps.py
python3 plot_eval_dynamic.py 1                                           # Evaluation: hill climbing (dynamic)
python3 plot_eval_dynamic_tps.py "$OUT/eval_dynamic_tps.pdf"              # Evaluation: dynamic YCSB
python3 plot_eval_dynamic_tps_tpcc.py "$OUT/eval_dynamic_tps_tpcc.pdf"    # Evaluation: dynamic TPC-C
python3 plot_eval_backoff.py                                             # Evaluation: thread throttling vs. backoff
echo "figures in $OUT"
