#!/usr/bin/env bash
# Build the binaries used in the Metis experiments and the mimalloc shared
# library that the experiment scripts preload (LD_PRELOAD).
#   ./build.sh [extra cmake arguments]
# Output: $BUILD (default build_release)/silo/{ycsb,tpcc}_silo_{nobackoff,backoff},
#         $BUILD/silo/ycsb_silo_breakdown,
#         $BUILD/cc/{cicada,ermia}/{ycsb,tpcc}_*.exe,
#         $BUILD/mimalloc_override/libmimalloc.so
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD=${BUILD:-$ROOT/build_release}
JOBS=${JOBS:-$(nproc)}

cmake -S "$ROOT" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release "$@"
cmake --build "$BUILD" -j "$JOBS" --target \
  ycsb_silo_nobackoff ycsb_silo_backoff tpcc_silo_nobackoff tpcc_silo_backoff \
  ycsb_silo_breakdown \
  ycsb_cicada.exe tpcc_cicada.exe ycsb_ermia.exe tpcc_ermia.exe

# mimalloc as a shared library, from the same source that CMake fetched.
src=$(sed -n 's/^libmimalloc_SOURCE_DIR:STATIC=//p' "$BUILD/CMakeCache.txt")
cmake -S "$src" -B "$BUILD/mimalloc_override" -DCMAKE_BUILD_TYPE=Release \
  -DMI_BUILD_SHARED=ON -DMI_BUILD_STATIC=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF
cmake --build "$BUILD/mimalloc_override" -j "$JOBS"
