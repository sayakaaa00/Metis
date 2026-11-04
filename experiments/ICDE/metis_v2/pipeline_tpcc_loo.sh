#!/usr/bin/env bash
# Train, merge, and leave-one-out evaluate Metis v2 A/B1/B2 on the 8 TPC-C states.
set -euo pipefail
cd "$(dirname "$0")/../../.."
for v in ${VARIANTS:-A B1 B2}; do
  python3 experiments/ICDE/metis_v2/run.py train --bench tpcc --variant "$v" --runs 2 --extime 30
  python3 experiments/ICDE/metis_v2/run.py merge --bench tpcc --variant "$v"
done
for v in ${VARIANTS:-A B1 B2}; do
  python3 experiments/ICDE/metis_v2/run.py fixed --bench tpcc --variant "$v" --runs 2 --extime 10
done
