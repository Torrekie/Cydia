/* Owner used only by the authenticated persistent cydo transaction channel.
 * Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#ifndef Cydia_AptProviderTransactionOwner_HPP
#define Cydia_AptProviderTransactionOwner_HPP
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/AptProviderTransactionFiles.hpp"
#include "Cydia/AptProviderTriggerEffects.hpp"
#include "Cydia/NativeLaunchEnvironment.hpp"
#include "Cydia/AptProviderConffilePolicy.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
struct TransactionEffectChildChannels {
    int inputDescriptor = -1, statusDescriptor = -1;
    // Fresh per-child question/status ownership. Callbacks must not throw.
    // settled closes/releases this scope, including when no child was started.
    std::function<void()> started;
    // v3 only: immutable suppression policy acknowledged before actual spawn.
    std::function<bool(const ConffilePolicyDecision &, std::string *)> policy;
    std::function<void(const ParentExecutionReply &)> settled;
};
struct TransactionOwnerOptions {
    bool requireConffilePolicy = false; // Internal v3 negotiation, no feature permission.
    BrokerEnvironment selected; // Independently resolved once by cydo.
    CydiaRuntime::Privileged::ApplicationProcessIdentity application;
    uid_t applicationUID = 0;
    TransactionLockIdentity lock;
    std::string privateStateDirectory, nonce, reviewDigest, expectedExtendedState;
    ReviewedTransaction review;
    ReviewPolicy policy;
    std::vector<AutoInstalledDelta> changes;
    // Only an independently captured, natively displayed and approved pool.
    // Begin recomputes it from the locked state; no provider-proposed pool or
    // post-download expansion is accepted. Empty retains the existing route.
    std::shared_ptr<const TriggerEffectEnvelope> reviewedEffects;
    // Required for opt-in effects. Never reuse another child's conffile input
    // or status stream. The service must bind each scope to the shown pass and
    // its exact targets before this factory returns; it grants no target authority.
    std::function<bool(const TriggerDrainPlan &, TransactionEffectChildChannels *, std::string *)> effectChildChannels;
    // Scoped mode obtains primary descriptors only after preceding drains have
    // settled and released their scopes. Unscoped legacy mode retains passed
    // descriptors. V3 scopes each primary even without a trigger envelope.
    std::function<bool(const ParentExecutionRequest &, TransactionEffectChildChannels *, std::string *)> primaryChildChannels;
    // Kernel process identity/UID capture owned by cydo; never a channel field.
    std::function<bool(CydiaRuntime::Privileged::ApplicationProcessIdentity *, uid_t *, std::string *)> authenticate;
    // Uses cydo's existing direct child executor with separately validated
    // stdin/status descriptors. started must run immediately after spawn, and
    // the callback must wait/reap the actual child even if the channel closes.
    // It must not throw, and must never return with a live child. cydo installs
    // selected.executableSearchPath beforehand. The final argument is the exact
    // parent-retained envp; an executor must never substitute ambient environ.
    std::function<ParentExecutionReply(const std::string &, const std::vector<std::string> &,
        int inputDescriptor, int statusDescriptor, const std::function<void()> &started, const CydiaRuntime::NativeLaunchEnvironment &)> execute;
    // Receives final child-fd3 argv and exact descriptor-option index. This
    // callback validates that span and must not rewrite argv/env after matching.
    std::function<ParentExecutionReply(const std::string &, const std::vector<std::string> &,
        int, int, const std::function<void()> &, const CydiaRuntime::NativeLaunchEnvironment &, std::size_t)> executePrepared;
};
class TransactionOwner {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
public:
    explicit TransactionOwner(const TransactionOwnerOptions &);
    ~TransactionOwner();
    TransactionOwner(const TransactionOwner &) = delete;
    TransactionOwner &operator=(const TransactionOwner &) = delete;
    // Returns ready only after native configuration/loader authority, app/lock,
    // baseline state and every retained archive have independently passed.
    bool Begin(std::string *error, const std::function<bool()> &cancelled = {});
    bool Capture(const TransactionLeaseEnvelope &, DpkgState *, std::string *error,
        const std::function<bool()> &cancelled = {});
    // Calls are serialized by the owner channel. Only Cancel/TransportLost may
    // be called concurrently; destroy the owner only after a call settles.
    // started is a nonthrowing channel notification, never execution authority.
    bool Execute(const TransactionLeaseEnvelope &, const ParentExecutionRequest &,
        int inputDescriptor, int statusDescriptor, ParentExecutionReply *, DpkgState *, std::string *error,
        const std::function<bool()> &cancelled = {}, const std::function<void()> &started = {});
    bool Commit(const TransactionLeaseEnvelope &, const std::vector<AutoInstalledDelta> &,
        const std::string &expectedExtendedState, std::string *error, const std::function<void()> &started = {});
    void Cancel();
    void TransportLost();
    bool Close(std::string *error);
    bool mutationStarted() const;
    bool complete() const;
    bool indeterminate() const;
};
}}
#endif
