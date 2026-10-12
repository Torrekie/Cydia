/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_LegacyCydiaSourceAlias_HPP
#define Cydia_LegacyCydiaSourceAlias_HPP

#include <string>
#include <sys/types.h>

namespace CydiaRuntime {
class PackageDatabasePaths;
enum class LegacyCydiaSourceAliasResult { Unchanged, Materialized, Refused };

/* Maintscript-only migration of Cydia's historical mobile cache alias. This
 * preserves the cache and exact source bytes, and never adopts another
 * frontend's alias or a diverted source. */
LegacyCydiaSourceAliasResult MaterializeLegacyCydiaSourceAlias(
    const PackageDatabasePaths &paths, const std::string &mobileHome,
    uid_t mobileOwner, gid_t mobileGroup, const std::string &adminDirectory);

/* Explicit paths and administrator identity allow disposable, unprivileged
 * host fixtures to exercise the same boundary. Production always uses UID 0. */
LegacyCydiaSourceAliasResult MaterializeLegacyCydiaSourceAliasAt(
    const std::string &source, const std::string &mobileHome,
    uid_t mobileOwner, gid_t mobileGroup, const std::string &adminDirectory,
    uid_t administrator);
}
#endif
