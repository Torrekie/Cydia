/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT API compatibility boundary owned by Cydia.
 */

#include "Cydia/AptCompatibility.hpp"

#include <apt-pkg/algorithms.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/depcache.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/install-progress.h>
#include <apt-pkg/macros.h>
#include <apt-pkg/packagemanager.h>
#include <apt-pkg/pkgcache.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/upgrade.h>

#if !defined(APT_PKG_ABI) || APT_PKG_ABI < 500
#error "Cydia's APT compatibility layer requires libapt-pkg ABI 5.0 or newer"
#endif

#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT {

namespace {

pkgRecords::Parser *ParserFrom(void *parser) {
    return static_cast<pkgRecords::Parser *>(parser);
}

void TrimAsciiWhitespace(std::string &value) {
    std::string::size_type first(value.find_first_not_of(" \t\r\n"));
    if (first == std::string::npos) {
        value.clear();
        return;
    }

    std::string::size_type last(value.find_last_not_of(" \t\r\n"));
    value.assign(value, first, last - first + 1);
}

} // namespace

PackageRecord::PackageRecord(void *parser) : parser_(parser) {
}

std::string PackageRecord::Field(const char *name) const {
    if (parser_ == NULL || name == NULL || name[0] == '\0')
        return std::string();
#if APT_PKG_MAJOR < 7
    const char *start;
    const char *end;
    if (!ParserFrom(parser_)->Find(name, start, end))
        return std::string();
    return std::string(start, end);
#else
    return ParserFrom(parser_)->RecordField(name);
#endif
}

std::string PackageRecord::DisplayName() const {
    if (parser_ == NULL)
        return std::string();
    std::string display(ParserFrom(parser_)->RecordField("Name"));
    if (display.empty())
        display = ParserFrom(parser_)->RecordField("Maemo-Display-Name");
    return display;
}

std::vector<std::string> PackageRecord::Tags() const {
    std::vector<std::string> tags;
    std::string field(parser_ == NULL ? std::string() : ParserFrom(parser_)->RecordField("Tag"));
    std::string::size_type begin(0);

    while (begin <= field.size()) {
        std::string::size_type comma(field.find(',', begin));
        std::string tag(field.substr(begin, comma == std::string::npos ? comma : comma - begin));
        TrimAsciiWhitespace(tag);
        if (!tag.empty())
            tags.push_back(tag);
        if (comma == std::string::npos)
            break;
        begin = comma + 1;
    }

    return tags;
}

std::string Fingerprint(const void *data, std::size_t size) {
    if (data == NULL && size != 0)
        return std::string();

    unsigned char empty(0);
    const unsigned char *bytes(data == NULL ? &empty : static_cast<const unsigned char *>(data));
    Hashes hashes(Hashes::SHA256SUM);
    if (!hashes.Add(bytes, size))
        return std::string();

    HashStringList values(hashes.GetHashStringList());
    const HashString *value(values.find("SHA256"));
    return value == NULL ? std::string() : value->HashValue();
}

PackageManagerResult RunPackageManager(pkgPackageManager &manager, int statusFd) {
    APT::Progress::PackageManagerProgressFd progress(statusFd);

    switch (manager.DoInstall(&progress)) {
        case pkgPackageManager::Failed:
            return PackageManagerResult::Failed;
        case pkgPackageManager::Incomplete:
            return PackageManagerResult::Incomplete;
        case pkgPackageManager::Completed:
            return PackageManagerResult::Completed;
    }

    return PackageManagerResult::Failed;
}

namespace {

class ArchiveCleaner : public pkgArchiveCleaner {
  protected:
#if APT_PKG_MAJOR >= 6
    virtual void Erase(int const directoryFd, char const * const file,
                       std::string const &, std::string const &,
                       struct stat const &) {
        if (directoryFd >= 0)
            (void) unlinkat(directoryFd, file, 0);
        else
            (void) unlink(file);
    }
#else
    virtual void Erase(const char *file, std::string, std::string, struct stat &) {
        (void) unlink(file);
    }
#endif
};

} // namespace

bool CleanArchives(const std::string &directory, pkgCache &cache) {
    ArchiveCleaner cleaner;
    return cleaner.Go(directory, cache);
}

bool MinimizeUpgrade(pkgDepCache &cache) {
    return pkgMinimizeUpgrade(cache);
}

bool PrepareDistUpgrade(pkgDepCache &cache) {
    return APT::Upgrade::Upgrade(cache, APT::Upgrade::ALLOW_EVERYTHING);
}

bool ResolveDependencies(pkgProblemResolver &resolver) {
    // InstallProtect was already a deprecated no-op in the oldest supported
    // ABI 5 baseline and was removed from newer libapt-pkg releases.
    return resolver.Resolve(true);
}

} // namespace CydiaAPT
