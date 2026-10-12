/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptCompatibilityInternal.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/AptVersionPolicyInternal.hpp"

#include <apt-pkg/policy.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/debindexfile.h>
#include <apt-pkg/debmetaindex.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/tagfile.h>
#include <apt-pkg/version.h>

#include <cstring>
#include <limits>
#include <algorithm>

namespace {

class ParserView {
  private:
    pkgRecords::Parser *parser_;

    std::string Field(const char *name) const {
#if APT_PKG_MAJOR < 6
        const char *start(NULL);
        const char *end(NULL);
        if (!parser_->Find(name, start, end))
            return std::string();
        return std::string(start, end);
#else
        return parser_->RecordField(name);
#endif
    }

    static void Trim(std::string &value) {
        std::string::size_type first(value.find_first_not_of(" \t\r\n"));
        if (first == std::string::npos) {
            value.clear();
            return;
        }
        std::string::size_type last(value.find_last_not_of(" \t\r\n"));
        value.assign(value, first, last - first + 1);
    }

  public:
    explicit ParserView(pkgRecords::Parser &parser) : parser_(&parser) {
    }

    std::string DisplayName() const {
        std::string display(Field("Name"));
        if (display.empty())
            display = Field("Maemo-Display-Name");
        return display;
    }

    std::vector<std::string> Tags() const {
        std::vector<std::string> tags;
        std::string field(Field("Tag"));
        std::string::size_type begin(0);
        while (begin <= field.size()) {
            std::string::size_type comma(field.find(',', begin));
            std::string tag(field.substr(begin, comma == std::string::npos ? comma : comma - begin));
            Trim(tag);
            if (!tag.empty())
                tags.push_back(tag);
            if (comma == std::string::npos)
                break;
            begin = comma + 1;
        }
        return tags;
    }

    std::string field(const char *name) const {
        return Field(name);
    }
};

} // namespace

namespace CydiaAPT {
namespace Internal {

pkgCache::VerFileIterator PreferredVersionFile(pkgCache::VerIterator version) {
    pkgCache::VerFileIterator first(version.FileList());
    for (pkgCache::VerFileIterator file(first); !file.end(); ++file)
        if (!file.File().Flagged(pkgCache::Flag::NotSource))
            return file;
    return first;
}

class PackageRegistry {
  public:
    struct Entry {
        pkgCache::PkgIterator package;
        pkgCache::VerIterator version;
        pkgCache::VerFileIterator file;

        Entry(pkgCache::PkgIterator package, pkgCache::VerIterator version) :
            package(package),
            version(version),
            file(PreferredVersionFile(version))
        {
        }
    };

    std::vector<Entry> entries;
    std::map<std::string, PackageHandle> handles;
};

class SourceRegistry {
  public:
    struct Entry {
        metaIndex *index;
        SourceSnapshot snapshot;
        std::vector<std::uint32_t> fileIDs;

        Entry(metaIndex *index) : index(index) {
        }
    };

    std::vector<Entry> entries;
};

namespace {

MultiArchMode GetMultiArchMode(pkgCache::VerIterator version) {
    if (version.end())
        return MultiArchMode::None;

    switch (version->MultiArch & ~pkgCache::Version::All) {
        case pkgCache::Version::Same:
            return MultiArchMode::Same;
        case pkgCache::Version::Foreign:
            return MultiArchMode::Foreign;
        case pkgCache::Version::Allowed:
            return MultiArchMode::Allowed;
        default:
            return MultiArchMode::None;
    }
}

PackageIdentity GetPackageIdentity(pkgCache::PkgIterator package,
                                   pkgCache::VerIterator version,
                                   const char *nativeArchitecture) {
    if (package.end() || version.end() || nativeArchitecture == NULL)
        return PackageIdentity();
    return BuildPackageIdentity(package.Name(), package.Arch(), version.Arch(),
                                nativeArchitecture, GetMultiArchMode(version));
}

std::string GetPackageRouteName(pkgCache::PkgIterator package) {
    if (package.end() || package.Cache()->NativeArch() == NULL)
        return std::string();
    return BuildPackageRouteName(package.Name(), package.Arch(),
                                 package.Cache()->NativeArch());
}

std::string RegistryKey(pkgCache::PkgIterator package, pkgCache::VerIterator version) {
    std::string key(package.Name());
    key.push_back('\n');
    key.append(package.Arch());
    key.push_back('\n');
    key.append(version.Arch());
    key.push_back('\n');
    key.append(version.VerStr());
    key.push_back('\n');
    key.append(std::to_string(version->ID));
    return key;
}

PackageHandle RegisterPackage(PackageRegistry &registry, pkgCache::PkgIterator package,
                              pkgCache::VerIterator version) {
    if (package.end() || version.end())
        return PackageHandle();

    const std::string key(RegistryKey(package, version));
    std::map<std::string, PackageHandle>::const_iterator found(registry.handles.find(key));
    if (found != registry.handles.end())
        return found->second;

    if (registry.entries.size() >= std::numeric_limits<std::uint32_t>::max())
        return PackageHandle();
    registry.entries.push_back(PackageRegistry::Entry(package, version));
    PackageHandle handle(static_cast<std::uint32_t>(registry.entries.size()));
    registry.handles[key] = handle;
    return handle;
}

bool HasLocalState(pkgCache::PkgIterator package) {
    return !package.end() &&
        (package->CurrentState != pkgCache::State::NotInstalled ||
         !package.CurrentVer().end());
}

pkgCache::VerIterator LocalStateVersion(pkgCache::PkgIterator package) {
    const pkgCache::VerIterator installed(package.CurrentVer());
    if (!installed.end()) return installed;
    if (package->CurrentState == pkgCache::State::ConfigFiles) {
        for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version)
            for (pkgCache::VerFileIterator file(version.FileList()); !file.end(); ++file) {
                const char *type(file.File().IndexType());
                if (type != NULL && strcmp(type, "Debian dpkg status file") == 0) return version;
            }
    }
    return pkgCache::VerIterator();
}

void RecomputeCandidateState(pkgDepCache &cache) {
    // APT has no SetCandidateVersion(end) overload. After clearing a null
    // policy candidate, rebuild dependency/count state using its public API.
    // Update also rereads extended_states; preserve other queued user changes.
    std::vector<std::pair<pkgCache::PkgIterator, bool>> automatic;
    for (pkgCache::PkgIterator package(cache.PkgBegin()); !package.end(); ++package)
        automatic.push_back(std::make_pair(package, (cache[package].Flags & pkgCache::Flag::Auto) != 0));
    cache.Update();
    for (const auto &entry : automatic) cache.MarkAuto(entry.first, entry.second);
    cache.MarkAndSweep();
}

bool RestorePolicyCandidate(pkgDepCache &cache, pkgPolicy *policy, pkgCache::PkgIterator package) {
    if (policy == NULL) return false;
    const pkgCache::VerIterator candidate(policy->GetCandidateVer(package));
    if (!candidate.end()) {
        cache.SetCandidateVersion(candidate);
        return false;
    }
    if (cache[package].CandidateVer == NULL) return false;
    cache[package].CandidateVer = NULL;
    cache[package].Update(package, cache);
    return true;
}

bool IsVisiblePackageVersion(pkgCache::PkgIterator package,
                             pkgCache::VerIterator version) {
    return !package.end() && !version.end() &&
        IsPackageArchitectureVisible(version.Arch(), HasLocalState(package),
                                     RegisteredArchitectures());
}

bool MatchesVersionArchitecture(pkgCache::VerIterator version,
                                const std::string &architecture, bool includeAll) {
    return !version.end() && (architecture == version.Arch() ||
        (includeAll && strcmp(version.Arch(), "all") == 0));
}

pkgCache::VerIterator SelectedVersion(pkgCacheFile &cache, pkgCache::PkgIterator package,
                                      const std::string &architecture, bool includeAll) {
    if (package.end()) return pkgCache::VerIterator();
    const pkgCache::VerIterator candidate(cache->GetCandidateVersion(package));
    if (MatchesVersionArchitecture(candidate, architecture, includeAll)) return candidate;

    /* Filter the same priority and no-implicit-downgrade rules used by
     * pkgPolicy::GetCandidateVer. Looking up :all or an exact native version
     * must not change the shared native/all cache bucket's policy candidate. */
    pkgCache::VerIterator selected;
    const pkgCache::VerIterator current(package.CurrentVer());
    signed short selectedPriority(-1);
    if (cache.Policy != NULL) {
        for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version) {
            if (!MatchesVersionArchitecture(version, architecture, includeAll)) continue;
            const signed short priority(cache.Policy->GetPriority(version, true));
            if (priority == 0 || priority <= selectedPriority) continue;
            if (!current.end() && priority < 1000 && package.Cache()->VS != NULL &&
                package.Cache()->VS->CmpVersion(version.VerStr(), current.VerStr()) < 0)
                continue;
            selected = version;
            selectedPriority = priority;
        }
    }
    if (!selected.end()) return selected;
    // Installed records stay inspectable/removable even with no candidate.
    if (MatchesVersionArchitecture(current, architecture, includeAll)) return current;
    if (package->CurrentState == pkgCache::State::ConfigFiles)
        for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version)
            if (MatchesVersionArchitecture(version, architecture, includeAll)) return version;
    return pkgCache::VerIterator();
}

std::string DependencyTargetName(pkgCache::DepIterator dependency) {
    const pkgCache::PkgIterator target(dependency.TargetPkg());
    // Unqualified dependencies use the depender's architecture internally;
    // that cache detail is not an explicit architecture in the expression.
    return target.end() ? std::string() : target.Name();
}

std::vector<PackageHandle> DependencyProviders(PackageRegistry &registry,
                                              pkgCache::DepIterator dependency) {
    std::vector<PackageHandle> providers;
    std::set<std::uint32_t> seen;
    std::unique_ptr<pkgCache::Version *[]> targets(dependency.AllTargets());
    for (pkgCache::Version **target(targets.get()); target != NULL && *target != NULL; ++target) {
        pkgCache::VerIterator version(*dependency.Cache(), *target);
        const PackageHandle handle(RegisterPackage(registry, version.ParentPkg(), version));
        if (handle.valid() && seen.insert(handle.value).second) providers.push_back(handle);
    }
    return providers;
}

PackageRegistry::Entry *FindPackage(PackageRegistry *registry, PackageHandle handle) {
    if (registry == NULL || !handle.valid() || handle.value > registry->entries.size())
        return NULL;
    return &registry->entries[handle.value - 1];
}

SourceRegistry::Entry *FindSource(SourceRegistry *registry, SourceHandle handle) {
    if (registry == NULL || !handle.valid() || handle.value > registry->entries.size())
        return NULL;
    return &registry->entries[handle.value - 1];
}

const char *CurrentStateName(unsigned char state) {
    switch (state) {
        case pkgCache::State::NotInstalled: return "NotInstalled";
        case pkgCache::State::UnPacked: return "UnPacked";
        case pkgCache::State::HalfConfigured: return "HalfConfigured";
        case pkgCache::State::HalfInstalled: return "HalfInstalled";
        case pkgCache::State::ConfigFiles: return "ConfigFiles";
        case pkgCache::State::Installed: return "Installed";
        case pkgCache::State::TriggersAwaited: return "TriggersAwaited";
        case pkgCache::State::TriggersPending: return "TriggersPending";
    }
    return NULL;
}

const char *SelectionName(unsigned char state) {
    switch (state) {
        case pkgCache::State::Unknown: return "Unknown";
        case pkgCache::State::Install: return "Install";
        case pkgCache::State::Hold: return "Hold";
        case pkgCache::State::DeInstall: return "DeInstall";
        case pkgCache::State::Purge: return "Purge";
    }
    return NULL;
}

} // namespace

AptBackend::AptBackend(pkgAcquireStatus &status) :
    status_(&status),
    policy_(NULL),
    records_(NULL),
    resolver_(NULL),
    fetcher_(NULL),
    lock_(NULL),
    list_(NULL),
    packages_(new PackageRegistry()),
    sources_(new SourceRegistry())
{
}

AptBackend::~AptBackend() {
    reset();
}

void AptBackend::KeepFileDescriptor(int descriptor) {
    if (descriptor < 0) return;
    const auto retained(_config->FindVector("APT::Keep-Fds"));
    const std::string value(std::to_string(descriptor));
    if (std::find(retained.begin(), retained.end(), value) == retained.end())
        _config->Set("APT::Keep-Fds::", descriptor);
}

void AptBackend::reset() {
    packages_.reset(new PackageRegistry());
    sources_.reset(new SourceRegistry());
    delete list_;
    list_ = NULL;
    manager_.reset();
    delete lock_;
    lock_ = NULL;
    delete fetcher_;
    fetcher_ = NULL;
    delete resolver_;
    resolver_ = NULL;
    delete records_;
    records_ = NULL;
    delete policy_;
    policy_ = NULL;
    cache_.Close();
}

void AptBackend::createCacheViews() {
    packages_.reset(new PackageRegistry());
    delete resolver_;
    resolver_ = NULL;
    delete records_;
    records_ = NULL;
    delete policy_;
    policy_ = NULL;

    policy_ = new pkgDepCache::Policy();
    records_ = new pkgRecords(cache_);
    resolver_ = new pkgProblemResolver(cache_);
}

bool AptBackend::loadSources() {
    delete list_;
    list_ = new pkgSourceList();
    sources_.reset(new SourceRegistry());
    if (!list_->ReadMainList())
        return false;

    delete fetcher_;
    fetcher_ = new pkgAcquire(status_);
    return true;
}

std::vector<PackageHandle> AptBackend::packageHandles() {
    std::vector<PackageHandle> handles;
    if (static_cast<pkgDepCache *>(cache_) == NULL)
        return handles;

    PackageRegistry &registry(*packages_);
    for (pkgCache::PkgIterator package(cache_->PkgBegin()); !package.end(); ++package) {
        pkgCache::VerIterator version(cache_->GetCandidateVersion(package));
        if (version.end()) version = LocalStateVersion(package);
        if (!IsVisiblePackageVersion(package, version))
            continue;
        PackageHandle handle(RegisterPackage(registry, package, version));
        if (handle.valid())
            handles.push_back(handle);
    }
    return handles;
}

PackageLookupResult AptBackend::lookupPackage(const std::string &name, const std::string &preferredArchitecture) {
    PackageLookupResult result;
    result.selector = ParsePackageSelector(name);
    if (!result.selector.valid()) {
        result.status = PackageLookupStatus::InvalidSelector;
        return result;
    }
    if (static_cast<pkgDepCache *>(cache_) == NULL) return result;
    const char *nativeArchitecture(static_cast<pkgCache &>(cache_).NativeArch());
    const std::string native(nativeArchitecture == NULL ? preferredArchitecture : nativeArchitecture);
    const PackageSelector &selector(result.selector);
    const std::string architecture(selector.kind == PackageSelectorKind::Native ||
        selector.kind == PackageSelectorKind::Default ? native : selector.architecture);
    const pkgCache::GrpIterator group(cache_->FindGrp(selector.baseName));
    const bool supported(selector.kind == PackageSelectorKind::Any || IsArchitectureSupported(architecture));
    if (group.end()) {
        result.status = supported ? PackageLookupStatus::NotFound : PackageLookupStatus::UnsupportedArchitecture;
        return result;
    }

    std::set<std::string> architectures;
    std::set<std::string> alternatives;
    for (pkgCache::PkgIterator package(group.PackageList()); !package.end(); package = group.NextPkg(package)) {
        for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version)
            architectures.insert(version.Arch());
        const pkgCache::VerIterator version(SelectedVersion(cache_, package, package.Arch(), true));
        if (version.end() || !IsArchitectureSupported(version.Arch())) continue;
        const std::string key(std::string(version.Arch()) + "\n" + version.VerStr());
        if (alternatives.insert(key).second)
            result.alternatives.push_back(RegisterPackage(*packages_, package, version));
    }
    result.availableArchitectures.assign(architectures.begin(), architectures.end());

    if (selector.kind == PackageSelectorKind::Any) {
        if (result.alternatives.size() == 1) {
            result.status = PackageLookupStatus::Found;
            result.handle = result.alternatives.front();
        } else result.status = result.alternatives.empty() ? PackageLookupStatus::NoEligibleVersion :
                                                           PackageLookupStatus::Ambiguous;
        return result;
    }

    // APT maps "all" to its native package bucket. Select the version's
    // actual architecture below, instead of accepting that bucket's alias.
    const pkgCache::PkgIterator package(cache_->FindPkg(selector.baseName, architecture));
    if (!supported && (package.end() || !HasLocalState(package))) {
        result.status = PackageLookupStatus::UnsupportedArchitecture;
        return result;
    }
    const pkgCache::VerIterator version(SelectedVersion(cache_, package, architecture,
        selector.kind == PackageSelectorKind::Default));
    if (version.end()) {
        result.status = !supported ? PackageLookupStatus::UnsupportedArchitecture :
            (architectures.empty() ? PackageLookupStatus::NotFound : PackageLookupStatus::NoEligibleVersion);
        return result;
    }
    result.handle = RegisterPackage(*packages_, package, version);
    result.status = result.handle.valid() ? PackageLookupStatus::Found : PackageLookupStatus::NoEligibleVersion;
    return result;
}

PackageHandle AptBackend::packageHandle(const std::string &name, const std::string &preferredArchitecture) {
    const PackageLookupResult result(lookupPackage(name, preferredArchitecture));
    return result.status == PackageLookupStatus::Found ? result.handle : PackageHandle();
}

std::vector<PackageHandle> AptBackend::downgradeHandles(PackageHandle handle) {
    std::vector<PackageHandle> handles;
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL)
        return handles;

    const pkgCache::PkgIterator package(entry->package);
    const pkgCache::VerIterator selected(entry->version);
    for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version) {
        if (version == selected)
            continue;
        if (!IsVisiblePackageVersion(package, version))
            continue;
        PackageHandle other(RegisterPackage(*packages_, package, version));
        if (other.valid())
            handles.push_back(other);
    }
    return handles;
}

std::vector<PackageHandle> AptBackend::versionHandles(PackageHandle handle) {
    std::vector<PackageHandle> handles;
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL) return handles;
    const pkgCache::PkgIterator package(entry->package);
    for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version)
        if (IsVisiblePackageVersion(package, version) && version.Downloadable())
            handles.push_back(RegisterPackage(*packages_, package, version));
    return handles;
}

CydiaAPT::PackageRecordData AptBackend::recordData(PackageHandle handle) {
    CydiaAPT::PackageRecordData data;
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (records_ == NULL || entry == NULL || entry->file.end())
        return data;

    pkgRecords::Parser &parser(records_->Lookup(entry->file));
    ParserView record(parser);

    static const char * const fieldNames[] = {
        /* Keep the complete read-only package-record subset that the native
         * depiction compatibility snapshot advertises.  The previous list
         * omitted core Debian fields such as Version and Description, making
         * an installed package's legacy getField() return undefined even
         * though the same record was rendered by native UI. */
        "Package", "Name", "Version", "Architecture", "Description", "Section",
        "Maintainer", "Depends", "Pre-Depends", "Recommends", "Suggests",
        "Conflicts", "Replaces", "Provides", "Installed-Size", "Filename",
        "Size", "MD5sum", "SHA256", "Icon", "Depiction", "Homepage", "Website",
        "Bugs", "Support", "Author", "Multi-Arch", "Maemo-Display-Name", "Tag",
    };
    for (size_t index(0); index != sizeof(fieldNames) / sizeof(fieldNames[0]); ++index)
        data.fields[fieldNames[index]] = record.field(fieldNames[index]);

    data.tags = record.Tags();
    data.displayName = record.DisplayName();
    data.maintainer = parser.Maintainer();
    data.shortDescription = parser.ShortDesc();
    data.longDescription = parser.LongDesc();

    const char *start(NULL);
    const char *end(NULL);
    parser.GetRec(start, end);
    if (start != NULL && end != NULL && end >= start)
        data.raw.assign(start, end);

    return data;
}

CydiaAPT::PackageSnapshot AptBackend::packageSnapshot(PackageHandle handle) {
    CydiaAPT::PackageSnapshot data;
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL)
        return data;

    data.handle = handle;
    data.registeredArchitectures = RegisteredArchitectures();
    data.record = recordData(handle);
    data.state = packageState(handle);
    data.identity = GetPackageIdentity(entry->package, entry->version,
                                       entry->package.Cache()->NativeArch());
    data.identifier = data.identity.routingName;
    data.version = entry->version.VerStr();
    data.architecture = data.identity.versionArchitecture;
    data.installedSize = entry->version->InstalledSize;
    if (const char *section = entry->version.Section())
        data.section = section;

    pkgCache::VerIterator installed(entry->package.CurrentVer());
    if (!installed.end())
        data.installedVersion = installed.VerStr();
    const pkgCache::VerIterator local(LocalStateVersion(entry->package));
    if (!local.end()) {
        data.installedIdentity = GetPackageIdentity(entry->package, local,
                                                    entry->package.Cache()->NativeArch());
    }

    if (!entry->file.end()) {
        pkgCache::PkgFileIterator file(entry->file.File());
        if (!file.end()) {
            data.hasSourceFile = true;
            data.sourceFileID = file->ID;
        }
    }

    if (cache_.Policy != NULL)
        data.defaultPriority = cache_.Policy->GetPriority(entry->version, true) == 500;
    return data;
}

CydiaAPT::PackageStateData AptBackend::packageState(PackageHandle handle) {
    CydiaAPT::PackageStateData data;
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return data;

    pkgCache::PkgIterator package(entry->package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    pkgDepCache::StateCache &state(cache[package]);

    if (const char *name = CurrentStateName(package->CurrentState))
        data.state = name;
    if (const char *name = SelectionName(package->SelectedState))
        data.selection = name;

    data.essential = (package->Flags & pkgCache::Flag::Essential) != 0;
    data.protectedPackage = (package->Flags & pkgCache::Flag::Important) != 0;
    data.ignored = package->SelectedState == pkgCache::State::Hold;
    data.broken = state.InstBroken();
    data.newInstall = state.NewInstall();
    data.deletePackage = state.Delete();
    data.reinstall = (state.iFlags & pkgDepCache::ReInstall) == pkgDepCache::ReInstall;
    data.upgrade = state.Upgrade();
    data.downgrade = state.Downgrade();
    data.hasMode = state.Mode != pkgDepCache::ModeKeep;
    data.half = package->CurrentState == pkgCache::State::HalfConfigured ||
        package->CurrentState == pkgCache::State::HalfInstalled;
    data.halfConfigured = package->CurrentState == pkgCache::State::HalfConfigured;
    data.halfInstalled = package->CurrentState == pkgCache::State::HalfInstalled;

    pkgCache::VerIterator version(entry->version);
    pkgCache::VerIterator current(package.CurrentVer());
    data.hasCurrent = !current.end();
    data.architectureSupported = !version.end() && IsArchitectureSupported(version.Arch());
    data.versionAvailable = !version.end() && version.Downloadable();
    data.installedVersionAvailable = !current.end() && current.Downloadable();
    data.installedVersion = version == current;
    if (cache_.Policy != NULL && !version.end()) {
        data.policyCandidate = version == cache_.Policy->GetCandidateVer(package);
        data.versionPriority = cache_.Policy->GetPriority(version, true);
    }
    if (!version.end() && !current.end() && package.Cache()->VS != NULL)
        data.versionComparison = package.Cache()->VS->CmpVersion(version.VerStr(), current.VerStr());
    data.upgradable = !version.end() && !current.end() && package.Cache()->VS != NULL &&
        IsDpkgVersionUpgrade(*package.Cache()->VS, version.VerStr(), current.VerStr());

    if (!version.end() && cache_.Policy != NULL)
        data.candidateMatchesVersion = state.CandidateVerIter(cache) == cache_.Policy->GetCandidateVer(package);

    switch (state.Mode) {
        case pkgDepCache::ModeDelete:
            data.mode = (state.iFlags & pkgDepCache::Purge) != 0 ? "PURGE" : "REMOVE";
            break;
        case pkgDepCache::ModeKeep:
            if ((state.iFlags & pkgDepCache::ReInstall) != 0)
                data.mode = "REINSTALL";
            break;
        case pkgDepCache::ModeInstall:
            switch (state.Status) {
                case -1:
                    data.mode = "DOWNGRADE";
                    break;
                case 0: data.mode = "INSTALL"; break;
                case 1: data.mode = "UPGRADE"; break;
                case 2: data.mode = "NEW_INSTALL"; break;
            }
            break;
    }

    return data;
}

std::vector<RelationData> AptBackend::relations(PackageHandle handle) {
    std::vector<RelationData> result;
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL)
        return result;

    const pkgCache::VerIterator selected(entry->version);
    for (pkgCache::DepIterator dependency(selected.DependsList()); !dependency.end(); ) {
        pkgCache::DepIterator first;
        pkgCache::DepIterator last;
        dependency.GlobOr(first, last);

        RelationData relation;
        relation.relationship = first.DepType();
        for (;;) {
            RelationClauseData clause;
            clause.package = DependencyTargetName(first);
            clause.providers = DependencyProviders(*packages_, first);
            if (const char *version = first.TargetVer()) {
                clause.comparison = first.CompType();
                clause.version = version;
            }
            relation.clauses.push_back(clause);
            if (first == last)
                break;
            ++first;
        }
        result.push_back(relation);
    }
    return result;
}

namespace {

bool DependsOnSubstrate(pkgCache::VerIterator version) {
    if (version.end())
        return false;
    for (pkgCache::DepIterator dependency(version.DependsList()); !dependency.end(); ++dependency) {
        if (dependency->Type != pkgCache::Dep::Depends && dependency->Type != pkgCache::Dep::PreDepends)
            continue;
        pkgCache::PkgIterator package(dependency.TargetPkg());
        if (!package.end() &&
            (strcmp(package.Name(), "mobilesubstrate") == 0 ||
             strcmp(package.Name(), "com.ex.substitute") == 0))
            return true;
    }
    return false;
}

void AddActionIssue(TransactionData &result, const std::string &name, const char *kind) {
    TransactionIssueData issue;
    issue.package = name;
    issue.kind = kind;
    result.issues.push_back(issue);
}

} // namespace

TransactionData AptBackend::transactionData() {
    TransactionData result;
    result.registeredArchitectures = RegisteredArchitectures();
    if (static_cast<pkgDepCache *>(cache_) == NULL)
        return result;

    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    // Transaction safety must include every cache entry, including versions
    // hidden from browsing because dpkg no longer registers their architecture.
    for (pkgCache::PkgIterator package(cache.PkgBegin()); !package.end(); ++package) {
        pkgDepCache::StateCache &selection(cache[package]);
        const bool reinstall((selection.iFlags & pkgDepCache::ReInstall) != 0);
        const bool changed(selection.Mode != pkgDepCache::ModeKeep || reinstall);
        if (!changed && !selection.InstBroken()) continue;
        const pkgCache::VerIterator planned(selection.InstVerIter(cache));
        const pkgCache::VerIterator local(LocalStateVersion(package));
        pkgCache::VerIterator version(selection.Delete() ? local : planned);
        if (version.end()) version = local;
        if (version.end()) version = selection.CandidateVerIter(cache);
        if (version.end()) version = package.VersionList();
        const std::string name(GetPackageRouteName(package));
        if (changed) {
            TransactionPackageData operation;
            operation.displayName = package.Name();
            operation.identity.baseName = package.Name();
            operation.identity.packageArchitecture = package.Arch();
            operation.identity.aptName = std::string(package.Name()) + ":" + package.Arch();
            operation.identity.routingName = name;
            result.packages[name] = operation;
        }
        if (version.end()) {
            if (changed) {
                if (package->SelectedState == pkgCache::State::Hold) AddActionIssue(result, name, "held");
                if (!selection.Delete()) AddActionIssue(result, name, "unavailable_version");
                else {
                    const bool essential((package->Flags & pkgCache::Flag::Essential) != 0);
                    const bool protectedPackage((package->Flags & pkgCache::Flag::Important) != 0);
                    if (essential || protectedPackage)
                        AddActionIssue(result, name, essential ? "essential_removal" : "protected_removal");
                    result.removesEssential = result.removesEssential || essential;
                    if ((selection.iFlags & pkgDepCache::Purge) != 0) result.purges.push_back(name);
                    else result.removes.push_back(name);
                }
            }
            if (selection.InstBroken()) AddActionIssue(result, name, "dependency");
            continue;
        }
        const PackageHandle handle(RegisterPackage(*packages_, package, version));
        const PackageStateData state(packageState(handle));
        if (changed) {
            TransactionPackageData &operation(result.packages[name]);
            const pkgCache::VerIterator exact(selection.Delete() ? local : planned);
            if (!exact.end()) {
                operation.identity = GetPackageIdentity(package, exact, package.Cache()->NativeArch());
                operation.version = exact.VerStr();
                const PackageHandle exactHandle(RegisterPackage(*packages_, package, exact));
                operation.displayName = recordData(exactHandle).displayName;
            }
            if (operation.displayName.empty()) operation.displayName = package.Name();
        }
        if (!state.deletePackage && changed) {
            if (planned.end()) AddActionIssue(result, name, "unavailable_version");
            else if (!IsArchitectureSupported(planned.Arch()))
                AddActionIssue(result, name, "unsupported_architecture");
        }

        if (state.broken) {
            TransactionIssueData issue;
            issue.package = name;
            issue.kind = "dependency";

            for (pkgCache::DepIterator dependency(planned.end() ? pkgCache::DepIterator() : planned.DependsList()); !dependency.end(); ) {
                pkgCache::DepIterator first;
                pkgCache::DepIterator last;
                dependency.GlobOr(first, last);
                if (!cache.IsImportantDep(last) || (cache[last] & pkgDepCache::DepGInstall) != 0)
                    continue;

                TransactionReasonData reason;
                reason.relationship = first.DepType();
                for (;;) {
                    TransactionClauseData clause;
                    pkgCache::PkgIterator target(first.TargetPkg());
                    clause.package = DependencyTargetName(first);
                    clause.providers = DependencyProviders(*packages_, first);
                    if (const char *required = first.TargetVer()) {
                        clause.comparison = first.CompType();
                        clause.version = required;
                    }

                    if (target.end() || (target.VersionList().end() && target->ProvidesList == 0))
                        clause.reason = "missing";
                    else {
                        pkgCache::VerIterator targetPlanned(cache[target].InstVerIter(cache));
                        if (!targetPlanned.end()) {
                            clause.reason = "installed";
                            clause.installed = targetPlanned.VerStr();
                        } else {
                            clause.reason = clause.providers.empty() ? "uninstallable" : "virtual";
                            for (PackageHandle provider : clause.providers) {
                                const PackageRegistry::Entry *provided(FindPackage(packages_.get(), provider));
                                if (provided == NULL) continue;
                                if (cache[provided->package].InstVerIter(cache) == provided->version) {
                                    clause.reason = "installed";
                                    clause.installed = provided->version.VerStr();
                                    break;
                                }
                                if (cache[provided->package].CandidateVerIter(cache) == provided->version)
                                    clause.reason = "uninstalled";
                            }
                        }
                    }
                    reason.clauses.push_back(clause);
                    if (first == last)
                        break;
                    ++first;
                }
                issue.reasons.push_back(reason);
            }
            result.issues.push_back(issue);
        }

        if (state.ignored && (state.hasMode || state.reinstall))
            AddActionIssue(result, name, "held");
        if (state.deletePackage && (state.essential || state.protectedPackage))
            AddActionIssue(result, name, state.essential ? "essential_removal" : "protected_removal");

        if (state.newInstall)
            result.installs.push_back(name);
        else if (!state.deletePackage && state.reinstall)
            result.reinstalls.push_back(name);
        else if (state.upgrade)
            result.upgrades.push_back(name);
        else if (state.downgrade)
            result.downgrades.push_back(name);
        else if (!state.deletePackage && state.hasMode)
            result.installs.push_back(name);
        else if (!state.deletePackage)
            continue;
        else {
            result.removesEssential = result.removesEssential || state.essential;
            if (state.mode == "PURGE") result.purges.push_back(name);
            else result.removes.push_back(name);
        }

        result.substrate = result.substrate || DependsOnSubstrate(version);
        result.substrate = result.substrate || DependsOnSubstrate(package.CurrentVer());
    }

    if (fetcher_ != NULL) {
        result.downloading = fetcher_->FetchNeeded();
        result.resuming = fetcher_->PartialPresent();
    }
    return result;
}

bool AptBackend::resolveDependencies() {
    const bool success(resolver_ != NULL && ResolveDependencies(*resolver_));
    if (!success)
        _error->Discard();
    return success;
}

void AptBackend::clearSelections() {
    if (static_cast<pkgDepCache *>(cache_) == NULL)
        return;
    delete resolver_;
    resolver_ = new pkgProblemResolver(cache_);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    bool recompute(false);
    for (pkgCache::PkgIterator package(cache.PkgBegin()); !package.end(); ++package) {
        cache.SetReInstall(package, false);
        cache[package].iFlags &= ~pkgDepCache::Protected;
        cache.MarkKeep(package, false);
        recompute = RestorePolicyCandidate(cache, cache_.Policy, package) || recompute;
        if (package.Name() == NULL || package.Arch() == NULL) continue;
        const std::string key(std::string(package.Name()) + ":" + package.Arch());
        const std::map<std::string, bool>::const_iterator original(originalAutoInstalled_.find(key));
        if (original != originalAutoInstalled_.end()) cache.MarkAuto(package, original->second);
    }
    if (recompute) RecomputeCandidateState(cache);
}

bool AptBackend::prepareDistUpgrade() {
    return static_cast<pkgDepCache *>(cache_) != NULL &&
        PrepareDistUpgrade(static_cast<pkgDepCache &>(cache_));
}

bool AptBackend::clearPackage(PackageHandle handle) {
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    pkgCache::PkgIterator package(entry->package);
    resolver_->Clear(package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    cache.SetReInstall(package, false);
    cache[package].iFlags &= ~pkgDepCache::Protected;
    const bool kept(cache.MarkKeep(package, false));
    const bool recompute(RestorePolicyCandidate(cache, cache_.Policy, package));
    if (package.Name() == NULL || package.Arch() == NULL) return kept;
    const std::string key(std::string(package.Name()) + ":" + package.Arch());
    const std::map<std::string, bool>::const_iterator original(originalAutoInstalled_.find(key));
    if (original != originalAutoInstalled_.end()) cache.MarkAuto(package, original->second);
    if (recompute) RecomputeCandidateState(cache);
    return kept;
}

bool AptBackend::installPackage(PackageHandle handle) {
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    pkgCache::PkgIterator package(entry->package);
    pkgCache::VerIterator version(entry->version);
    if (package->SelectedState == pkgCache::State::Hold || !version.Downloadable() ||
        !IsArchitectureSupported(version.Arch())) return false;
    resolver_->Clear(package);
    resolver_->Protect(package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    cache.SetCandidateVersion(version);
    cache.SetReInstall(package, false);
    if (!cache.MarkInstall(package, false)) return false;
    /* An explicit user request makes an automatic package manual, just as
     * apt install does. Cancellation restores its original shared flag. */
    cache.MarkAuto(package, false);
    pkgDepCache::StateCache &state(cache[package]);
    if (!state.Install() && version == package.CurrentVer())
        cache.SetReInstall(package, true);
    return true;
}

bool AptBackend::reinstallPackage(PackageHandle handle) {
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL) return false;
    pkgCache::PkgIterator package(entry->package);
    pkgCache::VerIterator installed(package.CurrentVer());
    if (installed.end() || !installed.Downloadable()) return false;
    return installPackage(RegisterPackage(*packages_, package, installed));
}

bool AptBackend::removePackage(PackageHandle handle, bool purge) {
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    pkgCache::PkgIterator package(entry->package);
    if (package->SelectedState == pkgCache::State::Hold ||
        (package->Flags & (pkgCache::Flag::Essential | pkgCache::Flag::Important)) != 0)
        return false;
    if (!purge && package.CurrentVer().end()) return false;
    resolver_->Clear(package);
    resolver_->Remove(package);
    resolver_->Protect(package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    cache.SetReInstall(package, false);
    return cache.MarkDelete(package, purge);
}

std::vector<SourceHandle> AptBackend::sourceHandles() {
    std::vector<SourceHandle> handles;
    if (list_ == NULL || fetcher_ == NULL)
        return handles;

    if (sources_->entries.empty()) {
        for (pkgSourceList::const_iterator source(list_->begin()); source != list_->end(); ++source) {
            SourceRegistry::Entry entry(*source);
            entry.snapshot.uri = (*source)->GetURI();
            entry.snapshot.distribution = (*source)->GetDist();
            entry.snapshot.type = (*source)->GetType();
            entry.snapshot.trusted = (*source)->IsTrusted();

            if (debReleaseIndex *release = dynamic_cast<debReleaseIndex *>(*source)) {
                entry.snapshot.base = release->MetaIndexURI("");

                const std::size_t first(fetcher_->ItemsEnd() - fetcher_->ItemsBegin());
                release->GetIndexes(fetcher_, true);
                for (pkgAcquire::ItemIterator item(fetcher_->ItemsBegin() + first); item != fetcher_->ItemsEnd(); ++item) {
                    const std::string file((*item)->DescURI());
                    const std::string::size_type slash(file.rfind('/'));
                    if (slash != std::string::npos)
                        entry.snapshot.files.insert(file.substr(0, slash));
                }

                FileFd fd;
                if (!fd.Open(release->MetaIndexFile("Release"), FileFd::ReadOnly))
                    _error->Discard();
                else {
                    pkgTagFile tags(&fd);
                    pkgTagSection section;
                    if (tags.Step(section)) {
                        struct Field {
                            const char *name;
                            std::string *value;
                        } fields[] = {
                            {"default-icon", &entry.snapshot.defaultIcon},
                            {"depiction", &entry.snapshot.depiction},
                            {"description", &entry.snapshot.description},
                            {"label", &entry.snapshot.label},
                            {"origin", &entry.snapshot.origin},
                            {"support", &entry.snapshot.support},
                            {"version", &entry.snapshot.version},
                        };
                        for (std::size_t index(0); index != sizeof(fields) / sizeof(fields[0]); ++index) {
                            const char *start(NULL);
                            const char *end(NULL);
                            if (section.Find(fields[index].name, start, end) && start != NULL && end >= start)
                                fields[index].value->assign(start, end);
                        }
                    }
                }
            }

            sources_->entries.push_back(entry);
        }
    }

    for (std::size_t index(0); index != sources_->entries.size(); ++index) {
        SourceHandle handle(static_cast<std::uint32_t>(index + 1));
        sources_->entries[index].snapshot.handle = handle;
        handles.push_back(handle);
    }
    return handles;
}

SourceSnapshot AptBackend::sourceSnapshot(SourceHandle handle) {
    (void) sourceHandles();
    SourceRegistry::Entry *entry(FindSource(sources_.get(), handle));
    return entry == NULL ? SourceSnapshot() : entry->snapshot;
}

std::string AptBackend::sourceField(SourceHandle handle, const std::string &name) {
    (void) sourceHandles();
    SourceRegistry::Entry *entry(FindSource(sources_.get(), handle));
    if (entry == NULL || name.empty())
        return std::string();

    debReleaseIndex *release(dynamic_cast<debReleaseIndex *>(entry->index));
    if (release == NULL)
        return std::string();
    FileFd fd;
    if (!fd.Open(release->MetaIndexFile("Release"), FileFd::ReadOnly)) {
        _error->Discard();
        return std::string();
    }
    pkgTagFile tags(&fd);
    pkgTagSection section;
    if (!tags.Step(section))
        return std::string();
    const char *start(NULL);
    const char *end(NULL);
    return section.Find(name.c_str(), start, end) && start != NULL && end >= start ? std::string(start, end) : std::string();
}

std::vector<std::uint32_t> AptBackend::sourceFileIDs(SourceHandle handle) {
    std::vector<std::uint32_t> result;
    (void) sourceHandles();
    SourceRegistry::Entry *entry(FindSource(sources_.get(), handle));
    if (entry == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return result;
    if (entry->fileIDs.empty()) {
        for (std::vector<pkgIndexFile *> *indices(entry->index->GetIndexFiles()); indices != NULL && !indices->empty(); ) {
            for (std::vector<pkgIndexFile *>::const_iterator index(indices->begin()); index != indices->end(); ++index) {
                if (dynamic_cast<debPackagesIndex *>(*index) == NULL)
                    continue;
                pkgCache::PkgFileIterator file((*index)->FindInCache(static_cast<pkgCache &>(cache_)));
                if (!file.end())
                    entry->fileIDs.push_back(file->ID);
            }
            break;
        }
    }
    result = entry->fileIDs;
    return result;
}

} // namespace Internal
} // namespace CydiaAPT
