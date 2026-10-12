/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderClient.hpp"
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
}

ProbeResult Probe(const std::string &executable, const Environment &expected,
    unsigned timeoutMilliseconds, const std::function<bool()> &cancelled) {
    ProbeResult result;
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
    result.executableIdentity = Identity(before);
    std::string bytes;
    CydiaRuntime::Dpkg::Runner runner(executable);
    const auto run = runner.RunAndCaptureBounded({executable, "--cydia-provider-info"}, &bytes,
        256 * 1024, timeoutMilliseconds == 0 || timeoutMilliseconds > 10000 ? 3000 : timeoutMilliseconds, cancelled);
    struct stat after;
    if (stat(executable.c_str(), &after) != 0 || Identity(after) != result.executableIdentity) {
        result.availability = Availability::Broken; result.errorCode = "provider_changed_during_probe"; return result;
    }
    if (!run.succeeded()) {
        // An otherwise runnable old APT tool can reject this option. That
        // does not establish that the distribution is broken.
        result.availability = run.kind == CydiaRuntime::Dpkg::ResultKind::Exited ?
            Availability::Unsupported : Availability::Broken;
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
}} // namespace CydiaAPT::Provider
