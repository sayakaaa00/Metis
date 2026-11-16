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
# Relative METIS_DATA / METIS_FIG_OUT are relative to the caller's directory.
if [ -n "${METIS_DATA:-}" ]; then export METIS_DATA=$(cd "$METIS_DATA" && pwd); fi
if [ -n "${METIS_FIG_OUT:-}" ]; then mkdir -p "$METIS_FIG_OUT"; export METIS_FIG_OUT=$(cd "$METIS_FIG_OUT" && pwd); fi
cd "$(dirname "$0")"
OUT=${METIS_FIG_OUT:-$(cd .. && pwd)/results/figures}
export METIS_FIG_OUT=$OUT
mkdir -p "$OUT"
python3 plot_eval_static.py                                              # Evaluation: static workloads
python3 plot_eval_static_time.py                                         # Evaluation: hill climbing (static)
python3 plot_eval_static_tps.py
python3 plot_eval_dynamic.py 1                                           # Evaluation: hill climbing (dynamic)
python3 plot_eval_dynamic_tps.py "$OUT/eval_dynamic_tps.pdf"              # Evaluation: dynamic YCSB
python3 plot_eval_dynamic_tps_tpcc.py "$OUT/eval_dynamic_tps_tpcc.pdf"    # Evaluation: dynamic TPC-C
echo "figures in $OUT"
