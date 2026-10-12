/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PackageArchiveReader.hpp"
#include "Cydia/PrivilegedRuntime.hpp"
#include <cstdlib>
#include <utility>

namespace CydiaPackages {
bool ResolveTrustedArchiveDecoders(const std::string &path,
    std::map<std::string, std::string> *decoders, std::string *error) {
    if (!decoders || path.empty() || path.size() > 16384 || path.find('\0') != std::string::npos) {
        if (error) *error = "provider_decoder_invalid_search_path";
        return false;
    }
    std::vector<std::string> directories;
    std::size_t start = 0;
    while (start <= path.size()) {
        const auto end = path.find(':', start);
        const std::string directory = path.substr(start, end == std::string::npos ? end : end - start);
        if (directory.empty() || directory.front() != '/' || directory.find_first_of("\r\n\t") != std::string::npos) {
            if (error) *error = "provider_decoder_invalid_search_path";
            return false;
        }
        directories.push_back(directory);
        if (end == std::string::npos) break;
        start = end + 1;
    }
    std::map<std::string, std::string> result;
    for (const auto &type : std::vector<std::pair<std::string, std::string>>{
            {"gzip", "gzip"}, {"bzip2", "bzip2"}, {"xz", "xz"}, {"lzma", "xz"}, {"lz4", "lz4"}, {"zstd", "zstd"}}) {
        for (const auto &directory : directories) {
            const std::string candidate = directory + (directory.back() == '/' ? "" : "/") + type.second;
            CydiaRuntime::Privileged::Error ignored;
            if (!CydiaRuntime::Privileged::ValidateRootOwnedPath(candidate, false, true, &ignored)) continue;
            char *canonical = realpath(candidate.c_str(), nullptr);
            if (canonical) { result[type.first] = canonical; free(canonical); break; }
        }
    }
    *decoders = std::move(result);
    if (error) error->clear();
    return true;
}
}
