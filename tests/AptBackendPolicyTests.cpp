/* Cydia package action policy exercised against the real bundled APT cache.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/RepositoryArchiveAuthorization.hpp"
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/progress.h>
#include <apt-pkg/strutl.h>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <unistd.h>

/* APT indexes include armhf, but dpkg registers only amd64 and i386. This
 * deliberately tests that fetch configuration cannot authorize installation.
 * All cache, policy and resolver
 * behavior below comes from libapt-pkg, rather than the portable APT stubs. */
namespace CydiaAPT {
RepositorySecurityMode fixtureSecurityMode = RepositorySecurityMode::Warning;
std::string fixtureInstallPrefix = "/";
RepositorySecurityMode GetRepositorySecurityMode() {
    return fixtureSecurityMode;
}
bool CachedRepositoryTrustValid() { return true; }
const std::string &PackageInstallPrefix() {
    return fixtureInstallPrefix;
}

const std::vector<std::string> &Architectures() {
    static const std::vector<std::string> architectures{"amd64", "i386", "armhf"};
    return architectures;
}
const std::vector<std::string> &RegisteredArchitectures() {
    static const std::vector<std::string> architectures{"amd64", "i386"};
    return architectures;
}
bool IsArchitectureSupported(const std::string &architecture) {
    return architecture == "all" || architecture == "amd64" || architecture == "i386";
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
    std::cerr << "[apt-package-actions] wanted " << backend.packageSnapshot(package).identifier << '=' << version
        << "; available:";
    for (CydiaAPT::PackageHandle handle : versions) {
        const CydiaAPT::PackageSnapshot snapshot(backend.packageSnapshot(handle));
        std::cerr << ' ' << snapshot.version << ':' << snapshot.architecture;
    }
    std::cerr << '\n';
    Require(false, "available version was missing from the backend picker");
    return CydiaAPT::PackageHandle();
}

void RequireTransaction(bool condition, const CydiaAPT::TransactionData &transaction, const char *message) {
    if (!condition) {
        for (const auto &entry : transaction.packages)
            std::cerr << "[apt-package-actions] planned " << entry.first << '=' << entry.second.version
                << " architecture=" << entry.second.identity.versionArchitecture << '\n';
        for (const auto &issue : transaction.issues)
            std::cerr << "[apt-package-actions] issue " << issue.package << ": " << issue.kind << '\n';
        for (const auto &removed : transaction.removes)
            std::cerr << "[apt-package-actions] removal " << removed << '\n';
    }
    Require(condition, message);
}

bool HasIssue(const CydiaAPT::TransactionData &transaction, const char *package, const char *kind) {
    for (const CydiaAPT::TransactionIssueData &issue : transaction.issues)
        if (issue.package == package && issue.kind == kind) return true;
    return false;
}

const CydiaAPT::RelationClauseData *Clause(const std::vector<CydiaAPT::RelationData> &relations,
                                          const char *package) {
    for (const CydiaAPT::RelationData &relation : relations)
        if (relation.relationship == "Depends")
            for (const CydiaAPT::RelationClauseData &clause : relation.clauses)
                if (clause.package == package) return &clause;
    return NULL;
}

void CheckMultiarch(CydiaAPT::Internal::AptBackend &backend) {
    using namespace CydiaAPT;
    Require(backend.lookupPackage("foreign-only", "amd64").status == PackageLookupStatus::NoEligibleVersion &&
        !backend.packageHandle("foreign-only", "amd64").valid(), "bare lookup fell back to a foreign package");
    Require(backend.packageSnapshot(backend.packageHandle("foreign-only:i386", "amd64")).architecture == "i386",
        "explicit configured foreign architecture was unavailable");
    Require(backend.lookupPackage("unknown", "amd64").status == PackageLookupStatus::NotFound &&
        backend.lookupPackage("foreign-only:any:any", "amd64").status == PackageLookupStatus::InvalidSelector,
        "lookup diagnostics conflated missing and invalid selectors");

    const PackageHandle mixed(backend.packageHandle("mixed-layout", "amd64"));
    const PackageHandle mixedAll(backend.packageHandle("mixed-layout:all", "amd64"));
    const PackageHandle mixedNative(backend.packageHandle("mixed-layout:native", "amd64"));
    const std::vector<std::string> registered{"amd64", "i386"};
    Require(backend.packageSnapshot(mixed).registeredArchitectures == registered,
        "package presentation snapshot omitted dpkg architectures or included an acquisition-only architecture");
    Require(backend.packageSnapshot(mixed).architecture == "amd64" &&
        backend.packageSnapshot(mixedAll).architecture == "all" &&
        backend.packageSnapshot(mixedNative).architecture == "amd64" && mixedAll.value != mixedNative.value,
        "exact native/all lookup reused the native cache bucket's wrong version");
    Require(backend.packageSnapshot(backend.packageHandle("mixed-layout", "amd64")).version == "2",
        "viewing an exact architecture changed APT's shared policy candidate");
    Require(backend.packageSnapshot(backend.packageHandle("portable", "amd64")).architecture == "all" &&
        backend.lookupPackage("portable:amd64", "amd64").status == PackageLookupStatus::NoEligibleVersion,
        "explicit native selector accepted Architecture: all");
    Require(backend.lookupPackage("native-only:all", "amd64").status == PackageLookupStatus::NoEligibleVersion,
        "explicit all selector accepted a concrete native version");
    const PackageLookupResult ambiguous(backend.lookupPackage("coinstall:any", "amd64"));
    Require(ambiguous.status == PackageLookupStatus::Ambiguous && ambiguous.alternatives.size() == 2,
        "user :any selector silently chose one of two actual architectures");
    Require(backend.lookupPackage("foreign-only:any", "amd64").status == PackageLookupStatus::Found,
        "unique concrete user :any selection was unavailable");

    const PackageHandle transition(backend.packageHandle("transition", "amd64"));
    Require(backend.packageSnapshot(transition).architecture == "amd64" && backend.removePackage(transition),
        "native/all transition fixture could not remove its installed version");
    TransactionData operation(backend.transactionData());
    Require(operation.registeredArchitectures == registered,
        "transaction presentation snapshot omitted dpkg architectures or included an acquisition-only architecture");
    const TransactionPackageData *removed(FindTransactionPackage(operation, "transition"));
    Require(removed != NULL && removed->identity.versionArchitecture == "all" && removed->version == "1" &&
        removed->displayName == "Portable transition", "removal snapshot borrowed the repository candidate's identity");
    backend.clearSelections();
    Require(backend.reinstallPackage(transition), "native/all transition reinstall failed");
    operation = backend.transactionData();
    const TransactionPackageData *reinstalled(FindTransactionPackage(operation, "transition:amd64"));
    Require(reinstalled != NULL && reinstalled->identity.versionArchitecture == "all" && reinstalled->version == "1",
        "APT progress alias did not retain the exact all-version reinstall");
    backend.clearSelections();
    Require(backend.installPackage(backend.packageHandle("transition", "amd64")), "native transition upgrade failed");
    operation = backend.transactionData();
    const TransactionPackageData *upgraded(FindTransactionPackage(operation, "transition"));
    Require(upgraded != NULL && upgraded->identity.versionArchitecture == "amd64" && upgraded->version == "2",
        "upgrade snapshot retained the removed architecture instead of the planned architecture");
    backend.clearSelections();
    const PackageHandle portableConfig(backend.packageHandle("portable-config", "amd64"));
    const PackageSnapshot retained(backend.packageSnapshot(portableConfig));
    Require(retained.architecture == "amd64" && retained.installedIdentity.valid() &&
        retained.installedIdentity.versionArchitecture == "all" &&
        retained.installedIdentity.dpkgName == "portable-config" && retained.installedVersion.empty() &&
        !retained.state.hasCurrent && retained.state.state == "ConfigFiles",
        "retained configuration lost its original identity or appeared installed under the newer candidate architecture");
    Require(backend.removePackage(portableConfig, true),
        "architecture-independent residual configuration could not be purged");
    operation = backend.transactionData();
    const TransactionPackageData *purged(FindTransactionPackage(operation, "portable-config"));
    Require(purged != NULL && purged->identity.versionArchitecture == "all" && purged->version == "1" &&
        purged->displayName == "Old portable configuration", "purge snapshot borrowed a newer repository architecture");
    backend.clearSelections();

    const PackageHandle consumer(backend.packageHandle("qualified-consumer", "amd64"));
    const std::vector<RelationData> relations(backend.relations(consumer));
    const RelationClauseData *any(Clause(relations, "allowed-runtime:any"));
    const RelationClauseData *exact(Clause(relations, "coinstall:i386"));
    const RelationClauseData *foreign(Clause(relations, "foreign-runtime"));
    const RelationClauseData *portable(Clause(relations, "portable"));
    Require(any != NULL && any->providers.size() == 1 &&
        backend.packageSnapshot(any->providers.front()).architecture == "i386",
        "contextual :any relation lost its eligible Multi-Arch: allowed provider");
    Require(exact != NULL && exact->providers.size() == 1 &&
        backend.packageSnapshot(exact->providers.front()).architecture == "i386",
        "concrete dependency qualifier was duplicated or resolved to the wrong architecture");
    Require(foreign != NULL && foreign->providers.size() == 1 &&
        backend.packageSnapshot(foreign->providers.front()).architecture == "i386",
        "unqualified dependency did not preserve APT's Multi-Arch: foreign provider");
    Require(portable != NULL && !portable->providers.empty(),
        "ordinary Architecture: all dependency required a fabricated :all qualifier");
    const std::vector<RelationData> invalidAnyRelations(backend.relations(
        backend.packageHandle("unqualified-runtime-consumer", "amd64")));
    const RelationClauseData *invalidAny(Clause(invalidAnyRelations, "native-only:any"));
    Require(invalidAny != NULL && invalidAny->providers.empty(),
        "dependency :any fell back to a package lacking Multi-Arch: allowed");
    Require(backend.installPackage(consumer) && backend.resolveDependencies() && backend.transactionData().issues.empty(),
        "valid APT multiarch dependencies did not resolve");
    backend.clearSelections();

    Require(backend.lookupPackage("unsupported:armhf", "amd64").status == PackageLookupStatus::UnsupportedArchitecture,
        "index architecture was treated as dpkg installation authorization");
    const PackageHandle unsupportedInstalled(backend.packageHandle("unsupported-installed:armhf", "amd64"));
    Require(unsupportedInstalled.valid() && !backend.packageState(unsupportedInstalled).architectureSupported &&
        !backend.installPackage(unsupportedInstalled) && !backend.reinstallPackage(unsupportedInstalled),
        "local-state visibility bypassed unsupported installation gates");
    Require(backend.removePackage(unsupportedInstalled) && backend.transactionData().issues.empty(),
        "unsupported installed package could not be removed safely");
    backend.clearSelections();
    const PackageHandle unsupportedConsumer(backend.packageHandle("unsupported-consumer", "amd64"));
    const std::vector<RelationData> unsupportedRelations(backend.relations(unsupportedConsumer));
    const RelationClauseData *unsupportedClause(Clause(unsupportedRelations, "unsupported:armhf"));
    Require(unsupportedClause != NULL && !unsupportedClause->providers.empty() &&
        !backend.installPackage(unsupportedClause->providers.front()),
        "contextual navigation handle bypassed unsupported installation gate");
    Require(backend.installPackage(unsupportedConsumer) && backend.resolveDependencies(),
        "fixture resolver did not select its unsupported indirect dependency");
    Require(HasIssue(backend.transactionData(), "unsupported:armhf", "unsupported_architecture"),
        "final transaction omitted an unsupported resolver-selected hidden package");
    backend.clearSelections();
    Require(backend.prepareDistUpgrade() &&
        HasIssue(backend.transactionData(), "unsupported-installed:armhf", "unsupported_architecture"),
        "bulk upgrade bypassed unsupported architecture validation");
    backend.clearSelections();
}

void CheckExactVersionIdentity(CydiaAPT::Internal::AptBackend &backend) {
    using namespace CydiaAPT;
    const PackageSnapshot before(backend.packageSnapshot(backend.packageHandle("same-version-layout", "amd64")));
    const PackageHandle portable(backend.packageHandle("same-version-layout:all", "amd64"));
    const PackageHandle native(backend.packageHandle("same-version-layout:amd64", "amd64"));
    const PackageSnapshot allVersion(backend.packageSnapshot(portable));
    const PackageSnapshot nativeVersion(backend.packageSnapshot(native));
    Require(portable.valid() && native.valid() && portable.value != native.value &&
        allVersion.version == "1" && nativeVersion.version == "1" &&
        allVersion.architecture == "all" && nativeVersion.architecture == "amd64" &&
        allVersion.record.Field("Architecture") == "all" && nativeVersion.record.Field("Architecture") == "amd64",
        "same-Version native/all records collapsed into one handle or borrowed each other's control metadata");
    Require(backend.versionHandles(before.handle).size() == 2 &&
        backend.packageHandle("same-version-layout", "amd64").value == before.handle.value,
        "same-Version architecture inspection omitted a version or changed the policy candidate");
    for (PackageHandle selected : {portable, native}) {
        const PackageSnapshot version(backend.packageSnapshot(selected));
        Require(backend.installPackage(selected) && backend.resolveDependencies(),
            "exact same-Version architecture choice could not be queued");
        const TransactionData transaction(backend.transactionData());
        const TransactionPackageData *planned(FindTransactionPackage(transaction, "same-version-layout"));
        RequireTransaction(transaction.issues.empty() && planned != NULL && planned->version == "1" &&
            planned->identity.versionArchitecture == version.architecture, transaction,
            "same-Version selected operation substituted the other native/all architecture");
        backend.clearSelections();
    }

    const PackageHandle epoch(backend.packageHandle("epoch-target", "amd64"));
    const PackageHandle oldEpoch(Version(backend, epoch, "1:1.0-1"));
    Require(backend.packageSnapshot(epoch).version == "2:1.0-1" && epoch.value != oldEpoch.value &&
        backend.packageState(epoch).upgradable && backend.packageState(epoch).versionComparison > 0,
        "real APT epoch ordering or same-upstream-version identity was lost");
    Require(backend.installPackage(epoch) && backend.resolveDependencies(), "epoch upgrade could not be queued");
    TransactionData transaction(backend.transactionData());
    const TransactionPackageData *upgrade(FindTransactionPackage(transaction, "epoch-target"));
    RequireTransaction(upgrade != NULL && upgrade->version == "2:1.0-1" && transaction.upgrades.size() == 1 &&
        transaction.issues.empty(), transaction, "epoch upgrade lost its full selected Debian version");
    backend.clearSelections();
    Require(backend.installPackage(oldEpoch) && backend.resolveDependencies(), "exact old-epoch reinstall failed");
    transaction = backend.transactionData();
    const TransactionPackageData *reinstall(FindTransactionPackage(transaction, "epoch-target"));
    RequireTransaction(reinstall != NULL && reinstall->version == "1:1.0-1" &&
        transaction.reinstalls.size() == 1 && transaction.issues.empty(), transaction,
        "same upstream version in another epoch replaced the explicitly selected installed version");
    backend.clearSelections();
}

void CheckVersionedProviders(CydiaAPT::Internal::AptBackend &backend) {
    using namespace CydiaAPT;
    for (const char *name : {"versioned-consumer", "alternative-consumer"}) {
        const PackageHandle consumer(backend.packageHandle(name, "amd64"));
        const std::vector<RelationData> relations(backend.relations(consumer));
        const RelationClauseData *provided(Clause(relations, "fixture-api:any"));
        Require(provided != NULL && provided->comparison == ">=" && provided->version == "2" &&
            provided->providers.size() == 1,
            "versioned :any Provides accepted an unversioned/too-old provider or lost the original relation");
        const PackageSnapshot target(backend.packageSnapshot(provided->providers.front()));
        Require(target.identity.baseName == "versioned-runtime" && target.architecture == "i386" && target.version == "7",
            "versioned Provides confused the provided ABI version 2 with provider package version 7");
        if (std::string(name) == "alternative-consumer") {
            const RelationClauseData *missing(Clause(relations, "missing-fixture-api:any"));
            Require(relations.size() == 1 && relations.front().clauses.size() == 2 && missing != NULL &&
                missing->providers.empty(), "OR alternatives were flattened or a missing :any target gained a fallback");
        }
        Require(backend.installPackage(consumer) && backend.resolveDependencies(),
            "resolver did not select the eligible versioned foreign provider/OR alternative");
        const TransactionData transaction(backend.transactionData());
        const TransactionPackageData *provider(FindTransactionPackage(transaction, "versioned-runtime:i386"));
        RequireTransaction(transaction.issues.empty() && transaction.installs.size() == 2 && provider != NULL &&
            provider->version == "7" && provider->identity.versionArchitecture == "i386", transaction,
            "resolver chose a wrong provider or failed to select the second OR alternative");
        backend.clearSelections();
    }
    const std::vector<RelationData> unsatisfied(backend.relations(
        backend.packageHandle("unsatisfied-versioned-consumer", "amd64")));
    const RelationClauseData *clause(Clause(unsatisfied, "fixture-api:any"));
    Require(clause != NULL && clause->version == "3" && clause->providers.empty(),
        "provider package version 7/99 incorrectly satisfied an unavailable provided ABI version 3");
}

void CheckCoinstalledSiblings(CydiaAPT::Internal::AptBackend &backend) {
    using namespace CydiaAPT;
    const PackageHandle native(backend.packageHandle("lockstep:amd64", "amd64"));
    const PackageHandle foreign(backend.packageHandle("lockstep:i386", "amd64"));
    Require(backend.packageSnapshot(native).installedVersion == "1" &&
        backend.packageSnapshot(foreign).installedVersion == "1", "Multi-Arch: same fixture was not coinstalled");
    Require(backend.installPackage(native) && backend.resolveDependencies(),
        "resolver could not upgrade a coinstalled Multi-Arch: same sibling");
    TransactionData transaction(backend.transactionData());
    const TransactionPackageData *nativeUpgrade(FindTransactionPackage(transaction, "lockstep:amd64"));
    const TransactionPackageData *foreignUpgrade(FindTransactionPackage(transaction, "lockstep:i386"));
    RequireTransaction(transaction.issues.empty() && transaction.upgrades.size() == 2 && transaction.removes.empty() &&
        nativeUpgrade != NULL && foreignUpgrade != NULL && nativeUpgrade->version == "2" && foreignUpgrade->version == "2",
        transaction, "resolver left coinstalled Multi-Arch: same versions unequal instead of upgrading both");
    backend.clearSelections();

    Require(backend.installPackage(native) && backend.installPackage(Version(backend, foreign, "1")),
        "explicit conflicting sibling versions could not be staged for dependency review");
    const bool resolved(backend.resolveDependencies());
    transaction = backend.transactionData();
    RequireTransaction(!resolved && !transaction.issues.empty(), transaction,
        "resolver accepted explicitly protected unequal Multi-Arch: same sibling versions");
    backend.clearSelections();

    Require(backend.removePackage(foreign) && backend.resolveDependencies(),
        "removing one coinstalled architecture was blocked by the retained sibling");
    transaction = backend.transactionData();
    RequireTransaction(transaction.issues.empty() && transaction.removes.size() == 1 &&
        transaction.removes.front() == "lockstep:i386" && transaction.packages.size() == 1, transaction,
        "removing the foreign sibling also changed the native instance");
    backend.clearSelections();
    // Shared-file equality and unpack/configure ordering remain dpkg/APT's
    // responsibility; this fixture never simulates their filesystem behavior.
}

void CheckNegativePins(CydiaAPT::Internal::AptBackend &backend) {
    using namespace CydiaAPT;
    bool installedVisible(false), unsupportedVisible(false);
    for (PackageHandle handle : backend.packageHandles()) {
        const PackageSnapshot package(backend.packageSnapshot(handle));
        if (package.identifier == "negative-installed") installedVisible = true;
        if (package.identifier == "negative-foreign:armhf") unsupportedVisible = true;
    }
    Require(installedVisible && unsupportedVisible,
        "all-negative policy hid installed package instances from inspection/removal");
    const PackageHandle foreign(backend.packageHandle("negative-foreign:armhf", "amd64"));
    Require(foreign.valid() && backend.removePackage(foreign),
        "unsupported installed package with no policy candidate could not be removed");
    backend.clearSelections();
    Require(backend.lookupPackage("negative-only", "amd64").status == PackageLookupStatus::NoEligibleVersion,
        "negative pin unexpectedly supplied an uninstalled policy candidate");
    const std::vector<RelationData> relations(backend.relations(backend.packageHandle("negative-consumer", "amd64")));
    const RelationClauseData *clause(Clause(relations, "negative-only"));
    Require(clause != NULL && clause->providers.size() == 1,
        "exact version fixture lost APT's contextual target behind the negative pin");
    const PackageHandle exact(clause->providers.front());
    Require(backend.installPackage(exact) && backend.packageHandle("negative-only", "amd64").valid(),
        "explicit version selection did not use the real APT candidate override");
    Require(backend.clearPackage(exact) &&
        backend.lookupPackage("negative-only", "amd64").status == PackageLookupStatus::NoEligibleVersion &&
        backend.transactionData().packages.empty() && backend.cacheState().installs == 0 && backend.cacheState().deletes == 0,
        "single cancellation retained an explicitly selected version with no policy candidate");

    const PackageHandle target(backend.packageHandle("target", "amd64"));
    Require(backend.installPackage(Version(backend, target, "3")) && backend.installPackage(exact),
        "two-package cancellation fixture could not be selected");
    Require(backend.clearPackage(exact) && !backend.autoInstalledDeltas().empty() &&
        backend.packageState(target).hasMode,
        "clearing a null candidate reset another queued package's manual/automatic state");
    Require(backend.installPackage(exact), "negative-pinned version could not be selected a second time");
    backend.clearSelections();
    Require(backend.lookupPackage("negative-only", "amd64").status == PackageLookupStatus::NoEligibleVersion &&
        backend.transactionData().packages.empty() && backend.cacheState().installs == 0 &&
        backend.cacheState().deletes == 0 && backend.autoInstalledDeltas().empty(),
        "whole transaction cancellation retained a candidate or package-state change under negative pins");
}

void CheckCommercialArchiveInputs(bool cached) {
    using namespace CydiaAPT;
    using namespace CydiaRuntime;
    pkgCacheFile cache;
    OpProgress progress;
    Require(cache.Open(&progress, false), "commercial archive fixture cache unavailable");
    pkgCache &packages(cache);
    const pkgCache::PkgIterator package(packages.FindPkg("archive-parent", "amd64"));
    Require(!package.end() && !package.VersionList().end(), "commercial archive fixture package unavailable");
    pkgSourceList sources;
    Require(sources.ReadMainList(), "commercial archive fixture sources unavailable");
    pkgRecords records(cache);
    FixtureAcquireStatus status;
    pkgAcquire fetcher(&status);
    std::string filename;
    auto archive = new pkgAcqArchive(&fetcher, &sources, &records, package.VersionList(), filename);
    const std::string selectedSource(LookupTag(archive->Custom600Headers(), "Target-Repo-URI"));
    Require(!selectedSource.empty() && archive->GetExpectedHashes().usable(),
        "real APT archive did not retain selected repository and expected hashes");
    Require((archive->Complete && archive->Status == pkgAcquire::Item::StatDone) == cached,
        "commercial archive fixture cache state differs from intended path");
    Internal::PreparedArchiveData expected;
    expected.identity = {"archive-parent", "1", "all"}; expected.package = "archive-parent";
    expected.commercial = true; expected.commercialSources.insert(selectedSource);
    std::map<const pkgAcquire::Item *, Internal::PreparedArchiveData> prepared{{archive, expected}};
    unsigned calls = 0;
    std::string grantURL;
    RepositoryArchiveAuthorizationStatus grantStatus = RepositoryArchiveAuthorizationStatus::Authorized;
    SetRepositoryArchiveAuthorizationHandler([&](const RepositoryArchiveAuthorizationRequest &request,
        const std::function<bool()> &) {
        ++calls;
        Require(request.sourceURL == selectedSource && request.package == "archive-parent" &&
            request.version == "1" && request.architecture == "all",
            "authorization request changed selected source or exact package identity");
        RepositoryArchiveAuthorizationResult result;
        result.status = grantStatus;
        if (grantStatus == RepositoryArchiveAuthorizationStatus::Authorized) result.transportURL = grantURL;
        return result;
    });
    if (cached) {
        FetchResultData result; bool staged = true;
        Require(Internal::StageAuthorizedArchives(fetcher, status, prepared, &result, &staged, 1000) &&
            !staged && calls == 0 && result.failures.empty(),
            "cached commercial archive requested unnecessary account authorization");
    } else {
        // The selected archive may be ordinary even when an alternative
        // repository labels the same package/version as commercial.
        prepared[archive].commercial = false;
        prepared[archive].commercialSources = {"https://unselected.invalid/"};
        FetchResultData ordinary; bool staged = true;
        Require(Internal::StageAuthorizedArchives(fetcher, status, prepared, &ordinary, &staged, 1000) &&
            !staged && calls == 0 && ordinary.failures.empty(),
            "ordinary selected archive invoked commercial authorization");
        prepared[archive] = expected;
        for (const std::string &invalid : {std::string(), std::string("http://download.invalid/file.deb"),
             std::string("file:///archive.deb"), std::string("https://user:secret@download.invalid/file.deb"),
             std::string("https://download.invalid/file.deb\nInjected: header"),
             std::string("https://download.invalid/file.deb\vheader"),
             std::string("https://download.invalid/file\\other.deb"),
             std::string("https://download.invalid/file.deb#fragment")}) {
            grantURL = invalid;
            const unsigned before(calls); FetchResultData result; staged = true;
            Require(!Internal::StageAuthorizedArchives(fetcher, status, prepared, &result, &staged, 1000) &&
                !staged && calls == before + 1 && result.failures.size() == 1 &&
                result.failures.front().reason == "invalid_download_grant",
                "invalid/non-HTTPS grant reached archive staging");
        }
        for (const auto &denial : {
            std::make_pair(RepositoryArchiveAuthorizationStatus::AuthenticationRequired, "repository_account_required"),
            std::make_pair(RepositoryArchiveAuthorizationStatus::Unavailable, "repository_package_unavailable"),
            std::make_pair(RepositoryArchiveAuthorizationStatus::Unsupported, "repository_authorization_required")}) {
            grantStatus = denial.first;
            const unsigned before(calls); FetchResultData result; staged = true;
            Require(!Internal::StageAuthorizedArchives(fetcher, status, prepared, &result, &staged, 1000) &&
                !staged && calls == before + 1 && result.failures.size() == 1 &&
                result.failures.front().reason == denial.second,
                "restricted archive silently downgraded or lost its authorization failure class");
        }
        grantStatus = RepositoryArchiveAuthorizationStatus::NotRequired;
        FetchResultData legacy; staged = true;
        Require(Internal::StageAuthorizedArchives(fetcher, status, prepared, &legacy, &staged, 1000) &&
            !staged && legacy.failures.empty(), "proven legacy/public archive path was blocked");
        Require(access(archive->DestFile.c_str(), F_OK) != 0,
            "rejected authorization created a package payload");
    }
    SetRepositoryArchiveAuthorizationHandler({});
}

void CheckAuthorizedArchiveDownload(CydiaAPT::Internal::AptBackend &backend) {
    using namespace CydiaAPT;
    using namespace CydiaRuntime;
    const char *method(std::getenv("CYDIA_APT_AUTHORIZED_METHOD"));
    const char *marker(std::getenv("CYDIA_APT_AUTHORIZED_MARKER"));
    Require(method != NULL && marker != NULL && access(marker, F_OK) != 0,
        "authorized acquisition fixture was not configured or already ran");
    const std::string cache(_config->FindDir("Dir::Cache::Archives") + "archive-authorized_1_all.deb");
    Require(access(cache.c_str(), F_OK) != 0, "authorized acquisition fixture started with a cached payload");
    const SourceListData sources(backend.sourceList());
    Require(sources.success && sources.uris.size() == 1, "authorized fixture has an ambiguous source identity");
    unsigned authorizations(0);
    unsigned renewalRequests(0);
    bool renewalFixture(false), revokeOnRenewal(false);
    SetRepositoryArchiveAuthorizationHandler([&](const RepositoryArchiveAuthorizationRequest &request,
        const std::function<bool()> &) {
        ++authorizations;
        if (renewalFixture) ++renewalRequests;
        Require(request.sourceURL == sources.uris.front() && request.package == "archive-authorized" &&
            request.version == "1" && request.architecture == "all",
            "authorized download lost selected repository or exact package identity");
        RepositoryArchiveAuthorizationResult result;
        if (revokeOnRenewal && renewalRequests == 2) {
            result.status = RepositoryArchiveAuthorizationStatus::Unavailable;
            result.message = "Fixture ownership was revoked.";
            return result;
        }
        result.status = RepositoryArchiveAuthorizationStatus::Authorized;
        result.transportURL = renewalFixture && renewalRequests == 2 ?
            "https://authorized.invalid/archive.deb?token=renewed" :
            "https://authorized.invalid/archive.deb?token=fixture";
        return result;
    });
    const std::string previousMethod(_config->Find("Dir::Bin::Methods::https",
        _config->FindDir("Dir::Bin::Methods") + "https"));
    _config->Set("Dir::Bin::Methods::https", method);
    fixtureSecurityMode = RepositorySecurityMode::Allow;
    const PackageHandle package(backend.packageHandle("archive-authorized", "amd64"));
    Require(package.valid() && backend.installPackage(package) && backend.resolveDependencies() &&
        backend.transactionData().installs.size() == 1 && backend.prepareArchives(),
        "authorized acquisition fixture could not prepare its exact independent package");
    const FetchResultData staged(backend.runFetcher(1000));
    Require(staged.completed && staged.failures.empty() && staged.warnings.empty() && authorizations == 1 &&
        access(cache.c_str(), F_OK) == 0,
        "authorized archive did not survive staging, GetArchives reconstruction and hash/layout validation");

    Require(backend.prepareArchives(), "authorized cache could not be reconstructed a second time");
    const FetchResultData cached(backend.runFetcher(1000));
    Require(cached.completed && cached.failures.empty() && cached.warnings.empty() && authorizations == 1,
        "verified authorized cache was downloaded or authorized again");
    // Authorization changes acquisition only: the usual selected-layout gate
    // must still reject the same verified rooted archive in a rootless plan.
    fixtureInstallPrefix = "/var/jb";
    Require(backend.prepareArchives(), "authorized archive layout fixture could not be prepared");
    const FetchResultData incompatible(backend.runFetcher(1000));
    bool layoutRejected(false);
    for (const FetchFailureData &failure : incompatible.failures)
        if (failure.package == "archive-authorized" && failure.kind == FetchDiagnosticKind::ArchiveLayoutMismatch)
            layoutRejected = true;
    Require(incompatible.completed && layoutRejected && authorizations == 1,
        "authorization bypassed the package layout gate or requested an account for cached bytes");
    std::ifstream acquisition(marker);
    std::string first, extra;
    Require(std::getline(acquisition, first) && first == "private" && !std::getline(acquisition, extra),
        "authorized acquisition did not use exactly one private pkgAcqFile download");
    acquisition.close();
    fixtureInstallPrefix = "/";
    renewalFixture = true;
    for (const std::string &scenario : {std::string("expire"), std::string("reject"),
         std::string("network"), std::string("hash"), std::string("revoke")}) {
        unlink(cache.c_str()); unlink(marker); renewalRequests = 0;
        revokeOnRenewal = scenario == "revoke";
        setenv("CYDIA_APT_AUTHORIZED_FAILURE", revokeOnRenewal ? "expire" : scenario.c_str(), 1);
        Require(backend.prepareArchives(), "authorization renewal fixture could not prepare its archive");
        const FetchResultData renewed(backend.runFetcher(1000));
        Require(renewed.completed && renewalRequests == (scenario == "network" || scenario == "hash" ? 1u : 2u),
            "authorization renewed a network error or exceeded its single retry bound");
        if (scenario == "expire") {
            Require(renewed.failures.empty() && access(cache.c_str(), F_OK) == 0,
                "fresh exact authorization did not recover a rejected temporary grant");
        } else {
            const std::string reason(scenario == "revoke" ? "repository_package_unavailable" :
                scenario == "hash" ? "archive_hash_mismatch" :
                scenario == "reject" ? "authorized_download_rejected" : "authorized_download_failed");
            Require(renewed.failures.size() == 1 && renewed.failures.front().reason == reason &&
                access(cache.c_str(), F_OK) != 0,
                "authorization renewal lost its denial, downloaded revoked bytes or bypassed integrity");
        }
        Require(!_error->PendingError(), "private signed acquisition leaked errors into the ordinary APT stack");
    }
    unsetenv("CYDIA_APT_AUTHORIZED_FAILURE");
    backend.clearSelections();
    fixtureInstallPrefix = "/";
    fixtureSecurityMode = RepositorySecurityMode::Warning;
    _config->Set("Dir::Bin::Methods::https", previousMethod);
    SetRepositoryArchiveAuthorizationHandler({});
}

void CheckArchivePreflight(CydiaAPT::Internal::AptBackend &backend, bool cached = false) {
    using namespace CydiaAPT;
    const char *marker(std::getenv("CYDIA_APT_PREFLIGHT_DPKG_MARKER"));
    const char *sentinel(std::getenv("CYDIA_APT_PREFLIGHT_DPKG_SENTINEL"));
    Require(marker != NULL && sentinel != NULL, "archive preflight sentinel was not configured");
    Require(access(marker, F_OK) != 0, "dpkg sentinel was already triggered");
    // These tagged fixtures model free packages in a commercial repository.
    // The separate success fixture exercises a package requiring a grant.
    CydiaRuntime::SetRepositoryArchiveAuthorizationHandler([](
        const CydiaRuntime::RepositoryArchiveAuthorizationRequest &request, const std::function<bool()> &) {
        Require(request.package == "archive-parent" || request.package == "archive-layout-dependency",
            "ordinary archive fixture authorized an unexpected package");
        CydiaRuntime::RepositoryArchiveAuthorizationResult result;
        result.status = CydiaRuntime::RepositoryArchiveAuthorizationStatus::NotRequired;
        return result;
    });
    const PackageHandle parent(backend.packageHandle("archive-parent", "amd64"));
    Require(parent.valid() && backend.installPackage(parent) && backend.resolveDependencies(),
        "archive fixture dependency could not be selected");
    const TransactionData transaction(backend.transactionData());
    Require(transaction.installs.size() == 2 && transaction.issues.empty(),
        "archive fixture did not have two initially eligible packages");
    fixtureSecurityMode = RepositorySecurityMode::Allow;
    Require(backend.prepareArchives(), "real dependency archives could not be prepared");
    const FetchResultData fetched(backend.runFetcher(1000));
    bool layoutFailure(false), scriptWarning(false);
    for (const FetchFailureData &failure : fetched.failures)
        if (failure.package == "archive-layout-dependency" && failure.kind == FetchDiagnosticKind::ArchiveLayoutMismatch &&
            !failure.path.empty() && !failure.reason.empty()) layoutFailure = true;
    for (const FetchFailureData &warning : fetched.warnings)
        if (warning.package == "archive-parent" && warning.kind == FetchDiagnosticKind::ArchiveUnverified)
            scriptWarning = true;
    Require(fetched.completed && layoutFailure && scriptWarning,
        "permissive repository security skipped archive layout/complete-script inspection");
    const std::string previousDpkg(_config->Find("Dir::Bin::dpkg"));
    _config->Set("Dir::Bin::dpkg", sentinel);
    Require(backend.lockForTransaction(), "fixture transaction lock was unavailable");
    bool started(true);
    FetchResultData finalValidation;
    Require(backend.runPackageManager(-1, &finalValidation, &started) == PackageManagerResult::Failed &&
        !started && !finalValidation.failures.empty() && access(marker, F_OK) != 0,
        "a dependency archive failure reached dpkg before blocking the whole transaction");
    backend.discardErrors();
    backend.clearSelections();
    Require(backend.runPackageManager(-1) == PackageManagerResult::Failed && access(marker, F_OK) != 0,
        "changed transaction selections reused already-prepared archives");
    backend.discardErrors();
    backend.unlockForTransaction();
    _config->Set("Dir::Bin::dpkg", previousDpkg);
    fixtureSecurityMode = RepositorySecurityMode::Warning;

    fixtureInstallPrefix = "/opt/distro";
    Require(backend.installPackage(backend.packageHandle("archive-layout-dependency", "amd64")) &&
        backend.resolveDependencies() && backend.prepareArchives(), "custom-prefix archive fixture could not be prepared");
    const FetchResultData customPrefix(backend.runFetcher(1000));
    bool foreignPrefixBlocked(false);
    for (const FetchFailureData &failure : customPrefix.failures)
        if (failure.package == "archive-layout-dependency" && failure.kind == FetchDiagnosticKind::ArchiveLayoutMismatch)
            foreignPrefixBlocked = true;
    Require(customPrefix.completed && foreignPrefixBlocked,
        "custom installation prefix treated the known /var/jb layout as an advisory instead of a mismatch");
    backend.clearSelections();
    fixtureInstallPrefix = "/";

    // APT's file method may retain the repository pathname rather than copy
    // the archive. Only the second invocation explicitly populates the cache.
    if (!cached) {
        CydiaRuntime::SetRepositoryArchiveAuthorizationHandler({});
        return;
    }

    // APT's cache fast path checks size before marking an archive complete.
    // A same-size modification must still fail Cydia's hash verification,
    // even for an already-authorized commercial package.
    const std::string cachedParent(_config->FindDir("Dir::Cache::Archives") + "archive-parent_1_all.deb");
    const int payload(open(cachedParent.c_str(), O_RDWR | O_CLOEXEC));
    Require(payload >= 0, "cached commercial payload could not be opened for tamper fixture");
    unsigned char original;
    Require(pread(payload, &original, 1, 0) == 1, "cached payload fixture could not be read");
    const unsigned char changed(original ^ 0x40);
    Require(pwrite(payload, &changed, 1, 0) == 1, "cached payload fixture could not be changed");
    Require(backend.installPackage(parent) && backend.resolveDependencies() && backend.prepareArchives(),
        "cached commercial integrity fixture could not be selected");
    const FetchResultData tampered(backend.runFetcher(1000));
    const bool restored(pwrite(payload, &original, 1, 0) == 1);
    close(payload);
    bool hashFailure(false);
    for (const FetchFailureData &failure : tampered.failures)
        if (failure.package == "archive-parent" && failure.kind == FetchDiagnosticKind::ArchiveMismatch)
            hashFailure = true;
    Require(restored && hashFailure && access(marker, F_OK) != 0,
        "cached commercial archive bypassed hash validation or entered dpkg");
    backend.clearSelections();
    CydiaRuntime::SetRepositoryArchiveAuthorizationHandler({});
}
}

int main(int argc, char **) {
    Require(pkgInitConfig(*_config) && pkgInitSystem(*_config, _system), "APT initialization failed");
    _config->Set("Dir::Cache::pkgcache", "");
    _config->Set("Dir::Cache::srcpkgcache", "");
    FixtureAcquireStatus status;
    CydiaAPT::Internal::AptBackend backend(status);
    Require(backend.openCache(), "real APT cache could not be opened");
    backend.createCacheViews();
    Require(backend.loadSources(), "fixture source definitions could not be loaded");
    CheckCommercialArchiveInputs(argc > 1);
    if (argc > 1) {
        CheckArchivePreflight(backend, true);
        std::cout << "[apt-package-actions] cached archive preflight passed\n";
        return 0;
    }
    CheckAuthorizedArchiveDownload(backend);
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
    CheckMultiarch(backend);
    CheckExactVersionIdentity(backend);
    CheckVersionedProviders(backend);
    CheckCoinstalledSiblings(backend);
    CheckNegativePins(backend);
    CheckArchivePreflight(backend);
    std::cout << "[apt-package-actions] real APT action/resolver fixture passed\n";
}
