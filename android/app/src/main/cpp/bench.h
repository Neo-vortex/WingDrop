// Device benchmark for the transfer pipeline. Scores are unbounded, higher is better.
#pragma once

#include <vector>

namespace bench {

// Returns, in order (MB/s unless noted):
//  0 encrypt single-core      1 encrypt all cores
//  2 lz4 compress single      3 lz4 compress all cores
//  4 lz4 decompress single    5 lz4 decompress all cores
//  6 memcpy all cores         7 loopback TCP (4 streams)
//  8 threads used             9 single-core score
// 10 multi-core score        11 overall score
// 12 pipeline MB/s: estimated sustained send rate with LZ4 + encryption on
// 13 1 when encryption uses hardware AEGIS-128L, 0 for XChaCha20-Poly1305
std::vector<double> run();

}  // namespace bench
