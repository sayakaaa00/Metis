#!/usr/bin/env bash
# Fixed leave-one-W-out evaluation with the SMT model, preserving old outputs.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export EXP_NAME=${EXP_NAME:-physical_first_item100k_aware_smt_loo_v1}
export METIS_BINARY="$ROOT/build_release/silo/tpcc_metis_test_smt"
bash "$SCRIPT_DIR/physical_first_item100k_aware_fixed.sh"
