/* Protected transaction-owned files; no provider or application claims grant
 * filesystem authority. Copyright (C) 2026 Torrekie; GPL-3.0-or-later. */
#ifndef Cydia_AptProviderTransactionFiles_HPP
#define Cydia_AptProviderTransactionFiles_HPP
#include "Cydia/AptProviderArchiveEvidence.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include <memory>

namespace CydiaAPT { namespace Provider {
class TransactionArchiveStore {
    class Implementation;
    std::unique_ptr<Implementation> implementation_;
public:
    TransactionArchiveStore();
    ~TransactionArchiveStore();
    TransactionArchiveStore(const TransactionArchiveStore &) = delete;
    TransactionArchiveStore &operator=(const TransactionArchiveStore &) = delete;
    // privateStateDirectory is resolved by cydo, never decoded from a request.
    // Source/index association is independently captured here. Every approved
    // archive is copied, fully hashed and inspected before success is exposed.
    bool Begin(const std::string &privateStateDirectory, const RuntimeDescriptor &,
        const ReviewedTransaction &, const ReviewPolicy &, const std::string &decoderSearchPath,
        const std::map<std::string, std::vector<std::string>> &successorPaths,
        std::string *error, const std::function<bool()> &cancelled = {}, bool captureEffectControls = false);
    // Rehash retained descriptors and check their named path/inode/parent chain.
    bool Capture(std::vector<StagedArchiveEvidence> *, std::string *error,
        const std::function<bool()> &cancelled = {}) const;
    const std::string &directory() const;
    const std::vector<RetainedTransactionArchive> &archives() const;
    const std::vector<RetainedComponentArchive> &successors() const;
    const std::vector<VerifiedArchiveControlEvidence> &effectControls() const;
};
}}
#endif
