/* Cydia package action policy exercised against the real bundled APT cache.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptRuntime.hpp"
#include <apt-pkg/error.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>
#include <cstdlib>
#include <iostream>

/* The fixture has two explicit architectures. All cache, policy and resolver
 * behavior below comes from libapt-pkg, rather than the portable APT stubs. */
namespace CydiaAPT {
RepositorySecurityMode GetRepositorySecurityMode() {
    return RepositorySecurityMode::Warning;
}
bool CachedRepositoryTrustValid() { return true; }

const std::vector<std::string> &Architectures() {
    static const std::vector<std::string> architectures{"amd64", "i386"};
    return architectures;
}
}

namespace {
class FixtureAcquireStatus : public pkgAcquireStatus {
public:
    bool MediaChange(std::string, std::string) override { return false; }
};

void Require(bool condition, const char *message) {
    if (condition) return;
    std::cerr << "[apt-package-actions] " << message << '\n';
    _error->DumpErrors();
    std::exit(1);
}

CydiaAPT::PackageHandle Version(CydiaAPT::Internal::AptBackend &backend,
                               CydiaAPT::PackageHandle package, const char *version) {
    const std::vector<CydiaAPT::PackageHandle> versions(backend.versionHandles(package));
    for (CydiaAPT::PackageHandle handle : versions)
        if (backend.packageSnapshot(handle).version == version) return handle;
    Require(false, "available version was missing from the backend picker");
    return CydiaAPT::PackageHandle();
}
}

int main() {
    Require(pkgInitConfig(*_config) && pkgInitSystem(*_config, _system), "APT initialization failed");
    _config->Set("Dir::Cache::pkgcache", "");
    _config->Set("Dir::Cache::srcpkgcache", "");
    FixtureAcquireStatus status;
    CydiaAPT::Internal::AptBackend backend(status);
    Require(backend.openCache(), "real APT cache could not be opened");
    backend.createCacheViews();
    Require(backend.loadSources(), "fixture source definitions could not be loaded");
    const CydiaAPT::PackageHandle target(backend.packageHandle("target", "amd64"));
    Require(target.valid(), "fixture target was missing");
    Require(backend.packageSnapshot(target).version == "1", "APT pin did not select the lower candidate");
    CydiaAPT::PackageStateData state(backend.packageState(target));
    Require(state.policyCandidate && state.versionPriority == 1001 && state.versionComparison < 0,
        "native APT pin priority/candidate/downgrade metadata was incorrect");
    const CydiaAPT::PackageHandle newer(Version(backend, target, "3"));
    const CydiaAPT::PackageHandle installed(Version(backend, target, "2"));
    Require(backend.packageState(installed).installedVersion, "installed version was not identified");

    Require(backend.installPackage(target), "lower policy candidate could not be queued");
    state = backend.packageState(target);
    Require(state.mode == "DOWNGRADE" && state.downgrade, "policy downgrade was mislabeled as an upgrade");
    CydiaAPT::TransactionData transaction(backend.transactionData());
    Require(transaction.downgrades.size() == 1 && transaction.upgrades.empty(),
        "review placed the downgrade in the upgrade section");
    backend.clearSelections();

    Require(backend.installPackage(newer), "explicit version could not be queued");
    Require(backend.packageSnapshot(backend.packageHandle("target", "amd64")).version == "3",
        "explicit install did not change the real APT candidate");
    Require(!backend.autoInstalledDeltas().empty(), "explicit install did not mark the automatic target manual");
    Require(backend.clearPackage(newer), "single package cancellation failed");
    Require(backend.packageSnapshot(backend.packageHandle("target", "amd64")).version == "1" &&
        backend.autoInstalledDeltas().empty(), "single cancellation did not restore candidate/automatic state");
    Require(backend.installPackage(newer), "second explicit version could not be queued");
    Require(backend.resolveDependencies(), "real dependency resolver failed for the independent target");
    backend.clearSelections();
    Require(backend.packageSnapshot(backend.packageHandle("target", "amd64")).version == "1" &&
        backend.autoInstalledDeltas().empty(), "whole transaction cancellation retained candidate/automatic changes");

    Require(backend.reinstallPackage(target), "exact installed-version reinstall failed");
    Require(backend.packageSnapshot(backend.packageHandle("target", "amd64")).version == "2" &&
        backend.packageState(target).mode == "REINSTALL", "Reinstall selected the lower policy candidate");
    backend.clearSelections();
    const CydiaAPT::PackageHandle unavailable(backend.packageHandle("missing-reinstall", "amd64"));
    Require(unavailable.valid() && !backend.packageState(unavailable).installedVersionAvailable &&
        !backend.reinstallPackage(unavailable), "Reinstall accepted an unavailable installed version");

    Require(backend.removePackage(target), "normal removal failed");
    transaction = backend.transactionData();
    Require(backend.packageState(target).mode == "REMOVE" && transaction.removes.size() == 1 &&
        transaction.purges.empty(), "normal Remove silently purged saved configuration");
    backend.clearSelections();
    Require(backend.removePackage(target, true), "explicit purge failed");
    transaction = backend.transactionData();
    Require(backend.packageState(target).mode == "PURGE" && transaction.purges.size() == 1 &&
        transaction.removes.empty(), "Purge was not separate in the review");
    backend.clearSelections();

    const CydiaAPT::PackageHandle residual(backend.packageHandle("residual-config", "amd64"));
    Require(residual.valid() && backend.packageState(residual).state == "ConfigFiles" &&
        !backend.removePackage(residual) && backend.removePackage(residual, true),
        "residual configuration without a repository candidate could not be explicitly purged");
    backend.clearSelections();

    const CydiaAPT::PackageHandle held(backend.packageHandle("held-target", "amd64"));
    const CydiaAPT::PackageHandle essential(backend.packageHandle("essential-target", "amd64"));
    const CydiaAPT::PackageHandle protectedPackage(backend.packageHandle("protected-target", "amd64"));
    Require(backend.packageState(held).ignored && !backend.installPackage(held) &&
        !backend.reinstallPackage(held) && !backend.removePackage(held) && !backend.removePackage(held, true),
        "explicit package action bypassed the real dpkg hold");
    Require(backend.packageState(essential).essential && !backend.removePackage(essential) &&
        !backend.removePackage(essential, true), "actual Essential flag was ignored");
    Require(backend.packageState(protectedPackage).protectedPackage && !backend.removePackage(protectedPackage) &&
        !backend.removePackage(protectedPackage, true), "actual Protected flag was ignored");
    _config->Set("APT::Ignore-Hold", true);
    Require(backend.prepareDistUpgrade(), "native bulk upgrade failed");
    Require(!backend.packageState(held).hasMode && !backend.packageState(held).reinstall,
        "bulk upgrade changed a held package through an inherited Ignore-Hold option");
    Require(_config->FindB("APT::Ignore-Hold", false), "temporary hold policy changed bootstrap configuration");
    backend.clearSelections();
    std::cout << "[apt-package-actions] real APT action/resolver fixture passed\n";
}
