/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ApplicationIdentity_HPP
#define Cydia_ApplicationIdentity_HPP

#include "Cydia/PrivilegedRuntime.hpp"
#include <array>
#include <set>

namespace CydiaRuntime { namespace Privileged {
using ApplicationCodeHash = std::array<unsigned char, 20>;

inline bool ParseApplicationCodeHashes(const std::string &bytes, std::set<ApplicationCodeHash> *hashes) {
    hashes->clear();
    if (bytes.empty() || bytes.size() > 4096) return false;
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        if (bytes.size() - offset < 41 || bytes[offset + 40] != '\n') return false;
        ApplicationCodeHash hash;
        for (std::size_t index = 0; index < 40; ++index) {
            const char digit(bytes[offset + index]);
            const int value = digit >= '0' && digit <= '9' ? digit - '0' :
                digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 : -1;
            if (value < 0) return false;
            if (index % 2 == 0) hash[index / 2] = value << 4;
            else hash[index / 2] |= value;
        }
        hashes->insert(hash); offset += 41;
    }
    return !hashes->empty();
}

/* Only the app's own directory and executable must be immutable to mobile.
 * Shared Applications parents may follow the bootstrap's administrator policy.
 * This leaf check is NOT authorization: the caller must also match a kernel
 * process code hash from the manifest beside the protected installed helper. */
inline bool InspectApplicationExecutable(const std::string &path, struct stat *identity) {
    const std::size_t slash(path.find_last_of('/'));
    if (path.empty() || path[0] != '/' || slash == std::string::npos ||
        path.find('\0') != std::string::npos || lstat(path.c_str(), identity) != 0 ||
        !S_ISREG(identity->st_mode) || identity->st_uid != 0 || (identity->st_mode & 0022) != 0 ||
        (identity->st_mode & 0111) == 0) return false;
    struct stat directory, alias;
    const std::string parent(path.substr(0, slash));
    if (lstat(parent.c_str(), &alias) != 0 || alias.st_uid != 0 ||
        stat(parent.c_str(), &directory) != 0 || !S_ISDIR(directory.st_mode) ||
        directory.st_uid != 0 || (directory.st_mode & 0022) != 0) return false;
    return true;
}
} }
#endif
