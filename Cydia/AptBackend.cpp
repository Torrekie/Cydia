/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 */

#include "Cydia/AptBackend.hpp"

#include <apt-pkg/policy.h>

#include <cstring>

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

namespace {

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
    list_(NULL)
{
}

AptBackend::~AptBackend() {
    reset();
}

void AptBackend::reset() {
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

CydiaAPT::PackageRecordData AptBackend::recordData(const void *verFileIterator) {
    CydiaAPT::PackageRecordData data;
    if (records_ == NULL || verFileIterator == NULL)
        return data;

    const pkgCache::VerFileIterator &file(
        *static_cast<const pkgCache::VerFileIterator *>(verFileIterator));
    pkgRecords::Parser &parser(records_->Lookup(file));
    ParserView record(parser);

    static const char * const fieldNames[] = {
        "Architecture", "Icon", "Depiction", "Homepage", "Website", "Bugs",
        "Support", "Author", "MD5sum", "Name", "Maemo-Display-Name", "Tag",
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

CydiaAPT::PackageStateData AptBackend::packageState(const void *pkgIterator, const void *verIterator) {
    CydiaAPT::PackageStateData data;
    if (pkgIterator == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return data;

    const pkgCache::PkgIterator &sourcePackage(
        *static_cast<const pkgCache::PkgIterator *>(pkgIterator));
    pkgCache::PkgIterator package(sourcePackage);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    pkgDepCache::StateCache &state(cache[package]);

    if (const char *name = CurrentStateName(package->CurrentState))
        data.state = name;
    if (const char *name = SelectionName(package->SelectedState))
        data.selection = name;

    data.essential = (package->Flags & pkgCache::Flag::Essential) != 0;
    data.ignored = package->SelectedState == pkgCache::State::Hold;
    data.broken = state.InstBroken();
    data.hasMode = state.Mode != pkgDepCache::ModeKeep;
    data.half = package->CurrentState == pkgCache::State::HalfConfigured ||
        package->CurrentState == pkgCache::State::HalfInstalled;
    data.halfConfigured = package->CurrentState == pkgCache::State::HalfConfigured;
    data.halfInstalled = package->CurrentState == pkgCache::State::HalfInstalled;

    pkgCache::VerIterator version;
    if (verIterator != NULL)
        version = *static_cast<const pkgCache::VerIterator *>(verIterator);
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

bool AptBackend::clearPackage(const void *pkgIterator) {
    if (pkgIterator == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    const pkgCache::PkgIterator &source(*static_cast<const pkgCache::PkgIterator *>(pkgIterator));
    pkgCache::PkgIterator package(source);
    resolver_->Clear(package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    cache.SetReInstall(package, false);
    cache.MarkKeep(package, false);
    return true;
}

bool AptBackend::installPackage(const void *pkgIterator, const void *verIterator) {
    if (pkgIterator == NULL || verIterator == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    const pkgCache::PkgIterator &sourcePackage(*static_cast<const pkgCache::PkgIterator *>(pkgIterator));
    const pkgCache::VerIterator &sourceVersion(*static_cast<const pkgCache::VerIterator *>(verIterator));
    pkgCache::PkgIterator package(sourcePackage);
    pkgCache::VerIterator version(sourceVersion);
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

bool AptBackend::removePackage(const void *pkgIterator) {
    if (pkgIterator == NULL || resolver_ == NULL || static_cast<pkgDepCache *>(cache_) == NULL)
        return false;
    const pkgCache::PkgIterator &source(*static_cast<const pkgCache::PkgIterator *>(pkgIterator));
    pkgCache::PkgIterator package(source);
    resolver_->Clear(package);
    resolver_->Remove(package);
    resolver_->Protect(package);
    pkgDepCache &cache(static_cast<pkgDepCache &>(cache_));
    cache.SetReInstall(package, false);
    cache.MarkDelete(package, true);
    return true;
}

pkgSourceList *AptBackend::createSourceList() {
    delete list_;
    list_ = new pkgSourceList();
    return list_;
}

pkgAcquire *AptBackend::createFetcher() {
    delete fetcher_;
    fetcher_ = new pkgAcquire(status_);
    return fetcher_;
}

pkgCacheFile &AptBackend::cache() {
    return cache_;
}

pkgDepCache::Policy *AptBackend::policy() const {
    return policy_;
}

pkgRecords *AptBackend::records() const {
    return records_;
}

pkgProblemResolver *&AptBackend::resolver() {
    return resolver_;
}

pkgAcquire *AptBackend::fetcher() const {
    return fetcher_;
}

FileFd *&AptBackend::lock() {
    return lock_;
}

std::unique_ptr<pkgPackageManager> &AptBackend::manager() {
    return manager_;
}

pkgSourceList *AptBackend::list() const {
    return list_;
}

} // namespace CydiaAPT
