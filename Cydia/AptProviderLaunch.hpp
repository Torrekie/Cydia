/* Bounded unprivileged provider launch, with explicit recovery-only input.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderLaunch_HPP
#define Cydia_AptProviderLaunch_HPP
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <sys/types.h>

namespace CydiaAPT { namespace Provider {
constexpr std::size_t MaximumRecoveryCapsuleBytes = 4 * 1024 * 1024;

// The caller supplies a bounded serialized snapshot from independently
// validated parent authority, plus its existing private cache directory.
// Contents are never arguments, environment variables, diagnostics or named
// files after creation. This read-only transport is not runtime authority.
class RecoveryLaunchCapsule {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
    explicit RecoveryLaunchCapsule(std::unique_ptr<Implementation>);
public:
    ~RecoveryLaunchCapsule();
    RecoveryLaunchCapsule(const RecoveryLaunchCapsule &) = delete;
    RecoveryLaunchCapsule &operator=(const RecoveryLaunchCapsule &) = delete;
    static std::shared_ptr<const RecoveryLaunchCapsule> Create(const std::string &snapshot,
        const std::string &temporaryDirectory, std::string *errorCode,
        const std::function<bool()> &cancelled = {});
    // Recheck exact private bytes as well as inode identity/size/mode.
    // Child fd 3 has no writable access; all creation handles are closed.
    bool unchanged() const;
    // Returns a new CLOEXEC read-only descriptor >=4. Caller owns it. Position
    // is irrelevant to workers, which read this bounded regular file by pread.
    int duplicateDescriptor() const;
};

namespace Launch {
struct Child { int channel = -1; pid_t pid = -1; };
// Takes no ownership of capsule. On success the caller owns both results;
// channel is nonblocking/CLOEXEC and pid owns a private unprivileged group.
// Only stdin/stdout/stderr and, explicitly for recovery, fd 3 survive exec.
// No runtime/path/privilege admission is performed at this low-level boundary.
bool Start(const std::string &executable, const std::vector<std::string> &arguments,
    const std::shared_ptr<const RecoveryLaunchCapsule> &capsule, Child *, std::string *errorCode);
void Terminate(pid_t child);
enum class ProbeExit { Exited, Signaled, LaunchFailed, Failed, Cancelled, TimedOut, OutputLimit };
struct ProbeRunResult { ProbeExit kind = ProbeExit::LaunchFailed; int code = 0, error = 0; };
ProbeRunResult RunProbe(const std::string &executable, const std::vector<std::string> &arguments,
    const std::shared_ptr<const RecoveryLaunchCapsule> &capsule, const std::string &input,
    std::string *output, std::size_t maximumOutputBytes, unsigned timeoutMilliseconds,
    const std::function<bool()> &cancelled);
} // namespace Launch
}} // namespace CydiaAPT::Provider
#endif
