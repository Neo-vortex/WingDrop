// WingDrop native transfer engine.
//
// Wire protocol (all integers little-endian):
//   Every TCP connection starts with a 64-byte Hello (sender -> receiver).
//   Control (kind 0): Hello authenticated with a pairing key (QR key, the
//     advertised radar key, or a trusted-device bond), then a Vortex tunnel
//     (see vortex.h): X25519 handshake, protocol handshake and [u32 len][u8 flag]
//     messages carrying options, manifest, READY (capabilities, bond, resume
//     bitmap) and DONE.
//   Data (kind 1, N of them): Hello authenticated with the session data key,
//     then FrameHeader (24 bytes) + payload. Payload is raw file bytes, LZ4 or
//     zstd, and/or AEAD ciphertext (+16 byte tag): AEGIS-128L on AES hardware
//     when both phones have it, XChaCha20-Poly1305 otherwise.
//   Files are cut into fixed chunks; chunks come from one queue shared by all
//   streams, and the receiver tracks them in a bitmap so an interrupted
//   transfer resumes where it stopped.
//   Any number of sessions (senders and receivers) run side by side.
//   After the manifest the sender may send small JPEG previews (photos,
//   videos, app icons) so the receiver can show what's coming right away.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wd {

constexpr uint32_t kMagic = 0x50524457;  // "WDRP"
constexpr uint16_t kVersion = 3;
constexpr uint32_t kEndOfStream = 0xFFFFFFFFu;

enum Flags : uint32_t {
    kOptCompress = 1u << 0,     // adaptive LZ4/zstd, skipping already-compressed formats
    kOptCompressAll = 1u << 1,  // adaptive LZ4/zstd on every file
    kOptEncrypt = 1u << 2,      // AEAD per chunk
    kOptZeroCopy = 1u << 3,     // sendfile()/splice() for raw data, MSG_ZEROCOPY otherwise
    kOptAegis = 1u << 4,        // encryption runs AEGIS-128L on AES hardware (negotiated)
};

enum FrameFlags : uint8_t {
    kFrameCompressed = 1,
    kFrameEncrypted = 2,
    kFrameAegis = 4,  // with kFrameEncrypted: AEGIS-128L instead of XChaCha20-Poly1305
    kFrameZstd = 8,   // with kFrameCompressed: zstd instead of LZ4
};

#pragma pack(push, 1)
struct Hello {
    uint32_t magic;
    uint16_t version;
    uint8_t kind;
    uint8_t stream;  // data: stream index; control: 1 = encrypted tunnel, 0 = plain
    uint8_t session[16];
    uint8_t auth[32];
    uint8_t pad[8];
};
static_assert(sizeof(Hello) == 64, "hello size");

struct FrameHeader {
    uint32_t file;
    uint64_t offset;
    uint32_t rawLen;
    uint32_t wireLen;
    uint8_t flags;
    uint8_t pad[3];
};
static_assert(sizeof(FrameHeader) == 24, "frame size");
#pragma pack(pop)

struct Options {
    uint32_t flags = kOptZeroCopy;
    uint32_t streams = 4;
    uint32_t chunkSize = 4u << 20;
    uint32_t sockBuf = 8u << 20;
    uint32_t tos = 0;    // IP TOS byte (WMM access category), 0 = best effort
    uint32_t depth = 4;  // chunks in flight per stream between disk/crypto and socket
    uint32_t buddy = 0;  // sender identity, shown to the receiver
    std::string nick;
    std::string deviceId;      // sender's device id
    std::string peerDeviceId;  // sender side: who we send to (feeds the transfer id)
    uint8_t transferId[16]{};  // stable across retries of the same transfer
};

struct FileEntry {
    std::string name;
    std::string rel;       // relative folder on the receiver
    uint8_t category = 0;  // 0 file, 1 photo, 2 video, 3 music, 4 app
    uint64_t size = 0;
    int fd = -1;
};

struct Peer {
    uint32_t buddy = 0;
    std::string nick;
    std::string deviceId;
};

enum State : int64_t {
    kIdle = 0,
    kListening = 1,
    kConnecting = 2,
    kTransferring = 3,
    kDone = 4,
    kFailed = 5,
    kCancelled = 6,
};

// Receiver-side hooks implemented by the JNI layer. `batch` identifies a session.
struct ReceiverSink {
    // One writable fd per entry (-1 = reject). For a resumed transfer (same
    // transferId and chunk size), reopen the partial files and fill `bitmap`
    // (one bit per chunk, LSB first) with the chunks already stored.
    std::function<bool(uint64_t batch, const std::string& transferId, uint32_t chunkSize,
                       const std::vector<FileEntry>& files, std::vector<int>& fds, std::vector<uint8_t>& bitmap)>
        openOutputs;
    std::function<void(uint64_t batch, int index)> fileDone;
    // bitmap: chunks stored so far (to resume a failed session).
    // bond: 32-byte trusted-device key when the peer should be remembered, else null.
    std::function<void(uint64_t batch, bool ok, const std::vector<uint8_t>& bitmap, const Peer& peer,
                       const uint8_t* bond)>
        sessionDone;
    // Asked before accepting a sender that found us over the air (not QR, not
    // bonded). 0 = no, 1 = yes, 2 = yes and remember this device.
    std::function<int(const Peer& peer, size_t files, uint64_t bytes)> approve;
};

struct Chunk {
    uint32_t file;
    uint32_t len;
    uint64_t offset;
};

int64_t nowMs();

class Session;

class Engine {
public:
    static Engine& get();

    void setIdentity(const std::string& deviceId);
    void setBonds(const std::vector<std::array<uint8_t, 32>>& bonds);

    // key: shared through the QR code (implicitly trusted).
    // radarKey: advertised over Wi-Fi Direct service discovery; senders using
    // it need the receiver's approval. May be null.
    int listen(int port, const uint8_t key[32], const uint8_t* radarKey, ReceiverSink sink);
    void stopListening();

    // Starts a send session in the background. fds are owned (closed) by the
    // engine. Returns the session id, or 0 on failure.
    // previews: index-aligned with files (empty = none), small JPEGs.
    uint64_t send(const std::vector<std::string>& hosts, int port, int64_t netHandle, const uint8_t key[32],
                  std::vector<FileEntry> files, Options opts, std::vector<std::vector<uint8_t>> previews = {});

    void cancel(uint64_t id = 0);  // 0 = everything

    // Aggregate + per-session progress as JSON, for the UI.
    std::string status();
    // Per-file overview (name, size, category, done, has preview) of the
    // current sessions, at most `limit` files in total.
    std::string files(size_t limit);
    std::vector<uint8_t> preview(uint64_t session, uint32_t file);

    // Chat while files move. session 0 = every active session. Returns how
    // many phones it went to.
    int chat(uint64_t session, const std::string& text);
    // Messages with seq > since, as JSON.
    std::string chatLog(uint64_t since);
    std::string lastError();
    void setError(const std::string& e);

private:
    Engine() = default;
    void acceptLoop();
    void handleControl(int fd, const Hello& hello);
    void handleData(int fd, const Hello& hello);
    void sendStream(const std::shared_ptr<Session>& s, const std::vector<Chunk>& chunks, std::atomic<size_t>& next,
                    const std::string& host, int port, int64_t netHandle, uint32_t index);
    void addToGroup(const std::shared_ptr<Session>& s);
    std::shared_ptr<Session> findSession(const uint8_t sid[16]);

    std::mutex mu_;
    std::string error_;
    std::string deviceId_;
    std::vector<std::array<uint8_t, 32>> bonds_;
    std::atomic<int> listenFd_{-1};
    std::thread acceptThread_;
    uint8_t key_[32]{};
    uint8_t radarKey_[32]{};
    bool hasRadar_ = false;
    ReceiverSink sink_;
    // Sessions since the engine was last idle; the UI shows them together.
    std::vector<std::shared_ptr<Session>> group_;
    std::atomic<uint64_t> nextId_{1};
    std::atomic<uint64_t> chatSeq_{0};
};

}  // namespace wd
