// Pairing crypto for TwilightKit, implemented with mbedTLS.
// Mirrors the OpenSSL logic in Twilight's app/backend/nvpairingmanager.cpp and identitymanager.cpp.

#include "TwilightKitC.h"

#include <stdlib.h>
#include <string.h>

#include <mbedtls/aes.h>
#include <mbedtls/pem.h>
#include <mbedtls/pk.h>
#include <mbedtls/rsa.h>
#include <mbedtls/sha1.h>
#include <mbedtls/sha256.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/x509_csr.h>
#include <psa/crypto.h>

// arc4random_buf is the platform CSPRNG on Apple systems.
static int twRng(void* ctx, unsigned char* out, size_t len) {
    (void)ctx;
    arc4random_buf(out, len);
    return 0;
}

int TwCryptoInit(void) {
    return psa_crypto_init() == PSA_SUCCESS ? 0 : -1;
}

int TwRandomBytes(uint8_t* out, size_t len) {
    return twRng(NULL, out, len);
}

int TwGenerateIdentity(char* certPem, size_t certPemCap, char* keyPem, size_t keyPemCap) {
    int ret;
    mbedtls_pk_context key;
    mbedtls_x509write_cert crt;
    unsigned char serial[8];

    mbedtls_pk_init(&key);
    mbedtls_x509write_crt_init(&crt);

    if ((ret = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA))) != 0) goto out;
    if ((ret = mbedtls_rsa_gen_key(mbedtls_pk_rsa(key), twRng, NULL, 2048, 65537)) != 0) goto out;

    twRng(NULL, serial, sizeof(serial));
    serial[0] &= 0x7F; // Keep the serial number positive

    mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&crt, &key);
    mbedtls_x509write_crt_set_issuer_key(&crt, &key);
    if ((ret = mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial))) != 0) goto out;
    if ((ret = mbedtls_x509write_crt_set_subject_name(&crt, "CN=NVIDIA GameStream Client")) != 0) goto out;
    if ((ret = mbedtls_x509write_crt_set_issuer_name(&crt, "CN=NVIDIA GameStream Client")) != 0) goto out;
    // mbedTLS emits an empty (invalid) extensions block for v3 certs without extensions,
    // which Apple's Security framework rejects. Basic constraints keeps it well-formed.
    if ((ret = mbedtls_x509write_crt_set_basic_constraints(&crt, 0, -1)) != 0) goto out;
    // Twilight uses a 20 year validity period
    if ((ret = mbedtls_x509write_crt_set_validity(&crt, "20250101000000", "20450101000000")) != 0) goto out;

    if ((ret = mbedtls_x509write_crt_pem(&crt, (unsigned char*)certPem, certPemCap, twRng, NULL)) != 0) goto out;
    if ((ret = mbedtls_pk_write_key_pem(&key, (unsigned char*)keyPem, keyPemCap)) != 0) goto out;

out:
    mbedtls_x509write_crt_free(&crt);
    mbedtls_pk_free(&key);
    return ret;
}

static int twParseKey(mbedtls_pk_context* key, const char* keyPem) {
    mbedtls_pk_init(key);
    return mbedtls_pk_parse_key(key, (const unsigned char*)keyPem, strlen(keyPem) + 1, NULL, 0, twRng, NULL);
}

static int twParseCert(mbedtls_x509_crt* crt, const char* certPem) {
    mbedtls_x509_crt_init(crt);
    return mbedtls_x509_crt_parse(crt, (const unsigned char*)certPem, strlen(certPem) + 1);
}

int TwPrivateKeyPemToDer(const char* keyPem, uint8_t* out, size_t outCap) {
    mbedtls_pk_context key;
    int ret = twParseKey(&key, keyPem);
    if (ret == 0) {
        // mbedtls_pk_write_key_der writes at the END of the buffer and returns the length
        ret = mbedtls_pk_write_key_der(&key, out, outCap);
        if (ret > 0) {
            memmove(out, out + outCap - ret, ret);
        }
    }
    else {
        ret = -1;
    }
    mbedtls_pk_free(&key);
    return ret;
}

int TwCertPemToDer(const char* certPem, uint8_t* out, size_t outCap) {
    mbedtls_x509_crt crt;
    int ret = twParseCert(&crt, certPem);
    if (ret == 0) {
        if (crt.raw.len <= outCap) {
            memcpy(out, crt.raw.p, crt.raw.len);
            ret = (int)crt.raw.len;
        }
        else {
            ret = -1;
        }
    }
    else {
        ret = -1;
    }
    mbedtls_x509_crt_free(&crt);
    return ret;
}

int TwCertSignature(const char* certPem, uint8_t* out, size_t outCap) {
    mbedtls_x509_crt crt;
    int ret = twParseCert(&crt, certPem);
    if (ret == 0) {
        if (crt.MBEDTLS_PRIVATE(sig).len <= outCap) {
            memcpy(out, crt.MBEDTLS_PRIVATE(sig).p, crt.MBEDTLS_PRIVATE(sig).len);
            ret = (int)crt.MBEDTLS_PRIVATE(sig).len;
        }
        else {
            ret = -1;
        }
    }
    else {
        ret = -1;
    }
    mbedtls_x509_crt_free(&crt);
    return ret;
}

int TwSha256(const uint8_t* data, size_t len, uint8_t out[32]) {
    return mbedtls_sha256(data, len, out, 0);
}

int TwSha1(const uint8_t* data, size_t len, uint8_t out[20]) {
    return mbedtls_sha1(data, len, out);
}

static int twAesEcb(int mode, const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out) {
    if (len % 16 != 0) {
        return -1;
    }

    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    int ret = mode == MBEDTLS_AES_ENCRYPT ?
        mbedtls_aes_setkey_enc(&aes, key, 128) :
        mbedtls_aes_setkey_dec(&aes, key, 128);
    for (size_t i = 0; ret == 0 && i < len; i += 16) {
        ret = mbedtls_aes_crypt_ecb(&aes, mode, in + i, out + i);
    }
    mbedtls_aes_free(&aes);
    return ret;
}

int TwAes128EcbEncrypt(const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out) {
    return twAesEcb(MBEDTLS_AES_ENCRYPT, key, in, len, out);
}

int TwAes128EcbDecrypt(const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out) {
    return twAesEcb(MBEDTLS_AES_DECRYPT, key, in, len, out);
}

int TwSignSha256(const char* keyPem, const uint8_t* data, size_t len, uint8_t* sig, size_t sigCap) {
    uint8_t hash[32];
    size_t sigLen = 0;
    mbedtls_pk_context key;

    int ret = twParseKey(&key, keyPem);
    if (ret == 0) {
        ret = mbedtls_sha256(data, len, hash, 0);
    }
    if (ret == 0) {
        ret = mbedtls_pk_sign(&key, MBEDTLS_MD_SHA256, hash, sizeof(hash), sig, sigCap, &sigLen, twRng, NULL);
    }
    mbedtls_pk_free(&key);
    return ret == 0 ? (int)sigLen : -1;
}

bool TwVerifySha256(const char* certPem, const uint8_t* data, size_t len, const uint8_t* sig, size_t sigLen) {
    uint8_t hash[32];
    mbedtls_x509_crt crt;

    int ret = twParseCert(&crt, certPem);
    if (ret == 0) {
        ret = mbedtls_sha256(data, len, hash, 0);
    }
    if (ret == 0) {
        ret = mbedtls_pk_verify(&crt.pk, MBEDTLS_MD_SHA256, hash, sizeof(hash), sig, sigLen);
    }
    mbedtls_x509_crt_free(&crt);
    return ret == 0;
}
