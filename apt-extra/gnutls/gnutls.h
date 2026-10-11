/*
 * Narrow GnuTLS compatibility surface for APT's iOS method backend.
 *
 * APT's upstream method uses GnuTLS, which is not shipped by iOS.  The
 * Cydia build keeps the same method source/API but maps its stream operations
 * to Apple's SecureTransport.  Non-Apple builds retain the real GnuTLS header.
 */
#if !defined(__APPLE__)
# include_next <gnutls/gnutls.h>
#else

#ifndef CYDIA_GNUTLS_COMPAT_H
#define CYDIA_GNUTLS_COMPAT_H

#include <Security/SecureTransport.h>
#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void *gnutls_transport_ptr_t;
typedef struct cydia_gnutls_session *gnutls_session_t;
typedef struct cydia_gnutls_credentials *gnutls_certificate_credentials_t;
typedef struct {
    unsigned char *data;
    unsigned int size;
} gnutls_datum_t;

typedef ssize_t (*gnutls_pull_func)(gnutls_transport_ptr_t, void *, size_t);
typedef ssize_t (*gnutls_push_func)(gnutls_transport_ptr_t, const void *, size_t);

enum {
    GNUTLS_CLIENT = 1u << 0,
    GNUTLS_NONBLOCK = 1u << 1,
    GNUTLS_CRD_CERTIFICATE = 1,
    GNUTLS_NAME_DNS = 1,
    GNUTLS_X509_FMT_PEM = 1,
    GNUTLS_VERIFY_ALLOW_X509_V1_CA_CRT = 1,
    GNUTLS_SHUT_RDWR = 1,
    GNUTLS_E_INTERRUPTED = -4,
    GNUTLS_E_AGAIN = -10,
    GNUTLS_E_REHANDSHAKE = -37,
    GNUTLS_E_CERTIFICATE_VERIFICATION_ERROR = -43,
    GNUTLS_E_UNIMPLEMENTED_FEATURE = -125,
};

struct cydia_gnutls_credentials { };

struct cydia_gnutls_session {
    SSLContextRef context;
    gnutls_transport_ptr_t transport;
    int fd;
    gnutls_pull_func pull;
    gnutls_push_func push;
};

static inline OSStatus cydia_gnutls_read(SSLConnectionRef connection, void *data, size_t *length)
{
    gnutls_session_t session = (gnutls_session_t)connection;
    ssize_t result;
    if (session->pull != NULL)
        result = session->pull(session->transport, data, *length);
    else
        result = read(session->fd, data, *length);
    if (result < 0) {
        *length = 0;
        return errno == EAGAIN || errno == EWOULDBLOCK ? errSSLWouldBlock : (OSStatus)-1;
    }
    *length = (size_t)result;
    return noErr;
}

static inline OSStatus cydia_gnutls_write(SSLConnectionRef connection, const void *data, size_t *length)
{
    gnutls_session_t session = (gnutls_session_t)connection;
    ssize_t result;
    if (session->push != NULL)
        result = session->push(session->transport, data, *length);
    else
        result = write(session->fd, data, *length);
    if (result < 0) {
        *length = 0;
        return errno == EAGAIN || errno == EWOULDBLOCK ? errSSLWouldBlock : (OSStatus)-1;
    }
    *length = (size_t)result;
    return noErr;
}

static inline int cydia_gnutls_status(OSStatus status)
{
    if (status == noErr || status == errSSLServerAuthCompleted)
        return 0;
    if (status == errSSLWouldBlock)
        return GNUTLS_E_AGAIN;
    if (status == errSSLClosedGraceful)
        return 0;
    return (int)status;
}

static inline int gnutls_init(gnutls_session_t *session, unsigned int flags)
{
    (void)flags;
    *session = (gnutls_session_t)calloc(1, sizeof(**session));
    if (*session == NULL)
        return -1;
    (*session)->fd = -1;
    (*session)->context = SSLCreateContext(NULL, kSSLClientSide, kSSLStreamType);
    if ((*session)->context == NULL) {
        free(*session);
        *session = NULL;
        return -1;
    }
    SSLSetIOFuncs((*session)->context, cydia_gnutls_read, cydia_gnutls_write);
    SSLSetConnection((*session)->context, *session);
    SSLSetProtocolVersionMin((*session)->context, kTLSProtocol1);
    return 0;
}

static inline int gnutls_handshake(gnutls_session_t session)
{
    return cydia_gnutls_status(SSLHandshake(session->context));
}

static inline ssize_t gnutls_record_recv(gnutls_session_t session, void *data, size_t length)
{
    size_t processed = 0;
    OSStatus status = SSLRead(session->context, data, length, &processed);
    return status == noErr ? (ssize_t)processed : cydia_gnutls_status(status);
}

static inline ssize_t gnutls_record_send(gnutls_session_t session, const void *data, size_t length)
{
    size_t processed = 0;
    OSStatus status = SSLWrite(session->context, data, length, &processed);
    return status == noErr ? (ssize_t)processed : cydia_gnutls_status(status);
}

static inline int gnutls_record_get_direction(gnutls_session_t session)
{
    (void)session;
    return 0;
}

static inline int gnutls_record_check_pending(gnutls_session_t session)
{
    (void)session;
    return 0;
}

static inline int gnutls_bye(gnutls_session_t session, int how)
{
    (void)how;
    return cydia_gnutls_status(SSLClose(session->context));
}

static inline void gnutls_deinit(gnutls_session_t session)
{
    if (session == NULL)
        return;
    if (session->context != NULL)
        CFRelease(session->context);
    free(session);
}

static inline void gnutls_transport_set_int(gnutls_session_t session, int fd)
{
    session->fd = fd;
    session->transport = NULL;
}

static inline void gnutls_transport_set_ptr(gnutls_session_t session, gnutls_transport_ptr_t ptr)
{
    session->transport = ptr;
}

static inline void gnutls_transport_set_pull_function(gnutls_session_t session, gnutls_pull_func pull)
{
    session->pull = pull;
}

static inline void gnutls_transport_set_push_function(gnutls_session_t session, gnutls_push_func push)
{
    session->push = push;
}

static inline int gnutls_server_name_set(gnutls_session_t session, int type, const void *name, size_t length)
{
    (void)type;
    return cydia_gnutls_status(SSLSetPeerDomainName(session->context, (const char *)name, length));
}

static inline int gnutls_session_set_verify_cert(gnutls_session_t session, const char *hostname, unsigned int flags)
{
    (void)session;
    (void)hostname;
    (void)flags;
    return 0;
}

static inline int gnutls_set_default_priority(gnutls_session_t session)
{
    (void)session;
    return 0;
}

static inline int gnutls_credentials_set(gnutls_session_t session, int type, gnutls_certificate_credentials_t credentials)
{
    (void)session;
    (void)type;
    (void)credentials;
    return 0;
}

static inline int gnutls_certificate_allocate_credentials(gnutls_certificate_credentials_t *credentials)
{
    *credentials = (gnutls_certificate_credentials_t)calloc(1, sizeof(**credentials));
    return *credentials == NULL ? -1 : 0;
}

static inline void gnutls_certificate_free_credentials(gnutls_certificate_credentials_t credentials)
{
    free(credentials);
}

static inline int gnutls_certificate_set_x509_system_trust(gnutls_certificate_credentials_t credentials)
{
    (void)credentials;
    /* SecureTransport already evaluates the peer against Apple's system
     * trust service. APT only distinguishes unavailable (zero) from a
     * positive result; no exported PEM bundle is required on iOS. */
    return 1;
}

static inline int gnutls_certificate_set_x509_trust_file(gnutls_certificate_credentials_t credentials, const char *file, int format)
{
    (void)credentials;
    (void)file;
    (void)format;
    return GNUTLS_E_UNIMPLEMENTED_FEATURE;
}

static inline int gnutls_certificate_set_x509_key_file(gnutls_certificate_credentials_t credentials, const char *cert, const char *key, int format)
{
    (void)credentials;
    (void)cert;
    (void)key;
    (void)format;
    return GNUTLS_E_UNIMPLEMENTED_FEATURE;
}

static inline int gnutls_certificate_set_x509_crl_file(gnutls_certificate_credentials_t credentials, const char *file, int format)
{
    (void)credentials;
    (void)file;
    (void)format;
    return GNUTLS_E_UNIMPLEMENTED_FEATURE;
}

static inline void gnutls_certificate_set_verify_flags(gnutls_certificate_credentials_t credentials, unsigned int flags)
{
    (void)credentials;
    (void)flags;
}

static inline int gnutls_certificate_type_get(gnutls_session_t session)
{
    (void)session;
    return 0;
}

static inline unsigned int gnutls_session_get_verify_cert_status(gnutls_session_t session)
{
    (void)session;
    return 0;
}

static inline int gnutls_certificate_verification_status_print(unsigned int status, int type, gnutls_datum_t *output, unsigned int flags)
{
    (void)status;
    (void)type;
    (void)flags;
    output->data = NULL;
    output->size = 0;
    return -1;
}

static inline void gnutls_free(void *value)
{
    free(value);
}

static inline int gnutls_error_is_fatal(int error)
{
    return error != GNUTLS_E_AGAIN && error != GNUTLS_E_INTERRUPTED;
}

static inline const char *gnutls_strerror(int error)
{
    if (error == GNUTLS_E_UNIMPLEMENTED_FEATURE)
        return "Custom CA files, client certificates and revocation lists are not supported by this SecureTransport backend";
    return "SecureTransport error";
}

#endif

#endif
