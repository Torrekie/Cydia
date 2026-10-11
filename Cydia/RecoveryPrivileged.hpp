/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RecoveryPrivileged_HPP
#define Cydia_RecoveryPrivileged_HPP
#include "Cydia/RecoveryPlan.hpp"
#include "Cydia/SourceDocumentCommit.hpp"
#include "Cydia/PrivilegedRuntime.hpp"
#include <functional>
namespace CydiaRuntime { namespace Recovery {
struct ScriptSnapshot {
    std::string path, suffix;
    CydiaSources::ProtectedFileSnapshot file;
};
struct Snapshot {
    CydiaSources::ProtectedFileSnapshot status;
    std::vector<ScriptSnapshot> scripts;
    Review review;
};
struct RemovalResult {
    std::string backupDirectory;
    int exitCode;
    bool scriptsRestored;
    RemovalResult() : exitCode(-1), scriptsRestored(false) {}
};
/* Independently resolved environment and native dpkg architecture are
 * required. No script pathname or backup destination arrives from the app.
 * trustedOwner is only a host-fixture seam; cydo always uses root. */
bool Prepare(const Privileged::Environment &environment, const std::string &identity,
             const std::string &nativeArchitecture, Snapshot *snapshot,
             Privileged::Error *error, uid_t trustedOwner = 0);
/* The caller holds the active frontend lock and rechecks runtime evidence.
 * Every original script and chosen package stanza is durably backed up before
 * the first unlink. Failure restores only absent original files, never
 * overwrites another manager's work or follows a symlink. */
bool Remove(const std::string &privateState, const Privileged::Environment &environment,
            const std::string &identity, const std::string &nativeArchitecture,
            const std::string &reviewToken,
            const std::function<int(const std::string &)> &executeRemoval,
            RemovalResult *result, Privileged::Error *error, uid_t trustedOwner = 0);
} }
#endif
