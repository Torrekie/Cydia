/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptLocalStateVersion_HPP
#define Cydia_AptLocalStateVersion_HPP
#include <apt-pkg/pkgcache.h>
#include <cstring>

namespace CydiaAPT {
// Residual configuration has no CurrentVer. Only the dpkg status record can
// identify what is being purged; a newer repository candidate is not evidence.
inline pkgCache::VerIterator LocalStateVersion(pkgCache::PkgIterator package) {
    if (package.end()) return pkgCache::VerIterator();
    const pkgCache::VerIterator installed(package.CurrentVer());
    if (!installed.end()) return installed;
    if (package->CurrentState == pkgCache::State::ConfigFiles) {
        for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version)
            for (pkgCache::VerFileIterator file(version.FileList()); !file.end(); ++file) {
                const char *type(file.File().IndexType());
                if (type != nullptr && std::strcmp(type, "Debian dpkg status file") == 0) return version;
            }
    }
    return pkgCache::VerIterator();
}
} // namespace CydiaAPT
#endif
