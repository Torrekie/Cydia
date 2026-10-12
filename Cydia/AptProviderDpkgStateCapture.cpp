/* Read-only production capture kept separate from the pure transition model.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/RuntimeState.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
bool Fail(std::string *error, const char *code) {
    if (error) *error = code;
    return false;
}
bool ParentLock(const CydiaRuntime::Privileged::Environment &environment, int descriptor) {
    namespace P = CydiaRuntime::Privileged;
    P::Error ignored; struct stat opened, named;
    const std::string path(environment.dpkgAdmin + "/lock-frontend");
    // Do not open this path: closing any fd for the lock inode in this process
    // drops its POSIX record locks, including the broker's retained one.
    if (descriptor < 3 || !P::ValidateDpkgAdminPath(path, false, &ignored) ||
        fstat(descriptor, &opened) != 0 || lstat(path.c_str(), &named) != 0 ||
        !S_ISREG(named.st_mode) || named.st_nlink != 1 || opened.st_dev != named.st_dev ||
        opened.st_ino != named.st_ino || opened.st_uid != named.st_uid || opened.st_mode != named.st_mode)
        return false;
    struct flock lock = {};
    lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
    return fcntl(descriptor, F_SETLK, &lock) == 0;
}
bool JournalSettled(const CydiaRuntime::Privileged::Environment &environment) {
    CydiaRuntime::Privileged::Evidence journal; CydiaRuntime::Privileged::Error ignored;
    if (!CydiaRuntime::Privileged::CaptureAdminEvidence(environment.dpkgAdmin + "/updates",
            true, true, &journal, &ignored)) return false;
    for (const auto &name : journal.entries)
        if (!name.empty() && name.find_first_not_of("0123456789") == std::string::npos) return false;
    return CydiaRuntime::Privileged::RecheckEvidence({journal}, &ignored);
}
bool CaptureDeferredTriggers(const CydiaRuntime::Privileged::Environment &environment,
                             std::vector<CydiaRuntime::Privileged::Evidence> *evidence) {
    namespace P = CydiaRuntime::Privileged;
    P::Evidence directory, pending; P::Error ignored;
    const std::string path(environment.dpkgAdmin + "/triggers");
    if (!P::CaptureAdminEvidence(path, true, true, &directory, &ignored)) return false;
    evidence->push_back(directory);
    if (directory.absent) return true;
    // dpkg-query's status fields cannot prove the absence of trigger
    // activations still queued in the separate Unincorp journal.
    if (!P::CaptureAdminEvidence(path + "/Unincorp", false, true, &pending, &ignored) ||
        !pending.bytes.empty()) return false;
    evidence->push_back(pending);
    return P::RecheckEvidence(*evidence, &ignored);
}
}
bool CaptureDpkgState(const CydiaRuntime::Privileged::Environment &environment,
                     int frontendLockDescriptor, DpkgState *state, std::string *error,
                     const std::function<bool()> &cancelled) {
    if (!state) return Fail(error, "provider_dpkg_state_invalid");
    *state = DpkgState();
    namespace P = CydiaRuntime::Privileged;
    P::Error ignored; P::Evidence dpkg, query;
    if (!ParentLock(environment, frontendLockDescriptor)) return Fail(error, "provider_frontend_lock_missing");
    if (!P::RecheckEvidence(environment.evidence, &ignored) ||
        !P::CapturePathIdentity(environment.dpkg, false, true, &dpkg, &ignored) ||
        !P::CapturePathIdentity(environment.dpkgQuery, false, true, &query, &ignored))
        return Fail(error, "provider_environment_changed");
    std::string before, after, native, foreign, records;
    std::vector<P::Evidence> triggerEvidence;
    if (!JournalSettled(environment) || !CaptureDeferredTriggers(environment, &triggerEvidence) ||
        !P::RuntimeSnapshot(environment, &before, &ignored))
        return Fail(error, "provider_dpkg_state_unavailable");
    CydiaRuntime::Dpkg::Runner manager(environment.dpkg), reader(environment.dpkgQuery);
    std::vector<std::string> arguments{"--root=" + environment.dpkgRoot,
        "--admindir=" + environment.dpkgAdmin, "--print-architecture"};
    if (!manager.RunAndCaptureBounded(arguments, &native, 32768, 3000, cancelled).succeeded())
        return Fail(error, "provider_dpkg_architecture_query_failed");
    arguments.back() = "--print-foreign-architectures";
    if (!manager.RunAndCaptureBounded(arguments, &foreign, 32768, 3000, cancelled).succeeded())
        return Fail(error, "provider_dpkg_architecture_query_failed");
    // --admindir alone selects this read-only database and supports older
    // dpkg-query versions that predate its --root option. No --load-avail:
    // repository metadata must never masquerade as installed package state.
    arguments = {"--admindir=" + environment.dpkgAdmin,
        "--showformat=" + std::string(DpkgStateQueryFormat()), "--show"};
    if (!reader.RunAndCaptureBounded(arguments, &records, 32 * 1024 * 1024, 3000, cancelled).succeeded())
        return Fail(error, "provider_dpkg_state_query_failed");
    if ((cancelled && cancelled()) || !ParentLock(environment, frontendLockDescriptor) ||
        !P::RecheckEvidence({dpkg, query}, &ignored) || !P::RecheckEvidence(environment.evidence, &ignored) ||
        !P::RecheckEvidence(triggerEvidence, &ignored) ||
        !JournalSettled(environment) || !P::RuntimeSnapshot(environment, &after, &ignored) || before != after)
        return Fail(error, "provider_dpkg_state_changed");
    return ParseDpkgState(records, native, foreign, after, state, error);
}
}} // namespace CydiaAPT::Provider
