// Vortex tunnel, native edition.
//
// Modelled on VortexTunnel (github.com/Neo-vortex/VortexTunnel):
//   * the same 5-byte message header: [u32 length][u8 flag]
//   * the same flags: NORMAL = 0, AUTHENTICATION = 14, PROTOCOL = 15
//   * the same handshake order: security (ECDH) first, then protocol version
//   * the same Pipes/Channels idea: producers and the socket committer are
//     decoupled by a bounded channel so disk, crypto and network overlap.
// Differences, each addressing a caveat from the VortexTunnel README:
//   * X25519 instead of NIST ECDH, and the shared secret is mixed with the
//     pairing key from the QR code, so a man in the middle cannot complete
//     the handshake.
//   * nonces are sequence numbers (per direction), not random, so replayed or
//     reordered messages fail authentication.
//   * XChaCha20-Poly1305 (Monocypher) instead of AES-GCM: constant time in
//     portable C, no OpenSSL dependency (the NDK does not ship one).
//   * a plain mode (secure = false) for maximum speed / compatibility: the
//     X25519 exchange still runs (it costs microseconds), but messages travel
//     in the clear. The session key stays secret, so it can still authenticate
//     data streams and seed trusted-device bonds.
#pragma once

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace vortex {

constexpr uint8_t kFlagNormal = 0;
constexpr uint8_t kFlagChat = 2;  // WingDrop: a chat line during a transfer (UTF-8)
constexpr uint8_t kFlagAuthentication = 14;
constexpr uint8_t kFlagProtocol = 15;
constexpr uint32_t kProtocolVersion = 1;
constexpr size_t kHeaderSize = 5;

class Tunnel {
public:
    Tunnel(int fd, bool secure) : fd_(fd), secure_(secure) {}
    ~Tunnel();

    // pairingKey is the secret shared out of band (QR code).
    bool handshakeAsClient(const uint8_t pairingKey[32]);
    bool handshakeAsServer(const uint8_t pairingKey[32]);

    bool send(const std::vector<uint8_t>& data, uint8_t flag = kFlagNormal);
    bool receive(std::vector<uint8_t>& data, uint8_t* flag = nullptr);

    const uint8_t* sessionKey() const { return key_; }
    int fd() const { return fd_; }

private:
    bool sendRaw(uint8_t flag, const uint8_t* data, size_t len);
    bool recvRaw(uint8_t& flag, std::vector<uint8_t>& data);
    bool protocolHandshake(bool client);

    int fd_;
    std::mutex txMu_;  // chat and control messages may be sent from different threads
    bool secure_;
    bool secured_ = false;
    bool client_ = false;
    uint8_t key_[32]{};
    uint64_t txSeq_ = 0, rxSeq_ = 0;
};

// Bounded blocking channel, the native counterpart of System.Threading.Channels.
template <typename T>
class Channel {
public:
    explicit Channel(size_t capacity) : cap_(capacity) {}

    bool write(T v) {
        std::unique_lock<std::mutex> l(mu_);
        notFull_.wait(l, [&] { return closed_ || q_.size() < cap_; });
        if (closed_) return false;
        q_.push_back(std::move(v));
        notEmpty_.notify_one();
        return true;
    }

    // Non-blocking read; false when nothing is queued right now.
    bool tryRead(T& out) {
        std::lock_guard<std::mutex> l(mu_);
        if (q_.empty()) return false;
        out = std::move(q_.front());
        q_.pop_front();
        notFull_.notify_one();
        return true;
    }

    bool closed() {
        std::lock_guard<std::mutex> l(mu_);
        return closed_ && q_.empty();
    }

    bool read(T& out) {
        std::unique_lock<std::mutex> l(mu_);
        notEmpty_.wait(l, [&] { return closed_ || !q_.empty(); });
        if (q_.empty()) return false;
        out = std::move(q_.front());
        q_.pop_front();
        notFull_.notify_one();
        return true;
    }

    void close() {
        std::lock_guard<std::mutex> l(mu_);
        closed_ = true;
        notFull_.notify_all();
        notEmpty_.notify_all();
    }

private:
    size_t cap_;
    bool closed_ = false;
    std::deque<T> q_;
    std::mutex mu_;
    std::condition_variable notFull_, notEmpty_;
};

}  // namespace vortex
