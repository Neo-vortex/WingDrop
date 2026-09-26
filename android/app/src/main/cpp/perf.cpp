#include "perf.h"

#include <dlfcn.h>
#include <sched.h>
#include <sys/resource.h>
#include <unistd.h>

#include <cstdio>
#include <mutex>
#include <vector>

namespace perf {

namespace {

struct Cpus {
    cpu_set_t big;
    int bigCount = 0;
};

const Cpus& cpus() {
    static Cpus c = [] {
        Cpus r;
        CPU_ZERO(&r.big);
        long n = sysconf(_SC_NPROCESSORS_CONF);
        std::vector<long> freq(static_cast<size_t>(n > 0 ? n : 1), 0);
        long best = 0;
        for (long i = 0; i < n; ++i) {
            char path[96];
            snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%ld/cpufreq/cpuinfo_max_freq", i);
            if (FILE* f = fopen(path, "r")) {
                if (fscanf(f, "%ld", &freq[static_cast<size_t>(i)]) != 1) freq[static_cast<size_t>(i)] = 0;
                fclose(f);
            }
            if (freq[static_cast<size_t>(i)] > best) best = freq[static_cast<size_t>(i)];
        }
        for (long i = 0; i < n; ++i) {
            // Unknown frequencies (sysfs blocked): treat every core as big.
            if (best == 0 || freq[static_cast<size_t>(i)] * 10 >= best * 8) {
                CPU_SET(static_cast<int>(i), &r.big);
                r.bigCount++;
            }
        }
        // A lone prime core would serialise everything: widen to all cores.
        if (r.bigCount < 2) {
            CPU_ZERO(&r.big);
            for (long i = 0; i < n; ++i) CPU_SET(static_cast<int>(i), &r.big);
            r.bigCount = static_cast<int>(n);
        }
        return r;
    }();
    return c;
}

// ADPF (APerformanceHint, NDK API 33+), resolved at runtime so minSdk stays 29.
using GetManagerFn = void* (*)();
using CreateSessionFn = void* (*)(void*, const int32_t*, size_t, int64_t);
using ReportFn = int (*)(void*, int64_t);
using CloseFn = void (*)(void*);

struct Adpf {
    GetManagerFn getManager = nullptr;
    CreateSessionFn create = nullptr;
    ReportFn report = nullptr;
    CloseFn close = nullptr;
    void* manager = nullptr;
};

const Adpf& adpf() {
    static Adpf a = [] {
        Adpf r;
        void* lib = dlopen("libandroid.so", RTLD_NOW);
        if (!lib) return r;
        r.getManager = reinterpret_cast<GetManagerFn>(dlsym(lib, "APerformanceHint_getManager"));
        r.create = reinterpret_cast<CreateSessionFn>(dlsym(lib, "APerformanceHint_createSession"));
        r.report = reinterpret_cast<ReportFn>(dlsym(lib, "APerformanceHint_reportActualWorkDuration"));
        r.close = reinterpret_cast<CloseFn>(dlsym(lib, "APerformanceHint_closeSession"));
        if (r.getManager && r.create && r.report && r.close) r.manager = r.getManager();
        return r;
    }();
    return a;
}

// Tight target: every chunk "overruns" it, so the hint asks for more speed.
constexpr int64_t kTargetNanos = 500 * 1000;

}  // namespace

int bigCoreCount() { return cpus().bigCount; }

ThreadBoost::ThreadBoost() {
    sched_setaffinity(0, sizeof(cpu_set_t), &cpus().big);
    // Android grants apps RLIMIT_NICE down to -20; -10 matches THREAD_PRIORITY_URGENT_DISPLAY territory.
    setpriority(PRIO_PROCESS, 0, -10);
    const Adpf& a = adpf();
    if (a.manager) {
        int32_t tid = gettid();
        session_ = a.create(a.manager, &tid, 1, kTargetNanos);
    }
}

ThreadBoost::~ThreadBoost() {
    if (session_) adpf().close(session_);
}

void ThreadBoost::reportWork(int64_t nanos) {
    if (session_ && nanos > 0) adpf().report(session_, nanos);
}

}  // namespace perf
