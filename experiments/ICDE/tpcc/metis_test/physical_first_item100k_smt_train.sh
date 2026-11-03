#!/usr/bin/env bash
# Same warehouse-aware leave-one-W-out training, using the 14D SMT binary.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export EXP_NAME=${EXP_NAME:-physical_first_item100k_aware_smt_loo_v1}
export BIN="$ROOT/build_release/silo/tpcc_metis_test_smt"
export SMT_FEATURE=true
bash "$SCRIPT_DIR/physical_first_item100k_aware_train.sh"
