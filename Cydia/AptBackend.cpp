/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptCompatibilityInternal.hpp"

#include <apt-pkg/policy.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/debindexfile.h>
#include <apt-pkg/debmetaindex.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/tagfile.h>

#include <cstring>
#include <limits>

namespace {

class ParserView {
  private:
    pkgRecords::Parser *parser_;

    std::string Field(const char *name) const {
#if APT_PKG_MAJOR < 7
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

class PackageRegistry {
  public:
    struct Entry {
        pkgCache::PkgIterator package;
        pkgCache::VerIterator version;
        pkgCache::VerFileIterator file;

        Entry(pkgCache::PkgIterator package, pkgCache::VerIterator version) :
            package(package),
            version(version),
            file(version.FileList())
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
    key.append(version.Arch());
    key.push_back('\n');
    key.append(version.VerStr());
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
    if (descriptor >= 0)
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
        PackageHandle handle(RegisterPackage(registry, package, version));
        if (handle.valid())
            handles.push_back(handle);
    }
    return handles;
}

PackageHandle AptBackend::packageHandle(const std::string &name, const std::string &preferredArchitecture) {
    if (name.empty() || static_cast<pkgDepCache *>(cache_) == NULL)
        return PackageHandle();

    pkgCache::PkgIterator package;
    if (name.rfind(':') != std::string::npos)
        package = cache_->FindPkg(name);
    else {
        if (!preferredArchitecture.empty())
            package = cache_->FindPkg(name, preferredArchitecture);
        if (package.end())
            package = cache_->FindPkg(name, "any");
        if (package.end())
            package = cache_->FindPkg(name);
    }
    if (package.end())
        return PackageHandle();

    pkgCache::VerIterator version(cache_->GetCandidateVersion(package));
    const std::string::size_type qualifier(name.rfind(':'));
    if (version.end() && qualifier != std::string::npos &&
        name.compare(qualifier + 1, std::string::npos, "any") == 0) {
        pkgCache::GrpIterator group(cache_->FindGrp(name.substr(0, qualifier)));
        if (!group.end()) {
            pkgCache::PkgIterator preferred(group.FindPreferredPkg(true));
            pkgCache::VerIterator preferredVersion(cache_->GetCandidateVersion(preferred));
            if (!preferred.end() && !preferredVersion.end()) {
                package = preferred;
                version = preferredVersion;
            }
        }
    }

    return RegisterPackage(*packages_, package, version);
}

std::vector<PackageHandle> AptBackend::downgradeHandles(PackageHandle handle) {
    std::vector<PackageHandle> handles;
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL)
        return handles;

    for (pkgCache::VerIterator version(entry->package.VersionList()); !version.end(); ++version) {
        if (version == entry->version)
            continue;
        PackageHandle other(RegisterPackage(*packages_, entry->package, version));
        if (other.valid())
            handles.push_back(other);
    }
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
        "Architecture", "Icon", "Depiction", "Homepage", "Website", "Bugs",
        "Support", "Author", "MD5sum", "Multi-Arch", "Name", "Maemo-Display-Name", "Tag",
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
    if (!installed.end()) {
        data.installedVersion = installed.VerStr();
        data.installedIdentity = GetPackageIdentity(entry->package, installed,
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
    data.upgradable = !version.end() && !current.end() && version != current && state.Status != 0;

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
                    data.mode = data.candidateMatchesVersion ? "UPGRADE" : "DOWNGRADE";
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

    for (pkgCache::DepIterator dependency(entry->version.DependsList()); !dependency.end(); ) {
        pkgCache::DepIterator first;
        pkgCache::DepIterator last;
        dependency.GlobOr(first, last);

        RelationData relation;
        relation.relationship = first.DepType();
        for (;;) {
            RelationClauseData clause;
            clause.package = GetPackageRouteName(first.TargetPkg());
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

bool IsSpecialRemoval(const std::string &name) {
    return name.compare(0, 8, "firmware") == 0 ||
        name.compare(0, 4, "gsc.") == 0 ||
        name.compare(0, 3, "cy+") == 0;
}

} // namespace

TransactionData AptBackend::transactionData() {
    TransactionData result;
    if (static_cast<pkgDepCache *>(cache_) == NULL)
        return result;

    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    const std::vector<PackageHandle> handles(packageHandles());
    for (std::vector<PackageHandle>::const_iterator handle(handles.begin()); handle != handles.end(); ++handle) {
        PackageRegistry::Entry *entry(FindPackage(packages_.get(), *handle));
        if (entry == NULL)
            continue;

        PackageIdentity identity(GetPackageIdentity(entry->package, entry->version,
                                                     entry->package.Cache()->NativeArch()));
        const std::string name(identity.valid() ? identity.routingName :
                                                  GetPackageRouteName(entry->package));
        const PackageStateData state(packageState(*handle));

        if (state.broken) {
            TransactionIssueData issue;
            issue.package = name;

            pkgCache::VerIterator planned(cache[entry->package].InstVerIter(cache));
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
                    clause.package = GetPackageRouteName(target);
                    if (const char *required = first.TargetVer()) {
                        clause.comparison = first.CompType();
                        clause.version = required;
                    }

                    if (target.end() || target->ProvidesList != 0)
                        clause.reason = "missing";
                    else {
                        pkgCache::VerIterator targetPlanned(cache[target].InstVerIter(cache));
                        if (!targetPlanned.end()) {
                            clause.reason = "installed";
                            clause.installed = targetPlanned.VerStr();
                        } else if (!cache[target].CandidateVerIter(cache).end())
                            clause.reason = "uninstalled";
                        else if (target->ProvidesList == 0)
                            clause.reason = "uninstallable";
                        else
                            clause.reason = "virtual";
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

        if (state.newInstall)
            result.installs.push_back(name);
        else if (!state.deletePackage && state.reinstall)
            result.reinstalls.push_back(name);
        else if (state.upgrade || (state.downgrade && state.candidateMatchesVersion))
            result.upgrades.push_back(name);
        else if (state.downgrade)
            result.downgrades.push_back(name);
        else if (!state.deletePackage)
            continue;
        else if (IsSpecialRemoval(name)) {
            TransactionIssueData issue;
            TransactionReasonData reason;
            TransactionClauseData clause;
            issue.package.clear();
            reason.relationship = "Conflicts";
            clause.package = name;
            clause.reason = "installed";
            reason.clauses.push_back(clause);
            issue.reasons.push_back(reason);
            result.issues.push_back(issue);
        } else {
            result.removesEssential = result.removesEssential || state.essential;
            result.removes.push_back(name);
        }

        result.substrate = result.substrate || DependsOnSubstrate(entry->version);
        result.substrate = result.substrate || DependsOnSubstrate(entry->package.CurrentVer());
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
    for (pkgCache::PkgIterator package(cache.PkgBegin()); !package.end(); ++package) {
        if (!cache[package].Keep())
            cache.MarkKeep(package, false);
        else if ((cache[package].iFlags & pkgDepCache::ReInstall) != 0)
            cache.SetReInstall(package, false);
    }
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
    cache.MarkKeep(package, false);
    return true;
}

bool AptBackend::installPackage(PackageHandle handle) {
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    pkgCache::PkgIterator package(entry->package);
    pkgCache::VerIterator version(entry->version);
    resolver_->Clear(package);
    resolver_->Protect(package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    cache.SetCandidateVersion(version);
    cache.SetReInstall(package, false);
    cache.MarkInstall(package, false);
    pkgDepCache::StateCache &state(cache[package]);
    if (!state.Install())
        cache.SetReInstall(package, true);
    return true;
}

bool AptBackend::removePackage(PackageHandle handle) {
    PackageRegistry::Entry *entry(FindPackage(packages_.get(), handle));
    if (entry == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    pkgCache::PkgIterator package(entry->package);
    resolver_->Clear(package);
    resolver_->Remove(package);
    resolver_->Protect(package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    cache.SetReInstall(package, false);
    cache.MarkDelete(package, true);
    return true;
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
