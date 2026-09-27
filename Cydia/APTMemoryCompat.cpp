/* Cydia - iPhone UIKit Front-End for Debian APT
 * Darwin compatibility shims for newer embedded APT releases.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <stddef.h>

#if defined(__APPLE__)
extern "C" void *memrchr(const void *value, int character, size_t length) {
    const unsigned char *bytes(static_cast<const unsigned char *>(value));
    const unsigned char wanted(static_cast<unsigned char>(character));
    while (length != 0) {
        --length;
        if (bytes[length] == wanted)
            return const_cast<unsigned char *>(bytes + length);
    }
    return NULL;
}
#endif
