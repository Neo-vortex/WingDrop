#include "bench.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <functional>
#include <memory>
#include <random>
#include <thread>

#include "aegis.h"
#include "perf.h"

extern "C" {
#include "third_party/lz4.h"
#include "third_party/monocypher.h"
}

namespace bench {

namespace {

constexpr size_t kBlock = 1u << 20;   // 1 MiB work unit, like a small chunk
constexpr double kSeconds = 0.6;      // per measurement

double now() {
    using namespace std::chrono;
    return duration_cast<duration<double>>(steady_clock::now().time_since_epoch()).count();
}

// Semi-compressible data (~2:1 with LZ4), closer to documents/APKs than
// pure text or pure noise.
void fill(uint8_t* p, size_t n, uint32_t seed) {
    std::mt19937 rng(seed);
    static const char* words[] = {"vortex ", "share ", "packet ", "stream ", "android ", "chunk ", "0x1f2e ", "\n"};
    size_t i = 0;
    while (i < n) {
        if (rng() % 3 == 0) {
            p[i++] = static_cast<uint8_t>(rng());
        } else {
            const char* w = words[rng() % 8];
            for (size_t k = 0; w[k] && i < n; ++k) p[i++] = static_cast<uint8_t>(w[k]);
        }
    }
}

// Runs `work` (processing one block, returns bytes) on `threads` threads for
// kSeconds and returns MB/s.
double measure(int threads, const std::function<size_t(int, std::vector<uint8_t>&)>& setupAndWork) {
    std::atomic<bool> go{false}, stop{false};
    std::atomic<uint64_t> bytes{0};
    std::vector<std::thread> ts;
    for (int t = 0; t < threads; ++t) {
        ts.emplace_back([&, t] {
            perf::ThreadBoost boost;
            std::vector<uint8_t> state;
            setupAndWork(-1 - t, state);  // setup call
            while (!go) std::this_thread::yield();
            uint64_t local = 0;
            while (!stop) local += setupAndWork(t, state);
            bytes += local;
        });
    }
    double t0 = now();
    go = true;
    std::this_thread::sleep_for(std::chrono::duration<double>(kSeconds));
    stop = true;
    for (auto& t : ts) t.join();
    return static_cast<double>(bytes) / (now() - t0) / 1e6;
}

// State layout per thread: [input kBlock][scratch bound][output kBlock]
size_t stateSize() { return kBlock + static_cast<size_t>(LZ4_compressBound(kBlock)) + 16 + kBlock; }

double encrypt(int threads) {
    return measure(threads, [](int t, std::vector<uint8_t>& s) -> size_t {
        if (t < 0) {
            s.resize(stateSize());
            fill(s.data(), kBlock, static_cast<uint32_t>(-t));
            return 0;
        }
        uint8_t key[32] = {1}, nonce[24] = {2}, mac[16];
        // The cipher a transfer would actually use on this phone.
        if (aegis::available())
            aegis::encrypt(s.data() + kBlock, mac, s.data(), kBlock, nullptr, 0, key, nonce);
        else
            crypto_aead_lock(s.data() + kBlock, mac, key, nonce, nullptr, 0, s.data(), kBlock);
        return kBlock;
    });
}

double compress(int threads) {
    return measure(threads, [](int t, std::vector<uint8_t>& s) -> size_t {
        if (t < 0) {
            s.resize(stateSize());
            fill(s.data(), kBlock, static_cast<uint32_t>(-t));
            return 0;
        }
        LZ4_compress_default(reinterpret_cast<const char*>(s.data()), reinterpret_cast<char*>(s.data() + kBlock),
                             kBlock, LZ4_compressBound(kBlock));
        return kBlock;
    });
}

double decompress(int threads) {
    return measure(threads, [](int t, std::vector<uint8_t>& s) -> size_t {
        const size_t out = kBlock + static_cast<size_t>(LZ4_compressBound(kBlock)) + 16;
        if (t < 0) {
            s.resize(stateSize() + 4);
            fill(s.data(), kBlock, static_cast<uint32_t>(-t));
            int z = LZ4_compress_default(reinterpret_cast<const char*>(s.data()), reinterpret_cast<char*>(s.data() + kBlock),
                                         kBlock, LZ4_compressBound(kBlock));
            memcpy(s.data() + s.size() - 4, &z, 4);
            return 0;
        }
        int z;
        memcpy(&z, s.data() + s.size() - 4, 4);
        LZ4_decompress_safe(reinterpret_cast<const char*>(s.data() + kBlock), reinterpret_cast<char*>(s.data() + out), z,
                            kBlock);
        return kBlock;
    });
}

double memBandwidth(int threads) {
    return measure(threads, [](int t, std::vector<uint8_t>& s) -> size_t {
        if (t < 0) {
            s.resize(16u << 20);  // bigger than caches
            memset(s.data(), 1, s.size());
            return 0;
        }
        const size_t half = s.size() / 2;
        memcpy(s.data() + half, s.data(), half);
        return half;
    });
}

// Real kernel TCP path over loopback, 4 parallel streams, like a transfer.
double loopbackTcp() {
    int lfd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (lfd < 0) return 0;
    int one = 1, buf = 8 << 20;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(lfd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t sl = sizeof sa;
    if (bind(lfd, reinterpret_cast<sockaddr*>(&sa), sizeof sa) < 0 || listen(lfd, 8) < 0 ||
        getsockname(lfd, reinterpret_cast<sockaddr*>(&sa), &sl) < 0) {
        close(lfd);
        return 0;
    }
    constexpr int kStreams = 4;
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> bytes{0};
    std::vector<std::thread> ts;
    for (int i = 0; i < kStreams; ++i) {
        ts.emplace_back([&] {  // receiver
            perf::ThreadBoost boost;
            int fd = accept4(lfd, nullptr, nullptr, SOCK_CLOEXEC);
            if (fd < 0) return;
            std::unique_ptr<uint8_t[]> b(new uint8_t[kBlock]);
            ssize_t n;
            while ((n = recv(fd, b.get(), kBlock, 0)) > 0) bytes += static_cast<uint64_t>(n);
            close(fd);
        });
        ts.emplace_back([&] {  // sender
            perf::ThreadBoost boost;
            int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);
            if (connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof sa) < 0) {
                close(fd);
                return;
            }
            std::unique_ptr<uint8_t[]> b(new uint8_t[kBlock]());
            while (!stop && send(fd, b.get(), kBlock, MSG_NOSIGNAL) > 0) {
            }
            shutdown(fd, SHUT_WR);
            close(fd);
        });
    }
    double t0 = now();
    std::this_thread::sleep_for(std::chrono::duration<double>(kSeconds * 1.5));
    stop = true;
    double secs = now() - t0;
    uint64_t total = bytes.load();
    for (auto& t : ts) t.join();
    close(lfd);
    return static_cast<double>(total) / secs / 1e6;
}

double geomean(std::initializer_list<double> v) {
    double s = 0;
    for (double x : v) s += std::log(std::max(x, 1.0));
    return std::exp(s / static_cast<double>(v.size()));
}

}  // namespace

std::vector<double> run() {
    const int threads = std::max(1, static_cast<int>(std::thread::hardware_concurrency()));
    std::vector<double> r(14, 0);
    r[0] = encrypt(1);
    r[1] = encrypt(threads);
    r[2] = compress(1);
    r[3] = compress(threads);
    r[4] = decompress(1);
    r[5] = decompress(threads);
    r[6] = memBandwidth(threads);
    r[7] = loopbackTcp();
    r[8] = threads;
    // Score units: 1 point per 10 MB/s of geometric-mean throughput.
    r[9] = geomean({r[0], r[2], r[4]}) / 10.0;
    r[10] = geomean({r[1], r[3], r[5], r[6], r[7]}) / 10.0;
    r[11] = std::sqrt(r[9] * r[10]) * 2.0;
    // Sender with LZ4 + encryption: each byte is compressed then (~half of it)
    // encrypted, across all cores; network stack is the other ceiling.
    double cpu = 1.0 / (1.0 / r[3] + 0.5 / r[1]);
    r[12] = std::min(cpu, r[7]);
    r[13] = aegis::available() ? 1 : 0;
    return r;
}

}  // namespace bench
