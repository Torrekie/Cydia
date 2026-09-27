#ifndef APT_H
#define APT_H

#include <stddef.h>
#include <unistd.h>
#define DPKG_DATADIR "/usr/share/dpkg"

/* Apple platforms expose the ICU and APT ABI used by Cydia but do not expose
 * glibc's memrchr declaration.  Keep the declaration in the forced APT
 * compatibility header; the small implementation lives in the app-owned
 * Cydia source set rather than in a particular APT checkout. */
#if defined(__APPLE__)
extern "C" void *memrchr(const void *value, int character, size_t length);
#endif

template <typename Type_>
static Type_ *strchrnul(Type_ *s, int c) {
    while (*s != c && *s != '\0')
        ++s;
    return s;
}

#define faccessat(arg0, arg1, arg2, arg3) \
    access(arg1, arg2)

#if 0
#include <syslog.h>
static unsigned nonce(0);
#define _trace() syslog(LOG_ERR, "_trace():%s[%u] #%u\n", __FILE__, __LINE__, ++nonce)
#endif

#endif//APT_H
