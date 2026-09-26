#include "aegis.h"

#include <cstring>

#if defined(__aarch64__)
#include <arm_neon.h>
#include <sys/auxv.h>
#ifndef HWCAP_AES
#define HWCAP_AES (1 << 3)
#endif
#define AEGIS_ARM 1
#define TARGET
#elif defined(__x86_64__)
#include <immintrin.h>
#define AEGIS_X86 1
#define TARGET __attribute__((target("aes,sse4.1")))
#endif

namespace aegis {

#if defined(AEGIS_ARM) || defined(AEGIS_X86)

namespace {

#if defined(AEGIS_ARM)
using B = uint8x16_t;
inline B load(const uint8_t* p) { return vld1q_u8(p); }
inline void store(uint8_t* p, B v) { vst1q_u8(p, v); }
inline B bxor(B a, B b) { return veorq_u8(a, b); }
inline B band(B a, B b) { return vandq_u8(a, b); }
// AESE xors the key first; with a zero key it is exactly SubBytes+ShiftRows.
inline B round(B in, B rk) { return veorq_u8(vaesmcq_u8(vaeseq_u8(in, vdupq_n_u8(0))), rk); }
#else
using B = __m128i;
TARGET inline B load(const uint8_t* p) { return _mm_loadu_si128(reinterpret_cast<const __m128i*>(p)); }
TARGET inline void store(uint8_t* p, B v) { _mm_storeu_si128(reinterpret_cast<__m128i*>(p), v); }
TARGET inline B bxor(B a, B b) { return _mm_xor_si128(a, b); }
TARGET inline B band(B a, B b) { return _mm_and_si128(a, b); }
TARGET inline B round(B in, B rk) { return _mm_aesenc_si128(in, rk); }
#endif

alignas(16) const uint8_t kC0[16] = {0x00, 0x01, 0x01, 0x02, 0x03, 0x05, 0x08, 0x0d,
                                     0x15, 0x22, 0x37, 0x59, 0x90, 0xe9, 0x79, 0x62};
alignas(16) const uint8_t kC1[16] = {0xdb, 0x3d, 0x18, 0x55, 0x6d, 0xc2, 0x2f, 0xf1,
                                     0x20, 0x11, 0x31, 0x42, 0x73, 0xb5, 0x28, 0xdd};

struct State {
    B s[8];

    TARGET inline void update(B m0, B m1) {
        B t = s[7];
        s[7] = round(s[6], s[7]);
        s[6] = round(s[5], s[6]);
        s[5] = round(s[4], s[5]);
        s[4] = bxor(round(s[3], s[4]), m1);
        s[3] = round(s[2], s[3]);
        s[2] = round(s[1], s[2]);
        s[1] = round(s[0], s[1]);
        s[0] = bxor(round(t, s[0]), m0);
    }

    TARGET void init(const uint8_t key[16], const uint8_t nonce[16]) {
        B k = load(key), n = load(nonce), c0 = load(kC0), c1 = load(kC1);
        B kn = bxor(k, n);
        s[0] = kn;
        s[1] = c1;
        s[2] = c0;
        s[3] = c1;
        s[4] = kn;
        s[5] = bxor(k, c0);
        s[6] = bxor(k, c1);
        s[7] = bxor(k, c0);
        for (int i = 0; i < 10; ++i) update(n, k);
    }

    TARGET void absorb(const uint8_t* ad, size_t len) {
        size_t i = 0;
        for (; i + 32 <= len; i += 32) update(load(ad + i), load(ad + i + 16));
        if (i < len) {
            alignas(16) uint8_t pad[32] = {};
            memcpy(pad, ad + i, len - i);
            update(load(pad), load(pad + 16));
        }
    }

    TARGET inline void z(B& z0, B& z1) const {
        z0 = bxor(bxor(s[6], s[1]), band(s[2], s[3]));
        z1 = bxor(bxor(s[2], s[5]), band(s[6], s[7]));
    }

    TARGET void finalize(size_t adLen, size_t msgLen, uint8_t tag[16]) {
        alignas(16) uint8_t lens[16];
        uint64_t a = static_cast<uint64_t>(adLen) * 8, m = static_cast<uint64_t>(msgLen) * 8;
        memcpy(lens, &a, 8);  // little-endian on every target we build for
        memcpy(lens + 8, &m, 8);
        B t = bxor(s[2], load(lens));
        for (int i = 0; i < 7; ++i) update(t, t);
        B out = bxor(bxor(bxor(s[0], s[1]), bxor(s[2], s[3])), bxor(bxor(s[4], s[5]), s[6]));
        store(tag, out);
    }
};

TARGET void encryptImpl(uint8_t* c, uint8_t tag[16], const uint8_t* m, size_t len, const uint8_t* ad, size_t adLen,
                        const uint8_t key[16], const uint8_t nonce[16]) {
    State st;
    st.init(key, nonce);
    st.absorb(ad, adLen);
    size_t i = 0;
    B z0, z1;
    // Two blocks per iteration keeps both AES pipelines of big cores fed.
    for (; i + 64 <= len; i += 64) {
        B t0 = load(m + i), t1 = load(m + i + 16);
        st.z(z0, z1);
        st.update(t0, t1);
        store(c + i, bxor(t0, z0));
        store(c + i + 16, bxor(t1, z1));
        B u0 = load(m + i + 32), u1 = load(m + i + 48);
        st.z(z0, z1);
        st.update(u0, u1);
        store(c + i + 32, bxor(u0, z0));
        store(c + i + 48, bxor(u1, z1));
    }
    for (; i + 32 <= len; i += 32) {
        B t0 = load(m + i), t1 = load(m + i + 16);
        st.z(z0, z1);
        st.update(t0, t1);
        store(c + i, bxor(t0, z0));
        store(c + i + 16, bxor(t1, z1));
    }
    if (i < len) {
        alignas(16) uint8_t pad[32] = {}, out[32];
        memcpy(pad, m + i, len - i);
        B t0 = load(pad), t1 = load(pad + 16);
        st.z(z0, z1);
        st.update(t0, t1);
        store(out, bxor(t0, z0));
        store(out + 16, bxor(t1, z1));
        memcpy(c + i, out, len - i);
    }
    st.finalize(adLen, len, tag);
}

TARGET bool decryptImpl(uint8_t* m, const uint8_t* c, size_t len, const uint8_t tag[16], const uint8_t* ad,
                        size_t adLen, const uint8_t key[16], const uint8_t nonce[16]) {
    State st;
    st.init(key, nonce);
    st.absorb(ad, adLen);
    size_t i = 0;
    B z0, z1;
    for (; i + 32 <= len; i += 32) {
        st.z(z0, z1);
        B o0 = bxor(load(c + i), z0), o1 = bxor(load(c + i + 16), z1);
        st.update(o0, o1);
        store(m + i, o0);
        store(m + i + 16, o1);
    }
    if (i < len) {
        alignas(16) uint8_t pad[32] = {}, out[32];
        memcpy(pad, c + i, len - i);
        st.z(z0, z1);
        store(out, bxor(load(pad), z0));
        store(out + 16, bxor(load(pad + 16), z1));
        memset(out + (len - i), 0, 32 - (len - i));  // ZeroPad(Truncate(out))
        st.update(load(out), load(out + 16));
        memcpy(m + i, out, len - i);
    }
    alignas(16) uint8_t expected[16];
    st.finalize(adLen, len, expected);
    uint8_t diff = 0;
    for (int k = 0; k < 16; ++k) diff |= static_cast<uint8_t>(expected[k] ^ tag[k]);
    return diff == 0;
}

bool hardware() {
#if defined(AEGIS_ARM)
    return (getauxval(AT_HWCAP) & HWCAP_AES) != 0;
#else
    __builtin_cpu_init();
    return __builtin_cpu_supports("aes") && __builtin_cpu_supports("sse4.1");
#endif
}

// Test vectors from draft-irtf-cfrg-aegis-aead (AEGIS-128L, 128-bit tags).
bool selfTest() {
    const uint8_t key[16] = {0x10, 0x01};
    const uint8_t nonce[16] = {0x10, 0x00, 0x02};
    // Vector 1: 16 zero bytes, no AD.
    {
        const uint8_t msg[16] = {};
        const uint8_t ct[16] = {0xc1, 0xc0, 0xe5, 0x8b, 0xd9, 0x13, 0x00, 0x6f,
                                0xeb, 0xa0, 0x0f, 0x4b, 0x3c, 0xc3, 0x59, 0x4e};
        const uint8_t tg[16] = {0xab, 0xe0, 0xec, 0xe8, 0x0c, 0x24, 0x86, 0x8a,
                                0x22, 0x6a, 0x35, 0xd1, 0x6b, 0xda, 0xe3, 0x7a};
        uint8_t c[16], t[16];
        encryptImpl(c, t, msg, 16, nullptr, 0, key, nonce);
        if (memcmp(c, ct, 16) != 0 || memcmp(t, tg, 16) != 0) return false;
    }
    // Vector 3: 32-byte message, 8-byte AD.
    {
        uint8_t ad[8], msg[32];
        for (int i = 0; i < 8; ++i) ad[i] = static_cast<uint8_t>(i);
        for (int i = 0; i < 32; ++i) msg[i] = static_cast<uint8_t>(i);
        const uint8_t ct[32] = {0x79, 0xd9, 0x45, 0x93, 0xd8, 0xc2, 0x11, 0x9d, 0x7e, 0x8f, 0xd9,
                                0xb8, 0xfc, 0x77, 0x84, 0x5c, 0x5c, 0x07, 0x7a, 0x05, 0xb2, 0x52,
                                0x8b, 0x6a, 0xc5, 0x4b, 0x56, 0x3a, 0xed, 0x8e, 0xfe, 0x84};
        const uint8_t tg[16] = {0xcc, 0x6f, 0x33, 0x72, 0xf6, 0xaa, 0x1b, 0xb8,
                                0x23, 0x88, 0xd6, 0x95, 0xc3, 0x96, 0x2d, 0x9a};
        uint8_t c[32], t[16], back[32];
        encryptImpl(c, t, msg, 32, ad, 8, key, nonce);
        if (memcmp(c, ct, 32) != 0 || memcmp(t, tg, 16) != 0) return false;
        if (!decryptImpl(back, c, 32, t, ad, 8, key, nonce) || memcmp(back, msg, 32) != 0) return false;
        t[0] ^= 1;
        if (decryptImpl(back, c, 32, t, ad, 8, key, nonce)) return false;
    }
    return true;
}

}  // namespace

bool available() {
    static const bool ok = hardware() && selfTest();
    return ok;
}

void encrypt(uint8_t* c, uint8_t tag[16], const uint8_t* m, size_t len, const uint8_t* ad, size_t adLen,
             const uint8_t key[16], const uint8_t nonce[16]) {
    encryptImpl(c, tag, m, len, ad, adLen, key, nonce);
}

bool decrypt(uint8_t* m, const uint8_t* c, size_t len, const uint8_t tag[16], const uint8_t* ad, size_t adLen,
             const uint8_t key[16], const uint8_t nonce[16]) {
    return decryptImpl(m, c, len, tag, ad, adLen, key, nonce);
}

#else  // no AES hardware path on this architecture (e.g. armeabi-v7a)

bool available() { return false; }
void encrypt(uint8_t*, uint8_t*, const uint8_t*, size_t, const uint8_t*, size_t, const uint8_t*, const uint8_t*) {}
bool decrypt(uint8_t*, const uint8_t*, size_t, const uint8_t*, const uint8_t*, size_t, const uint8_t*, const uint8_t*) {
    return false;
}

#endif

}  // namespace aegis
