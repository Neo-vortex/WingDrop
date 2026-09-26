// AEGIS-128L authenticated encryption (draft-irtf-cfrg-aegis-aead) on the
// CPU's AES round instructions: ARMv8 Crypto Extensions (AESE/AESMC) or
// x86 AES-NI. ~2-3x faster than AES-GCM and 3-4x faster than
// ChaCha20-Poly1305 wherever AES hardware exists.
#pragma once

#include <cstddef>
#include <cstdint>

namespace aegis {

// True when the CPU has AES instructions and the known-answer self-test passed.
bool available();

// In-place operation (c == m) is allowed.
void encrypt(uint8_t* c, uint8_t tag[16], const uint8_t* m, size_t len, const uint8_t* ad, size_t adLen,
             const uint8_t key[16], const uint8_t nonce[16]);

// Returns false (and leaves garbage in m) if authentication fails.
bool decrypt(uint8_t* m, const uint8_t* c, size_t len, const uint8_t tag[16], const uint8_t* ad, size_t adLen,
             const uint8_t key[16], const uint8_t nonce[16]);

}  // namespace aegis
