/*
 * APT 2.7 uses the libgcrypt digest API for its hash wrapper.  libgcrypt is
 * not part of iOS, while CommonCrypto is provided by libSystem and supports
 * the iOS 12 deployment target.  Keep this small API-compatible adapter in
 * the Cydia compatibility include path; non-Apple builds continue to use the
 * platform libgcrypt header.
 */
#if !defined(__APPLE__)
# include_next <gcrypt.h>
#else

#include <CommonCrypto/CommonDigest.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned int gcry_error_t;

enum {
    GCRY_MD_MD5 = 1,
    GCRY_MD_SHA1 = 2,
    GCRY_MD_SHA256 = 8,
    GCRY_MD_SHA512 = 10,
};

static inline unsigned int cydia_gcry_mask(int algorithm)
{
    switch (algorithm) {
    case GCRY_MD_MD5: return 1u << 0;
    case GCRY_MD_SHA1: return 1u << 1;
    case GCRY_MD_SHA256: return 1u << 2;
    case GCRY_MD_SHA512: return 1u << 3;
    default: return 0;
    }
}

enum {
    GCRYCTL_INITIALIZATION_FINISHED_P = 1,
    GCRYCTL_INITIALIZATION_FINISHED = 2,
};

struct cydia_gcry_md_handle {
    unsigned int enabled;
    unsigned int finalized;
    CC_MD5_CTX md5;
    CC_SHA1_CTX sha1;
    CC_SHA256_CTX sha256;
    CC_SHA512_CTX sha512;
    unsigned char md5_digest[CC_MD5_DIGEST_LENGTH];
    unsigned char sha1_digest[CC_SHA1_DIGEST_LENGTH];
    unsigned char sha256_digest[CC_SHA256_DIGEST_LENGTH];
    unsigned char sha512_digest[CC_SHA512_DIGEST_LENGTH];
};
typedef struct cydia_gcry_md_handle *gcry_md_hd_t;

static inline int gcry_control(int command, ...)
{
    return command == GCRYCTL_INITIALIZATION_FINISHED_P;
}

static inline const char *gcry_check_version(const char *required)
{
    (void)required;
    return "cydia-commoncrypto";
}

static inline gcry_error_t gcry_md_open(gcry_md_hd_t *handle, int ignored, unsigned int flags)
{
    (void)ignored;
    (void)flags;
    *handle = (gcry_md_hd_t)calloc(1, sizeof(**handle));
    return *handle == NULL;
}

static inline gcry_error_t gcry_md_enable(gcry_md_hd_t handle, int algorithm)
{
    if (handle == NULL)
        return 1;
    switch (algorithm) {
    case GCRY_MD_MD5:
        handle->enabled |= cydia_gcry_mask(algorithm);
        return CC_MD5_Init(&handle->md5) == 1 ? 0 : 1;
    case GCRY_MD_SHA1:
        handle->enabled |= cydia_gcry_mask(algorithm);
        return CC_SHA1_Init(&handle->sha1) == 1 ? 0 : 1;
    case GCRY_MD_SHA256:
        handle->enabled |= cydia_gcry_mask(algorithm);
        return CC_SHA256_Init(&handle->sha256) == 1 ? 0 : 1;
    case GCRY_MD_SHA512:
        handle->enabled |= cydia_gcry_mask(algorithm);
        return CC_SHA512_Init(&handle->sha512) == 1 ? 0 : 1;
    default:
        return 1;
    }
}

static inline void gcry_md_close(gcry_md_hd_t handle)
{
    if (handle != NULL)
        free(handle);
}

static inline gcry_error_t gcry_md_write(gcry_md_hd_t handle, const void *data, size_t length)
{
    if (handle == NULL || handle->finalized != 0 || length > UINT_MAX)
        return 1;
    if ((handle->enabled & cydia_gcry_mask(GCRY_MD_MD5)) != 0)
        CC_MD5_Update(&handle->md5, data, (CC_LONG)length);
    if ((handle->enabled & cydia_gcry_mask(GCRY_MD_SHA1)) != 0)
        CC_SHA1_Update(&handle->sha1, data, (CC_LONG)length);
    if ((handle->enabled & cydia_gcry_mask(GCRY_MD_SHA256)) != 0)
        CC_SHA256_Update(&handle->sha256, data, (CC_LONG)length);
    if ((handle->enabled & cydia_gcry_mask(GCRY_MD_SHA512)) != 0)
        CC_SHA512_Update(&handle->sha512, data, (CC_LONG)length);
    return 0;
}

static inline unsigned int gcry_md_get_algo_dlen(int algorithm)
{
    switch (algorithm) {
    case GCRY_MD_MD5: return CC_MD5_DIGEST_LENGTH;
    case GCRY_MD_SHA1: return CC_SHA1_DIGEST_LENGTH;
    case GCRY_MD_SHA256: return CC_SHA256_DIGEST_LENGTH;
    case GCRY_MD_SHA512: return CC_SHA512_DIGEST_LENGTH;
    default: return 0;
    }
}

static inline const unsigned char *gcry_md_read(gcry_md_hd_t handle, int algorithm)
{
    if (handle == NULL)
        return NULL;
    if (handle->finalized == 0) {
        if ((handle->enabled & cydia_gcry_mask(GCRY_MD_MD5)) != 0)
            CC_MD5_Final(handle->md5_digest, &handle->md5);
        if ((handle->enabled & cydia_gcry_mask(GCRY_MD_SHA1)) != 0)
            CC_SHA1_Final(handle->sha1_digest, &handle->sha1);
        if ((handle->enabled & cydia_gcry_mask(GCRY_MD_SHA256)) != 0)
            CC_SHA256_Final(handle->sha256_digest, &handle->sha256);
        if ((handle->enabled & cydia_gcry_mask(GCRY_MD_SHA512)) != 0)
            CC_SHA512_Final(handle->sha512_digest, &handle->sha512);
        handle->finalized = 1;
    }
    switch (algorithm) {
    case GCRY_MD_MD5: return handle->md5_digest;
    case GCRY_MD_SHA1: return handle->sha1_digest;
    case GCRY_MD_SHA256: return handle->sha256_digest;
    case GCRY_MD_SHA512: return handle->sha512_digest;
    default: return NULL;
    }
}

static inline int gcry_md_is_enabled(gcry_md_hd_t handle, int algorithm)
{
    return handle != NULL && (handle->enabled & cydia_gcry_mask(algorithm)) != 0;
}

#endif
