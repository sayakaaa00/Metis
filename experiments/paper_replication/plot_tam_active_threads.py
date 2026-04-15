#!/usr/bin/env python3
import os
import re

import matplotlib.pyplot as plt


# ==== 設定（ここを書き換えて使う） ==========================================

# TAM の更新周期 [microseconds]
UPDATE_US = 1000.0  # 1ms ごとに更新

# 3フェーズの動的パターン設定
# compare_tam_dynamic.sh の PHASE*_SEC / 最適スレッド数と合わせる
PHASE_DURS_SEC = [20, 20, 20]
PHASE_OPT_THREADS = [32, 26, 21]
PHASE_NAMES = ["phase1", "phase2", "phase3"]


def parse_log(path):
    pattern = re.compile(r"active_threads=(\d+)")
    active_threads = []
    with open(path, "r") as f:
        for line in f:
            m = pattern.search(line)
            if not m:
                continue
            active_threads.append(int(m.group(1)))
    return active_threads


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Plot TAM active_threads over time from tam_active_threads_*.log")
    parser.add_argument("logfile", help="path to tam_active_threads_*.log")
    parser.add_argument("--out", help="output png path (default: same dir, basename + _active_threads.png)")

    args = parser.parse_args()

    active = parse_log(args.logfile)
    if not active:
        print(f"no active_threads lines found in {args.logfile}")
        return

    # 時間軸: 1サンプルごとに UPDATE_US だけ時間が進むとみなす
    # 先頭サンプルを t = 0ms, 2番目を t = UPDATE_US, ... とする
    dt_ms = UPDATE_US / 1000.0
    times_ms = [dt_ms * i for i in range(len(active))]

    plt.figure(figsize=(10, 4))
    ax = plt.gca()
    ax.plot(times_ms, active, drawstyle="steps-post")
    ax.set_xlabel("time [ms]")
    ax.set_ylabel("active_threads")

    # タイトル
    ax.set_title("LinUCB_TAM (3-phase dynamic)")
    # x 軸は必ず 0ms から開始する
    ax.set_xlim(left=0)

    # ==== 3フェーズごとの最適スレッドの水平線と最初到達点 ==================

    # フェーズ境界の時間 [ms]
    phase_starts_ms = [0.0]
    for d in PHASE_DURS_SEC[:-1]:
        phase_starts_ms.append(phase_starts_ms[-1] + d * 1000.0)
    phase_ends_ms = [s + d * 1000.0 for s, d in zip(phase_starts_ms, PHASE_DURS_SEC)]

    # 水平線を描画
    colors = ["red", "green", "blue"]
    for idx, opt_thr in enumerate(PHASE_OPT_THREADS):
        c = colors[idx % len(colors)]
        ax.axhline(y=opt_thr, color=c, linestyle="--", linewidth=1,
                   label=f"{PHASE_NAMES[idx]} optimal={opt_thr}")

    # 各フェーズで「最適スレッド数」に最初に到達した時刻を計算
    first_reach_times = [None] * len(PHASE_OPT_THREADS)
    for t, thr in zip(times_ms, active):
        for idx, (start_ms, end_ms, opt_thr) in enumerate(zip(phase_starts_ms, phase_ends_ms, PHASE_OPT_THREADS)):
            if first_reach_times[idx] is not None:
                continue  # すでに見つかっている
            if not (start_ms <= t < end_ms):
                continue
            if thr == opt_thr:
                first_reach_times[idx] = t

    # 最初の到達点が存在すれば，プロット上にマーカーを追加
    for idx, t in enumerate(first_reach_times):
        if t is None:
            continue
        opt_thr = PHASE_OPT_THREADS[idx]
        c = colors[idx % len(colors)]
        ax.scatter([t], [opt_thr], color=c, zorder=3,
                   label=f"{PHASE_NAMES[idx]} first reach ({t:.1f} ms)")

    ax.grid(True, linestyle="--", alpha=0.5)
    ax.legend(loc="best", fontsize=8)

    out_path = args.out
    if not out_path:
        base, _ = os.path.splitext(args.logfile)
        out_path = base + "_active_threads.png"

    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    print(f"saved plot to {out_path}")


if __name__ == "__main__":
    main()
