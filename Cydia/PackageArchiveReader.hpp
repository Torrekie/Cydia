/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PackageArchiveReader_HPP
#define Cydia_PackageArchiveReader_HPP
#include "Cydia/PackageArchivePolicy.hpp"

namespace CydiaPackages {
/* Uses the active APT compressor configuration. The caller serializes APT
 * access and supplies the exact queued archive identity and selected layout.
 * No files are extracted and no package scripts are executed. Archive hash
 * verification and ensuring this is the file subsequently given to dpkg
 * remain the acquisition/transaction owner's responsibility. */
ArchivePolicyResult InspectPackageArchive(const std::string &path,
                                         const ArchiveIdentity &expected,
                                         const ArchiveLayout &layout,
                                         const ArchiveLimits &limits = ArchiveLimits());
}
#endif
