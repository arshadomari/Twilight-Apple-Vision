// TwilightKitC: C glue between Swift and the vendored C libraries.
//
// - Re-exports the moonlight-common-c streaming API (Limelight.h).
// - Re-exports libopus multistream decoding.
// - Provides the crypto primitives the GameStream pairing handshake needs
//   (ported from Twilight's NvPairingManager/IdentityManager, which use OpenSSL),
//   implemented with mbedTLS.
// - Provides a non-variadic log hook, since Swift can't implement C varargs callbacks.

#ifndef TWILIGHTKITC_H
#define TWILIGHTKITC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "../../../Vendor/moonlight-common-c/src/Limelight.h"
#include <opus_multistream.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Logging

typedef void (*TwLogHandler)(const char* message);

// Installs the function that receives formatted log lines from moonlight-common-c.
void TwSetLogHandler(TwLogHandler handler);

// Variadic log function suitable for CONNECTION_LISTENER_CALLBACKS.logMessage.
void TwLogMessage(const char* format, ...);

// Returns a ConnListenerLogMessage pointer to TwLogMessage (avoids variadic types in Swift).
ConnListenerLogMessage TwLogMessageCallback(void);

// MARK: - Video

// Converts an Annex-B H.264/HEVC byte stream (3- or 4-byte start codes) into 4-byte big-endian
// length-prefixed NAL units, as VideoToolbox expects. Pass out = NULL to get the size needed.
// Returns the number of bytes written (or needed).
size_t TwAnnexBToLengthPrefixed(const uint8_t* in, size_t len, uint8_t* out);

// AV1 stream details read from a sequence header OBU.
typedef struct {
    int width;
    int height;
    int bitDepth;
    int colorPrimaries;          // ITU-T H.273 code points (2 = unspecified)
    int transferCharacteristics;
    int matrixCoefficients;
    bool fullRange;
} TwAV1Info;

// Finds the sequence header OBU in an AV1 temporal unit, fills `info`, and writes an ISO-BMFF
// 'av1C' configuration record (header plus the sequence header OBU) into `av1c`.
// Returns the av1C length, 0 if the temporal unit has no sequence header, or -1 if it is malformed
// or `av1cCap` is too small.
int TwAV1ParseSequenceHeader(const uint8_t* data, size_t len, TwAV1Info* info, uint8_t* av1c, size_t av1cCap);

// Copies an AV1 temporal unit without its temporal delimiter OBUs, which must not appear
// inside a sample. Pass out = NULL to get the size needed. Returns bytes written (or needed).
size_t TwAV1StripTemporalDelimiters(const uint8_t* data, size_t len, uint8_t* out);

// MARK: - Crypto

// Must be called once before any other crypto function. Returns 0 on success.
int TwCryptoInit(void);

// Fills `out` with `len` cryptographically secure random bytes. Returns 0 on success.
int TwRandomBytes(uint8_t* out, size_t len);

// Generates the client identity used for pairing: an RSA-2048 key and a self-signed
// X.509 certificate with CN "NVIDIA GameStream Client". Buffers receive NUL-terminated PEM.
// Returns 0 on success.
int TwGenerateIdentity(char* certPem, size_t certPemCap, char* keyPem, size_t keyPemCap);

// Converts the PEM private key into a PKCS#1 RSAPrivateKey DER blob (for the Keychain).
// On success returns the DER length written to the start of `out`; negative on failure.
int TwPrivateKeyPemToDer(const char* keyPem, uint8_t* out, size_t outCap);

// Converts a PEM certificate to DER. Returns DER length or negative on failure.
int TwCertPemToDer(const char* certPem, uint8_t* out, size_t outCap);

// Copies the signature bit-string of a PEM certificate. Returns the length or negative on failure.
int TwCertSignature(const char* certPem, uint8_t* out, size_t outCap);

// Hashes `data` with SHA-256 (32-byte output) or SHA-1 (20-byte output).
int TwSha256(const uint8_t* data, size_t len, uint8_t out[32]);
int TwSha1(const uint8_t* data, size_t len, uint8_t out[20]);

// AES-128-ECB with no padding. `len` must be a multiple of 16.
int TwAes128EcbEncrypt(const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out);
int TwAes128EcbDecrypt(const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out);

// SHA-256 with RSA (PKCS#1 v1.5) signing using the PEM private key.
// Returns the signature length or negative on failure.
int TwSignSha256(const char* keyPem, const uint8_t* data, size_t len, uint8_t* sig, size_t sigCap);

// Verifies a SHA-256/RSA signature against the public key in a PEM certificate.
bool TwVerifySha256(const char* certPem, const uint8_t* data, size_t len, const uint8_t* sig, size_t sigLen);

#ifdef __cplusplus
}
#endif

#endif
