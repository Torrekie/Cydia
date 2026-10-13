/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryPackageManager_HPP
#define Cydia_AptRecoveryPackageManager_HPP
#include "Cydia/AptProviderProtocol.hpp"
#include "Cydia/AptRuntimeDescriptor.hpp"
#include <apt-pkg/deb/dpkgpm.h>
#include <functional>
#include <map>
#include <set>

class pkgRecords;
class pkgSourceList;

namespace CydiaAPT {
enum class RecoveryCaptureStatus { Recorded, Unsupported, Failed, Cancelled };
struct RecoveryCaptureResult {
    RecoveryCaptureStatus status = RecoveryCaptureStatus::Failed;
    Provider::ReviewedTransaction review;
    // Cydia-local batching hints from the exact selected Packages records.
    // At most Provider::MaximumCollectionItems distinct reviewed archive IDs.
    // They are not dependency readiness or parent execution authority.
    std::set<std::string> preDependsArchives;
    std::string errorCode;
};

/* A one-shot, recording-only package manager, suitable for ownership through
 * unique_ptr<pkgPackageManager>. The caller keeps a nonowning pointer to this
 * object for BindArchive/Capture, and holds the selected cache/configuration
 * operation gate throughout its lifetime. It must not reuse a cache after
 * recording without rebuilding the package manager's ordering state.
 *
 * Recorded means that libapt's explicit abstract operations were captured,
 * NOT permission to execute them. The parent must independently approve the
 * transaction, validate source/index/archive/layout evidence, and bound all
 * trigger/deconfiguration/state effects through the existing review broker.
 * This class never calls pkgDPkgPM::Go, writes selection/extended state, runs
 * hooks, or executes dpkg. Even DoInstall/DoInstallPostFork cannot execute.
 * It deliberately does not reproduce pkgDPkgPM::Go's mutable batching and
 * pending-action expansion; unsupported configurations fail explicitly.
 */
class AptRecoveryPackageManager final : public pkgDPkgPM {
    struct ArchiveBinding {
        pkgCache::VerIterator version;
        pkgCache::VerFileIterator record;
        std::string path;
    };
    std::map<unsigned long, ArchiveBinding> archives_;
    bool capturing_ = false, consumed_ = false, finiteEffects_ = false;
    std::function<bool()> cancelled_;
    std::string refusal_;
    bool Proceed();
    OrderResult OrderInstall() override;
    bool Install(PkgIterator package, std::string file) override;
    bool Configure(PkgIterator package) override;
    bool Remove(PkgIterator package, bool purge) override;
    bool Go(APT::Progress::PackageManager *) override;
public:
    explicit AptRecoveryPackageManager(pkgDepCache *cache);
    ~AptRecoveryPackageManager() override;
    /* The acquisition layer supplies its exact selected VerFile. No fallback
     * to the first available origin is allowed. The path is the planned final
     * archive path; the file need not exist until the parent's verification.
     * Binding also seeds libapt's FileNames for a pre-download preview. */
    bool BindArchive(pkgCache::VerIterator version, pkgCache::VerFileIterator record,
        const std::string &path, std::string *errorCode = nullptr);
    // finiteEffects is an explicitly accepted provider session mode. It
    // permits trigger-only pending states and omits libapt's unqualified
    // trigger markers; the parent's independently reviewed ledger owns them.
    // All other pending actions, hooks and unsupported policies still refuse.
    RecoveryCaptureResult Capture(pkgSourceList &sources, pkgRecords &records,
        const RuntimeDescriptor &runtime, const TransactionData &transaction,
        const Provider::Binding &binding, const CydiaPackages::ArchiveLayout &layout,
        const std::function<bool()> &cancelled = {}, bool finiteEffects = false);
};
} // namespace CydiaAPT
#endif
