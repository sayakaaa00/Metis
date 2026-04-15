#!/usr/bin/env bash
set -euo pipefail

# 0.9 / 0.99 の skew について、summary_pinned_tuple_10000_release.csv 内の
# (skew,thread) ごとに 5回実験の throughput_tps / abort_rate の平均値を求め、
# 別 CSV として保存するスクリプト。

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
IN_DIR="$REPO_ROOT/experiments/paper_replication/optTAM_scan_results"
IN_FILE="$IN_DIR/summary_pinned_tuple_10000_release.csv"
OUT_FILE="$IN_DIR/highskew_avg_pinned_tuple_10000_release.csv"

if [[ ! -f "$IN_FILE" ]]; then
  echo "ERROR: input file not found: $IN_FILE" >&2
  exit 1
fi

awk 'BEGIN{FS=","; OFS=","}
     NR==1{next}  # ヘッダ行はスキップ
     ($1=="0.9" || $1=="0.99"){
       sk  = $1; th = $2;
       tps = $4 + 0; ab = $5 + 0;
       key = sk "\t" th;
       cnt[key]    += 1;
       sum_tps[key] += tps;
       sum_ab[key]  += ab;
     }
     END{
       print "skew","thread","mean_throughput_tps","mean_abort_rate";
       for (key in cnt) {
         split(key, a, "\t");
         sk = a[1]; th = a[2];
         mtps = sum_tps[key] / cnt[key];
         mab  = sum_ab[key]  / cnt[key];
         print sk, th, mtps, mab;
       }
     }' "$IN_FILE" | sort -t',' -k1,1 -k2,2n > "$OUT_FILE"

echo "Wrote averages to: $OUT_FILE" >&2
