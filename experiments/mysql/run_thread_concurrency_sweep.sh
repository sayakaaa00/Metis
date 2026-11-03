#!/usr/bin/env bash
set -Eeuo pipefail

# Overrides: RESET_EACH_POINT=0|1, PREPARE=auto|0|1, LIMITS="...",
# REPEATS=N, ORDER_MODE=as-given|balanced, PREWARM_RUNS=N,
# PREWARM_LIMIT=N, LAB_ROOT=...
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="${LAB_ROOT:-/home/ubuntu/metis-mysql-lab}"
BENCHBASE_DIR="${BENCHBASE_DIR:-${LAB_ROOT}/benchbase-run}"
MYSQL_BIN_DIR="${MYSQL_BIN_DIR:-${LAB_ROOT}/mysql-build-baseline/runtime_output_directory}"
MYSQL_CONFIG="${MYSQL_CONFIG:-${LAB_ROOT}/config/my-baseline.cnf}"
MYSQL_SOCKET="${MYSQL_SOCKET:-${LAB_ROOT}/run/mysql-baseline.sock}"
WARMUP_CONFIG="${WARMUP_CONFIG:-${SCRIPT_DIR}/tpcc-high-contention-warmup.xml}"
MEASURE_CONFIG="${MEASURE_CONFIG:-${SCRIPT_DIR}/tpcc-high-contention.xml}"
RESULT_ROOT="${RESULT_ROOT:-${LAB_ROOT}/results/thread-concurrency-sweep}"
LIMITS="${LIMITS:-0 8 16 24 32 48 64 96}"
REPEATS="${REPEATS:-1}"
PREPARE="${PREPARE:-auto}"
RESET_EACH_POINT="${RESET_EACH_POINT:-1}"
WAREHOUSES="${WAREHOUSES:-4}"
TERMINALS="${TERMINALS:-96}"
ORDER_MODE="${ORDER_MODE:-as-given}"
PREWARM_RUNS="${PREWARM_RUNS:-0}"
PREWARM_LIMIT="${PREWARM_LIMIT:-0}"
FAIL_ON_SQL_ERRORS="${FAIL_ON_SQL_ERRORS:-1}"
MYSQL="${MYSQL_BIN_DIR}/mysql"
MYSQLADMIN="${MYSQL_BIN_DIR}/mysqladmin"
MYSQLD="${MYSQL_BIN_DIR}/mysqld"
BENCHBASE_JAR="${BENCHBASE_DIR}/benchbase.jar"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RESULT_ROOT}/${RUN_ID}"
SUMMARY_CSV="${RUN_DIR}/summary.csv"
AGGREGATE_CSV="${RUN_DIR}/aggregate.csv"

mysql_root() { "${MYSQL}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot --batch --skip-column-names "$@"; }
benchbase() { (cd "${BENCHBASE_DIR}" && java -jar "${BENCHBASE_JAR}" "$@"); }
require_file() { [[ -f "$1" ]] || { echo "Required file not found: $1" >&2; exit 1; }; }
reverse_words() {
  local result="" word
  for word in $1; do result="${word} ${result}"; done
  printf '%s\n' "${result% }"
}
cleanup() {
  local status=$?
  if "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null 2>&1; then
    mysql_root -e "SET GLOBAL innodb_thread_concurrency=0" || true
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

for file in "${MYSQLD}" "${MYSQL}" "${BENCHBASE_JAR}" "${WARMUP_CONFIG}" "${MEASURE_CONFIG}"; do require_file "${file}"; done
case "${ORDER_MODE}" in as-given|balanced) ;; *) echo "ORDER_MODE must be as-given or balanced" >&2; exit 2 ;; esac
mkdir -p "${RUN_DIR}"

if ! "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null 2>&1; then
  echo "Starting baseline MySQL..."
  "${MYSQLD}" --defaults-file="${MYSQL_CONFIG}" --daemonize
fi
for _ in $(seq 1 60); do
  "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null 2>&1 && break
  sleep 1
done
"${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null

warehouse_count=0
table_exists="$(mysql_root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='benchbase' AND table_name='warehouse'" 2>/dev/null || true)"
[[ "${table_exists}" == "1" ]] && warehouse_count="$(mysql_root benchbase -e "SELECT COUNT(*) FROM warehouse" 2>/dev/null || true)"
need_prepare=0
case "${PREPARE}" in
  1|true|TRUE|yes|YES) need_prepare=1 ;;
  0|false|FALSE|no|NO) need_prepare=0 ;;
  auto) [[ "${warehouse_count}" == "${WAREHOUSES}" ]] || need_prepare=1 ;;
  *) echo "PREPARE must be auto, 1, or 0" >&2; exit 2 ;;
esac
if (( need_prepare )) && [[ "${RESET_EACH_POINT}" == "0" ]]; then
  echo "Preparing a fresh TPC-C scale-factor-${WAREHOUSES} database..."
  benchbase -b tpcc -c "${MEASURE_CONFIG}" --create=true --load=false --execute=false >"${RUN_DIR}/prepare-create.log" 2>&1
  benchbase -b tpcc -c "${MEASURE_CONFIG}" --create=false --load=true --execute=false >"${RUN_DIR}/prepare-load.log" 2>&1
fi
if [[ "${RESET_EACH_POINT}" == "0" ]]; then
  actual_warehouses="$(mysql_root benchbase -e "SELECT COUNT(*) FROM warehouse")"
  [[ "${actual_warehouses}" == "${WAREHOUSES}" ]] || { echo "Expected ${WAREHOUSES} warehouses, found ${actual_warehouses}" >&2; exit 1; }
fi

{
  echo "run_id=${RUN_ID}"; echo "utc_started=$(date -u +%FT%TZ)"
  echo "mysql_version=$(mysql_root -e 'SELECT VERSION()')"
  echo "warehouses=${WAREHOUSES}"; echo "terminals=${TERMINALS}"; echo "warmup_seconds=30"; echo "measurement_seconds=60"
  echo "reset_each_point=${RESET_EACH_POINT}"
  echo "limits=${LIMITS}"; echo "repeats=${REPEATS}"
  echo "order_mode=${ORDER_MODE}"; echo "prewarm_runs=${PREWARM_RUNS}"; echo "prewarm_limit=${PREWARM_LIMIT}"
  echo "mysql_commit=$(git -C "${LAB_ROOT}/mysql-server" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "benchbase_commit=$(git -C "${LAB_ROOT}/benchbase" rev-parse HEAD 2>/dev/null || echo unknown)"
} >"${RUN_DIR}/metadata.txt"
echo "repeat,limit,requests,tps,avg_ms,p50_ms,p95_ms,p99_ms,max_ms,deadlocks,rollbacks,unexpected_sql_errors,threads_running_max" >"${SUMMARY_CSV}"

read_status() { mysql_root -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_deadlocks','Com_rollback','Threads_running')"; }
json_number() {
  awk -v key="$2" 'index($0,"\"" key "\""){sub(/^[^:]*:[[:space:]]*/,"");sub(/[,[:space:]]*$/,"");print;exit}' "$1"
}
unexpected_sql_errors() {
  awk '
    /Unexpected SQL Errors:/ { inside=1; next }
    /Unknown Status Transactions:/ { inside=0 }
    inside && /\[[[:space:]]*[0-9]+\]/ {
      value=$0
      sub(/^.*\[/,"",value)
      sub(/\].*$/, "", value)
      gsub(/[[:space:]]/, "", value)
      total += value
    }
    END { print total + 0 }
  ' "$1"
}

if (( PREWARM_RUNS > 0 )); then
  echo "Pre-warming database: ${PREWARM_RUNS} x 30 s at limit=${PREWARM_LIMIT}"
  mkdir -p "${RUN_DIR}/prewarm"
  mysql_root -e "SET GLOBAL innodb_thread_concurrency=${PREWARM_LIMIT}"
  for prewarm_run in $(seq 1 "${PREWARM_RUNS}"); do
    prewarm_dir="${RUN_DIR}/prewarm/run-${prewarm_run}"
    mkdir -p "${prewarm_dir}"
    benchbase -b tpcc -c "${WARMUP_CONFIG}" --create=false --load=false --execute=true \
      -d "${prewarm_dir}" -im 1000 >"${RUN_DIR}/prewarm/run-${prewarm_run}.log" 2>&1
  done
fi

for repeat in $(seq 1 "${REPEATS}"); do
  run_limits="${LIMITS}"
  if [[ "${ORDER_MODE}" == "balanced" ]] && (( repeat % 2 == 0 )); then
    run_limits="$(reverse_words "${LIMITS}")"
  fi
  echo "[repeat ${repeat}/${REPEATS}] order: ${run_limits}"
  for limit in ${run_limits}; do
    point_dir="${RUN_DIR}/repeat-${repeat}/limit-${limit}"
    warmup_dir="${point_dir}/warmup"; measure_dir="${point_dir}/measure"
    mkdir -p "${warmup_dir}" "${measure_dir}"
    if [[ "${RESET_EACH_POINT}" == "1" ]]; then
      echo "[repeat ${repeat}/${REPEATS}] limit=${limit}: reset and load"
      benchbase -b tpcc -c "${MEASURE_CONFIG}" --create=true --load=false --execute=false >"${point_dir}/prepare-create.log" 2>&1
      benchbase -b tpcc -c "${MEASURE_CONFIG}" --create=false --load=true --execute=false >"${point_dir}/prepare-load.log" 2>&1
      actual_warehouses="$(mysql_root benchbase -e "SELECT COUNT(*) FROM warehouse")"
      [[ "${actual_warehouses}" == "${WAREHOUSES}" ]] || { echo "Expected ${WAREHOUSES} warehouses, found ${actual_warehouses}" >&2; exit 1; }
    fi
    echo "[repeat ${repeat}/${REPEATS}] limit=${limit}: warmup"
    mysql_root -e "SET GLOBAL innodb_thread_concurrency=${limit}"
    mysql_root -e "SELECT @@GLOBAL.innodb_thread_concurrency" >"${point_dir}/applied-limit.txt"
    benchbase -b tpcc -c "${WARMUP_CONFIG}" --create=false --load=false --execute=true -d "${warmup_dir}" -im 1000 >"${point_dir}/warmup.log" 2>&1

    read_status >"${point_dir}/status-before.tsv"
    deadlocks_before="$(awk '$1=="Innodb_deadlocks"{print $2}' "${point_dir}/status-before.tsv")"
    rollbacks_before="$(awk '$1=="Com_rollback"{print $2}' "${point_dir}/status-before.tsv")"
    echo "[repeat ${repeat}/${REPEATS}] limit=${limit}: measure"
    (while true; do printf '%s\t' "$(date +%s%3N)"; read_status | awk '$1=="Threads_running"{print $2}'; sleep 1; done) >"${point_dir}/threads-running.tsv" &
    sampler_pid=$!
    if ! benchbase -b tpcc -c "${MEASURE_CONFIG}" --create=false --load=false --execute=true -d "${measure_dir}" -im 1000 >"${point_dir}/measure.log" 2>&1; then
      kill "${sampler_pid}" 2>/dev/null || true; wait "${sampler_pid}" 2>/dev/null || true
      echo "BenchBase failed; see ${point_dir}/measure.log" >&2; exit 1
    fi
    kill "${sampler_pid}" 2>/dev/null || true; wait "${sampler_pid}" 2>/dev/null || true
    read_status >"${point_dir}/status-after.tsv"
    deadlocks_after="$(awk '$1=="Innodb_deadlocks"{print $2}' "${point_dir}/status-after.tsv")"
    rollbacks_after="$(awk '$1=="Com_rollback"{print $2}' "${point_dir}/status-after.tsv")"
    deadlocks=$((deadlocks_after-deadlocks_before)); rollbacks=$((rollbacks_after-rollbacks_before))
    threads_running_max="$(awk 'BEGIN{m=0}$2>m{m=$2}END{print m}' "${point_dir}/threads-running.tsv")"
    sql_errors="$(unexpected_sql_errors "${point_dir}/measure.log")"
    summary_json="$(find "${measure_dir}" -maxdepth 1 -name '*.summary.json' -print -quit)"
    [[ -n "${summary_json}" ]] || { echo "No summary JSON in ${measure_dir}" >&2; exit 1; }
    requests="$(json_number "${summary_json}" "Measured Requests")"
    tps="$(json_number "${summary_json}" "Throughput (requests/second)")"
    avg="$(json_number "${summary_json}" "Average Latency (microseconds)")"
    p50="$(json_number "${summary_json}" "Median Latency (microseconds)")"
    p95="$(json_number "${summary_json}" "95th Percentile Latency (microseconds)")"
    p99="$(json_number "${summary_json}" "99th Percentile Latency (microseconds)")"
    max="$(json_number "${summary_json}" "Maximum Latency (microseconds)")"
    awk -v r="${repeat}" -v l="${limit}" -v q="${requests}" -v t="${tps}" -v a="${avg}" -v b="${p50}" -v c="${p95}" -v d="${p99}" -v e="${max}" -v f="${deadlocks}" -v g="${rollbacks}" -v h="${sql_errors}" -v i="${threads_running_max}" 'BEGIN{printf "%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d\n",r,l,q,t,a/1000,b/1000,c/1000,d/1000,e/1000,f,g,h,i}' >>"${SUMMARY_CSV}"
    tail -n 1 "${SUMMARY_CSV}"
    if [[ "${FAIL_ON_SQL_ERRORS}" == "1" ]] && (( sql_errors > 0 )); then
      echo "Unexpected SQL errors detected (${sql_errors}); refusing to continue with invalid measurements." >&2
      echo "See ${point_dir}/measure.log" >&2
      exit 1
    fi
  done
done
mysql_root -e "SET GLOBAL innodb_thread_concurrency=0"
{
  echo "limit,runs,avg_tps,stddev_tps,avg_p95_ms,avg_p99_ms,avg_rollbacks,total_unexpected_sql_errors"
  awk -F, 'NR > 1 {
    n[$2]++; t[$2]+=$4; t2[$2]+=$4*$4; p95[$2]+=$7; p99[$2]+=$8; rb[$2]+=$11; err[$2]+=$12
  } END {
    for (l in n) {
      mean=t[l]/n[l]; var=t2[l]/n[l]-mean*mean; if (var<0) var=0;
      printf "%d,%d,%.3f,%.3f,%.3f,%.3f,%.1f,%d\n", l,n[l],mean,sqrt(var),p95[l]/n[l],p99[l]/n[l],rb[l]/n[l],err[l]
    }
  }' "${SUMMARY_CSV}" | sort -t, -k1,1n
} >"${AGGREGATE_CSV}"
echo "Sweep complete: ${SUMMARY_CSV}"
echo "Aggregate: ${AGGREGATE_CSV}"
