#include "engine.h"

#include <android/log.h>
#include <android/multinetwork.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <linux/errqueue.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/sendfile.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <map>

#include "aegis.h"
#include "perf.h"
#include "vortex.h"
#include "wdlog.h"

extern "C" {
#include "third_party/lz4.h"
#include "third_party/monocypher.h"
#include "third_party/zstd/zstd.h"
}

#ifndef SO_ZEROCOPY
#define SO_ZEROCOPY 60
#endif
#ifndef MSG_ZEROCOPY
#define MSG_ZEROCOPY 0x4000000
#endif

#define LOG_TAG "wingdrop-engine"
#define LOGI(...) wdlog::log('I', LOG_TAG, __VA_ARGS__)
#define LOGW(...) wdlog::log('W', LOG_TAG, __VA_ARGS__)

namespace wd {

int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

static int64_t nowNs() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

namespace {

constexpr uint32_t kMaxChunk = 64u << 20;
constexpr int kPipeSize = 1 << 20;
constexpr size_t kMaxReceiveSessions = 8;
// Upper bound for pipeline buffers per session (all streams together).
constexpr size_t kBufferBudget = 192u << 20;
constexpr uint8_t kAckVersion = 0xFE;  // Hello answer: "different protocol version", then u16 version
constexpr size_t kMaxPreview = 32u << 10;       // per image
constexpr size_t kMaxPreviewTotal = 640u << 10;  // per session

// ---------------------------------------------------------------- io helpers

bool writeAll(int fd, const void* buf, size_t len, int flags = 0) {
    auto p = static_cast<const uint8_t*>(buf);
    while (len > 0) {
        ssize_t n = ::send(fd, p, len, flags | MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

bool readAll(int fd, void* buf, size_t len) {
    auto p = static_cast<uint8_t*>(buf);
    while (len > 0) {
        ssize_t n = ::recv(fd, p, len, MSG_WAITALL);
        if (n == 0) return false;
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

bool preadAll(int fd, uint8_t* buf, size_t len, off64_t off) {
    while (len > 0) {
        ssize_t n = ::pread64(fd, buf, len, off);
        if (n == 0) return false;
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        buf += n;
        off += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

bool pwriteAll(int fd, const uint8_t* buf, size_t len, off64_t off) {
    while (len > 0) {
        ssize_t n = ::pwrite64(fd, buf, len, off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        buf += n;
        off += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

void tune(int fd, const Options& o) {
    int one = 1;
    int buf = static_cast<int>(o.sockBuf);
    // The kernel clamps these to net.core.[rw]mem_max; asking big is free.
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
    if (o.tos) {
        int tos = static_cast<int>(o.tos);
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, sizeof tos);
    }
    timeval tv{30, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
}

int connectTimeout(const std::string& host, int port, int64_t netHandle, const Options& o, int timeoutMs) {
    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, host.c_str(), &sa.sin_addr) != 1) return -1;
    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (netHandle != 0) {
        android_setsocknetwork(static_cast<net_handle_t>(netHandle), fd);
    } else if (host.rfind("192.168.49.", 0) == 0) {
        // Wi-Fi Direct group owner: a directly connected link. Select Android's
        // local network (netId 99) so an always-on VPN can't capture the
        // connection; if the platform refuses, the default route is used.
        constexpr uint64_t kLocalNetId = 99;
        android_setsocknetwork(static_cast<net_handle_t>((kLocalNetId << 32) | 0xfacade), fd);
    }
    // Buffers must be sized before connect() so the window scale is negotiated.
    tune(fd, o);
    int fl = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    int r = ::connect(fd, reinterpret_cast<sockaddr*>(&sa), sizeof sa);
    if (r < 0 && errno != EINPROGRESS) {
        ::close(fd);
        return -1;
    }
    if (r < 0) {
        pollfd p{fd, POLLOUT, 0};
        int err = 0;
        socklen_t el = sizeof err;
        if (poll(&p, 1, timeoutMs) <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) != 0 || err != 0) {
            ::close(fd);
            return -1;
        }
    }
    fcntl(fd, F_SETFL, fl);
    return fd;
}

// ---------------------------------------------------------------- crypto helpers

void helloAuth(const uint8_t key[32], const Hello& h, uint8_t out[32]) {
    crypto_blake2b_keyed(out, 32, key, 32, reinterpret_cast<const uint8_t*>(&h), 24);
}

bool helloMatches(const uint8_t key[32], const Hello& h) {
    uint8_t auth[32];
    helloAuth(key, h, auth);
    return crypto_verify32(auth, h.auth) == 0;
}

void kdf(const uint8_t key[32], const char* label, const uint8_t* extra, size_t extraLen, uint8_t* out,
         size_t outLen) {
    uint8_t msg[64];
    size_t l = strlen(label);
    memcpy(msg, label, l);
    if (extraLen) memcpy(msg + l, extra, extraLen);
    crypto_blake2b_keyed(out, outLen, key, 32, msg, l + extraLen);
}

// (file, offset) is unique per chunk, so nonces never repeat under a key.
void dataNonce(uint32_t file, uint64_t offset, uint8_t nonce[24]) {
    memset(nonce, 0, 24);
    nonce[0] = 'D';
    memcpy(nonce + 4, &file, 4);
    memcpy(nonce + 8, &offset, 8);
}

void aegisNonce(uint32_t file, uint64_t offset, uint8_t nonce[16]) {
    memset(nonce, 0, 16);
    nonce[0] = 'A';
    memcpy(nonce + 4, &file, 4);
    memcpy(nonce + 8, &offset, 8);
}

std::string hex(const uint8_t* p, size_t n) {
    static const char* d = "0123456789abcdef";
    std::string s(n * 2, '0');
    for (size_t i = 0; i < n; ++i) {
        s[2 * i] = d[p[i] >> 4];
        s[2 * i + 1] = d[p[i] & 15];
    }
    return s;
}

std::string jsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (unsigned char c : in) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            default:
                if (c < 0x20) {
                    char b[8];
                    snprintf(b, sizeof b, "\\u%04x", c);
                    out += b;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

// ---------------------------------------------------------------- (de)serialize

template <typename T>
void put(std::vector<uint8_t>& b, T v) {
    auto p = reinterpret_cast<const uint8_t*>(&v);
    b.insert(b.end(), p, p + sizeof v);
}

void putStr(std::vector<uint8_t>& b, const std::string& s) {
    size_t n = std::min<size_t>(s.size(), 65535);
    put<uint16_t>(b, static_cast<uint16_t>(n));
    b.insert(b.end(), s.begin(), s.begin() + static_cast<long>(n));
}

void putBlob(std::vector<uint8_t>& b, const std::vector<uint8_t>& v) {
    put<uint32_t>(b, static_cast<uint32_t>(v.size()));
    b.insert(b.end(), v.begin(), v.end());
}

struct Reader {
    const std::vector<uint8_t>& b;
    size_t pos = 0;
    bool ok = true;

    template <typename T>
    T get() {
        T v{};
        if (pos + sizeof v > b.size()) {
            ok = false;
            return v;
        }
        memcpy(&v, b.data() + pos, sizeof v);
        pos += sizeof v;
        return v;
    }

    std::string str() {
        auto n = get<uint16_t>();
        if (!ok || pos + n > b.size()) {
            ok = false;
            return {};
        }
        std::string s(reinterpret_cast<const char*>(b.data() + pos), n);
        pos += n;
        return s;
    }

    void raw(uint8_t* out, size_t n) {
        if (pos + n > b.size()) {
            ok = false;
            return;
        }
        memcpy(out, b.data() + pos, n);
        pos += n;
    }

    std::vector<uint8_t> blob() {
        auto n = get<uint32_t>();
        if (!ok || pos + n > b.size()) {
            ok = false;
            return {};
        }
        std::vector<uint8_t> v(b.begin() + static_cast<long>(pos), b.begin() + static_cast<long>(pos + n));
        pos += n;
        return v;
    }
};

// Formats LZ4/zstd cannot shrink; compressing them only burns CPU.
bool looksCompressed(const std::string& name) {
    static const char* exts[] = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".avif", ".gif",
                                 ".mp4", ".mkv", ".mov", ".webm", ".3gp", ".m4v", ".avi", ".mp3",
                                 ".aac", ".m4a", ".ogg", ".opus", ".flac", ".zip", ".apk", ".apks",
                                 ".xapk", ".obb", ".jar", ".gz", ".tgz", ".xz", ".7z", ".rar", ".zst",
                                 ".br", ".bz2", ".lz4", ".pdf", ".docx", ".xlsx", ".pptx"};
    auto dot = name.rfind('.');
    if (dot == std::string::npos) return false;
    std::string ext = name.substr(dot);
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    for (auto e : exts)
        if (ext == e) return true;
    return false;
}

size_t wireCapacity(size_t chunk) {
    size_t lz = static_cast<size_t>(LZ4_compressBound(static_cast<int>(chunk)));
    return std::max(lz, ZSTD_compressBound(chunk)) + 64;
}

// One in-flight chunk travelling through a stream pipeline. Buffers are
// allocated on first use, so raw zero-copy sessions never allocate any.
struct Block {
    FrameHeader h{};
    std::unique_ptr<uint8_t[]> raw;  // chunk + tag room
    std::unique_ptr<uint8_t[]> lz;   // compressed / wire buffer
    size_t chunk = 0;
    uint8_t* payload = nullptr;
    size_t len = 0;
    bool end = false;

    uint8_t* rawBuf() {
        if (!raw) raw.reset(new uint8_t[chunk + 64]);
        return raw.get();
    }
    uint8_t* wireBuf() {
        if (!lz) lz.reset(new uint8_t[wireCapacity(chunk)]);
        return lz.get();
    }
};

using BlockPtr = std::unique_ptr<Block>;

void fillPool(vortex::Channel<BlockPtr>& pool, size_t n, size_t chunk) {
    for (size_t i = 0; i < n; ++i) {
        auto b = std::make_unique<Block>();
        b->chunk = chunk;
        pool.write(std::move(b));
    }
}

size_t blocksPerStream(const Options& o, uint32_t streams) {
    size_t perBlock = 2 * static_cast<size_t>(o.chunkSize);
    size_t budget = kBufferBudget / std::max<size_t>(1, streams * perBlock);
    return std::clamp<size_t>(budget, 2, o.depth + 1);
}

}  // namespace

// ---------------------------------------------------------------- session

class Session {
public:
    const uint64_t id;
    const bool sender;
    uint8_t sid[16]{};
    uint8_t dataKey[32]{};
    uint8_t aegisKey[16]{};
    bool aegis = false;
    uint8_t bondKey[32]{};
    std::atomic<bool> bonded{false};
    Options opts;
    Peer peer;
    std::vector<FileEntry> files;
    std::vector<std::atomic<int>> fds;
    std::unique_ptr<std::atomic<int64_t>[]> done;
    std::vector<uint8_t> compress;
    std::vector<uint64_t> chunkBase;
    uint64_t chunkCount = 0;
    std::unique_ptr<std::atomic<uint8_t>[]> chunkDone;
    std::atomic<int64_t> remaining{0};
    std::atomic<bool> failed{false};

    // Progress, polled by the UI.
    std::atomic<int64_t> state{kConnecting};
    std::atomic<int64_t> total{0}, doneBytes{0}, skipped{0}, wire{0}, filesDone{0};
    std::atomic<int64_t> startMs{0}, endMs{0}, flags{0}, streams{0};
    // Sender: 0 reaching the receiver, 1 waiting for its answer (it may be
    // asking its person), 2 moving data.
    std::atomic<int> phase{0};

    std::mutex mu;
    std::condition_variable cv;
    std::vector<int> socks;
    std::string error;
    std::map<uint32_t, std::vector<uint8_t>> previews;  // guarded by mu

    // Chat: the control tunnel while it's open, and the conversation so far.
    struct ChatMsg {
        uint64_t seq;
        bool mine;
        std::string text;
        int64_t atMs;
    };
    std::shared_ptr<vortex::Tunnel> tunnel;  // guarded by mu
    std::vector<ChatMsg> chat;               // guarded by mu
    bool gotDone = false;                    // sender: receiver's final answer arrived (mu)
    bool doneOk = false;
    bool ctlClosed = false;

    Session(uint64_t id_, bool sender_, std::vector<FileEntry> f)
        : id(id_), sender(sender_), files(std::move(f)), fds(files.size()) {
        done.reset(new std::atomic<int64_t>[std::max<size_t>(1, files.size())]);
        for (size_t i = 0; i < files.size(); ++i) {
            done[i] = 0;
            fds[i] = files[i].fd;
        }
        remaining = static_cast<int64_t>(files.size());
    }

    ~Session() {
        for (auto& fd : fds) {
            int f = fd.exchange(-1);
            if (f >= 0) ::close(f);
        }
        crypto_wipe(dataKey, sizeof dataKey);
        crypto_wipe(aegisKey, sizeof aegisKey);
        crypto_wipe(bondKey, sizeof bondKey);
    }

    bool active() const {
        int64_t s = state.load();
        return s == kConnecting || s == kTransferring;
    }

    void initChunks() {
        const uint64_t cs = opts.chunkSize;
        chunkBase.resize(files.size());
        uint64_t n = 0;
        int64_t sum = 0;
        for (size_t i = 0; i < files.size(); ++i) {
            chunkBase[i] = n;
            n += (files[i].size + cs - 1) / cs;
            sum += static_cast<int64_t>(files[i].size);
        }
        chunkCount = n;
        chunkDone.reset(new std::atomic<uint8_t>[std::max<uint64_t>(1, n)]);
        for (uint64_t i = 0; i < n; ++i) chunkDone[i] = 0;
        total = sum;
    }

    uint64_t chunkIndex(uint32_t file, uint64_t offset) const { return chunkBase[file] + offset / opts.chunkSize; }

    uint32_t chunkLen(uint32_t file, uint64_t offset) const {
        return static_cast<uint32_t>(std::min<uint64_t>(opts.chunkSize, files[file].size - offset));
    }

    std::vector<uint8_t> bitmap() const {
        std::vector<uint8_t> bm((chunkCount + 7) / 8, 0);
        for (uint64_t i = 0; i < chunkCount; ++i)
            if (chunkDone[i]) bm[i / 8] |= static_cast<uint8_t>(1u << (i % 8));
        return bm;
    }

    // Marks chunks from a resume bitmap as done. Returns files it completed.
    std::vector<uint32_t> applyBitmap(const std::vector<uint8_t>& bm) {
        std::vector<uint32_t> completed;
        if (bm.empty() || bm.size() != (chunkCount + 7) / 8) return completed;
        for (uint32_t f = 0; f < files.size(); ++f) {
            for (uint64_t off = 0; off < files[f].size; off += opts.chunkSize) {
                uint64_t i = chunkIndex(f, off);
                if (!(bm[i / 8] & (1u << (i % 8)))) continue;
                chunkDone[i] = 1;
                int64_t len = chunkLen(f, off);
                doneBytes += len;
                skipped += len;
                if (addProgress(f, len)) completed.push_back(f);
            }
        }
        return completed;
    }

    void addSock(int fd) {
        std::lock_guard<std::mutex> l(mu);
        socks.push_back(fd);
    }

    void removeSock(int fd) {
        std::lock_guard<std::mutex> l(mu);
        socks.erase(std::remove(socks.begin(), socks.end(), fd), socks.end());
    }

    void setError(const std::string& e) {
        LOGW("session %llu: %s", static_cast<unsigned long long>(id), e.c_str());
        std::lock_guard<std::mutex> l(mu);
        if (error.empty()) error = e;
    }

    std::string errorText() {
        std::lock_guard<std::mutex> l(mu);
        return error;
    }

    void fail(const std::string& why = {}) {
        if (!why.empty()) setError(why);
        failed = true;
        std::lock_guard<std::mutex> l(mu);
        for (int s : socks) ::shutdown(s, SHUT_RDWR);
        cv.notify_all();
    }

    void finishState(int64_t st) {
        int64_t cur = state.load();
        while ((cur == kConnecting || cur == kTransferring) && !state.compare_exchange_weak(cur, st)) {
        }
        if (endMs == 0) endMs = nowMs();
    }

    // Returns true when this call completed the file.
    bool addProgress(uint32_t i, int64_t n) {
        return done[i].fetch_add(n) + n == static_cast<int64_t>(files[i].size);
    }

    void fileFinished() {
        filesDone++;
        if (remaining.fetch_sub(1) == 1) {
            std::lock_guard<std::mutex> l(mu);
            cv.notify_all();
        }
    }

    // The file being worked on right now: the first one that has started but
    // not finished, else the first one not finished.
    int currentFile() const {
        int firstOpen = -1;
        for (size_t i = 0; i < files.size(); ++i) {
            int64_t d = done[i].load();
            if (d >= static_cast<int64_t>(files[i].size)) continue;
            if (d > 0) return static_cast<int>(i);
            if (firstOpen < 0) firstOpen = static_cast<int>(i);
        }
        return firstOpen;
    }
};

namespace {

size_t sealFrame(const Session& s, FrameHeader& h, uint8_t* p, size_t len) {
    h.flags |= kFrameEncrypted | (s.aegis ? kFrameAegis : 0);
    h.wireLen = static_cast<uint32_t>(len + 16);
    FrameHeader ad = h;  // the header (final lengths and flags) is authenticated
    if (s.aegis) {
        uint8_t nonce[16];
        aegisNonce(h.file, h.offset, nonce);
        aegis::encrypt(p, p + len, p, len, reinterpret_cast<uint8_t*>(&ad), sizeof ad, s.aegisKey, nonce);
    } else {
        uint8_t nonce[24];
        dataNonce(h.file, h.offset, nonce);
        crypto_aead_lock(p, p + len, s.dataKey, nonce, reinterpret_cast<uint8_t*>(&ad), sizeof ad, p, len);
    }
    return len + 16;
}

bool openFrame(const Session& s, const FrameHeader& h, uint8_t* p, size_t len) {
    FrameHeader ad = h;
    if (h.flags & kFrameAegis) {
        if (!aegis::available()) return false;
        uint8_t nonce[16];
        aegisNonce(h.file, h.offset, nonce);
        return aegis::decrypt(p, p, len, p + len, reinterpret_cast<uint8_t*>(&ad), sizeof ad, s.aegisKey, nonce);
    }
    uint8_t nonce[24];
    dataNonce(h.file, h.offset, nonce);
    return crypto_aead_unlock(p, p + len, s.dataKey, nonce, reinterpret_cast<uint8_t*>(&ad), sizeof ad, p, len) == 0;
}

void deriveSessionKeys(Session& s, const uint8_t sessionKey[32]) {
    kdf(sessionKey, "wdr-data", s.sid, 16, s.dataKey, 32);
    kdf(s.dataKey, "wdr-aegis", nullptr, 0, s.aegisKey, 16);
    kdf(sessionKey, "wdr-bond", nullptr, 0, s.bondKey, 32);
}

}  // namespace

// ---------------------------------------------------------------- engine basics

Engine& Engine::get() {
    static Engine e;
    return e;
}

void Engine::setIdentity(const std::string& deviceId) {
    std::lock_guard<std::mutex> l(mu_);
    deviceId_ = deviceId;
}

void Engine::setBonds(const std::vector<std::array<uint8_t, 32>>& bonds) {
    std::lock_guard<std::mutex> l(mu_);
    bonds_ = bonds;
}

std::string Engine::lastError() {
    std::lock_guard<std::mutex> l(mu_);
    return error_;
}

void Engine::setError(const std::string& e) {
    LOGW("%s", e.c_str());
    std::lock_guard<std::mutex> l(mu_);
    error_ = e;
}

std::shared_ptr<Session> Engine::findSession(const uint8_t sid[16]) {
    std::lock_guard<std::mutex> l(mu_);
    for (auto& s : group_)
        if (!s->sender && memcmp(s->sid, sid, 16) == 0) return s;
    return nullptr;
}

void Engine::addToGroup(const std::shared_ptr<Session>& s) {
    std::lock_guard<std::mutex> l(mu_);
    // A new batch after everything went quiet starts a fresh group for the UI.
    bool anyActive = std::any_of(group_.begin(), group_.end(), [](auto& x) { return x->active(); });
    if (!anyActive) group_.clear();
    group_.push_back(s);
}

void Engine::cancel(uint64_t id) {
    std::vector<std::shared_ptr<Session>> targets;
    {
        std::lock_guard<std::mutex> l(mu_);
        for (auto& s : group_)
            if (id == 0 || s->id == id) targets.push_back(s);
    }
    for (auto& s : targets) {
        if (s->active()) s->finishState(kCancelled);
        s->fail();
    }
}

std::string Engine::status() {
    std::vector<std::shared_ptr<Session>> g;
    bool listening;
    {
        std::lock_guard<std::mutex> l(mu_);
        g = group_;
        listening = listenFd_ >= 0;
    }
    int64_t total = 0, done = 0, skipped = 0, wire = 0, filesTotal = 0, filesDone = 0, streams = 0, flags = 0;
    int64_t start = 0, end = 0;
    bool anyActive = false, anyTransferring = false, anyFailed = false, allCancelled = !g.empty();
    std::string error, sessions;
    const Session* current = nullptr;
    int currentFile = -1;
    for (auto& s : g) {
        int64_t st = s->state.load();
        total += s->total;
        done += s->doneBytes;
        skipped += s->skipped;
        wire += s->wire;
        filesTotal += static_cast<int64_t>(s->files.size());
        filesDone += s->filesDone;
        streams = std::max<int64_t>(streams, s->streams);
        flags |= s->flags;
        if (s->startMs > 0 && (start == 0 || s->startMs < start)) start = s->startMs;
        end = std::max<int64_t>(end, s->endMs);
        anyActive |= s->active();
        anyTransferring |= st == kTransferring;
        anyFailed |= st == kFailed;
        allCancelled &= st == kCancelled;
        std::string e = s->errorText();
        if (error.empty() && !e.empty() && st != kDone) error = e;
        if (!current && st == kTransferring) {
            int f = s->currentFile();
            if (f >= 0) {
                current = s.get();
                currentFile = f;
            }
        }
        int64_t el = s->startMs == 0 ? 0 : (s->endMs > s->startMs ? s->endMs.load() : nowMs()) - s->startMs;
        if (!sessions.empty()) sessions += ',';
        sessions += "{\"id\":" + std::to_string(s->id) + ",\"role\":\"" + (s->sender ? "send" : "recv") +
                    "\",\"state\":" + std::to_string(st) + ",\"buddy\":" + std::to_string(s->peer.buddy) +
                    ",\"nick\":\"" + jsonEscape(s->peer.nick) + "\",\"peer\":\"" + jsonEscape(s->peer.deviceId) +
                    "\",\"total\":" + std::to_string(s->total.load()) + ",\"done\":" +
                    std::to_string(s->doneBytes.load()) + ",\"skipped\":" + std::to_string(s->skipped.load()) +
                    ",\"filesTotal\":" + std::to_string(s->files.size()) + ",\"filesDone\":" +
                    std::to_string(s->filesDone.load()) + ",\"elapsedMs\":" + std::to_string(el) +
                    ",\"phase\":" + std::to_string(s->phase.load()) + ",\"error\":\"" + jsonEscape(e) + "\",\"bond\":\"" +
                    (s->sender && st == kDone && s->bonded ? hex(s->bondKey, 32) : "") + "\"}";
    }
    int64_t state;
    if (anyTransferring) state = kTransferring;
    else if (anyActive) state = kConnecting;
    else if (g.empty()) state = listening ? kListening : kIdle;
    else if (allCancelled) state = kCancelled;
    else if (anyFailed) state = kFailed;
    else state = kDone;
    int64_t elapsed = start == 0 ? 0 : (anyActive ? nowMs() : std::max(end, start)) - start;

    std::string cur = "null";
    if (current) {
        const FileEntry& f = current->files[static_cast<size_t>(currentFile)];
        cur = "{\"name\":\"" + jsonEscape(f.name) + "\",\"size\":" + std::to_string(f.size) + ",\"done\":" +
              std::to_string(current->done[static_cast<size_t>(currentFile)].load()) +
              ",\"cat\":" + std::to_string(f.category) + ",\"key\":\"" + std::to_string(current->id) + ":" +
              std::to_string(currentFile) + "\"}";
    }
    return "{\"state\":" + std::to_string(state) + ",\"total\":" + std::to_string(total) +
           ",\"done\":" + std::to_string(done) + ",\"skipped\":" + std::to_string(skipped) +
           ",\"wire\":" + std::to_string(wire) + ",\"filesTotal\":" + std::to_string(filesTotal) +
           ",\"filesDone\":" + std::to_string(filesDone) + ",\"elapsedMs\":" + std::to_string(elapsed) +
           ",\"streams\":" + std::to_string(streams) + ",\"flags\":" + std::to_string(flags) + ",\"error\":\"" +
           jsonEscape(error) + "\",\"current\":" + cur + ",\"sessions\":[" + sessions + "]}";
}

std::string Engine::files(size_t limit) {
    std::vector<std::shared_ptr<Session>> g;
    {
        std::lock_guard<std::mutex> l(mu_);
        g = group_;
    }
    std::string out = "[";
    size_t shown = 0;
    for (auto& s : g) {
        std::vector<char> hasPreview(s->files.size(), 0);
        {
            std::lock_guard<std::mutex> l(s->mu);
            for (auto& [i, _] : s->previews)
                if (i < hasPreview.size()) hasPreview[i] = 1;
        }
        if (out.size() > 1) out += ',';
        out += "{\"id\":" + std::to_string(s->id) + ",\"total\":" + std::to_string(s->files.size()) + ",\"files\":[";
        for (size_t i = 0; i < s->files.size() && shown < limit; ++i, ++shown) {
            const FileEntry& f = s->files[i];
            if (i) out += ',';
            out += "[\"" + jsonEscape(f.name) + "\"," + std::to_string(f.size) + "," + std::to_string(f.category) + "," +
                   std::to_string(s->done[i].load()) + "," + (hasPreview[i] ? "1" : "0") + "]";
        }
        out += "]}";
    }
    return out + "]";
}

std::vector<uint8_t> Engine::preview(uint64_t session, uint32_t file) {
    std::lock_guard<std::mutex> l(mu_);
    for (auto& s : group_) {
        if (s->id != session) continue;
        std::lock_guard<std::mutex> sl(s->mu);
        auto it = s->previews.find(file);
        return it == s->previews.end() ? std::vector<uint8_t>{} : it->second;
    }
    return {};
}

namespace {
constexpr size_t kMaxChat = 2000;

// Reads the control tunnel while files move: chat lines, and (sender side)
// the receiver's final answer, which ends the loop.
void readControl(const std::shared_ptr<Session>& s, const std::shared_ptr<vortex::Tunnel>& t,
                 std::atomic<uint64_t>& seq) {
    std::vector<uint8_t> m;
    uint8_t flag = 0;
    while (t->receive(m, &flag)) {
        if (flag == vortex::kFlagChat) {
            std::lock_guard<std::mutex> l(s->mu);
            s->chat.push_back({++seq, false, std::string(m.begin(), m.end()).substr(0, kMaxChat), nowMs()});
            continue;
        }
        if (s->sender && flag == vortex::kFlagNormal) {
            Reader r{m};
            std::lock_guard<std::mutex> l(s->mu);
            s->gotDone = true;
            s->doneOk = r.get<uint32_t>() == 0;
            s->cv.notify_all();
            break;
        }
    }
    std::lock_guard<std::mutex> l(s->mu);
    s->ctlClosed = true;
    s->cv.notify_all();
}
}  // namespace

int Engine::chat(uint64_t session, const std::string& text) {
    if (text.empty()) return 0;
    std::vector<std::shared_ptr<Session>> g;
    {
        std::lock_guard<std::mutex> l(mu_);
        g = group_;
    }
    std::string msg = text.substr(0, kMaxChat);
    std::vector<uint8_t> bytes(msg.begin(), msg.end());
    int sent = 0;
    for (auto& s : g) {
        if (session != 0 && s->id != session) continue;
        std::shared_ptr<vortex::Tunnel> t;
        {
            std::lock_guard<std::mutex> l(s->mu);
            t = s->tunnel;
        }
        if (!t || !t->send(bytes, vortex::kFlagChat)) continue;
        std::lock_guard<std::mutex> l(s->mu);
        s->chat.push_back({++chatSeq_, true, msg, nowMs()});
        sent++;
    }
    return sent;
}

std::string Engine::chatLog(uint64_t since) {
    std::vector<std::shared_ptr<Session>> g;
    {
        std::lock_guard<std::mutex> l(mu_);
        g = group_;
    }
    std::string out = "[";
    for (auto& s : g) {
        std::lock_guard<std::mutex> l(s->mu);
        for (auto& c : s->chat) {
            if (c.seq <= since) continue;
            if (out.size() > 1) out += ',';
            out += "{\"seq\":" + std::to_string(c.seq) + ",\"session\":" + std::to_string(s->id) +
                   ",\"mine\":" + (c.mine ? "true" : "false") + ",\"buddy\":" + std::to_string(s->peer.buddy) +
                   ",\"nick\":\"" + jsonEscape(s->peer.nick) + "\",\"text\":\"" + jsonEscape(c.text) + "\",\"at\":" +
                   std::to_string(c.atMs) + "}";
        }
    }
    return out + "]";
}

// ---------------------------------------------------------------- receiver

int Engine::listen(int port, const uint8_t key[32], const uint8_t* radarKey, ReceiverSink sink) {
    stopListening();
    {
        std::lock_guard<std::mutex> l(mu_);
        memcpy(key_, key, 32);
        hasRadar_ = radarKey != nullptr;
        if (radarKey) memcpy(radarKey_, radarKey, 32);
        sink_ = std::move(sink);
        error_.clear();
        group_.erase(std::remove_if(group_.begin(), group_.end(), [](auto& s) { return !s->active(); }),
                     group_.end());
    }

    int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        setError(std::string("socket: ") + strerror(errno));
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    // Accepted sockets inherit these; they must be set before listen() for the
    // TCP window scale to be negotiated large enough.
    int buf = 8 << 20;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);

    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    sa.sin_port = htons(static_cast<uint16_t>(port));
    if (::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof sa) < 0) {
        sa.sin_port = 0;  // preferred port busy: take any
        if (::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof sa) < 0) {
            setError(std::string("bind: ") + strerror(errno));
            ::close(fd);
            return -1;
        }
    }
    if (::listen(fd, 64) < 0) {
        setError(std::string("listen: ") + strerror(errno));
        ::close(fd);
        return -1;
    }
    socklen_t sl = sizeof sa;
    getsockname(fd, reinterpret_cast<sockaddr*>(&sa), &sl);
    listenFd_ = fd;
    acceptThread_ = std::thread([this] { acceptLoop(); });
    return ntohs(sa.sin_port);
}

void Engine::stopListening() {
    int fd = listenFd_.exchange(-1);
    if (fd >= 0) {
        ::shutdown(fd, SHUT_RDWR);
        ::close(fd);
    }
    if (acceptThread_.joinable()) acceptThread_.join();
    std::vector<std::shared_ptr<Session>> receiving;
    {
        std::lock_guard<std::mutex> l(mu_);
        for (auto& s : group_)
            if (!s->sender) receiving.push_back(s);
    }
    for (auto& s : receiving) {
        if (s->active()) s->finishState(kCancelled);
        s->fail();
    }
}

void Engine::acceptLoop() {
    for (;;) {
        int lfd = listenFd_.load();
        if (lfd < 0) break;
        int fd = ::accept4(lfd, nullptr, nullptr, SOCK_CLOEXEC);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            break;
        }
        std::thread([this, fd] {
            timeval tv{10, 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            Hello h{};
            if (!readAll(fd, &h, sizeof h) || h.magic != kMagic) {
                ::close(fd);
                return;
            }
            if (h.version != kVersion) {
                // Tell the other phone why instead of hanging up silently, so it
                // can say "update WingDrop" rather than wait for a timeout.
                uint8_t reply[3] = {kAckVersion, static_cast<uint8_t>(kVersion & 0xff), static_cast<uint8_t>(kVersion >> 8)};
                writeAll(fd, reply, sizeof reply);
                LOGW("peer speaks protocol v%u, we speak v%u", h.version, kVersion);
                ::close(fd);
                return;
            }
            if (h.kind == 0)
                handleControl(fd, h);
            else
                handleData(fd, h);
        }).detach();
    }
}

void Engine::handleControl(int fd, const Hello& hello) {
    // Which key opened the door decides how much we trust the sender:
    // QR key or a remembered bond = trusted, radar key = ask the person.
    uint8_t pairKey[32]{};
    bool trusted = false, bondMatch = false, radar = false;
    size_t activeReceives = 0;
    std::string myId;
    ReceiverSink sink;
    {
        std::lock_guard<std::mutex> l(mu_);
        myId = deviceId_;
        sink = sink_;
        for (auto& s : group_)
            if (!s->sender && s->active()) activeReceives++;
        if (helloMatches(key_, hello)) {
            trusted = true;
            memcpy(pairKey, key_, 32);
        } else {
            for (auto& b : bonds_) {
                if (helloMatches(b.data(), hello)) {
                    bondMatch = true;
                    memcpy(pairKey, b.data(), 32);
                    break;
                }
            }
            if (!bondMatch && hasRadar_ && helloMatches(radarKey_, hello)) {
                radar = true;
                memcpy(pairKey, radarKey_, 32);
            }
        }
    }
    uint8_t ack = ((trusted || bondMatch || radar) && activeReceives < kMaxReceiveSessions) ? 1 : 0;
    LOGI("control hello: key=%s tunnel=%s active=%zu -> %s", trusted ? "qr" : bondMatch ? "bond" : radar ? "radar" : "unknown",
         hello.stream == 1 ? "encrypted" : "plain", activeReceives, ack ? "accept" : "reject");
    if (!writeAll(fd, &ack, 1) || !ack) {
        if (!ack) LOGW("rejected control connection (unknown key or too busy)");
        ::close(fd);
        return;
    }

    // The sender picks the tunnel mode; it is covered by the Hello auth tag.
    auto tunnelPtr = std::make_shared<vortex::Tunnel>(fd, hello.stream == 1);
    vortex::Tunnel& tunnel = *tunnelPtr;
    bool shaken = tunnel.handshakeAsServer(pairKey);
    crypto_wipe(pairKey, 32);
    if (!shaken) {
        ::close(fd);
        return;
    }

    std::vector<uint8_t> msg;
    if (!tunnel.receive(msg)) {
        ::close(fd);
        return;
    }
    Reader r{msg};
    Options o;
    o.flags = r.get<uint32_t>();
    o.streams = r.get<uint32_t>();
    o.chunkSize = r.get<uint32_t>();
    o.sockBuf = r.get<uint32_t>();
    o.tos = r.get<uint32_t>();
    o.depth = r.get<uint32_t>();
    o.buddy = r.get<uint32_t>();
    o.nick = r.str();
    o.deviceId = r.str();
    r.raw(o.transferId, 16);
    if (!r.ok || o.chunkSize < (64u << 10) || o.chunkSize > kMaxChunk || o.streams == 0 || o.streams > 64) {
        ::close(fd);
        return;
    }
    o.depth = std::clamp<uint32_t>(o.depth, 1, 16);
    tune(fd, o);

    if (!tunnel.receive(msg)) {
        ::close(fd);
        return;
    }
    Reader m{msg};
    uint32_t count = m.get<uint32_t>();
    std::vector<FileEntry> entries;
    uint64_t totalBytes = 0;
    for (uint32_t i = 0; i < count && m.ok; ++i) {
        FileEntry e;
        e.size = m.get<uint64_t>();
        e.category = m.get<uint8_t>();
        e.name = m.str();
        e.rel = m.str();
        totalBytes += e.size;
        entries.push_back(std::move(e));
    }
    if (!m.ok) {
        ::close(fd);
        return;
    }

    // Previews of what's coming (small JPEGs), shown before the first byte lands.
    std::map<uint32_t, std::vector<uint8_t>> previews;
    if (!tunnel.receive(msg)) {
        ::close(fd);
        return;
    }
    {
        Reader pr{msg};
        uint32_t n = pr.get<uint32_t>();
        size_t total = 0;
        for (uint32_t i = 0; i < n && pr.ok; ++i) {
            uint32_t idx = pr.get<uint32_t>();
            std::vector<uint8_t> jpg = pr.blob();
            total += jpg.size();
            if (pr.ok && idx < entries.size() && jpg.size() <= kMaxPreview && total <= kMaxPreviewTotal)
                previews[idx] = std::move(jpg);
        }
    }

    Peer peer{o.buddy, o.nick, o.deviceId};
    int decision = (trusted || bondMatch) ? 1 : (sink.approve ? sink.approve(peer, entries.size(), totalBytes) : 0);
    if (decision == 0) {
        std::vector<uint8_t> no;
        put<uint32_t>(no, 2);
        putStr(no, "declined");
        tunnel.send(no);
        ::close(fd);
        return;
    }
    const bool bondWanted = trusted || bondMatch || decision == 2;
    LOGI("incoming from %s (%s): %zu files, %llu bytes, chunk %u KB, %u streams, flags 0x%x, decision %d",
         peer.nick.c_str(), peer.deviceId.c_str(), entries.size(), static_cast<unsigned long long>(totalBytes),
         o.chunkSize >> 10, o.streams, o.flags, decision);

    auto s = std::make_shared<Session>(nextId_++, false, std::move(entries));
    s->previews = std::move(previews);
    memcpy(s->sid, hello.session, 16);
    deriveSessionKeys(*s, tunnel.sessionKey());
    s->opts = o;
    s->peer = peer;
    s->initChunks();
    s->streams = o.streams;
    s->flags = o.flags;

    std::vector<int> outs;
    std::vector<uint8_t> resume;
    bool accepted = sink.openOutputs &&
                    sink.openOutputs(s->id, hex(o.transferId, 16), o.chunkSize, s->files, outs, resume) &&
                    outs.size() == s->files.size() &&
                    std::none_of(outs.begin(), outs.end(), [](int f) { return f < 0; });
    for (size_t i = 0; i < outs.size() && i < s->files.size(); ++i) {
        s->files[i].fd = outs[i];
        s->fds[i] = outs[i];
    }
    if (!accepted) {
        std::vector<uint8_t> no;
        put<uint32_t>(no, 1);
        putStr(no, "receiver could not create output files");
        tunnel.send(no);
        setError("could not create output files");
        if (sink.sessionDone) sink.sessionDone(s->id, false, {}, peer, nullptr);
        ::close(fd);
        return;
    }
    if (resume.empty()) {
        for (size_t i = 0; i < s->files.size(); ++i) {
            // Reserve blocks up front: less fragmentation, no ENOSPC half way.
            if (s->files[i].size > 0) fallocate64(s->fds[i].load(), 0, 0, static_cast<off64_t>(s->files[i].size));
        }
    }

    addToGroup(s);
    s->startMs = nowMs();
    s->state = kTransferring;
    s->addSock(fd);

    auto complete = [&](uint32_t i) {
        int f = s->fds[i].exchange(-1);
        if (f >= 0) ::close(f);
        if (sink.fileDone) sink.fileDone(s->id, static_cast<int>(i));
        s->fileFinished();
    };
    // Zero-byte files never receive a frame; chunks we already have (resume)
    // are not sent again.
    for (uint32_t i = 0; i < s->files.size(); ++i)
        if (s->files[i].size == 0) complete(i);
    for (uint32_t f : s->applyBitmap(resume)) complete(f);
    if (s->skipped > 0) LOGI("resuming: %lld bytes already here", static_cast<long long>(s->skipped.load()));

    std::vector<uint8_t> ready;
    put<uint32_t>(ready, 0);
    put<uint32_t>(ready, aegis::available() ? 1u : 0u);  // receiver capabilities
    put<uint32_t>(ready, bondWanted ? 1u : 0u);
    putStr(ready, myId);
    putBlob(ready, s->bitmap());
    if (!tunnel.send(ready)) s->fail("control connection lost");

    // While files move, the control tunnel carries chat. No read timeout:
    // it's quiet for as long as the transfer runs; failures shut it down.
    timeval noTimeout{0, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, sizeof noTimeout);
    {
        std::lock_guard<std::mutex> l(s->mu);
        s->tunnel = tunnelPtr;
    }
    std::thread chatReader([s, tunnelPtr, this] { readControl(s, tunnelPtr, chatSeq_); });

    {
        std::unique_lock<std::mutex> l(s->mu);
        s->cv.wait(l, [&] { return s->remaining.load() == 0 || s->failed.load(); });
    }

    bool ok = !s->failed && s->remaining == 0;
    std::vector<uint8_t> fin;
    put<uint32_t>(fin, ok ? 0 : 1);
    tunnel.send(fin);
    if (!ok && s->errorText().empty()) s->setError("transfer interrupted");
    s->finishState(ok ? kDone : kFailed);
    LOGI("session %llu %s: %lld bytes (%lld resumed) in %lld ms", static_cast<unsigned long long>(s->id),
         ok ? "done" : "failed", static_cast<long long>(s->doneBytes.load()), static_cast<long long>(s->skipped.load()),
         static_cast<long long>(s->endMs - s->startMs));
    {
        std::lock_guard<std::mutex> l(s->mu);
        s->tunnel.reset();
    }
    s->removeSock(fd);
    ::shutdown(fd, SHUT_RDWR);
    chatReader.join();
    ::close(fd);
    if (sink.sessionDone) sink.sessionDone(s->id, ok, s->bitmap(), peer, ok && bondWanted ? s->bondKey : nullptr);
}

void Engine::handleData(int fd, const Hello& hello) {
    std::shared_ptr<Session> s = findSession(hello.session);
    bool valid = s && !s->failed && helloMatches(s->dataKey, hello);
    uint8_t ack = valid ? 1 : 0;
    if (!writeAll(fd, &ack, 1) || !ack) {
        ::close(fd);
        return;
    }
    tune(fd, s->opts);
    s->addSock(fd);
    ReceiverSink sink;
    {
        std::lock_guard<std::mutex> l(mu_);
        sink = sink_;
    }

    const bool encrypted = s->opts.flags & kOptEncrypt;
    const bool zeroCopy = s->opts.flags & kOptZeroCopy;
    const size_t chunk = s->opts.chunkSize;
    const size_t cap = wireCapacity(chunk);
    perf::ThreadBoost boost;

    auto finish = [s, &sink](const FrameHeader& h) {
        s->chunkDone[s->chunkIndex(h.file, h.offset)] = 1;
        s->doneBytes += h.rawLen;
        s->wire += sizeof h + h.wireLen;
        if (s->addProgress(h.file, h.rawLen)) {
            int f = s->fds[h.file].exchange(-1);
            if (f >= 0) ::close(f);
            if (sink.fileDone) sink.fileDone(s->id, static_cast<int>(h.file));
            s->fileFinished();
        }
    };

    // Vortex-style split: this thread only pulls bytes off the socket; a
    // committer thread decrypts, decompresses and writes to storage.
    const size_t blocks = blocksPerStream(s->opts, s->opts.streams);
    vortex::Channel<BlockPtr> full(blocks), free(blocks + 1);
    fillPool(free, blocks + 1, chunk);
    std::atomic<bool> ok{true};

    std::thread committer([&] {
        perf::ThreadBoost cboost;
        ZSTD_DCtx* dctx = nullptr;
        BlockPtr b;
        while (full.read(b)) {
            const int64_t t0 = nowNs();
            FrameHeader& h = b->h;
            uint8_t* data = b->wireBuf();
            size_t len = h.wireLen;
            bool good = true;
            if (h.flags & kFrameEncrypted) {
                len -= 16;
                if (h.flags & kFrameAegis) s->flags |= kOptAegis;
                if (!openFrame(*s, h, data, len)) {
                    s->setError("decryption failed: data tampered or wrong key");
                    good = false;
                }
            }
            if (good && (h.flags & kFrameCompressed)) {
                uint8_t* out = b->rawBuf();
                size_t n;
                if (h.flags & kFrameZstd) {
                    if (!dctx) dctx = ZSTD_createDCtx();
                    n = ZSTD_decompressDCtx(dctx, out, h.rawLen, data, len);
                    if (ZSTD_isError(n)) n = 0;
                } else {
                    int r = LZ4_decompress_safe(reinterpret_cast<const char*>(data), reinterpret_cast<char*>(out),
                                                static_cast<int>(len), static_cast<int>(h.rawLen));
                    n = r > 0 ? static_cast<size_t>(r) : 0;
                }
                if (n != h.rawLen) {
                    s->setError("decompression failed");
                    good = false;
                }
                data = out;
                len = h.rawLen;
            }
            int out = s->fds[h.file].load();
            if (good && (len != h.rawLen || out < 0 || !pwriteAll(out, data, len, static_cast<off64_t>(h.offset)))) {
                s->setError(std::string("write failed: ") + strerror(errno));
                good = false;
            }
            if (!good) {
                ok = false;
                s->fail();
                full.close();
                free.close();
                break;
            }
            // Start writeback now instead of one giant flush at the end.
            sync_file_range(out, static_cast<off64_t>(h.offset), h.rawLen, SYNC_FILE_RANGE_WRITE);
            finish(h);
            cboost.reportWork(nowNs() - t0);
            free.write(std::move(b));
        }
        if (dctx) ZSTD_freeDCtx(dctx);
    });

    int pipefd[2] = {-1, -1};
    bool canSplice = zeroCopy && !encrypted && pipe2(pipefd, O_CLOEXEC) == 0;
    int pipeCap = kPipeSize;
    if (canSplice) {
        int got = fcntl(pipefd[1], F_SETPIPE_SZ, kPipeSize);
        pipeCap = got > 0 ? got : 65536;
    }
    std::unique_ptr<uint8_t[]> spill;

    while (!s->failed && ok) {
        FrameHeader h{};
        if (!readAll(fd, &h, sizeof h)) {
            ok = false;
            break;
        }
        if (h.file == kEndOfStream) break;
        bool sane = h.file < s->files.size() && h.rawLen <= chunk && h.wireLen <= cap && h.offset % chunk == 0 &&
                    h.offset + h.rawLen <= s->files[h.file].size && h.rawLen == s->chunkLen(h.file, h.offset) &&
                    (!encrypted || (h.flags & kFrameEncrypted)) &&
                    (!(h.flags & kFrameEncrypted) || h.wireLen >= 16) && (h.flags != 0 || h.wireLen == h.rawLen);
        if (!sane) {
            s->setError("corrupt or unauthenticated frame");
            ok = false;
            break;
        }

        if (h.flags == 0 && canSplice) {
            // socket -> pipe -> file: payload never enters user space.
            int out = s->fds[h.file].load();
            size_t left = h.rawLen;
            off64_t off = static_cast<off64_t>(h.offset);
            while (left > 0 && ok) {
                ssize_t n = splice(fd, nullptr, pipefd[1], nullptr, std::min<size_t>(left, static_cast<size_t>(pipeCap)),
                                   SPLICE_F_MOVE | SPLICE_F_MORE);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) {
                    ok = false;
                    break;
                }
                left -= static_cast<size_t>(n);
                size_t inPipe = static_cast<size_t>(n);
                while (inPipe > 0) {
                    ssize_t k = splice(pipefd[0], nullptr, out, &off, inPipe, SPLICE_F_MOVE);
                    if (k < 0 && errno == EINTR) continue;
                    if (k > 0) {
                        inPipe -= static_cast<size_t>(k);
                        continue;
                    }
                    // Target fs cannot splice (some FUSE mounts): drain the pipe
                    // through user space and stop splicing on this stream.
                    canSplice = false;
                    if (!spill) spill.reset(new uint8_t[chunk]);
                    size_t got = 0;
                    while (got < inPipe) {
                        ssize_t q = ::read(pipefd[0], spill.get() + got, inPipe - got);
                        if (q <= 0) break;
                        got += static_cast<size_t>(q);
                    }
                    if (got != inPipe || !pwriteAll(out, spill.get(), inPipe, off)) ok = false;
                    off += static_cast<off64_t>(inPipe);
                    inPipe = 0;
                }
                if (!canSplice && left > 0 && ok) {
                    if (!readAll(fd, spill.get(), left) || !pwriteAll(out, spill.get(), left, off)) ok = false;
                    left = 0;
                }
            }
            if (!ok) break;
            sync_file_range(out, static_cast<off64_t>(h.offset), h.rawLen, SYNC_FILE_RANGE_WRITE);
            finish(h);
            continue;
        }

        BlockPtr b;
        if (!free.read(b)) break;
        b->h = h;
        if (!readAll(fd, b->wireBuf(), h.wireLen)) {
            ok = false;
            break;
        }
        if (!full.write(std::move(b))) break;
    }
    full.close();
    committer.join();

    if (pipefd[0] >= 0) ::close(pipefd[0]);
    if (pipefd[1] >= 0) ::close(pipefd[1]);
    s->removeSock(fd);
    ::close(fd);
    if (!ok && !s->failed && s->remaining > 0) s->fail(s->errorText().empty() ? "connection lost" : "");
}

// ---------------------------------------------------------------- sender

namespace {

// openConnection outcomes (negative = failure).
constexpr int kConnUnreachable = -1;  // nothing answered on any address
constexpr int kConnRefused = -2;      // answered, but our key isn't known (old code) or busy
constexpr int kConnPeerOld = -3;      // hung up without answering: an older WingDrop
constexpr int kConnPeerNewer = -4;    // answered with a newer protocol version
constexpr int kConnPeerOlder = -5;    // answered with an older protocol version

// Connects and sends a Hello; `authKey` is the pairing key for the control
// connection and the session data key for data streams.
int openConnection(const std::vector<std::string>& hosts, int port, int64_t net, const uint8_t authKey[32],
                   const uint8_t session[16], uint8_t kind, uint8_t stream, const Options& o, int deadlineMs,
                   const std::atomic<bool>& cancelled, std::string* hostOut) {
    int64_t deadline = nowMs() + deadlineMs;
    while (!cancelled && nowMs() < deadline) {
        for (const auto& h : hosts) {
            int fd = connectTimeout(h, port, net, o, 1500);
            if (fd < 0) continue;
            LOGI("tcp connected to %s:%d (kind %u)", h.c_str(), port, kind);
            Hello hello{};
            hello.magic = kMagic;
            hello.version = kVersion;
            hello.kind = kind;
            hello.stream = stream;
            memcpy(hello.session, session, 16);
            helloAuth(authKey, hello, hello.auth);
            uint8_t ack = 0;
            bool sent = writeAll(fd, &hello, sizeof hello);
            bool answered = sent && readAll(fd, &ack, 1);
            if (answered && ack == 1) {
                if (hostOut) *hostOut = h;
                return fd;
            }
            int why = kConnRefused;
            if (answered && ack == kAckVersion) {
                uint16_t v = 0;
                readAll(fd, &v, sizeof v);
                why = v > kVersion ? kConnPeerNewer : kConnPeerOlder;
            } else if (sent && !answered) {
                why = kConnPeerOld;  // older builds just close on a version they don't know
            }
            ::close(fd);
            if (kind == 0) return why;
        }
        usleep(300 * 1000);
    }
    return kConnUnreachable;
}

// Adaptive codec ladder: incompressible data is caught by the probe, then
// LZ4, then zstd at rising effort.
constexpr int kLevels = 5;
const int kZstdLevel[kLevels] = {0, 0, -1, 1, 3};

}  // namespace

uint64_t Engine::send(const std::vector<std::string>& hosts, int port, int64_t netHandle, const uint8_t key[32],
                      std::vector<FileEntry> files, Options opts, std::vector<std::vector<uint8_t>> previews) {
    opts.chunkSize = std::clamp<uint32_t>(opts.chunkSize, 64u << 10, kMaxChunk);
    // 0 = auto: one stream per big core (each stream owns a producer and a
    // committer thread), never fewer than 4 so Wi-Fi stays saturated.
    if (opts.streams == 0) opts.streams = static_cast<uint32_t>(std::max(4, perf::bigCoreCount()));
    opts.streams = std::clamp<uint32_t>(opts.streams, 1, 64);
    opts.depth = std::clamp<uint32_t>(opts.depth, 1, 16);
    {
        std::lock_guard<std::mutex> l(mu_);
        opts.deviceId = deviceId_;
    }

    // Stable id for "this set of files to this phone", so a retry resumes.
    crypto_blake2b_ctx idc;
    crypto_blake2b_init(&idc, 16);
    crypto_blake2b_update(&idc, reinterpret_cast<const uint8_t*>(opts.peerDeviceId.c_str()),
                          opts.peerDeviceId.size() + 1);
    for (auto& f : files) {
        struct stat sb{};
        if (f.fd >= 0 && fstat(f.fd, &sb) == 0 && S_ISREG(sb.st_mode)) f.size = static_cast<uint64_t>(sb.st_size);
        // Tell the kernel we stream these front to back: bigger read-ahead.
        if (f.fd >= 0) posix_fadvise64(f.fd, 0, 0, POSIX_FADV_SEQUENTIAL);
        crypto_blake2b_update(&idc, reinterpret_cast<const uint8_t*>(f.rel.c_str()), f.rel.size() + 1);
        crypto_blake2b_update(&idc, reinterpret_cast<const uint8_t*>(f.name.c_str()), f.name.size() + 1);
        crypto_blake2b_update(&idc, reinterpret_cast<const uint8_t*>(&f.size), sizeof f.size);
    }
    crypto_blake2b_update(&idc, reinterpret_cast<const uint8_t*>(&opts.chunkSize), sizeof opts.chunkSize);
    crypto_blake2b_final(&idc, opts.transferId);

    auto s = std::make_shared<Session>(nextId_++, true, std::move(files));
    s->opts = opts;
    arc4random_buf(s->sid, 16);
    {
        size_t total = 0;
        for (uint32_t i = 0; i < previews.size() && i < s->files.size(); ++i) {
            if (previews[i].empty() || previews[i].size() > kMaxPreview || total + previews[i].size() > kMaxPreviewTotal)
                continue;
            total += previews[i].size();
            s->previews[i] = std::move(previews[i]);
        }
    }
    s->compress.resize(s->files.size());
    for (size_t i = 0; i < s->files.size(); ++i) {
        s->compress[i] = (opts.flags & kOptCompressAll) ||
                         ((opts.flags & kOptCompress) && !looksCompressed(s->files[i].name));
    }
    s->initChunks();
    s->streams = opts.streams;
    s->flags = opts.flags;
    addToGroup(s);
    {
        std::lock_guard<std::mutex> l(mu_);
        error_.clear();
    }

    std::vector<uint8_t> pairKey(key, key + 32);
    std::thread([this, s, hosts, port, netHandle, pairKey] {
        auto fail = [&](const std::string& why) {
            LOGW("send session %llu failed: %s", static_cast<unsigned long long>(s->id), why.c_str());
            s->setError(why);
            s->finishState(kFailed);
            s->fail();
            setError(why);
        };

        std::string host;
        const bool secure = s->opts.flags & kOptEncrypt;
        int ctl = openConnection(hosts, port, netHandle, pairKey.data(), s->sid, 0, secure ? 1 : 0, s->opts, 25000,
                                 s->failed, &host);
        // Machine-readable reasons; the UI turns them into friendly words.
        if (ctl < 0 && s->failed) return fail("cancelled");
        if (ctl == kConnRefused) return fail("refused");
        if (ctl == kConnPeerOld || ctl == kConnPeerOlder) return fail("peer_outdated");
        if (ctl == kConnPeerNewer) return fail("self_outdated");
        if (ctl < 0) return fail("unreachable");
        s->addSock(ctl);

        auto tunnelPtr = std::make_shared<vortex::Tunnel>(ctl, secure);
        vortex::Tunnel& tunnel = *tunnelPtr;
        if (!tunnel.handshakeAsClient(pairKey.data())) return fail("handshake");
        deriveSessionKeys(*s, tunnel.sessionKey());
        LOGI("vortex tunnel (%s) up to %s:%d, %zu files, %u streams", secure ? "encrypted" : "plain", host.c_str(),
             port, s->files.size(), s->opts.streams);

        std::vector<uint8_t> msg;
        put<uint32_t>(msg, s->opts.flags);
        put<uint32_t>(msg, s->opts.streams);
        put<uint32_t>(msg, s->opts.chunkSize);
        put<uint32_t>(msg, s->opts.sockBuf);
        put<uint32_t>(msg, s->opts.tos);
        put<uint32_t>(msg, s->opts.depth);
        put<uint32_t>(msg, s->opts.buddy);
        putStr(msg, s->opts.nick);
        putStr(msg, s->opts.deviceId);
        msg.insert(msg.end(), s->opts.transferId, s->opts.transferId + 16);
        if (!tunnel.send(msg)) return fail("control connection lost");

        msg.clear();
        put<uint32_t>(msg, static_cast<uint32_t>(s->files.size()));
        for (auto& f : s->files) {
            put<uint64_t>(msg, f.size);
            put<uint8_t>(msg, f.category);
            putStr(msg, f.name);
            putStr(msg, f.rel);
        }
        if (!tunnel.send(msg)) return fail("control connection lost");
        msg.clear();
        {
            std::lock_guard<std::mutex> l(s->mu);
            put<uint32_t>(msg, static_cast<uint32_t>(s->previews.size()));
            for (auto& [i, jpg] : s->previews) {
                put<uint32_t>(msg, i);
                putBlob(msg, jpg);
            }
        }
        s->phase = 1;
        if (!tunnel.send(msg) || !tunnel.receive(msg))
            return fail(s->failed ? "cancelled" : "no_answer");
        Reader r{msg};
        const uint32_t status = r.get<uint32_t>();
        if (status == 2) return fail("declined");
        if (status != 0) return fail("receiver: " + r.str());
        const uint32_t peerCaps = r.get<uint32_t>();
        const bool bondOffered = r.get<uint32_t>() == 1;
        s->peer.deviceId = r.str();
        std::vector<uint8_t> have = r.blob();
        if (!r.ok) return fail("receiver sent a malformed reply");
        if ((s->opts.flags & kOptEncrypt) && aegis::available() && (peerCaps & 1)) {
            s->aegis = true;
            s->flags |= kOptAegis;
        }
        s->bonded = bondOffered;

        // Resume: skip every chunk the receiver already stored.
        for (uint32_t f : s->applyBitmap(have)) {
            (void)f;
            s->fileFinished();
        }
        std::vector<Chunk> chunks;
        const uint64_t cs = s->opts.chunkSize;
        for (uint32_t i = 0; i < s->files.size(); ++i) {
            for (uint64_t off = 0; off < s->files[i].size; off += cs) {
                if (s->chunkDone[s->chunkIndex(i, off)]) continue;
                chunks.push_back({i, s->chunkLen(i, off), off});
            }
            if (s->files[i].size == 0) s->fileFinished();
        }
        if (s->skipped > 0) LOGI("resuming: skipping %lld bytes", static_cast<long long>(s->skipped.load()));
        std::atomic<size_t> next{0};

        s->startMs = nowMs();
        s->phase = 2;
        s->state = kTransferring;

        // From here the control tunnel carries chat, then the final answer.
        timeval noTimeout{0, 0};
        setsockopt(ctl, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, sizeof noTimeout);
        {
            std::lock_guard<std::mutex> l(s->mu);
            s->tunnel = tunnelPtr;
        }
        std::thread chatReader([s, tunnelPtr, this] { readControl(s, tunnelPtr, chatSeq_); });
        struct Joiner {
            std::thread& t;
            int fd;
            ~Joiner() {
                ::shutdown(fd, SHUT_RDWR);
                if (t.joinable()) t.join();
            }
        } joiner{chatReader, ctl};

        std::vector<std::thread> workers;
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(s->opts.streams, std::max<size_t>(1, chunks.size())));
        for (uint32_t w = 0; w < n; ++w) {
            workers.emplace_back([this, s, &chunks, &next, &host, port, netHandle, w] {
                sendStream(s, chunks, next, host, port, netHandle, w);
            });
        }
        for (auto& t : workers) t.join();
        if (s->failed) {
            if (s->state == kCancelled) return fail("cancelled");
            return fail(s->errorText().empty() ? "transfer failed" : s->errorText());
        }

        // The receiver confirms only after every byte reached storage (the
        // reader thread picks that answer up).
        bool confirmed, ok;
        {
            std::unique_lock<std::mutex> l(s->mu);
            s->cv.wait_for(l, std::chrono::seconds(60), [&] { return s->gotDone || s->ctlClosed; });
            confirmed = s->gotDone;
            ok = s->doneOk;
            s->tunnel.reset();
        }
        if (!confirmed) return fail("receiver did not confirm");
        if (!ok) return fail("receiver reported an error");
        s->removeSock(ctl);
        s->finishState(kDone);
        const int64_t ms = std::max<int64_t>(1, s->endMs - s->startMs);
        LOGI("sent %lld bytes (%lld on the wire, %lld resumed) in %lld ms = %.1f MB/s, cipher %s",
             static_cast<long long>(s->doneBytes.load()), static_cast<long long>(s->wire.load()),
             static_cast<long long>(s->skipped.load()), static_cast<long long>(ms),
             (s->doneBytes - s->skipped) / 1e3 / static_cast<double>(ms),
             (s->flags & kOptEncrypt) ? (s->aegis ? "AEGIS-128L" : "XChaCha20-Poly1305") : "none");
    }).detach();
    return s->id;
}

void Engine::sendStream(const std::shared_ptr<Session>& s, const std::vector<Chunk>& chunks,
                        std::atomic<size_t>& next, const std::string& host, int port, int64_t netHandle,
                        uint32_t index) {
    std::vector<std::string> one{host};
    int fd = openConnection(one, port, netHandle, s->dataKey, s->sid, 1, static_cast<uint8_t>(index), s->opts, 10000,
                            s->failed, nullptr);
    if (fd < 0) {
        s->fail("could not open data stream");
        return;
    }
    s->addSock(fd);
    const bool enc = s->opts.flags & kOptEncrypt;
    bool zeroCopy = s->opts.flags & kOptZeroCopy;
    const size_t cs = s->opts.chunkSize;
    const size_t cap = wireCapacity(cs);
    perf::ThreadBoost boost;

    // MSG_ZEROCOPY for prepared payloads (compressed/encrypted): the kernel
    // sends straight from our buffer, which comes back to the pool once the
    // error queue reports the transmission complete.
    int yes = 1;
    bool zc = zeroCopy && setsockopt(fd, SOL_SOCKET, SO_ZEROCOPY, &yes, sizeof yes) == 0;

    auto account = [s](const Chunk& c, const FrameHeader& h) {
        s->doneBytes += c.len;
        s->wire += sizeof h + h.wireLen;
        s->chunkDone[s->chunkIndex(c.file, c.offset)] = 1;
        if (s->addProgress(c.file, c.len)) s->fileFinished();
    };

    // Vortex-style pipeline: a producer reads, compresses and encrypts ahead
    // while this thread (the committer) keeps the socket saturated.
    const size_t blocks = blocksPerStream(s->opts, s->opts.streams) + (zc ? 2 : 0);
    vortex::Channel<BlockPtr> full(blocks), free(blocks + 1);
    fillPool(free, blocks + 1, cs);
    std::unique_ptr<uint8_t[]> bounce;

    // Who waits on whom drives the codec: a producer waiting for free buffers
    // means the network is the bottleneck (compress harder); a committer
    // waiting for data means the CPU is (back off).
    std::atomic<int64_t> commitWait{0}, commitBusy{0};

    std::thread producer([&] {
        perf::ThreadBoost pboost;
        ZSTD_CCtx* cctx = nullptr;
        int level = 1;
        int sinceAdapt = 0;
        int64_t prodWait = 0, prodBusy = 0;
        BlockPtr b;
        for (;;) {
            int64_t w0 = nowNs();
            if (s->failed || !free.read(b)) break;
            int64_t t0 = nowNs();
            prodWait += t0 - w0;
            size_t idx = next.fetch_add(1);
            if (idx >= chunks.size()) {
                b->end = true;
                full.write(std::move(b));
                break;
            }
            const Chunk c = chunks[idx];
            FrameHeader& h = b->h;
            h = FrameHeader{};
            h.file = c.file;
            h.offset = c.offset;
            h.rawLen = c.len;
            b->end = false;
            const int src = s->fds[c.file].load();

            if (!enc && !s->compress[c.file] && zeroCopy) {
                // Raw payload: the committer sendfile()s it straight from the
                // page cache, nothing to prepare here.
                h.wireLen = c.len;
                b->payload = nullptr;
                b->len = c.len;
            } else {
                uint8_t* raw = b->rawBuf();
                if (!preadAll(src, raw, c.len, static_cast<off64_t>(c.offset))) {
                    s->fail("read failed: " + s->files[c.file].name);
                    break;
                }
                b->payload = raw;
                b->len = c.len;
                if (s->compress[c.file]) {
                    uint8_t* lz = b->wireBuf();
                    bool worth = true;
                    if (c.len > (256u << 10)) {
                        // Probe a 64 KB slice first: incompressible data skips
                        // the codec entirely instead of burning a full pass.
                        int zp = LZ4_compress_default(reinterpret_cast<const char*>(raw), reinterpret_cast<char*>(lz),
                                                      64 << 10, static_cast<int>(cap));
                        worth = zp > 0 && zp <= (64 << 10) * 97 / 100;
                    }
                    if (worth) {
                        size_t z = 0;
                        const bool zstd = level >= 2;
                        if (zstd) {
                            if (!cctx) cctx = ZSTD_createCCtx();
                            z = ZSTD_compressCCtx(cctx, lz, cap, raw, c.len, kZstdLevel[level]);
                            if (ZSTD_isError(z)) z = 0;
                        } else {
                            int r = LZ4_compress_default(reinterpret_cast<const char*>(raw),
                                                         reinterpret_cast<char*>(lz), static_cast<int>(c.len),
                                                         static_cast<int>(cap));
                            z = r > 0 ? static_cast<size_t>(r) : 0;
                        }
                        // Only use it if it saves at least ~3%.
                        if (z > 0 && z < c.len - c.len / 32) {
                            b->payload = lz;
                            b->len = z;
                            h.flags |= kFrameCompressed | (zstd ? kFrameZstd : 0);
                        }
                    }
                }
                if (enc) {
                    b->len = sealFrame(*s, h, b->payload, b->len);
                } else {
                    h.wireLen = static_cast<uint32_t>(b->len);
                }
            }
            int64_t t1 = nowNs();
            prodBusy += t1 - t0;
            pboost.reportWork(t1 - t0);

            if (s->compress[c.file] && ++sinceAdapt >= 8) {
                sinceAdapt = 0;
                int64_t cw = commitWait.exchange(0), cb = commitBusy.exchange(0);
                double pw = static_cast<double>(prodWait) / static_cast<double>(std::max<int64_t>(1, prodWait + prodBusy));
                double cwr = static_cast<double>(cw) / static_cast<double>(std::max<int64_t>(1, cw + cb));
                if (pw > 0.25 && level < kLevels - 1) level++;
                else if (cwr > 0.15 && level > 1) level--;
                prodWait = prodBusy = 0;
            }
            if (!full.write(std::move(b))) break;
        }
        full.close();
        if (cctx) ZSTD_freeCCtx(cctx);
    });

    // ---- committer (this thread)
    struct Pending {
        uint32_t last;
        BlockPtr block;
    };
    std::deque<Pending> pending;
    uint32_t seq = 0;        // next MSG_ZEROCOPY id the kernel will assign
    int64_t completed = -1;  // highest contiguous completed id
    std::vector<std::pair<uint32_t, uint32_t>> early;  // out-of-order completion ranges
    int copied = 0, notified = 0;

    auto reap = [&] {
        for (;;) {
            char ctrl[128];
            msghdr msg{};
            msg.msg_control = ctrl;
            msg.msg_controllen = sizeof ctrl;
            if (recvmsg(fd, &msg, MSG_ERRQUEUE | MSG_DONTWAIT) < 0) break;
            for (cmsghdr* cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
                if (!((cm->cmsg_level == SOL_IP && cm->cmsg_type == IP_RECVERR) ||
                      (cm->cmsg_level == SOL_IPV6 && cm->cmsg_type == IPV6_RECVERR)))
                    continue;
                auto* e = reinterpret_cast<sock_extended_err*>(CMSG_DATA(cm));
                if (e->ee_errno != 0 || e->ee_origin != SO_EE_ORIGIN_ZEROCOPY) continue;
                notified++;
                if (e->ee_code & SO_EE_CODE_ZEROCOPY_COPIED) copied++;
                early.emplace_back(e->ee_info, e->ee_data);
            }
        }
        // Fold ranges into the contiguous watermark.
        for (bool moved = true; moved;) {
            moved = false;
            for (auto it = early.begin(); it != early.end(); ++it) {
                if (static_cast<int64_t>(it->first) <= completed + 1) {
                    completed = std::max<int64_t>(completed, it->second);
                    early.erase(it);
                    moved = true;
                    break;
                }
            }
        }
        while (!pending.empty() && static_cast<int64_t>(pending.front().last) <= completed) {
            free.write(std::move(pending.front().block));
            pending.pop_front();
        }
        // The kernel keeps copying anyway (loopback, no scatter-gather in the
        // driver): notifications are pure overhead, stop asking for them.
        if (zc && notified >= 16 && copied * 2 > notified) zc = false;
    };

    auto sendPayload = [&](const uint8_t* p, size_t len, bool& usedZc) -> bool {
        usedZc = false;
        if (!zc || len < (64u << 10)) return writeAll(fd, p, len);
        size_t off = 0;
        while (off < len) {
            ssize_t n = ::send(fd, p + off, len - off, MSG_ZEROCOPY | MSG_NOSIGNAL);
            if (n < 0) {
                if (errno == EINTR) continue;
                if (errno == ENOBUFS) {  // pinned-page budget exhausted: let completions land
                    pollfd pf{fd, POLLERR, 0};
                    poll(&pf, 1, 5);
                    reap();
                    continue;
                }
                return false;
            }
            off += static_cast<size_t>(n);
            seq++;
            usedZc = true;
        }
        return true;
    };

    BlockPtr b;
    bool ok = true;
    for (;;) {
        int64_t w0 = nowNs();
        bool got = false;
        if (!pending.empty()) {
            // Don't block on the producer while buffers wait for completions:
            // it may be waiting for exactly those buffers.
            while (!(got = full.tryRead(b))) {
                if (full.closed()) break;
                pollfd pf{fd, POLLERR, 0};
                poll(&pf, 1, 2);
                reap();
                if (pending.empty()) {
                    got = full.read(b);
                    break;
                }
            }
        } else {
            got = full.read(b);
        }
        int64_t t0 = nowNs();
        commitWait += t0 - w0;
        if (!got || b->end) break;
        const FrameHeader h = b->h;
        const Chunk c{h.file, h.rawLen, h.offset};
        if (!writeAll(fd, &h, sizeof h, MSG_MORE)) {
            ok = false;
            break;
        }
        bool usedZc = false;
        if (b->payload) {
            ok = sendPayload(b->payload, b->len, usedZc);
        } else {
            const int src = s->fds[c.file].load();
            off64_t off = static_cast<off64_t>(c.offset);
            size_t left = c.len;
            while (left > 0) {
                ssize_t k = zeroCopy ? sendfile64(fd, src, &off, left) : -1;
                if (k < 0 && errno == EINTR) continue;
                if (k > 0) {
                    left -= static_cast<size_t>(k);
                    continue;
                }
                if (k == 0) {
                    ok = false;
                    break;
                }
                // Source cannot be spliced (e.g. some FUSE / provider fds):
                // finish by copy and stop trying sendfile on this stream.
                zeroCopy = false;
                if (!bounce) bounce.reset(new uint8_t[cs]);
                ok = preadAll(src, bounce.get(), left, off) && writeAll(fd, bounce.get(), left);
                left = 0;
            }
        }
        if (!ok) break;
        account(c, h);
        commitBusy += nowNs() - t0;
        if (usedZc) {
            pending.push_back({seq - 1, std::move(b)});
            reap();
        } else if (!free.write(std::move(b))) {
            break;
        }
    }
    if (!ok) s->fail(s->failed ? "" : "connection lost");

    // Let in-flight zero-copy sends finish before their buffers go away.
    for (int64_t until = nowMs() + 3000; !pending.empty() && nowMs() < until;) {
        pollfd pf{fd, POLLERR, 0};
        poll(&pf, 1, 20);
        reap();
    }
    free.close();
    full.close();
    producer.join();

    if (!s->failed) {
        FrameHeader eos{};
        eos.file = kEndOfStream;
        writeAll(fd, &eos, sizeof eos);
    }
    s->removeSock(fd);
    ::shutdown(fd, SHUT_WR);
    // Wait for the receiver to close its side so the tail is not reset.
    uint8_t sink;
    while (::recv(fd, &sink, 1, 0) > 0) {
    }
    ::close(fd);
}

}  // namespace wd
