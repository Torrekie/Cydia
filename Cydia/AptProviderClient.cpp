/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderClient.hpp"
#include "Cydia/AptProviderLaunch.hpp"
#include "Cydia/DpkgRunner.h"
#include <cerrno>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
std::string Identity(const struct stat &value) {
    std::ostringstream result;
    result << value.st_dev << ':' << value.st_ino << ':' << value.st_size << ':' << value.st_mode;
#if defined(__APPLE__)
    result << ':' << value.st_mtimespec.tv_sec << ':' << value.st_mtimespec.tv_nsec
           << ':' << value.st_ctimespec.tv_sec << ':' << value.st_ctimespec.tv_nsec;
#else
    result << ':' << value.st_mtim.tv_sec << ':' << value.st_mtim.tv_nsec
           << ':' << value.st_ctim.tv_sec << ':' << value.st_ctim.tv_nsec;
#endif
    return result.str();
}

ProbeResult ProbeInternal(const std::string &executable, const Environment &expected,
    unsigned timeoutMilliseconds, const std::function<bool()> &cancelled, const std::string &registrationPath,
    const std::shared_ptr<const RecoveryLaunchCapsule> &capsule) {
    ProbeResult result; result.recoveryCapsule = capsule;
    if (capsule && (!registrationPath.empty() || !capsule->unchanged())) {
        result.availability = Availability::Broken; result.errorCode = "provider_capsule_changed"; return result;
    }
    struct stat before;
    if (executable.empty() || stat(executable.c_str(), &before) != 0) {
        result.availability = executable.empty() || errno == ENOENT || errno == ENOTDIR ?
            Availability::Missing : Availability::Broken;
        result.errorCode = result.availability == Availability::Missing ? "provider_missing" : "provider_unreadable";
        return result;
    }
    CydiaRuntime::Privileged::Error pathError;
    if (!CydiaRuntime::Privileged::ValidateRootOwnedPath(executable, false, true, &pathError)) {
        result.availability = Availability::Broken; result.errorCode = "provider_untrusted_path"; return result;
    }
    if (!registrationPath.empty() && !CydiaRuntime::Privileged::ValidateRootOwnedPath(registrationPath, false, false, &pathError)) {
        result.availability = Availability::Broken; result.errorCode = "provider_registration_untrusted"; return result;
    }
    result.registrationPath = registrationPath;
    result.executableIdentity = Identity(before);
    std::string bytes;
    std::vector<std::string> arguments{"--cydia-provider-info"};
    if (!registrationPath.empty()) arguments.push_back("--cydia-provider-registration=" + registrationPath);
    Message query;
    query.kind = MessageKind::Request; query.sequence = 1; query.operation = Operation::Hello;
    std::string input;
    if (!ValidEnvironment(expected) || !Encode(expected, &query.payload) || !EncodeFrame(query, &input) || input.size() > 256 * 1024) {
        result.availability = Availability::Broken; result.errorCode = "provider_environment_incomplete"; return result;
    }
    const unsigned maximum(capsule ? MaximumRecoveryStartupMilliseconds : 10000);
    const unsigned timeout = timeoutMilliseconds == 0 || timeoutMilliseconds > maximum ? 3000 : timeoutMilliseconds;
    bool succeeded = false, unsupported = false;
    if (capsule) {
        const auto run = Launch::RunProbe(executable, arguments, capsule, input, &bytes, 256 * 1024, timeout, cancelled);
        succeeded = run.kind == Launch::ProbeExit::Exited && run.code == 0;
        unsupported = run.kind == Launch::ProbeExit::Exited || run.error == EPIPE;
        if (!capsule->unchanged()) {
            result.availability = Availability::Broken; result.errorCode = "provider_capsule_changed"; return result;
        }
    } else {
        // Preserve the external provider's existing probe path and environment.
        CydiaRuntime::Dpkg::Runner runner(executable);
        const auto run = runner.RunWithInputAndCaptureBounded(arguments, input, &bytes, 256 * 1024, timeout, cancelled);
        succeeded = run.succeeded();
        unsupported = run.kind == CydiaRuntime::Dpkg::ResultKind::Exited || run.error == EPIPE;
    }
    struct stat after;
    if (stat(executable.c_str(), &after) != 0 || Identity(after) != result.executableIdentity) {
        result.availability = Availability::Broken; result.errorCode = "provider_changed_during_probe"; return result;
    }
    if (!succeeded) {
        // An otherwise runnable old APT tool can reject this option. That
        // does not establish that the distribution is broken.
        result.availability = unsupported ? Availability::Unsupported : Availability::Broken;
        result.errorCode = result.availability == Availability::Unsupported ?
            "provider_protocol_unsupported" : "provider_probe_failed";
        return result;
    }
    Message frame;
    if (!DecodeFrame(bytes, &frame) || frame.kind != MessageKind::Response || frame.sequence != 1 ||
        frame.operation != Operation::Hello || !Decode(frame.payload, &result.info)) {
        result.availability = Availability::Unsupported; result.errorCode = "provider_protocol_unsupported"; return result;
    }
    result.availability = result.info.availability;
    if (!frame.succeeded && result.availability == Availability::Ready) {
        result.availability = Availability::Broken; result.errorCode = "provider_probe_failed"; return result;
    }
    if (result.availability != Availability::Ready) {
        result.errorCode = result.info.errorCode.empty() ? "provider_unavailable" : result.info.errorCode;
        return result;
    }
    if (!Compatible(result.info, expected, &result.errorCode)) result.availability = Availability::Unsupported;
    return result;
}
} // namespace

ProbeResult Probe(const std::string &executable, const Environment &expected,
    unsigned timeoutMilliseconds, const std::function<bool()> &cancelled, const std::string &registrationPath) {
    return ProbeInternal(executable, expected, timeoutMilliseconds, cancelled, registrationPath, {});
}
ProbeResult ProbeRecovery(const std::string &executable, const Environment &expected,
    const std::shared_ptr<const RecoveryLaunchCapsule> &capsule, unsigned timeoutMilliseconds,
    const std::function<bool()> &cancelled) {
    if (!capsule) {
        ProbeResult result; result.availability = Availability::Broken; result.errorCode = "provider_capsule_invalid"; return result;
    }
    return ProbeInternal(executable, expected, timeoutMilliseconds, cancelled, {}, capsule);
}
}} // namespace CydiaAPT::Provider
