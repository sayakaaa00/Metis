#!/usr/bin/env bash
set -Eeuo pipefail

# Sweep BenchBase active_terminals while keeping the total number of terminal
# workers and persistent JDBC connections fixed at 96. MySQL's own
# innodb_thread_concurrency is held at 0 (disabled) for the entire experiment.
#
# Quick smoke test:
#   SKEWS="0.95" ACTIVE_TERMINALS="8 24 96" REPEATS=1 \
#     WARMUP_SECONDS=5 MEASURE_SECONDS=10 \
#     ./experiments/mysql/run_ycsb_active_terminals_sweep.sh
#
# Default exploratory sweep:
#   ./experiments/mysql/run_ycsb_active_terminals_sweep.sh
#
# Common overrides:
#   SKEWS="0.70 0.80 0.90 0.95"
#   ACTIVE_TERMINALS="1 2 4 8 12 16 24 32 48 64 80 96"
#   REPEATS=3 ORDER_MODE=balanced
#   WARMUP_SECONDS=30 MEASURE_SECONDS=60 COOLDOWN_SECONDS=5
#   SCALE_FACTOR=10 OPERATIONS_PER_TRANSACTION=10 READ_RATIO=50
#   MAX_RETRIES=3 PREPARE=auto|0|1 FAIL_ON_SQL_ERRORS=1

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="${LAB_ROOT:-/home/ubuntu/metis-mysql-lab}"
BENCHBASE_DIR="${BENCHBASE_DIR:-${LAB_ROOT}/benchbase-run}"
MYSQL_BIN_DIR="${MYSQL_BIN_DIR:-${LAB_ROOT}/mysql-build-baseline/runtime_output_directory}"
MYSQL_CONFIG="${MYSQL_CONFIG:-${LAB_ROOT}/config/my-baseline.cnf}"
MYSQL_SOCKET="${MYSQL_SOCKET:-${LAB_ROOT}/run/mysql-baseline.sock}"
CONFIG_TEMPLATE="${CONFIG_TEMPLATE:-${SCRIPT_DIR}/ycsb-active-terminals-template.xml}"
RESULT_ROOT="${RESULT_ROOT:-${LAB_ROOT}/results/ycsb-active-terminals-sweep}"

# Fixed by design: 96 worker objects, Java threads, and persistent JDBC connections.
readonly TERMINALS=96

SKEWS="${SKEWS:-0.70 0.80 0.90 0.95}"
ACTIVE_TERMINALS="${ACTIVE_TERMINALS:-1 2 4 8 12 16 24 32 48 64 80 96}"
REPEATS="${REPEATS:-3}"
ORDER_MODE="${ORDER_MODE:-balanced}"
WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
MEASURE_SECONDS="${MEASURE_SECONDS:-60}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-5}"
SCALE_FACTOR="${SCALE_FACTOR:-10}"
OPERATIONS_PER_TRANSACTION="${OPERATIONS_PER_TRANSACTION:-10}"
READ_RATIO="${READ_RATIO:-50}"
MAX_RETRIES="${MAX_RETRIES:-3}"
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

bench_pid=""
sampler_pid=""

mysql_root() {
  "${MYSQL}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot \
    --batch --skip-column-names "$@"
}

benchbase() {
  (cd "${BENCHBASE_DIR}" && java -jar "${BENCHBASE_JAR}" "$@")
}

require_file() {
  [[ -f "$1" ]] || { echo "Required file not found: $1" >&2; exit 1; }
}

reverse_words() {
  local result="" word
  for word in $1; do
    result="${word} ${result}"
  done
  printf '%s\n' "${result% }"
}

render_config() {
  local skew="$1" active="$2" output="$3"
  sed \
    -e "s/@SCALE_FACTOR@/${SCALE_FACTOR}/g" \
    -e "s/@SKEW@/${skew}/g" \
    -e "s/@OPERATIONS_PER_TRANSACTION@/${OPERATIONS_PER_TRANSACTION}/g" \
    -e "s/@READ_RATIO@/${READ_RATIO}/g" \
    -e "s/@MAX_RETRIES@/${MAX_RETRIES}/g" \
    -e "s/@WARMUP_SECONDS@/${WARMUP_SECONDS}/g" \
    -e "s/@MEASURE_SECONDS@/${MEASURE_SECONDS}/g" \
    -e "s/@ACTIVE_TERMINALS@/${active}/g" \
    "${CONFIG_TEMPLATE}" >"${output}"

  if grep -Eq '@[A-Z_]+@' "${output}"; then
    echo "Unresolved placeholder in generated config: ${output}" >&2
    exit 1
  fi
  grep -Eq "<terminals>[[:space:]]*${TERMINALS}[[:space:]]*</terminals>" "${output}" || {
    echo "Generated config does not keep terminals fixed at ${TERMINALS}: ${output}" >&2
    exit 1
  }
  grep -Eq "<active_terminals>[[:space:]]*${active}[[:space:]]*</active_terminals>" "${output}" || {
    echo "Generated config does not set active_terminals=${active}: ${output}" >&2
    exit 1
  }
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "${output}"
  fi
}

read_status() {
  mysql_root -e "SHOW GLOBAL STATUS WHERE Variable_name IN (
    'Com_commit',
    'Com_rollback',
    'Innodb_deadlocks',
    'Innodb_row_lock_time',
    'Innodb_row_lock_waits',
    'Threads_connected',
    'Threads_running'
  )"
}

status_value() {
  local file="$1" variable="$2"
  awk -v variable="${variable}" '$1 == variable { print $2; exit }' "${file}"
}

sample_server_state() {
  local output="$1"
  printf 'epoch_ms\tthreads_connected\tthreads_running\tinnodb_transactions\n' >"${output}"
  while [[ -n "${bench_pid}" ]] && kill -0 "${bench_pid}" 2>/dev/null; do
    mysql_root -e "SELECT
      CAST(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 AS UNSIGNED),
      MAX(CASE WHEN VARIABLE_NAME='Threads_connected' THEN VARIABLE_VALUE END),
      MAX(CASE WHEN VARIABLE_NAME='Threads_running' THEN VARIABLE_VALUE END),
      (SELECT COUNT(*) FROM information_schema.innodb_trx)
    FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN ('Threads_connected','Threads_running')" \
      >>"${output}" 2>/dev/null || true
    sleep 1
  done
}

json_number() {
  awk -v key="$2" '
    index($0, "\"" key "\"") {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[,[:space:]]*$/, "")
      print
      exit
    }
  ' "$1"
}

unexpected_sql_errors() {
  awk '
    /Unexpected SQL Errors:/ { inside=1; next }
    /Unknown Status Transactions:/ { inside=0 }
    inside && /\[[[:space:]]*[0-9]+\]/ {
      value=$0
      sub(/^.*\[/, "", value)
      sub(/\].*$/, "", value)
      gsub(/[[:space:]]/, "", value)
      total += value
    }
    END { print total + 0 }
  ' "$1"
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "${sampler_pid}" ]]; then
    kill "${sampler_pid}" 2>/dev/null || true
    wait "${sampler_pid}" 2>/dev/null || true
  fi
  if [[ -n "${bench_pid}" ]]; then
    kill "${bench_pid}" 2>/dev/null || true
    wait "${bench_pid}" 2>/dev/null || true
  fi
  if [[ -x "${MYSQLADMIN}" ]] && \
      "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping \
        >/dev/null 2>&1; then
    mysql_root -e "SET GLOBAL innodb_thread_concurrency=0" || true
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

for file in "${MYSQLD}" "${MYSQL}" "${BENCHBASE_JAR}" "${CONFIG_TEMPLATE}"; do
  require_file "${file}"
done
command -v "${JAVAP}" >/dev/null || {
  echo "javap is required to verify the patched BenchBase JAR" >&2
  exit 1
}

benchbase_ycsb_api="$(
  "${JAVAP}" -classpath "${BENCHBASE_JAR}" -private \
    com.oltpbenchmark.benchmarks.ycsb.YCSBBenchmark 2>/dev/null || true
)"
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

[[ "${REPEATS}" =~ ^[1-9][0-9]*$ ]] || {
  echo "REPEATS must be a positive integer" >&2; exit 2;
}
[[ "${WARMUP_SECONDS}" =~ ^[0-9]+$ ]] || {
  echo "WARMUP_SECONDS must be a non-negative integer" >&2; exit 2;
}
[[ "${MEASURE_SECONDS}" =~ ^[1-9][0-9]*$ ]] || {
  echo "MEASURE_SECONDS must be a positive integer" >&2; exit 2;
}
[[ "${COOLDOWN_SECONDS}" =~ ^[0-9]+$ ]] || {
  echo "COOLDOWN_SECONDS must be a non-negative integer" >&2; exit 2;
}
[[ "${SCALE_FACTOR}" =~ ^[1-9][0-9]*$ ]] || {
  echo "SCALE_FACTOR must be a positive integer" >&2; exit 2;
}
[[ "${OPERATIONS_PER_TRANSACTION}" =~ ^[1-9][0-9]*$ ]] || {
  echo "OPERATIONS_PER_TRANSACTION must be a positive integer" >&2; exit 2;
}
[[ "${READ_RATIO}" =~ ^[0-9]+$ ]] && (( READ_RATIO <= 100 )) || {
  echo "READ_RATIO must be an integer from 0 to 100" >&2; exit 2;
}
[[ "${MAX_RETRIES}" =~ ^[1-9][0-9]*$ ]] || {
  echo "MAX_RETRIES must be a positive integer" >&2; exit 2;
}

for skew in ${SKEWS}; do
  awk -v value="${skew}" 'BEGIN { exit !(value > 0 && value < 1) }' || {
    echo "Every skew must be greater than 0 and less than 1: ${skew}" >&2
    exit 2
  }
done

has_baseline=0
for active in ${ACTIVE_TERMINALS}; do
  [[ "${active}" =~ ^[1-9][0-9]*$ ]] && (( active <= TERMINALS )) || {
    echo "Every active terminal count must be an integer from 1 to ${TERMINALS}: ${active}" >&2
    exit 2
  }
  if (( active == TERMINALS )); then
    has_baseline=1
  fi
done
(( has_baseline == 1 )) || {
  echo "ACTIVE_TERMINALS must contain ${TERMINALS}, the no-admission baseline." >&2
  exit 2
}

mkdir -p "${CONFIG_DIR}"

if ! "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping \
    >/dev/null 2>&1; then
  echo "Starting baseline MySQL..."
  "${MYSQLD}" --defaults-file="${MYSQL_CONFIG}" --daemonize
fi
for _ in $(seq 1 60); do
  "${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping \
    >/dev/null 2>&1 && break
  sleep 1
done
"${MYSQLADMIN}" --protocol=socket --socket="${MYSQL_SOCKET}" -uroot ping >/dev/null

# This experiment controls concurrency only at BenchBase's transaction boundary.
mysql_root -e "SET GLOBAL innodb_thread_concurrency=0"
applied_innodb_limit="$(mysql_root -e 'SELECT @@GLOBAL.innodb_thread_concurrency')"
[[ "${applied_innodb_limit}" == "0" ]] || {
  echo "Failed to disable innodb_thread_concurrency" >&2
  exit 1
}

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
prepare_config="${CONFIG_DIR}/prepare.xml"
render_config "${first_skew}" "${TERMINALS}" "${prepare_config}"
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

configured_cpus="$(getconf _NPROCESSORS_CONF 2>/dev/null || echo unknown)"
if [[ "${configured_cpus}" != "unknown" && "${configured_cpus}" != "${TERMINALS}" ]]; then
  echo "WARNING: configured CPUs=${configured_cpus}, but terminals are intentionally fixed at ${TERMINALS}." >&2
fi

{
  echo "run_id=${RUN_ID}"
  echo "utc_started=$(date -u +%FT%TZ)"
  echo "benchmark=ycsb-ccbench-mixed-active-terminals"
  echo "mysql_version=$(mysql_root -e 'SELECT VERSION()')"
  echo "configured_cpus=${configured_cpus}"
  echo "terminals=${TERMINALS}"
  echo "active_terminals=${ACTIVE_TERMINALS}"
  echo "innodb_thread_concurrency=0"
  echo "scale_factor=${SCALE_FACTOR}"
  echo "records=${expected_records}"
  echo "skews=${SKEWS}"
  echo "repeats=${REPEATS}"
  echo "order_mode=${ORDER_MODE}"
  echo "warmup_seconds=${WARMUP_SECONDS}"
  echo "measurement_seconds=${MEASURE_SECONDS}"
  echo "cooldown_seconds=${COOLDOWN_SECONDS}"
  echo "operations_per_transaction=${OPERATIONS_PER_TRANSACTION}"
  echo "read_ratio=${READ_RATIO}"
  echo "max_retries=${MAX_RETRIES}"
  echo "weights=0,0,0,0,0,100 (ReadModifyWriteRecord dispatches the mixed transaction)"
  echo "prepare=${PREPARE}"
  echo "mysql_commit=$(git -C "${LAB_ROOT}/mysql-server" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "benchbase_commit=$(git -C "${LAB_ROOT}/benchbase" rev-parse HEAD 2>/dev/null || echo unknown)"
} >"${RUN_DIR}/metadata.txt"

echo "skew,repeat,active_terminals,requests,benchbase_tps,avg_ms,p50_ms,p95_ms,p99_ms,max_ms,server_window_s,commits,commit_tps,rollbacks,deadlocks,row_lock_waits,row_lock_time_ms,threads_running_max,innodb_trx_max,unexpected_sql_errors" \
  >"${SUMMARY_CSV}"

for skew in ${SKEWS}; do
  for repeat in $(seq 1 "${REPEATS}"); do
    run_values="${ACTIVE_TERMINALS}"
    if [[ "${ORDER_MODE}" == "balanced" ]] && (( repeat % 2 == 0 )); then
      run_values="$(reverse_words "${ACTIVE_TERMINALS}")"
    fi
    echo "[skew ${skew}, repeat ${repeat}/${REPEATS}] order: ${run_values}"

    for active in ${run_values}; do
      point_dir="${RUN_DIR}/skew-${skew}/repeat-${repeat}/active-${active}"
      result_dir="${point_dir}/benchbase"
      config="${CONFIG_DIR}/skew-${skew}-active-${active}.xml"
      log_file="${point_dir}/benchbase.log"
      mkdir -p "${point_dir}" "${result_dir}"
      render_config "${skew}" "${active}" "${config}"

      mysql_root -e "SET GLOBAL innodb_thread_concurrency=0"
      echo "[skew ${skew}, repeat ${repeat}/${REPEATS}] active_terminals=${active}"

      benchbase -b ycsb -c "${config}" --create=false --load=false --execute=true \
        -d "${result_dir}" -im 1000 >"${log_file}" 2>&1 &
      bench_pid=$!

      measure_marker='Warmup complete, starting measurements.'
      while ! grep -Fq "${measure_marker}" "${log_file}" 2>/dev/null; do
        if ! kill -0 "${bench_pid}" 2>/dev/null; then
          if wait "${bench_pid}"; then
            bench_status=0
          else
            bench_status=$?
          fi
          bench_pid=""
          echo "BenchBase exited before measurement (status=${bench_status}); see ${log_file}" >&2
          exit 1
        fi
        sleep 0.1
      done

      grep -Fq "ActiveWorkers=${active}" "${log_file}" || {
        echo "BenchBase did not report ActiveWorkers=${active}; see ${log_file}" >&2
        exit 1
      }

      measure_start_ms="$(date +%s%3N)"
      read_status >"${point_dir}/status-measure-start.tsv"
      sample_server_state "${point_dir}/server-samples.tsv" &
      sampler_pid=$!

      if wait "${bench_pid}"; then
        bench_status=0
      else
        bench_status=$?
      fi
      bench_pid=""

      kill "${sampler_pid}" 2>/dev/null || true
      wait "${sampler_pid}" 2>/dev/null || true
      sampler_pid=""
      measure_end_ms="$(date +%s%3N)"
      read_status >"${point_dir}/status-measure-end.tsv"

      if (( bench_status != 0 )); then
        echo "BenchBase failed with status ${bench_status}; see ${log_file}" >&2
        exit 1
      fi

      summary_json="$(find "${result_dir}" -maxdepth 1 -name '*.summary.json' -print -quit)"
      [[ -n "${summary_json}" ]] || {
        echo "No summary JSON in ${result_dir}" >&2
        exit 1
      }

      requests="$(json_number "${summary_json}" "Measured Requests")"
      tps="$(json_number "${summary_json}" "Throughput (requests/second)")"
      avg="$(json_number "${summary_json}" "Average Latency (microseconds)")"
      p50="$(json_number "${summary_json}" "Median Latency (microseconds)")"
      p95="$(json_number "${summary_json}" "95th Percentile Latency (microseconds)")"
      p99="$(json_number "${summary_json}" "99th Percentile Latency (microseconds)")"
      max="$(json_number "${summary_json}" "Maximum Latency (microseconds)")"
      sql_errors="$(unexpected_sql_errors "${log_file}")"

      commits_before="$(status_value "${point_dir}/status-measure-start.tsv" Com_commit)"
      commits_after="$(status_value "${point_dir}/status-measure-end.tsv" Com_commit)"
      rollbacks_before="$(status_value "${point_dir}/status-measure-start.tsv" Com_rollback)"
      rollbacks_after="$(status_value "${point_dir}/status-measure-end.tsv" Com_rollback)"
      deadlocks_before="$(status_value "${point_dir}/status-measure-start.tsv" Innodb_deadlocks)"
      deadlocks_after="$(status_value "${point_dir}/status-measure-end.tsv" Innodb_deadlocks)"
      lock_waits_before="$(status_value "${point_dir}/status-measure-start.tsv" Innodb_row_lock_waits)"
      lock_waits_after="$(status_value "${point_dir}/status-measure-end.tsv" Innodb_row_lock_waits)"
      lock_time_before="$(status_value "${point_dir}/status-measure-start.tsv" Innodb_row_lock_time)"
      lock_time_after="$(status_value "${point_dir}/status-measure-end.tsv" Innodb_row_lock_time)"

      commits=$((commits_after - commits_before))
      rollbacks=$((rollbacks_after - rollbacks_before))
      deadlocks=$((deadlocks_after - deadlocks_before))
      row_lock_waits=$((lock_waits_after - lock_waits_before))
      row_lock_time_ms=$((lock_time_after - lock_time_before))
      server_window_ms=$((measure_end_ms - measure_start_ms))
      commit_tps="$(awk -v commits="${commits}" -v elapsed_ms="${server_window_ms}" \
        'BEGIN { if (elapsed_ms <= 0) print 0; else printf "%.3f", commits * 1000.0 / elapsed_ms }')"
      server_window_s="$(awk -v elapsed_ms="${server_window_ms}" \
        'BEGIN { printf "%.3f", elapsed_ms / 1000.0 }')"
      threads_running_max="$(awk 'NR>1 && $3>m {m=$3} END {print m+0}' "${point_dir}/server-samples.tsv")"
      innodb_trx_max="$(awk 'NR>1 && $4>m {m=$4} END {print m+0}' "${point_dir}/server-samples.tsv")"

      awk -v s="${skew}" -v r="${repeat}" -v n="${active}" -v q="${requests}" \
        -v t="${tps}" -v a="${avg}" -v b="${p50}" -v c="${p95}" -v d="${p99}" \
        -v e="${max}" -v w="${server_window_s}" -v cm="${commits}" -v ct="${commit_tps}" \
        -v rb="${rollbacks}" -v dl="${deadlocks}" -v lw="${row_lock_waits}" \
        -v lt="${row_lock_time_ms}" -v tr="${threads_running_max}" -v tx="${innodb_trx_max}" \
        -v er="${sql_errors}" \
        'BEGIN {
          printf "%.2f,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%d,%d,%d,%d,%d,%d,%d\n",
            s,r,n,q,t,a/1000,b/1000,c/1000,d/1000,e/1000,w,cm,ct,rb,dl,lw,lt,tr,tx,er
        }' >>"${SUMMARY_CSV}"
      tail -n 1 "${SUMMARY_CSV}"

      if [[ "${FAIL_ON_SQL_ERRORS}" == "1" ]] && (( sql_errors > 0 )); then
        echo "Unexpected SQL errors detected (${sql_errors}); refusing to continue." >&2
        echo "See ${log_file}" >&2
        exit 1
      fi

      if (( COOLDOWN_SECONDS > 0 )); then
        sleep "${COOLDOWN_SECONDS}"
      fi
    done
  done
done

{
  echo "skew,active_terminals,runs,avg_benchbase_tps,stddev_benchbase_tps,avg_commit_tps,stddev_commit_tps,avg_p95_ms,avg_p99_ms,avg_rollbacks,avg_deadlocks,avg_row_lock_waits,avg_innodb_trx_max,avg_threads_running_max,total_unexpected_sql_errors"
  awk -F, 'NR > 1 {
    key=$1 SUBSEP $3
    skew[key]=$1; active[key]=$3; n[key]++
    t[key]+=$5; t2[key]+=$5*$5
    ct[key]+=$13; ct2[key]+=$13*$13
    p95[key]+=$8; p99[key]+=$9
    rb[key]+=$14; dl[key]+=$15; lw[key]+=$16
    tr[key]+=$18; tx[key]+=$19; err[key]+=$20
  } END {
    for (key in n) {
      tm=t[key]/n[key]; tv=t2[key]/n[key]-tm*tm; if (tv<0) tv=0
      cm=ct[key]/n[key]; cv=ct2[key]/n[key]-cm*cm; if (cv<0) cv=0
      printf "%.2f,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%.2f,%.2f,%d\n",
        skew[key],active[key],n[key],tm,sqrt(tv),cm,sqrt(cv),p95[key]/n[key],p99[key]/n[key],
        rb[key]/n[key],dl[key]/n[key],lw[key]/n[key],tx[key]/n[key],tr[key]/n[key],err[key]
    }
  }' "${SUMMARY_CSV}" | sort -t, -k1,1n -k2,2n
} >"${AGGREGATE_CSV}"

{
  echo "skew,best_active_terminals,avg_benchbase_tps,baseline_96_tps,gain_vs_96_pct,avg_commit_tps,avg_p95_ms,avg_p99_ms,runs"
  awk -F, -v baseline_active="${TERMINALS}" 'NR > 1 {
    s=$1
    if ($2 == baseline_active) baseline[s]=$4
    if (!(s in seen) || $4 > best[s]) {
      seen[s]=1; best[s]=$4; best_active[s]=$2; commit[s]=$6; p95[s]=$8; p99[s]=$9; runs[s]=$3
    }
  } END {
    for (s in best) {
      gain=(baseline[s] > 0) ? (best[s]/baseline[s]-1)*100 : 0
      printf "%.2f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d\n",
        s,best_active[s],best[s],baseline[s],gain,commit[s],p95[s],p99[s],runs[s]
    }
  }' "${AGGREGATE_CSV}" | sort -t, -k1,1n
} >"${BEST_CSV}"

echo "YCSB active-terminals sweep complete."
echo "Run metadata: ${RUN_DIR}/metadata.txt"
echo "Raw summary: ${SUMMARY_CSV}"
echo "Aggregates:   ${AGGREGATE_CSV}"
echo "Best values:  ${BEST_CSV}"
