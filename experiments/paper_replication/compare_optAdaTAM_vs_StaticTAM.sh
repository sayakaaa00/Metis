#!/usr/bin/env bash
set -euo pipefail

# extime / skew / pinning / OS 負荷などの条件を揃えたうえで、
# - OptAdaTAM: AdaTAM 有効 (update_us, step は optAdaTAM_scan で得たベスト値)
# - StaticTAM: TAM 完全無効 (ada_tam_enable=false, linucb_tam_enable=false) で
#              skew ごとの静的最適スレッド数だけを変えた構成
# をそれぞれ REPEATS 回ずつ実行し、throughput/abort_rate の平均と分散を求める。

# ==== 実験条件 ==============================================================

THREADS=${THREADS:-64}        # OptAdaTAM 側で使う最大スレッド数
EXTIME=${EXTIME:-3}
TUPLE_NUM=${TUPLE_NUM:-10000}
MAX_OPE=${MAX_OPE:-10}
RRATIO=${RRATIO:-50}
REPEATS=${REPEATS:-10}

# 対象 skew
SKEWS=(${SKEWS_OVERRIDE:-0.7 0.8 0.9 0.99})

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR="$REPO_ROOT/build_release"
BIN="$BUILD_DIR/silo/silo_with_TAM"

OUT_ROOT="$REPO_ROOT/experiments/paper_replication/compare_optAdaTAM_vs_StaticTAM_results"
RAW_FILE="$OUT_ROOT/raw_compare_optAdaTAM_vs_StaticTAM_v2.csv"
SUMMARY_FILE="$OUT_ROOT/summary_compare_optAdaTAM_vs_StaticTAM_v2.csv"

mkdir -p "$OUT_ROOT"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found or not executable. Build silo_with_TAM first (cmake --build build_release --target silo_with_TAM -j)." >&2
  exit 1
fi

# ==== OptAdaTAM: skew ごとのベスト (update_us, step) を返す ================
#   値は optAdaTAM_scan_results/summary_pinned_tuple_10000_release.csv から読み取ったものをハードコード

get_opt_params_for_skew() {
  local skew="$1"
  case "${skew}" in
    0.7)
      echo "5000 1"    # update_us=1000, step=1
      ;;
    0.8)
      echo "5000 1"    # update_us=1000, step=2
      ;;
    0.9)
      echo "5000 1"    # update_us=1000, step=2
      ;;
    0.99)
      echo "5000 1"    # update_us=5000, step=4
      ;;
    *)
      echo "ERROR: no OptAdaTAM params defined for skew=${skew}" >&2
      exit 1
      ;;
  esac
}

# ==== StaticTAM: skew ごとの静的最適スレッド数を返す =======================
#   ユーザが以前の実験から得たベストスレッド数に基づく。

get_static_threads_for_skew() {
  local skew="$1"
  case "${skew}" in
    0.7)
      echo "32"
      ;;
    0.8)
      echo "32"
      ;;
    0.9)
      echo "26"
      ;;
    0.99)
      echo "21"
      ;;
    *)
      echo "ERROR: no static best thread defined for skew=${skew}" >&2
      exit 1
      ;;
  esac
}

# ==== 1 回の実行 ============================================================
# config: OptAdaTAM / StaticTAM

run_one() {
  local config="$1"
  local skew="$2"
  local upd_us="$3"   # OptAdaTAM 用
  local step="$4"     # OptAdaTAM 用
  local runid="$5"

  local tmp_log
  tmp_log=$(mktemp)

  echo "[RUN] config=${config} skew=${skew} upd_us=${upd_us} step=${step} run=${runid}" >&2

  # 共通フラグ: extime / skew / YCSB / ピニングなど
  local base_flags=(
    "--extime=${EXTIME}"
    "--ycsb_tuple_num=${TUPLE_NUM}"
    "--ycsb_max_ope=${MAX_OPE}"
    "--ycsb_rratio=${RRATIO}"
    "--ycsb_zipf_skew=${skew}"
    "--pin_threads=true"
    "--tam_log_active_threads=false"
  )

  local cfg_flags=()

  case "${config}" in
    OptAdaTAM)
      # THREADS 個のワーカーを立て、AdaTAM による動的スレッド制御を有効化
      cfg_flags=(
        "--thread_num=${THREADS}"
        "--ada_tam_enable=true"
        "--linucb_tam_enable=false"
        "--tam_update_period_us=${upd_us}"
        "--ada_tam_step=${step}"
      )
      ;;
    StaticTAM)
      # TAM 完全無効で、skew ごとに決め打ちの静的スレッド数を使う
      local static_threads
      static_threads=$(get_static_threads_for_skew "${skew}")
      cfg_flags=(
        "--thread_num=${static_threads}"
        "--ada_tam_enable=false"
        "--linucb_tam_enable=false"
      )
      ;;
    *)
      echo "ERROR: unknown config=${config}" >&2
      rm -f "${tmp_log}"
      exit 1
      ;;
  esac

  if numactl --membind=0 "${BIN}" \
      "${base_flags[@]}" \
      "${cfg_flags[@]}" \
      | tee "${tmp_log}" >/dev/stderr; then
    :
  else
    echo "WARNING: run failed for config=${config}, skew=${skew}, run=${runid}. Skipping." >&2
    rm -f "${tmp_log}"
    return 1
  fi

  local throughput abort_rate keep_log=0
  throughput=$(awk -F':[ \t]+' '/throughput\[tps\]/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "${tmp_log}")
  abort_rate=$(awk -F':[ \t]+' '/^abort_rate/{gsub(/\r/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "${tmp_log}")

  if [[ -z "${throughput}" ]]; then throughput="NA"; keep_log=1; fi
  if [[ -z "${abort_rate}" ]]; then abort_rate="NA"; keep_log=1; fi

  if (( keep_log )); then
    echo "WARN: metrics missing for config=${config}, skew=${skew}, run=${runid} (log: ${tmp_log})" >&2
  else
    rm -f "${tmp_log}"
  fi

  # CSV 行: config,skew,update_us,step,run,throughput_tps,abort_rate
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "${config}" "${skew}" "${upd_us}" "${step}" "${runid}" "${throughput}" "${abort_rate}"
}

# ==== 全実行 ===============================================================

echo "config,skew,update_us,step,run,throughput_tps,abort_rate" > "${RAW_FILE}"

for skew in "${SKEWS[@]}"; do
  # AdaTAM 側の (update_us, step) を取得
  read -r OPT_UPD OPT_STEP < <(get_opt_params_for_skew "${skew}")

  for config in OptAdaTAM StaticTAM; do
    for ((r=1; r<=REPEATS; r++)); do
      if line=$(run_one "${config}" "${skew}" "${OPT_UPD}" "${OPT_STEP}" "${r}"); then
        echo "${line}" >> "${RAW_FILE}"
      fi
    done
  done
done

echo "All runs complete. Raw results: ${RAW_FILE}" >&2

# ==== 集計: (config,skew) ごとの平均 / 標準偏差 ============================

awk 'BEGIN{
       FS=","; OFS=",";
     }
     NR==1{ next; }
     $6=="NA"{ next; }
     {
       cfg=$1; sk=$2; upd=$3; step=$4;
       key=cfg "," sk "," upd "," step;

       run_count[key] += 1;
       sum_tps[key]   += $6;
       sum_tps2[key]  += ($6 * $6);
       sum_ab[key]    += $7;
       sum_ab2[key]   += ($7 * $7);
     }
     END{
       print "config","skew","update_us","step","runs","mean_tps","std_tps","mean_abort","std_abort";
       for (key in run_count) {
         n = run_count[key];
         split(key, a, ",");
         cfg=a[1]; sk=a[2]; upd=a[3]; step=a[4];

         mtps = sum_tps[key] / n;
         var_tps = sum_tps2[key] / n - mtps * mtps;
         if (var_tps < 0) var_tps = 0;
         std_tps = (var_tps > 0) ? sqrt(var_tps) : 0;

         mab = sum_ab[key] / n;
         var_ab = sum_ab2[key] / n - mab * mab;
         if (var_ab < 0) var_ab = 0;
         std_ab = (var_ab > 0) ? sqrt(var_ab) : 0;

         print cfg, sk, upd, step, n, mtps, std_tps, mab, std_ab;
       }
     }' "${RAW_FILE}" | sort -t',' -k2,2 -k1,1 > "${SUMMARY_FILE}"

echo "Summary written to: ${SUMMARY_FILE}" >&2
