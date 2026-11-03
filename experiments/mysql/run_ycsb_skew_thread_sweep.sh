#!/usr/bin/env bash
set -Eeuo pipefail

# Find the best fixed innodb_thread_concurrency value for each YCSB Zipf skew.
# Common overrides:
#   SKEWS="0.70 0.80 0.90 0.95"
#   LIMITS="0 8 16 24 32 48 64 80 96 112 128 160 192"
#   REPEATS=2 TERMINALS=192 SCALE_FACTOR=10
#   OPERATIONS_PER_TRANSACTION=10 READ_RATIO=50
#   WARMUP_SECONDS=30 MEASURE_SECONDS=30 PREPARE=auto|0|1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="${LAB_ROOT:-/home/ubuntu/metis-mysql-lab}"
BENCHBASE_DIR="${BENCHBASE_DIR:-${LAB_ROOT}/benchbase-run}"
MYSQL_BIN_DIR="${MYSQL_BIN_DIR:-${LAB_ROOT}/mysql-build-baseline/runtime_output_directory}"
MYSQL_CONFIG="${MYSQL_CONFIG:-${LAB_ROOT}/config/my-baseline.cnf}"
MYSQL_SOCKET="${MYSQL_SOCKET:-${LAB_ROOT}/run/mysql-baseline.sock}"
CONFIG_TEMPLATE="${CONFIG_TEMPLATE:-${SCRIPT_DIR}/ycsb-skew-template.xml}"
RESULT_ROOT="${RESULT_ROOT:-${LAB_ROOT}/results/ycsb-skew-thread-sweep}"

SKEWS="${SKEWS:-0.70 0.80 0.90 0.95}"
LIMITS="${LIMITS:-0 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64 66 68 70 72 74 76 78 80 82 84 86 88 90 92 94 96}"
REPEATS="${REPEATS:-2}"
ORDER_MODE="${ORDER_MODE:-balanced}"
PREWARM_RUNS="${PREWARM_RUNS:-1}"
PREWARM_LIMIT="${PREWARM_LIMIT:-96}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
MEASURE_SECONDS="${MEASURE_SECONDS:-30}"
TERMINALS="${TERMINALS:-192}"
SCALE_FACTOR="${SCALE_FACTOR:-10}"
OPERATIONS_PER_TRANSACTION="${OPERATIONS_PER_TRANSACTION:-10}"
READ_RATIO="${READ_RATIO:-50}"
PREPARE="${PREPARE:-auto}"
FAIL_ON_SQL_ERRORS="${FAIL_ON_SQL_ERRORS:-1}"

MYSQL="${MYSQL_BIN_DIR}/mysql"
MYSQLADMIN="${MYSQL_BIN_DIR}/mysqladmin"
MYSQLD="${MYSQL_BIN_DIR}/mysqld"
BENCHBASE_JAR="${BENCHBASE_DIR}/benchbase.jar"
JAVAP="${JAVAP:-javap}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${RESULT_ROOT}/${RUN_ID}"
CONFIG_DIR="${RUN_DIR}/configs"
SUMMARY_CSV="${RUN_DIR}/summary.csv"
AGGREGATE_CSV="${RUN_DIR}/aggregate.csv"
BEST_CSV="${RUN_DIR}/best_by_skew.csv"

mysql_root() {
  "${MYSQL}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot --batch --skip-column-names "$@"
}

benchbase() {
  (cd "${BENCHBASE_DIR}" && java -jar "${BENCHBASE_JAR}" "$@")
}

require_file() {
  [[ -f "$1" ]] || { echo "Required file not found: $1" >&2; exit 1; }
}

reverse_words() {
  local result="" word
  for word in $1; do result="${word} ${result}"; done
  printf '%s\n' "${result% }"
}

render_config() {
  local skew="$1" duration="$2" output="$3"
  sed \
    -e "s/@SCALE_FACTOR@/${SCALE_FACTOR}/g" \
    -e "s/@TERMINALS@/${TERMINALS}/g" \
    -e "s/@SKEW@/${skew}/g" \
    -e "s/@OPERATIONS_PER_TRANSACTION@/${OPERATIONS_PER_TRANSACTION}/g" \
    -e "s/@READ_RATIO@/${READ_RATIO}/g" \
    -e "s/@TIME_SECONDS@/${duration}/g" \
    "${CONFIG_TEMPLATE}" >"${output}"
}

read_status() {
  mysql_root -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Innodb_deadlocks','Com_rollback','Threads_running')"
}

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

cleanup() {
  local status=$?
  if "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null 2>&1; then
    mysql_root -e "SET GLOBAL innodb_thread_concurrency=0" || true
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

for file in "${MYSQLD}" "${MYSQL}" "${BENCHBASE_JAR}" "${CONFIG_TEMPLATE}"; do
  require_file "${file}"
done
command -v "${JAVAP}" >/dev/null || { echo "javap is required to verify the patched BenchBase JAR" >&2; exit 1; }
benchbase_ycsb_api="$("${JAVAP}" -classpath "${BENCHBASE_JAR}" -private com.oltpbenchmark.benchmarks.ycsb.YCSBBenchmark 2>/dev/null || true)"
[[ "${benchbase_ycsb_api}" == *operationsPerTransaction* ]] || {
  echo "BenchBase JAR lacks the ccbench-compatible multi-operation YCSB patch." >&2
  echo "Apply experiments/mysql/benchbase-ycsb-ccbench.patch and rebuild BenchBase." >&2
  exit 1
}


case "${ORDER_MODE}" in
  as-given|balanced) ;;
  *) echo "ORDER_MODE must be as-given or balanced" >&2; exit 2 ;;
esac
case "${PREPARE}" in
  auto|0|1|true|TRUE|false|FALSE|yes|YES|no|NO) ;;
  *) echo "PREPARE must be auto, 1, or 0" >&2; exit 2 ;;
esac
[[ "${REPEATS}" =~ ^[1-9][0-9]*$ ]] || { echo "REPEATS must be a positive integer" >&2; exit 2; }
[[ "${PREWARM_RUNS}" =~ ^[0-9]+$ ]] || { echo "PREWARM_RUNS must be a non-negative integer" >&2; exit 2; }
[[ "${WARMUP_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { echo "WARMUP_SECONDS must be a positive integer" >&2; exit 2; }
[[ "${MEASURE_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { echo "MEASURE_SECONDS must be a positive integer" >&2; exit 2; }
[[ "${TERMINALS}" =~ ^[1-9][0-9]*$ ]] || { echo "TERMINALS must be a positive integer" >&2; exit 2; }
[[ "${SCALE_FACTOR}" =~ ^[1-9][0-9]*$ ]] || { echo "SCALE_FACTOR must be a positive integer" >&2; exit 2; }
[[ "${OPERATIONS_PER_TRANSACTION}" =~ ^[1-9][0-9]*$ ]] || { echo "OPERATIONS_PER_TRANSACTION must be a positive integer" >&2; exit 2; }
[[ "${READ_RATIO}" =~ ^[0-9]+$ ]] && (( READ_RATIO <= 100 )) || { echo "READ_RATIO must be an integer from 0 to 100" >&2; exit 2; }
for skew in ${SKEWS}; do
  awk -v value="${skew}" 'BEGIN { exit !(value > 0 && value < 1) }' || {
    echo "Every skew must be greater than 0 and less than 1: ${skew}" >&2
    exit 2
  }
done
for limit in ${LIMITS}; do
  [[ "${limit}" =~ ^[0-9]+$ ]] && (( limit <= 1000 )) || {
    echo "Every limit must be an integer from 0 to 1000: ${limit}" >&2
    exit 2
  }
done

mkdir -p "${CONFIG_DIR}"
for skew in ${SKEWS}; do
  render_config "${skew}" "${WARMUP_SECONDS}" "${CONFIG_DIR}/skew-${skew}-warmup.xml"
  render_config "${skew}" "${MEASURE_SECONDS}" "${CONFIG_DIR}/skew-${skew}-measure.xml"
done

if ! "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null 2>&1; then
  echo "Starting baseline MySQL..."
  "${MYSQLD}" --defaults-file="${MYSQL_CONFIG}" --daemonize
fi
for _ in $(seq 1 60); do
  "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null 2>&1 && break
  sleep 1
done
"${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null

expected_records=$((SCALE_FACTOR * 1000))
record_count=0
table_exists="$(mysql_root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='benchbase' AND table_name='usertable'" 2>/dev/null || true)"
if [[ "${table_exists}" == "1" ]]; then
  record_count="$(mysql_root benchbase -e "SELECT COUNT(*) FROM usertable" 2>/dev/null || true)"
fi
need_prepare=0
case "${PREPARE}" in
  1|true|TRUE|yes|YES) need_prepare=1 ;;
  0|false|FALSE|no|NO) need_prepare=0 ;;
  auto) [[ "${record_count}" == "${expected_records}" ]] || need_prepare=1 ;;
esac

first_skew="${SKEWS%% *}"
prepare_config="${CONFIG_DIR}/skew-${first_skew}-measure.xml"
if (( need_prepare )); then
  echo "Preparing a fresh YCSB table with ${expected_records} records..."
  benchbase -b ycsb -c "${prepare_config}" --create=true --load=false --execute=false \
    >"${RUN_DIR}/prepare-create.log" 2>&1
  benchbase -b ycsb -c "${prepare_config}" --create=false --load=true --execute=false \
    >"${RUN_DIR}/prepare-load.log" 2>&1
fi

actual_records="$(mysql_root benchbase -e "SELECT COUNT(*) FROM usertable")"
[[ "${actual_records}" == "${expected_records}" ]] || {
  echo "Expected ${expected_records} YCSB records, found ${actual_records}. Use PREPARE=1." >&2
  exit 1
}

{
  echo "run_id=${RUN_ID}"
  echo "utc_started=$(date -u +%FT%TZ)"
  echo "benchmark=ycsb-ccbench-mixed"
  echo "mysql_version=$(mysql_root -e 'SELECT VERSION()')"
  echo "scale_factor=${SCALE_FACTOR}"
  echo "records=${expected_records}"
  echo "terminals=${TERMINALS}"
  echo "skews=${SKEWS}"
  echo "limits=${LIMITS}"
  echo "repeats=${REPEATS}"
  echo "order_mode=${ORDER_MODE}"
  echo "prewarm_runs=${PREWARM_RUNS}"
  echo "prewarm_limit=${PREWARM_LIMIT}"
  echo "warmup_seconds=${WARMUP_SECONDS}"
  echo "measurement_seconds=${MEASURE_SECONDS}"
  echo "operations_per_transaction=${OPERATIONS_PER_TRANSACTION}"
  echo "read_ratio=${READ_RATIO}"
  echo "weights=0,0,0,0,0,100 (ReadModifyWriteRecord dispatches the mixed transaction)"
  echo "prepare=${PREPARE}"
  echo "mysql_commit=$(git -C "${LAB_ROOT}/mysql-server" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "benchbase_ccbench_ycsb_patch=operationsPerTransaction/readRatio"
  echo "benchbase_commit=$(git -C "${LAB_ROOT}/benchbase" rev-parse HEAD 2>/dev/null || echo unknown)"
} >"${RUN_DIR}/metadata.txt"

echo "skew,repeat,limit,requests,tps,goodput,avg_ms,p50_ms,p95_ms,p99_ms,max_ms,deadlocks,rollbacks,unexpected_sql_errors,threads_running_max" >"${SUMMARY_CSV}"

for skew in ${SKEWS}; do
  warmup_config="${CONFIG_DIR}/skew-${skew}-warmup.xml"
  measure_config="${CONFIG_DIR}/skew-${skew}-measure.xml"

  if (( PREWARM_RUNS > 0 )); then
    echo "[skew ${skew}] pre-warming: ${PREWARM_RUNS} x ${WARMUP_SECONDS}s at limit=${PREWARM_LIMIT}"
    mysql_root -e "SET GLOBAL innodb_thread_concurrency=${PREWARM_LIMIT}"
    for prewarm_run in $(seq 1 "${PREWARM_RUNS}"); do
      prewarm_dir="${RUN_DIR}/skew-${skew}/prewarm/run-${prewarm_run}"
      mkdir -p "${prewarm_dir}"
      benchbase -b ycsb -c "${warmup_config}" --create=false --load=false --execute=true \
        -d "${prewarm_dir}" -im 1000 >"${RUN_DIR}/skew-${skew}/prewarm/run-${prewarm_run}.log" 2>&1
    done
  fi

  for repeat in $(seq 1 "${REPEATS}"); do
    run_limits="${LIMITS}"
    if [[ "${ORDER_MODE}" == "balanced" ]] && (( repeat % 2 == 0 )); then
      run_limits="$(reverse_words "${LIMITS}")"
    fi
    echo "[skew ${skew}, repeat ${repeat}/${REPEATS}] order: ${run_limits}"

    for limit in ${run_limits}; do
      point_dir="${RUN_DIR}/skew-${skew}/repeat-${repeat}/limit-${limit}"
      warmup_dir="${point_dir}/warmup"
      measure_dir="${point_dir}/measure"
      mkdir -p "${warmup_dir}" "${measure_dir}"

      echo "[skew ${skew}, repeat ${repeat}/${REPEATS}] limit=${limit}: warmup"
      mysql_root -e "SET GLOBAL innodb_thread_concurrency=${limit}"
      mysql_root -e "SELECT @@GLOBAL.innodb_thread_concurrency" >"${point_dir}/applied-limit.txt"
      benchbase -b ycsb -c "${warmup_config}" --create=false --load=false --execute=true \
        -d "${warmup_dir}" -im 1000 >"${point_dir}/warmup.log" 2>&1

      read_status >"${point_dir}/status-before.tsv"
      deadlocks_before="$(awk '$1=="Innodb_deadlocks"{print $2}' "${point_dir}/status-before.tsv")"
      rollbacks_before="$(awk '$1=="Com_rollback"{print $2}' "${point_dir}/status-before.tsv")"

      echo "[skew ${skew}, repeat ${repeat}/${REPEATS}] limit=${limit}: measure"
      (while true; do
        printf '%s\t' "$(date +%s%3N)"
        read_status | awk '$1=="Threads_running"{print $2}'
        sleep 1
      done) >"${point_dir}/threads-running.tsv" &
      sampler_pid=$!
      if ! benchbase -b ycsb -c "${measure_config}" --create=false --load=false --execute=true \
        -d "${measure_dir}" -im 1000 >"${point_dir}/measure.log" 2>&1; then
        kill "${sampler_pid}" 2>/dev/null || true
        wait "${sampler_pid}" 2>/dev/null || true
        echo "BenchBase failed; see ${point_dir}/measure.log" >&2
        exit 1
      fi
      kill "${sampler_pid}" 2>/dev/null || true
      wait "${sampler_pid}" 2>/dev/null || true

      read_status >"${point_dir}/status-after.tsv"
      deadlocks_after="$(awk '$1=="Innodb_deadlocks"{print $2}' "${point_dir}/status-after.tsv")"
      rollbacks_after="$(awk '$1=="Com_rollback"{print $2}' "${point_dir}/status-after.tsv")"
      deadlocks=$((deadlocks_after - deadlocks_before))
      rollbacks=$((rollbacks_after - rollbacks_before))
      threads_running_max="$(awk 'BEGIN{m=0}$2>m{m=$2}END{print m}' "${point_dir}/threads-running.tsv")"
      sql_errors="$(unexpected_sql_errors "${point_dir}/measure.log")"

      summary_json="$(find "${measure_dir}" -maxdepth 1 -name '*.summary.json' -print -quit)"
      [[ -n "${summary_json}" ]] || { echo "No summary JSON in ${measure_dir}" >&2; exit 1; }
      requests="$(json_number "${summary_json}" "Measured Requests")"
      tps="$(json_number "${summary_json}" "Throughput (requests/second)")"
      goodput="$(json_number "${summary_json}" "Goodput (requests/second)")"
      avg="$(json_number "${summary_json}" "Average Latency (microseconds)")"
      p50="$(json_number "${summary_json}" "Median Latency (microseconds)")"
      p95="$(json_number "${summary_json}" "95th Percentile Latency (microseconds)")"
      p99="$(json_number "${summary_json}" "99th Percentile Latency (microseconds)")"
      max="$(json_number "${summary_json}" "Maximum Latency (microseconds)")"

      awk -v s="${skew}" -v r="${repeat}" -v l="${limit}" -v q="${requests}" \
        -v t="${tps}" -v gp="${goodput}" -v a="${avg}" -v b="${p50}" -v c="${p95}" \
        -v d="${p99}" -v e="${max}" -v f="${deadlocks}" -v g="${rollbacks}" \
        -v h="${sql_errors}" -v i="${threads_running_max}" \
        'BEGIN{printf "%.2f,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d\n",s,r,l,q,t,gp,a/1000,b/1000,c/1000,d/1000,e/1000,f,g,h,i}' \
        >>"${SUMMARY_CSV}"
      tail -n 1 "${SUMMARY_CSV}"

      if [[ "${FAIL_ON_SQL_ERRORS}" == "1" ]] && (( sql_errors > 0 )); then
        echo "Unexpected SQL errors detected (${sql_errors}); refusing to continue with invalid measurements." >&2
        echo "See ${point_dir}/measure.log" >&2
        exit 1
      fi
    done
  done
done

mysql_root -e "SET GLOBAL innodb_thread_concurrency=0"

{
  echo "skew,limit,runs,avg_tps,stddev_tps,avg_goodput,stddev_goodput,avg_p95_ms,avg_p99_ms,avg_deadlocks,avg_rollbacks,total_unexpected_sql_errors"
  awk -F, 'NR > 1 {
    key=$1 SUBSEP $3
    skew[key]=$1; limit[key]=$3; n[key]++
    t[key]+=$5; t2[key]+=$5*$5
    gp[key]+=$6; gp2[key]+=$6*$6
    p95[key]+=$9; p99[key]+=$10
    dl[key]+=$12; rb[key]+=$13; err[key]+=$14
  } END {
    for (key in n) {
      tm=t[key]/n[key]; tv=t2[key]/n[key]-tm*tm; if (tv<0) tv=0
      gm=gp[key]/n[key]; gv=gp2[key]/n[key]-gm*gm; if (gv<0) gv=0
      printf "%.2f,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f,%d\n",
        skew[key],limit[key],n[key],tm,sqrt(tv),gm,sqrt(gv),p95[key]/n[key],p99[key]/n[key],dl[key]/n[key],rb[key]/n[key],err[key]
    }
  }' "${SUMMARY_CSV}" | sort -t, -k1,1n -k2,2n
} >"${AGGREGATE_CSV}"

{
  echo "skew,best_limit,avg_tps,avg_goodput,avg_p95_ms,avg_p99_ms,runs"
  awk -F, 'NR > 1 {
    s=$1
    if (!(s in seen) || $4 > best[s]) {
      seen[s]=1; best[s]=$4; row[s]=sprintf("%.2f,%d,%.3f,%.3f,%.3f,%.3f,%d",$1,$2,$4,$6,$8,$9,$3)
    }
  } END { for (s in row) print row[s] }' "${AGGREGATE_CSV}" | sort -t, -k1,1n
} >"${BEST_CSV}"

echo "YCSB skew sweep complete."
echo "Raw summary: ${SUMMARY_CSV}"
echo "Aggregates:   ${AGGREGATE_CSV}"
echo "Best limits:  ${BEST_CSV}"
