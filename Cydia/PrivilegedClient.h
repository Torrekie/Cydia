/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PrivilegedClient_H
#define Cydia_PrivilegedClient_H

#include "Cydia/PrivilegedRuntime.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/AptProviderTransactionChannel.hpp"
#include <memory>
#include <cstddef>
#include <string>

namespace CydiaAPT { namespace Provider { struct RegistrationIdentity; struct RegisteredProviderSnapshot; } }
namespace CydiaAPT { namespace Recovery { struct Preferences; struct Identity; struct RequestAuthority; struct Snapshot; } }

namespace CydiaRuntime {
namespace PrivilegedClient {

struct Result {
    int launchError;
    int exitCode;
    int termSignal;
    bool outputLimitExceeded;
    std::string output;
    std::string error;
    bool succeeded() const;
};

/* The helper independently resolves protected configuration. This descriptor
 * is the frontend's expectation, never privileged path authority. */
Privileged::ExpectedEnvironment CurrentExpectedEnvironment();
Privileged::Request RuntimeRequest(const std::string &payload);
/* Private setup writes do not depend on a working APT/tool environment.
 * The helper still authenticates Cydia and derives its private state path. */
Privileged::Request PrivateSettingsRequest(const std::string &payload);
Result Run(const std::string &helperPath, const std::string &command,
           const Privileged::Request &request,
           std::size_t captureLimit = 8 * 1024 * 1024,
           unsigned timeoutMilliseconds = 0);
Result RunNativeCommand(const std::string &command, const std::string &payload,
                       std::size_t captureLimit = 8 * 1024 * 1024,
                       unsigned timeoutMilliseconds = 0);
/* Only the private executable setting route is accepted here. */
Result RunPrivateSettingsCommand(const std::string &command, const std::string &payload,
                       std::size_t captureLimit = 8 * 1024 * 1024,
                       unsigned timeoutMilliseconds = 4000);

/* Returns a safely opened descriptor, without taking a lock. The frontend
 * must acquire its own fcntl lock; APT's GetLock callback does this normally. */
int OpenLock(const std::string &helperPath, const Privileged::Request &request,
             const std::string &purpose, Privileged::Error *error,
             unsigned timeoutMilliseconds = 0);
/* Register only outside an active operation under Database serialization.
 * Unrelated APT archive/list locks retain their ordinary open behavior. */
void ConfigureLockBridge(const std::string &helperPath,
                         const Privileged::ExpectedEnvironment &expected);
/* Scoped diagnostics may temporarily bound the existing bridge without
 * replacing its expected environment. Returns the previous timeout. */
unsigned SetLockBridgeTimeoutMilliseconds(unsigned timeoutMilliseconds);
void ClearLockBridge();
// Selected registration is pinned by the coordinator under Database's gate.
// Every helper call rereads that protected authority, never embedded defaults.
void ConfigureProviderAuthority(const std::string &helperPath,
    const CydiaAPT::Provider::RegistrationIdentity &identity,
    const Privileged::ExpectedEnvironment &expected);
void ConfigureRecoveryAuthority(const std::string &helperPath,
    const CydiaAPT::Recovery::RequestAuthority &authority,
    const Privileged::ExpectedEnvironment &expected);
void ClearProviderAuthority();
// Machine-readable helper response, including missing registration, without
// matching translated stderr. Suitable for RegistrationSnapshotReader.
bool ReadProviderSnapshot(const std::string &helperPath, const std::string &registrationPath,
    const CydiaAPT::Provider::RegistrationIdentity *expected,
    CydiaAPT::Provider::RegisteredProviderSnapshot *snapshot, Privileged::Error *error,
    unsigned timeoutMilliseconds = 4000,
    const std::function<bool()> &cancelled = std::function<bool()>());
bool ReadRecoverySnapshot(const std::string &helperPath, const CydiaAPT::Recovery::Preferences &preferences,
    const CydiaAPT::Recovery::Identity *expected, CydiaAPT::Recovery::Snapshot *snapshot,
    Privileged::Error *error, unsigned timeoutMilliseconds = 4000,
    const std::function<bool()> &cancelled = std::function<bool()>());
int OpenProviderLock(const std::string &helperPath, const Privileged::Request &wrappedRequest,
    Privileged::Error *error, unsigned timeoutMilliseconds = 0);
struct DpkgExecutionResult {
    Dpkg::Result result;
    bool started;
    bool indeterminate; // Helper transport disappeared without a verified pre-launch denial.
};
// Uses a separate inherited request channel. With the native UI bridge,
// interactive dpkg gets private per-child input/status channels; argvOptions
// supplies independently retained options, never worker-invented UI policy.
// No transaction timeout or kill.
DpkgExecutionResult RunProviderDpkg(const std::string &helperPath, const std::string &command,
    const Privileged::Request &wrappedRequest, int statusFd,
    const std::string *input = nullptr,
    const std::vector<std::string> &argvOptions = std::vector<std::string>());
// One authenticated direct cydo child retains the transaction lock and review.
// This client owns only transport/lifetime; cydo independently validates Begin
// authority and every subsequent operation. No transparent retry is allowed.
struct ProviderTransactionResult {
    bool transportValid = false, success = false, started = false, indeterminate = false;
    std::string payload, errorCode;
};
class ProviderTransaction {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
    explicit ProviderTransaction(std::unique_ptr<Implementation>);
public:
    ~ProviderTransaction();
    ProviderTransaction(const ProviderTransaction &) = delete;
    ProviderTransaction &operator=(const ProviderTransaction &) = delete;
    static std::unique_ptr<ProviderTransaction> Start(const std::string &helperPath,
        const Privileged::Request &wrappedBeginRequest, const std::string &expectedReviewDigest,
        std::string *errorCode, unsigned timeoutMilliseconds = 4000,
        const std::function<bool()> &cancelled = {}, bool scopedChildren = false);
    // scopedChildren is negotiated explicitly and requires reviewedEffects in
    // the canonical Begin. No provider capability is inferred by this client.
    // Serialized calls only. Execute requires the installed native conffile
    // bridge, and transfers fresh stdin/status descriptors for this child.
    // statusFd remains the reviewed target descriptor number, not a channel
    // inherited by the helper. The helper remaps the SCM_RIGHTS descriptors.
    // Execute/Commit have no receive timeout/cancellation after dispatch.
    ProviderTransactionResult Request(CydiaAPT::Provider::TransactionChannel::Operation,
        const std::string &payload, int statusFd = -1,
        const std::vector<std::string> &argvOptions = {},
        const std::function<void()> &started = {}, unsigned timeoutMilliseconds = 4000,
        const std::function<bool()> &cancelled = {});
    bool Close(std::string *errorCode = nullptr, unsigned timeoutMilliseconds = 4000);
    bool valid() const;
    bool mutationStarted() const;
    bool indeterminate() const;
};

// Compatibility bridge for Cydia's own explicit hold/configure actions. This
// is never exposed as a reverse-RPC operation to an external provider worker.
Dpkg::Result RunSelectedDpkg(const std::vector<std::string> &arguments, int statusFd = -1,
                            const std::string *input = nullptr);

} // namespace PrivilegedClient
} // namespace CydiaRuntime
#endif
