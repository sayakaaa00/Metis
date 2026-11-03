#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <numeric>
#include <random>
#include <stdexcept>
#include <vector>

#include "../zipf.hh"

// Immutable after initialization, shared by all TPC-C workers. A permutation
// preserves the sampler's probabilities while scattering popular item IDs across
// the Item and Stock key space. Reuse the same seed for every theta so the hot
// items do not move when only the skew changes.
struct TPCCItemZipfDistribution {
  std::vector<std::uint32_t> item_for_rank;
  double zetan = 0.0;

  void initialize(std::uint32_t item_count, double theta, std::uint64_t seed) {
    if (item_count < 15 || !std::isfinite(theta) || theta < 0.0 ||
        theta >= 1.0) {
      throw std::invalid_argument(
          "item Zipf requires at least 15 items and theta in [0, 1)");
    }
    item_for_rank.resize(item_count);
    std::iota(item_for_rank.begin(), item_for_rank.end(), 1U);
    std::mt19937_64 rng(seed);
    std::shuffle(item_for_rank.begin(), item_for_rank.end(), rng);
    zetan = FastZipf::zeta(item_count, theta);
  }

  std::uint32_t select(FastZipf& zipf) const {
    return item_for_rank[zipf() % item_for_rank.size()];
  }
};

inline TPCCItemZipfDistribution g_tpcc_item_zipf_distribution;
