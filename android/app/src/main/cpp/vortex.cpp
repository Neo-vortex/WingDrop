#include "vortex.h"

#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>

extern "C" {
#include "third_party/monocypher.h"
}

namespace vortex {

namespace {

constexpr uint32_t kMaxMessage = 64u << 20;

bool writeAll(int fd, const void* buf, size_t len) {
    auto p = static_cast<const uint8_t*>(buf);
    while (len > 0) {
        ssize_t n = ::send(fd, p, len, MSG_NOSIGNAL);
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

// Nonce = direction byte + 64-bit sequence number. Never reused under a key,
// and a replayed/reordered message fails to authenticate.
void nonceFor(bool fromClient, uint64_t seq, uint8_t out[24]) {
    memset(out, 0, 24);
    out[0] = 'V';
    out[1] = fromClient ? 'c' : 's';
    memcpy(out + 16, &seq, 8);
}

}  // namespace

Tunnel::~Tunnel() { crypto_wipe(key_, sizeof key_); }

bool Tunnel::sendRaw(uint8_t flag, const uint8_t* data, size_t len) {
    std::lock_guard<std::mutex> l(txMu_);
    std::vector<uint8_t> buf(kHeaderSize + len + (secured_ ? 16 : 0));
    uint32_t wireLen = static_cast<uint32_t>(buf.size() - kHeaderSize);
    memcpy(buf.data(), &wireLen, 4);
    buf[4] = flag;
    memcpy(buf.data() + kHeaderSize, data, len);
    if (secured_) {
        uint8_t nonce[24];
        nonceFor(client_, txSeq_++, nonce);
        // The flag byte is authenticated as associated data.
        crypto_aead_lock(buf.data() + kHeaderSize, buf.data() + kHeaderSize + len, key_, nonce, &buf[4], 1,
                         buf.data() + kHeaderSize, len);
    }
    return writeAll(fd_, buf.data(), buf.size());
}

bool Tunnel::recvRaw(uint8_t& flag, std::vector<uint8_t>& data) {
    uint8_t hdr[kHeaderSize];
    if (!readAll(fd_, hdr, sizeof hdr)) return false;
    uint32_t len;
    memcpy(&len, hdr, 4);
    flag = hdr[4];
    if (len > kMaxMessage) return false;
    data.resize(len);
    if (!readAll(fd_, data.data(), len)) return false;
    if (secured_) {
        if (len < 16) return false;
        size_t n = len - 16;
        uint8_t nonce[24];
        nonceFor(!client_, rxSeq_++, nonce);
        if (crypto_aead_unlock(data.data(), data.data() + n, key_, nonce, &flag, 1, data.data(), n) != 0)
            return false;
        data.resize(n);
    }
    return true;
}

bool Tunnel::send(const std::vector<uint8_t>& data, uint8_t flag) {
    return sendRaw(flag, data.data(), data.size());
}

bool Tunnel::receive(std::vector<uint8_t>& data, uint8_t* flag) {
    uint8_t f = 0;
    if (!recvRaw(f, data)) return false;
    if (flag) *flag = f;
    return f == kFlagNormal || flag != nullptr;
}

static void deriveKey(const uint8_t pairingKey[32], const uint8_t shared[32], const uint8_t clientPk[32],
                      const uint8_t serverPk[32], uint8_t out[32]) {
    uint8_t msg[9 + 32 * 3];
    memcpy(msg, "vortex-v1", 9);
    memcpy(msg + 9, shared, 32);
    memcpy(msg + 41, clientPk, 32);
    memcpy(msg + 73, serverPk, 32);
    crypto_blake2b_keyed(out, 32, pairingKey, 32, msg, sizeof msg);
    crypto_wipe(msg, sizeof msg);
}

bool Tunnel::protocolHandshake(bool client) {
    std::vector<uint8_t> msg(4);
    uint32_t v = kProtocolVersion;
    memcpy(msg.data(), &v, 4);
    uint8_t flag;
    std::vector<uint8_t> in;
    if (client) {
        if (!sendRaw(kFlagProtocol, msg.data(), msg.size())) return false;
        if (!recvRaw(flag, in) || flag != kFlagProtocol || in.size() != 4) return false;
    } else {
        if (!recvRaw(flag, in) || flag != kFlagProtocol || in.size() != 4) return false;
        if (!sendRaw(kFlagProtocol, msg.data(), msg.size())) return false;
    }
    uint32_t peer;
    memcpy(&peer, in.data(), 4);
    return peer == kProtocolVersion;
}

bool Tunnel::handshakeAsClient(const uint8_t pairingKey[32]) {
    client_ = true;
    uint8_t sk[32], pk[32], shared[32];
    arc4random_buf(sk, 32);
    crypto_x25519_public_key(pk, sk);
    uint8_t flag;
    std::vector<uint8_t> in;
    bool ok = sendRaw(kFlagAuthentication, pk, 32) && recvRaw(flag, in) && flag == kFlagAuthentication &&
              in.size() == 32;
    if (ok) {
        crypto_x25519(shared, sk, in.data());
        deriveKey(pairingKey, shared, pk, in.data(), key_);
        secured_ = secure_;
    }
    crypto_wipe(sk, 32);
    crypto_wipe(shared, 32);
    // Encrypted mode: the protocol handshake doubles as key confirmation.
    return ok && protocolHandshake(true);
}

bool Tunnel::handshakeAsServer(const uint8_t pairingKey[32]) {
    client_ = false;
    uint8_t sk[32], pk[32], shared[32];
    uint8_t flag;
    std::vector<uint8_t> in;
    if (!recvRaw(flag, in) || flag != kFlagAuthentication || in.size() != 32) return false;
    arc4random_buf(sk, 32);
    crypto_x25519_public_key(pk, sk);
    bool ok = sendRaw(kFlagAuthentication, pk, 32);
    if (ok) {
        crypto_x25519(shared, sk, in.data());
        deriveKey(pairingKey, shared, in.data(), pk, key_);
        secured_ = secure_;
    }
    crypto_wipe(sk, 32);
    crypto_wipe(shared, 32);
    return ok && protocolHandshake(false);
}

}  // namespace vortex
