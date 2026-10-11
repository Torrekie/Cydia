/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ApplicationIdentity_HPP
#define Cydia_ApplicationIdentity_HPP

#include "Cydia/PrivilegedRuntime.hpp"
#include <array>
#include <set>
#include <vector>

namespace CydiaRuntime { namespace Privileged {
using ApplicationCodeHash = std::array<unsigned char, 20>;

inline uint32_t ApplicationBigEndian32(const std::string &bytes, std::size_t offset) {
    uint32_t value = 0;
    for (unsigned index = 0; index < 4; ++index)
        value = (value << 8) | static_cast<unsigned char>(bytes[offset + index]);
    return value;
}

/* Jailbreak signature loaders can downgrade the CodeDirectory version and
 * replace XML/DER entitlements in their cached signing blob. Preserve every
 * other byte, including identifier, flags, resources and executable page
 * hashes. These canonical bytes are hashed against a protected package pin. */
inline bool CanonicalApplicationCodeDirectory(const std::string &bytes, std::string *canonical) {
    if (bytes.size() < 44 || bytes.size() > 1048576 ||
        ApplicationBigEndian32(bytes, 0) != 0xfade0c02 ||
        ApplicationBigEndian32(bytes, 4) != bytes.size()) return false;
    const uint32_t version = ApplicationBigEndian32(bytes, 8);
    std::size_t header;
    switch (version) {
        case 0x20001: header = 44; break;
        case 0x20100: header = 48; break;
        case 0x20200: header = 52; break;
        case 0x20300: header = 64; break;
        case 0x20400: header = 88; break;
        case 0x20500: header = 96; break;
        case 0x20600: header = 108; break;
        default: return false;
    }
    const unsigned hashSize = static_cast<unsigned char>(bytes[36]);
    const unsigned hashType = static_cast<unsigned char>(bytes[37]);
    if (!((hashType == 1 && hashSize == 20) || (hashType == 2 && hashSize == 32) ||
          (hashType == 3 && hashSize == 20) || (hashType == 4 && hashSize == 48))) return false;
    const uint32_t offset = ApplicationBigEndian32(bytes, 16);
    const uint32_t identifier = ApplicationBigEndian32(bytes, 20);
    const uint32_t special = ApplicationBigEndian32(bytes, 24);
    const uint32_t code = ApplicationBigEndian32(bytes, 28);
    if (bytes.size() < header || special > 64 || code == 0 ||
        offset > bytes.size() || special > offset / hashSize ||
        offset - special * hashSize < header || code > (bytes.size() - offset) / hashSize ||
        identifier < header || identifier >= offset - special * hashSize ||
        bytes.find('\0', identifier) >= offset - special * hashSize) return false;
    *canonical = bytes;
    canonical->replace(8, 4, 4, '\0');
    for (unsigned slot : {5U, 7U})
        if (special >= slot) canonical->replace(offset - slot * hashSize, hashSize, hashSize, '\0');
    return true;
}

inline bool CanonicalApplicationSigningBlob(const std::string &bytes, std::vector<std::string> *directories) {
    directories->clear();
    if (bytes.size() < 8 || bytes.size() > 1048576 || ApplicationBigEndian32(bytes, 4) != bytes.size()) return false;
    const uint32_t magic = ApplicationBigEndian32(bytes, 0);
    if (magic == 0xfade0c02) {
        std::string canonical;
        if (!CanonicalApplicationCodeDirectory(bytes, &canonical)) return false;
        directories->push_back(canonical); return true;
    }
    if (magic != 0xfade0cc0 || bytes.size() < 12) return false;
    const uint32_t count = ApplicationBigEndian32(bytes, 8);
    if (count == 0 || count > 64 || count > (bytes.size() - 12) / 8) return false;
    const std::size_t table = 12 + count * 8;
    std::set<uint32_t> slots;
    std::vector<std::pair<std::size_t, std::size_t>> ranges;
    bool primary = false;
    for (unsigned index = 0; index < count; ++index) {
        const uint32_t slot = ApplicationBigEndian32(bytes, 12 + index * 8);
        const uint32_t offset = ApplicationBigEndian32(bytes, 16 + index * 8);
        if (!slots.insert(slot).second || offset < table || offset > bytes.size() - 8) return false;
        const uint32_t length = ApplicationBigEndian32(bytes, offset + 4);
        if (length < 8 || length > bytes.size() - offset) return false;
        for (const auto &range : ranges)
            if (offset < range.second && range.first < offset + length) return false;
        ranges.push_back({offset, offset + length});
        const bool executable = slot == 0 || (slot >= 0x1000 && slot < 0x1005);
        const bool directory = ApplicationBigEndian32(bytes, offset) == 0xfade0c02;
        if (executable != directory) return false;
        if (!executable) continue;
        std::string canonical;
        if (!CanonicalApplicationCodeDirectory(bytes.substr(offset, length), &canonical)) return false;
        directories->push_back(canonical); primary |= slot == 0;
    }
    return primary && !directories->empty();
}

inline bool ApplicationCodeHashesAllowed(const std::set<ApplicationCodeHash> &installed,
                                         const std::set<ApplicationCodeHash> &running) {
    if (running.empty()) return false;
    for (const auto &hash : running) if (installed.count(hash) == 0) return false;
    return true;
}

inline bool ParseApplicationCodeHashes(const std::string &bytes, std::set<ApplicationCodeHash> *hashes) {
    hashes->clear();
    const std::string header("CYDIA-APPLICATION-IDENTITY-1\n");
    if (bytes.size() > 4096 || bytes.compare(0, header.size(), header) != 0) return false;
    std::size_t offset = header.size();
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
 * signing-code identity from the manifest beside the protected helper. */
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
