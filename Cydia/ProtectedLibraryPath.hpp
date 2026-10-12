/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ProtectedLibraryPath_HPP
#define Cydia_ProtectedLibraryPath_HPP

#include <cstdlib>
#include <string>
#include <sys/stat.h>

namespace CydiaRuntime {
namespace LibraryPath {
inline bool CanonicalChain(std::string path, bool directory) {
    bool leaf(true);
    for (;;) {
        struct stat value;
        if (lstat(path.c_str(), &value) != 0 || value.st_uid != 0 ||
            (value.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
            ((leaf && !directory) ? !S_ISREG(value.st_mode) : !S_ISDIR(value.st_mode))) return false;
        if (path == "/") return true;
        const auto slash(path.rfind('/'));
        if (slash == std::string::npos) return false;
        path.resize(slash == 0 ? 1 : slash); leaf = false;
    }
}
}

/* Validate every spelling prefix as well as its canonical target. Checking
 * only the final realpath would allow a writable alias to be exchanged between
 * validation and dlopen. Return the canonical name for the actual load. */
inline std::string ProtectedLibraryPath(const std::string &path, bool directory = false) {
    if (path.empty() || path[0] != '/' || path.find('\0') != std::string::npos) return {};
    std::string canonical;
    for (std::size_t end(1); ; ) {
        end = path.find('/', end);
        const bool last(end == std::string::npos);
        const std::string prefix(path.substr(0, end));
        struct stat value;
        if (lstat(prefix.c_str(), &value) != 0 || value.st_uid != 0 ||
            (!S_ISLNK(value.st_mode) && (value.st_mode & (S_IWGRP | S_IWOTH)) != 0)) return {};
        char *resolved(realpath(prefix.c_str(), nullptr));
        if (resolved == nullptr) return {};
        canonical = resolved; std::free(resolved);
        if (!LibraryPath::CanonicalChain(canonical, !last || directory)) return {};
        if (last) return canonical;
        ++end;
    }
}
}
#endif
