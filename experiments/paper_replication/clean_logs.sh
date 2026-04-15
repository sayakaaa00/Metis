#!/usr/bin/env bash
set -euo pipefail

# tam_active_threads_YYYYMMDD_HHMMSS.log を、指定した時間範囲で削除するスクリプト。
#
# 使い方:
#   bash clean_tam_logs_by_time.sh START END [--dry-run]
#   例: bash clean_tam_logs_by_time.sh 20260410_101200 20260410_102000 --dry-run
#
# START/END はファイル名に含まれるタイムスタンプ (YYYYMMDD_HHMMSS) をそのまま指定します。
# --dry-run を付けると、削除せずに対象ファイルだけ表示します。

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LOG_DIR="$REPO_ROOT/experiments/paper_replication/experiments/paper_replication/logs"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 START_TIMESTAMP END_TIMESTAMP [--dry-run]" >&2
  echo "  e.g. $0 20260410_101200 20260410_102000 --dry-run" >&2
  exit 1
fi

START_TS="$1"
END_TS="$2"
DRY_RUN=false
if [[ ${3:-} == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ ! -d "$LOG_DIR" ]]; then
  echo "log directory not found: $LOG_DIR" >&2
  exit 1
fi

echo "LOG_DIR = $LOG_DIR"
echo "start = $START_TS, end = $END_TS, dry_run = $DRY_RUN"

targets=()
shopt -s nullglob
for path in "$LOG_DIR"/tam_active_threads_*.log; do
  fname=$(basename "$path")
  # 例: tam_active_threads_20260410_101226.log からタイムスタンプ部分を抜き出す
  ts=${fname#tam_active_threads_}
  ts=${ts%.log}
  # 文字列比較で範囲チェック (YYYYMMDD_HHMMSS は辞書順 = 時刻順)
  if [[ "$ts" < "$START_TS" || "$ts" > "$END_TS" ]]; then
    continue
  fi
  targets+=("$path")
done
shopt -u nullglob

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "no log files found in range" >&2
  exit 0
fi

echo "targets (count=${#targets[@]}):"
for f in "${targets[@]}"; do
  echo "  $f"
done

if $DRY_RUN; then
  echo "dry-run mode: no files removed"
  exit 0
fi

echo
read -rp "remove these files? [y/N] " ans
case "$ans" in
  y|Y|yes|YES)
    ;;
  *)
    echo "aborted"
    exit 0
    ;;
esac

for f in "${targets[@]}"; do
  rm -f -- "$f"
  echo "removed $f"
done
