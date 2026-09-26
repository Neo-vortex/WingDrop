// Squeezes the SoC for transfer threads: big-core affinity, raised priority and
// an ADPF performance hint session so the governor keeps clocks up.
#pragma once

#include <cstdint>

namespace perf {

// Number of "big" cores (max frequency within 80% of the fastest core).
int bigCoreCount();

// Call at the top of every hot transfer thread. Returns an opaque handle.
class ThreadBoost {
public:
    ThreadBoost();
    ~ThreadBoost();
    // Report how long one unit of work (a chunk) took; keeps the hint session
    // telling the scheduler we are behind target, i.e. run faster.
    void reportWork(int64_t nanos);

private:
    void* session_ = nullptr;
};

}  // namespace perf
