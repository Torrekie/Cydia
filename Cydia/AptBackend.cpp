/* Cydia - iPhone UIKit Front-End for Debian APT
 * APT lifetime and transaction ownership boundary.
 */

#include "Cydia/AptBackend.hpp"

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
