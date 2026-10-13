/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryPackageManager.hpp"
#include "Cydia/AptLocalStateVersion.hpp"
#include "Cydia/SourceDocumentStore.hpp"
#include <apt-pkg/configuration.h>
#include <apt-pkg/depcache.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/indexfile.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/strutl.h>
#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <set>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT {
namespace {
namespace P = Provider;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Path(const std::string &value) {
    if (value.empty() || value.front() != '/' || value.back() == '/' || value.find("//") != std::string::npos) return false;
    for (unsigned char c : value) if (c < 32 || c == 127) return false;
    std::size_t start = 1;
    while (start < value.size()) {
        const auto end = value.find('/', start);
        const auto part = value.substr(start, end == std::string::npos ? end : end - start);
        if (part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return true;
}
P::ExecutionPackage ExecutionPackageValue(pkgCache::VerIterator version) {
    if (version.end()) return {};
    return {version.ParentPkg().Name(), version.VerStr(), version.Arch()};
}
bool Same(const P::ExecutionPackage &a, const P::ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool CoversTransaction(const P::ReviewedTransaction &review, std::string *error) {
    std::map<std::string, P::ExecutionAction> expected;
    const auto add = [&](const std::vector<std::string> &routes, P::ExecutionAction action) {
        for (const auto &route : routes)
            if (!review.transaction.packages.count(route) || !expected.emplace(route, action).second) return false;
        return true;
    };
    if (!add(review.transaction.installs, P::ExecutionAction::Unpack) ||
        !add(review.transaction.reinstalls, P::ExecutionAction::Unpack) ||
        !add(review.transaction.upgrades, P::ExecutionAction::Unpack) ||
        !add(review.transaction.downgrades, P::ExecutionAction::Unpack) ||
        !add(review.transaction.removes, P::ExecutionAction::Remove) ||
        !add(review.transaction.purges, P::ExecutionAction::Purge) ||
        expected.size() != review.transaction.packages.size()) return Fail(error, "recovery_transaction_changed");
    std::set<std::string> covered, configured;
    for (const auto &action : review.execution.actions) {
        std::string route;
        for (const auto &entry : review.transaction.packages) {
            const P::ExecutionPackage package{entry.second.identity.baseName, entry.second.version, entry.second.identity.versionArchitecture};
            if (!Same(action.package, package)) continue;
            if (!route.empty()) return Fail(error, "recovery_transaction_identity_ambiguous");
            route = entry.first;
        }
        if (route.empty()) return Fail(error, "recovery_action_not_reviewed");
        const auto primary = expected.at(route);
        if (primary == action.action) covered.insert(route);
        else if (primary == P::ExecutionAction::Unpack && action.action == P::ExecutionAction::Configure) {
            if (!covered.count(route)) return Fail(error, "recovery_configure_before_unpack");
            configured.insert(route);
        } else if (primary != P::ExecutionAction::Purge || action.action != P::ExecutionAction::Remove || covered.count(route))
            return Fail(error, "recovery_action_not_reviewed");
    }
    if (covered.size() != expected.size()) return Fail(error, "recovery_transaction_action_missing");
    for (const auto &entry : expected)
        if (entry.second == P::ExecutionAction::Unpack && !configured.count(entry.first))
            return Fail(error, "recovery_configure_action_missing");
    return true;
}
bool Has(const std::vector<std::string> &values, const std::string &value) {
    return std::find(values.begin(), values.end(), value) != values.end();
}
std::string Expand(std::string value, const std::string &architecture) {
    std::size_t position = 0;
    while ((position = value.find("$(ARCH)", position)) != std::string::npos) {
        value.replace(position, 7, architecture); position += architecture.size();
    }
    return value;
}
std::string Join(std::string base, const std::string &tail) {
    if (base.empty() || base.back() != '/') base += '/';
    return base + tail;
}
std::vector<std::string> Words(std::string value) {
    for (char &c : value) if (c == ',') c = ' ';
    std::vector<std::string> result;
    std::size_t start = 0;
    while ((start = value.find_first_not_of(" \t\r\n", start)) != std::string::npos) {
        const auto end = value.find_first_of(" \t\r\n", start);
        result.push_back(value.substr(start, end == std::string::npos ? end : end - start));
        if (end == std::string::npos) break;
        start = end;
    }
    return result;
}
bool Source(const CydiaSources::StoreSnapshot &sources, const RuntimeDescriptor &runtime,
            const IndexTarget &target, P::ArchiveManifest *archive) {
    unsigned matches = 0;
    for (const auto &stored : sources.documents) for (const auto &definition : stored.document.definitions) {
        if (!definition.enabled || !Has(definition.types, "deb")) continue;
        auto architectures = runtime.acquisitionArchitectures;
        std::vector<std::string> added, removed;
        for (const auto &field : definition.fields) {
            std::string key = field.name;
            for (char &c : key) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
            if (key == "arch" || key == "architectures") architectures = Words(field.value);
            else if (key == "arch+" || key == "architectures-add") added = Words(field.value);
            else if (key == "arch-" || key == "architectures-remove") removed = Words(field.value);
        }
        for (const auto &arch : added) if (!Has(architectures, arch)) architectures.push_back(arch);
        architectures.erase(std::remove_if(architectures.begin(), architectures.end(),
            [&](const std::string &arch) { return Has(removed, arch); }), architectures.end());
        if (archive->package.architecture != "all" && !Has(architectures, archive->package.architecture)) continue;
        if (!Has(removed, "all") && !Has(architectures, "all")) architectures.push_back("all");
        bool definitionMatches = false;
        std::string sourceURI;
        for (const auto &rawURI : definition.uris) for (const auto &rawSuite : definition.suites) {
            const auto uri = Expand(rawURI, runtime.architecture), suite = Expand(rawSuite, runtime.architecture);
            bool matched = !suite.empty() && suite.back() == '/' && definition.components.empty() &&
                target.URI == Join(uri, suite) + "Packages";
            if (!suite.empty() && suite.back() != '/')
                for (const auto &component : definition.components) for (const auto &arch : architectures)
                    if ((archive->package.architecture == "all" || archive->package.architecture == arch) &&
                        target.URI == Join(uri, "dists/" + suite + "/" + component + "/binary-" + arch + "/Packages")) matched = true;
            if (matched) { definitionMatches = true; sourceURI = uri; }
        }
        if (!definitionMatches) continue;
        ++matches; archive->sourceURI = sourceURI;
        archive->sourceDefinitionPath = stored.document.path;
        archive->sourceDefinitionOrdinal = definition.ordinal;
    }
    return matches == 1;
}
bool SameFile(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
#ifdef __APPLE__
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
        a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
bool IndexHash(const std::string &path, const std::function<bool()> &cancelled, std::string *identity) {
    if (!Path(path)) return false;
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    struct Close { int fd; ~Close() { close(fd); } } closeFile{fd};
    struct stat before, after, named;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_size <= 0 ||
        static_cast<std::uint64_t>(before.st_size) > 512ull * 1024 * 1024) return false;
    Hashes hash(Hashes::SHA256SUM);
    std::uint64_t left = before.st_size;
    while (left) {
        if (cancelled && cancelled()) return false;
        unsigned char bytes[65536];
        ssize_t count;
        do { count = read(fd, bytes, std::min<std::uint64_t>(sizeof(bytes), left)); } while (count < 0 && errno == EINTR);
        if (count <= 0 || !hash.Add(bytes, count)) return false;
        left -= count;
    }
    if (fstat(fd, &after) || lstat(path.c_str(), &named) || !SameFile(before, after) || !SameFile(before, named)) return false;
    *identity = "SHA256:" + hash.GetHashString(Hashes::SHA256SUM).HashValue();
    return true;
}
void CopyConfiguration(const Configuration::Item *item, Configuration &copy, const std::string &prefix = "") {
    for (; item; item = item->Next) {
        const std::string name(prefix.empty() ? item->Tag : prefix + "::" + item->Tag);
        copy.Set(name, item->Value);
        CopyConfiguration(item->Child, copy, name);
    }
}
// In libapt's default "smart" mode, ConfigureAll only marks most packages
// configured in its ordering flags. pkgDPkgPM::Go later implements that phase
// with --configure --pending. A reviewed worker must name every effect before
// execution, so ask libapt's own final configuration ordering to emit explicit
// Configure callbacks instead. Immediate/Pre-Depends ordering is unchanged.
// Do not run Go, expand pending selections, or retain a process-wide override.
struct OrderingConfigurationScope {
    Configuration *original = _config;
    Configuration copy;
    OrderingConfigurationScope() {
        CopyConfiguration(original->Tree(nullptr), copy);
        // EIPP diagnostics can create directories or launch a compressor.
        copy.Set("Dir::Log::Planner", "");
        copy.Set("PackageManager::Configure", "all");
        _config = &copy;
    }
    ~OrderingConfigurationScope() { _config = original; }
};
bool Hook(const char *name) {
    const auto *tree = _config->Tree(name);
    if (!tree) return false;
    if (!tree->Value.empty()) return true;
    for (auto *child = tree->Child; child; child = child->Next) if (!child->Value.empty() || child->Child) return true;
    return false;
}
}

AptRecoveryPackageManager::AptRecoveryPackageManager(pkgDepCache *cache) : pkgDPkgPM(cache) {}
AptRecoveryPackageManager::~AptRecoveryPackageManager() = default;
bool AptRecoveryPackageManager::Proceed() {
    if (!capturing_) return Fail(&refusal_, "recovery_recording_only");
    if (cancelled_ && cancelled_()) return Fail(&refusal_, "recovery_cancelled");
    return true;
}
bool AptRecoveryPackageManager::Install(PkgIterator package, std::string file) {
    return Proceed() && pkgDPkgPM::Install(package, file);
}
bool AptRecoveryPackageManager::Configure(PkgIterator package) { return Proceed() && pkgDPkgPM::Configure(package); }
bool AptRecoveryPackageManager::Remove(PkgIterator package, bool purge) { return Proceed() && pkgDPkgPM::Remove(package, purge); }
bool AptRecoveryPackageManager::Go(APT::Progress::PackageManager *) { return Fail(&refusal_, "recovery_recording_only"); }
pkgPackageManager::OrderResult AptRecoveryPackageManager::OrderInstall() {
    if (!Proceed()) return Failed;
    if (_config->Find("APT::Planner", "internal") != "internal") { refusal_ = "recovery_external_planner_unsupported"; return Failed; }
    // With RootDir, libapt prefixes even an empty planner log with that root.
    // Do not change the active filesystem namespace just to suppress a log.
    if (!_config->Find("RootDir").empty()) { refusal_ = "recovery_rootdir_ordering_unsupported"; return Failed; }
    for (const char *hook : {"DPkg::Pre-Invoke", "DPkg::Post-Invoke", "DPkg::Pre-Install-Pkgs"})
        if (Hook(hook)) { refusal_ = "recovery_hooks_unsupported"; return Failed; }
    for (const auto &option : _config->FindVector("DPkg::Options"))
        if (option.compare(0, 12, "--pre-invoke") == 0 || option.compare(0, 13, "--post-invoke") == 0) {
            refusal_ = "recovery_hooks_unsupported"; return Failed;
        }
    if ((!finiteEffects_ && _config->FindB("DPkg::TriggersPending", false)) || !_config->FindB("DPkg::NoTriggers", true) ||
        _config->FindB("dpkg::install::recursive", false) || _config->FindB("APT::Force-LoopBreak", false)) {
        refusal_ = "recovery_unbounded_effects_unsupported"; return Failed;
    }
    const std::string configure(_config->Find("PackageManager::Configure", "smart"));
    if ((configure != "smart" && configure != "all") ||
        (configure == "smart" && !_config->FindB("DPkg::ConfigurePending", true))) {
        refusal_ = "recovery_configure_policy_unsupported"; return Failed;
    }
    // Original Go may expand pending selections and process triggers that the
    // resolver's explicit list omits. Do not silently turn those into a plan.
    for (auto package = Cache.PkgBegin(); !package.end(); ++package) {
        const bool triggerState = package->CurrentState == pkgCache::State::TriggersPending ||
            package->CurrentState == pkgCache::State::TriggersAwaited;
        if ((!finiteEffects_ && triggerState) ||
            (package.State() != pkgCache::PkgIterator::NeedsNothing && Cache[package].Keep()) ||
            ((package->SelectedState == pkgCache::State::DeInstall || package->SelectedState == pkgCache::State::Purge) &&
                !Cache[package].Delete() && !package.CurrentVer().end())) {
            refusal_ = "recovery_pending_effects_unsupported"; return Failed;
        }
        if (Cache[package].Install()) {
            const auto version(Cache[package].InstVerIter(Cache));
            const auto selected(archives_.find(package->ID));
            if (version.end() || selected == archives_.end() || selected->second.version != version ||
                pkgPackageManager::FileNames[package->ID] != selected->second.path) {
                refusal_ = "recovery_selected_archive_unavailable"; return Failed;
            }
        }
    }
    OrderingConfigurationScope configuration;
    return pkgPackageManager::OrderInstall();
}
bool AptRecoveryPackageManager::BindArchive(pkgCache::VerIterator version, pkgCache::VerFileIterator record,
    const std::string &path, std::string *error) {
    if (consumed_ || version.end() || record.end() || version.Cache() != &Cache.GetCache() ||
        record.Cache() != &Cache.GetCache() || !Path(path)) return Fail(error, "recovery_invalid_archive_binding");
    const auto package = version.ParentPkg();
    if (package->ID >= Cache.Head().PackageCount || Cache[package].InstVerIter(Cache) != version)
        return Fail(error, "recovery_archive_version_mismatch");
    bool belongs = false;
    for (auto item = version.FileList(); !item.end(); ++item) if (item == record) belongs = true;
    if (!belongs || record.File().Flagged(pkgCache::Flag::NotSource)) return Fail(error, "recovery_archive_record_mismatch");
    if (archives_.count(package->ID)) return Fail(error, "recovery_duplicate_archive_binding");
    archives_.emplace(package->ID, ArchiveBinding{version, record, path});
    pkgPackageManager::FileNames[package->ID] = path;
    return true;
}

RecoveryCaptureResult AptRecoveryPackageManager::Capture(pkgSourceList &sources, pkgRecords &records,
    const RuntimeDescriptor &runtime, const TransactionData &transaction, const P::Binding &binding,
    const CydiaPackages::ArchiveLayout &layout, const std::function<bool()> &cancelled, bool finiteEffects) {
    RecoveryCaptureResult result;
    const auto fail = [&](const char *code, RecoveryCaptureStatus status = RecoveryCaptureStatus::Unsupported) {
        result.status = status; result.errorCode = code; result.review = P::ReviewedTransaction();
        result.preDependsArchives.clear(); return result;
    };
    if (consumed_) return fail("recovery_capture_already_consumed");
    consumed_ = true; cancelled_ = cancelled; capturing_ = true; finiteEffects_ = finiteEffects;
    struct Stop { AptRecoveryPackageManager *manager; ~Stop() { manager->capturing_ = false; manager->cancelled_ = {}; } } stop{this};
    if (!Proceed()) return fail("recovery_cancelled", RecoveryCaptureStatus::Cancelled);
    P::Message request; request.sequence = 1; request.kind = P::MessageKind::ParentRequest;
    request.operation = P::Operation::ExecuteDpkg; request.binding = binding;
    if (runtime.architecture.empty() || layout.prefix != runtime.packageInstallPrefix || !transaction.issues.empty() || transaction.removesEssential ||
        transaction.registeredArchitectures != runtime.registeredArchitectures || !P::ValidRequestBinding(request) ||
        runtime.binding.providerIdentifier != binding.providerIdentifier || runtime.binding.session != binding.session ||
        runtime.binding.configurationIdentity != binding.configurationIdentity || runtime.binding.policyIdentity != binding.policyIdentity ||
        runtime.binding.packageStateIdentity != binding.packageStateIdentity) return fail("recovery_invalid_review_inputs");
    const auto ordered = DoInstallPreFork();
    if (ordered != Completed) {
        if (refusal_ == "recovery_cancelled") return fail(refusal_.c_str(), RecoveryCaptureStatus::Cancelled);
        return fail(refusal_.empty() ? "recovery_ordering_failed" : refusal_.c_str(),
            refusal_.empty() ? RecoveryCaptureStatus::Failed : RecoveryCaptureStatus::Unsupported);
    }
    const auto documents = CydiaSources::ReadEffectiveDocuments({runtime.sourceListPath, runtime.sourcePartsDirectory});
    if (!documents.ready()) return fail("recovery_sources_unavailable");
    result.review.transaction = transaction; result.review.binding = binding;
    std::set<unsigned long> usedArchives;
    std::set<std::string> uniqueActions;
    std::map<std::string, std::set<std::string>> changingArchitectures;
    std::map<std::string, std::string> indexHashes;
    for (const auto &item : pkgDPkgPM::List) {
        if (!Proceed()) return fail("recovery_cancelled", RecoveryCaptureStatus::Cancelled);
        // The negotiated parent ledger owns complete, repeatable trigger
        // passes. An unqualified pending marker is never a primary action ID.
        if (finiteEffects_ && item.Op == Item::TriggersPending) continue;
        if (result.review.execution.actions.size() == P::MaximumCollectionItems) return fail("recovery_plan_too_large");
        if (item.Pkg.end()) return fail("recovery_pending_effects_unsupported");
        const bool removal = item.Op == Item::Remove || item.Op == Item::Purge;
        auto version = removal ? LocalStateVersion(item.Pkg) : Cache[item.Pkg].InstVerIter(Cache);
        if (version.end()) return fail("recovery_exact_version_unavailable");
        P::ReviewedAction action; action.identifier = result.review.execution.actions.size() + 1; action.package = ExecutionPackageValue(version);
        if (!removal && action.package.architecture != "all" && !Has(runtime.registeredArchitectures, action.package.architecture))
            return fail("recovery_architecture_unsupported");
        if (item.Op == Item::Install) action.action = P::ExecutionAction::Unpack;
        else if (item.Op == Item::Configure) action.action = P::ExecutionAction::Configure;
        else if (item.Op == Item::Remove) action.action = P::ExecutionAction::Remove;
        else if (item.Op == Item::Purge) action.action = P::ExecutionAction::Purge;
        else return fail("recovery_pending_effects_unsupported");
        const std::string actionKey = std::to_string(static_cast<unsigned>(action.action)) + ':' + action.package.package + ':' + action.package.architecture;
        if (!uniqueActions.insert(actionKey).second) return fail("recovery_repeated_effects_unsupported");
        changingArchitectures[action.package.package].insert(action.package.architecture);
        if (item.Op == Item::Install) {
            const auto selected = archives_.find(item.Pkg->ID);
            if (selected == archives_.end() || selected->second.version != version ||
                pkgPackageManager::FileNames[item.Pkg->ID] != selected->second.path) return fail("recovery_selected_archive_unavailable");
            const auto &input = selected->second;
            pkgIndexFile *index = nullptr;
            if (!sources.FindIndex(input.record.File(), index)) return fail("recovery_source_index_unavailable");
            const auto *debian = dynamic_cast<pkgDebianIndexTargetFile *>(index);
            if (!debian) return fail("recovery_source_index_unsupported");
            const auto target = debian->GetIndexTarget();
            auto &parser = records.Lookup(input.record);
            const char *start = nullptr, *end = nullptr; parser.GetRec(start, end);
            if (!start || !end || end <= start || static_cast<std::uint64_t>(end - start) > 1024 * 1024 ||
                parser.RecordField("Package") != action.package.package || parser.RecordField("Version") != action.package.version ||
                parser.RecordField("Architecture") != action.package.architecture) return fail("recovery_record_identity_mismatch");
            P::ArchiveManifest archive; archive.identifier = "archive-" + std::to_string(action.identifier);
            archive.package = action.package; archive.path = input.path; archive.layout = layout;
            const char *indexPath = input.record.File().FileName();
            if (!indexPath) return fail("recovery_source_index_unavailable");
            archive.sourceIndexPath = indexPath; archive.sourceIndexURI = target.URI;
            archive.recordOffset = input.record->Offset; archive.recordSize = end - start;
            archive.filename = parser.FileName();
            const auto hashes = parser.Hashes();
            archive.size = hashes.FileSize();
            for (const auto &hash : hashes) if (hash.HashType() != "Checksum-FileSize") archive.hashes[hash.HashType()] = hash.HashValue();
            if (!hashes.usable() || (!archive.hashes.count("SHA256") && !archive.hashes.count("SHA512")) || !archive.size || archive.filename.empty())
                return fail("recovery_archive_hashes_unavailable");
            if (!Source(documents, runtime, target, &archive)) return fail("recovery_source_association_ambiguous");
            const auto expected = Join(runtime.listsDirectory, URItoFileName(target.URI));
            bool pathMatches = archive.sourceIndexPath == expected;
            for (const char *extension : {".gz", ".bz2", ".xz", ".lzma", ".lz4", ".zst"})
                pathMatches = pathMatches || archive.sourceIndexPath == expected + extension;
            auto hashed = indexHashes.find(archive.sourceIndexPath);
            if (!pathMatches || (hashed == indexHashes.end() && !IndexHash(archive.sourceIndexPath, cancelled, &archive.sourceIndexIdentity)))
                return fail(cancelled && cancelled() ? "recovery_cancelled" : "recovery_index_evidence_unavailable",
                    cancelled && cancelled() ? RecoveryCaptureStatus::Cancelled : RecoveryCaptureStatus::Unsupported);
            if (hashed != indexHashes.end()) archive.sourceIndexIdentity = hashed->second;
            else indexHashes.emplace(archive.sourceIndexPath, archive.sourceIndexIdentity);
            // Use the same selected record as the manifest, never another
            // version/origin or the resolver's merged dependency graph.
            std::map<std::string, std::string> controls;
            std::string controlError;
            if (!CydiaPackages::CanonicalPackageEffectControlFields({{"pre-depends", parser.RecordField("Pre-Depends")}},
                    &controls, &controlError)) return fail("recovery_predepends_record_unsupported");
            if (!controls.at("pre-depends").empty()) result.preDependsArchives.insert(archive.identifier);
            action.archive = archive.identifier; result.review.execution.archives.push_back(std::move(archive));
            usedArchives.insert(item.Pkg->ID);
        }
        result.review.execution.actions.push_back(std::move(action));
    }
    // Go special-cases same-name crossgrades and may drop/order removals or
    // transfer automatic state. That must be modeled before supporting them.
    for (const auto &entry : changingArchitectures) if (entry.second.size() > 1) {
        bool removes = false;
        for (const auto &action : result.review.execution.actions)
            if (action.package.package == entry.first && (action.action == P::ExecutionAction::Remove || action.action == P::ExecutionAction::Purge)) removes = true;
        if (removes) return fail("recovery_crossgrade_effects_unsupported");
    }
    if (usedArchives.size() != archives_.size() || result.review.execution.actions.empty()) return fail("recovery_incomplete_recording");
    // The parent validates transaction coverage and all authority again. Catch
    // a stale caller preview locally instead of returning contradictory values.
    std::string coverageError;
    if (!CoversTransaction(result.review, &coverageError)) return fail(coverageError.c_str());
    result.status = RecoveryCaptureStatus::Recorded; return result;
}
} // namespace CydiaAPT
