#include "Cydia/Package.h"
#include "Cydia/Database.h"
#include "Cydia/DatabaseApt.h"

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/Profile.hpp"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/Section.h"
#include "CyteKit/Localize.h"
#include "CyteKit/RegEx.hpp"
#include "iPhonePrivate.h"

#include <unicode/ustring.h>

#include <apt-pkg/algorithms.h>
#include <apt-pkg/error.h>
#include <apt-pkg/policy.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/strutl.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>

static const CFStringCompareFlags LaxCompareFlags_ = kCFCompareNumerically | kCFCompareWidthInsensitive | kCFCompareForcedOrdering;

static bool IsLetterCharacter_(UniChar character) {
    return [[NSCharacterSet letterCharacterSet] characterIsMember:character];
}

static const char *StripVersion_(const char *version) {
    const char *colon(strchr(version, ':'));
    return colon == NULL ? version : colon + 1;
}

uint32_t PackageChangesRadix(Package *self, void *) {
    union {
        uint32_t key;

        struct {
            uint32_t timestamp : 30;
            uint32_t ignored : 1;
            uint32_t upgradable : 1;
        } bits;
    } value;

    bool upgradable([self upgradableAndEssential:YES]);

    if (upgradable) {
        value.bits.timestamp = 0;
        value.bits.ignored = [self ignored] ? 0 : 1;
        value.bits.upgradable = 1;
    } else {
        value.bits.timestamp = [self seen] >> 2;
        value.bits.ignored = 0;
        value.bits.upgradable = 0;
    }

    return _not(uint32_t) - value.key;
}

CYString &(*PackageName)(Package *self, SEL sel);

uint32_t PackagePrefixRadix(Package *self, void *context) {
    size_t offset(reinterpret_cast<size_t>(context));
    CYString &name(PackageName(self, @selector(cyname)));

    size_t size(name.size());
    if (size == 0)
        return 0;
    char *text(name.data());

    size_t zeros;
    if (!isdigit(text[0]))
        zeros = 0;
    else {
        size_t digits(1);
        while (size != digits && isdigit(text[digits]))
            if (++digits == 4)
                break;
        zeros = 4 - digits;
    }

    uint8_t data[4];

    if (offset == 0 && zeros != 0) {
        memset(data, '0', zeros);
        memcpy(data + zeros, text, 4 - zeros);
    } else {
        /* XXX: there's some danger here if you request a non-zero offset < 4 and it gets zero padded */
        if (size <= offset - zeros)
            return 0;

        text += offset - zeros;
        size -= offset - zeros;

        if (size >= 4)
            memcpy(data, text, 4);
        else {
            memcpy(data, text, size);
            memset(data + size, 0, 4 - size);
        }

        for (size_t i(0); i != 4; ++i)
            if (isalpha(data[i]))
                data[i] |= 0x20;
    }

    if (offset == 0)
        if (data[0] == '@')
            data[0] = 0x7f;
        else
            data[0] = (data[0] & 0x1f) | "\x80\x00\xc0\x40"[data[0] >> 6];

    /* XXX: ntohl may be more honest */
    return OSSwapInt32(*reinterpret_cast<uint32_t *>(data));
}

CFComparisonResult StringNameCompare(CFStringRef lhn, CFStringRef rhn, size_t length) {
    _profile(PackageNameCompare)
        if (lhn == NULL)
            return rhn == NULL ? kCFCompareEqualTo : kCFCompareLessThan;
        else if (rhn == NULL)
            return kCFCompareGreaterThan;

        CFIndex lhsLength(CFStringGetLength(lhn));

        _profile(PackageNameCompare$NumbersLast)
            if (lhsLength != 0 && CFStringGetLength(rhn) != 0) {
                UniChar lhc(CFStringGetCharacterAtIndex(lhn, 0));
                UniChar rhc(CFStringGetCharacterAtIndex(rhn, 0));
                bool lha(IsLetterCharacter_(lhc));
                if (lha != IsLetterCharacter_(rhc))
                    return lha ? kCFCompareLessThan : kCFCompareGreaterThan;
            }
        _end

        _profile(PackageNameCompare$Compare)
            return CFStringCompareWithOptionsAndLocale(lhn, rhn, CFRangeMake(0, length), LaxCompareFlags_, (__bridge CFLocaleRef) (id) CollationLocale_);
        _end
    _end
}

CFComparisonResult StringNameCompare(NSString *lhn, NSString *rhn, size_t length) {
    return StringNameCompare((__bridge CFStringRef) lhn, (__bridge CFStringRef) rhn, length);
}

CFComparisonResult PackageNameCompare(Package *lhs, Package *rhs, void *arg) {
    CYString &lhn(PackageName(lhs, @selector(cyname)));
    NSString *rhn(PackageName(rhs, @selector(cyname)));
    CFStringRef name((CFStringRef) lhn);
    size_t length(name == NULL ? 0 : CFStringGetLength(name));
    return StringNameCompare(name, (__bridge CFStringRef) rhn, length);
}

CFComparisonResult PackageNameCompare_(Package **lhs, Package **rhs, void *arg) {
    return PackageNameCompare(*lhs, *rhs, arg);
}

bool PackageNameOrdering::operator ()(Package *lhs, Package *rhs) const {
    return PackageNameCompare(lhs, rhs, NULL) == kCFCompareLessThan;
}

// The rest of Package's implementation lives in focused categories below.
// Keep the class implementation here for the runtime class symbol while
// allowing those category translation units to provide the remaining methods.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation Package

- (NSString *) description {
    return [NSString stringWithFormat:@"<Package:%@>", static_cast<NSString *>(name_)];
}

- (void) dealloc {
    if (!pooled_)
        delete pool_;
    if (parsed_ != NULL)
        delete parsed_;
}

+ (NSString *) webScriptNameForSelector:(SEL)selector {
    if (false);
    else if (selector == @selector(clear))
        return @"clear";
    else if (selector == @selector(getField:))
        return @"getField";
    else if (selector == @selector(getRecord))
        return @"getRecord";
    else if (selector == @selector(hasTag:))
        return @"hasTag";
    else if (selector == @selector(install))
        return @"install";
    else if (selector == @selector(remove))
        return @"remove";
    else
        return nil;
}

+ (BOOL) isSelectorExcludedFromWebScript:(SEL)selector {
    return [self webScriptNameForSelector:selector] == nil;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"applications",
        @"architecture",
        @"author",
        @"depiction",
        @"essential",
        @"homepage",
        @"icon",
        @"id",
        @"installed",
        @"latest",
        @"longDescription",
        @"longSection",
        @"maintainer",
        @"md5sum",
        @"mode",
        @"name",
        @"purposes",
        @"relations",
        @"section",
        @"selection",
        @"shortDescription",
        @"shortSection",
        @"simpleSection",
        @"size",
        @"source",
        @"state",
        @"support",
        @"tags",
        @"upgraded",
        @"warnings",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSArray *) relations {
@synchronized (database_) {
    NSMutableArray *relations([NSMutableArray arrayWithCapacity:16]);
    for (pkgCache::DepIterator dep(version_.DependsList()); !dep.end(); ++dep)
        [relations addObject:[[CydiaRelation alloc] initWithIterator:dep]];
    return relations;
} }

- (NSString *) architecture {
    [self parse];
@synchronized (database_) {
    return parsed_->architecture_.empty() ? [NSNull null] : (id) parsed_->architecture_;
} }

- (NSString *) getField:(NSString *)name {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser &parser([database_ records]->Lookup(file_));

    CydiaAPT::PackageRecord record(&parser);
    std::string value(record.Field([name UTF8String]));
    if (value.empty())
        return (NSString *) [NSNull null];

    return [NSString stringWithString:CFBridgingRelease(CYStringCreate(value))];
} }

- (NSString *) getRecord {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser &parser([database_ records]->Lookup(file_));

    const char *start, *end;
    parser.GetRec(start, end);

    return [NSString stringWithString:CFBridgingRelease(CYStringCreate(start, end - start))];
} }

- (void) parse {
    if (parsed_ != NULL)
        return;
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return;

    ParsedPackage *parsed(new ParsedPackage);
    parsed_ = parsed;

    _profile(Package$parse)
        pkgRecords::Parser *parser;

        _profile(Package$parse$Lookup)
            parser = &[database_ records]->Lookup(file_);
        _end

        CYString bugs;
        CYString website;

        _profile(Package$parse$Find)
            CydiaAPT::PackageRecord record(parser);
            struct {
                const char *name_;
                CYString *value_;
            } names[] = {
                {"architecture", &parsed->architecture_},
                {"icon", &parsed->icon_},
                {"depiction", &parsed->depiction_},
                {"homepage", &parsed->homepage_},
                {"website", &website},
                {"bugs", &bugs},
                {"support", &parsed->support_},
                {"author", &parsed->author_},
                {"md5sum", &parsed->md5sum_},
            };

            for (size_t i(0); i != sizeof(names) / sizeof(names[0]); ++i) {
                std::string field(record.Field(names[i].name_));
                if (!field.empty()) {
                    CYString &value(*names[i].value_);
                    _profile(Package$parse$Value)
                        value.set(pool_, field);
                    _end
                }
            }
        _end

        _profile(Package$parse$Tagline)
            parsed->tagline_.set(pool_, parser->ShortDesc());
        _end

        _profile(Package$parse$Retain)
            if (parsed->homepage_.empty())
                parsed->homepage_ = website;
            if (parsed->homepage_ == parsed->depiction_)
                parsed->homepage_.clear();
            if (parsed->support_.empty())
                parsed->support_ = bugs;
        _end
    _end
} }

- (instancetype) initWithVersion:(pkgCache::VerIterator)version withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database {
    if ((self = [super init]) != nil) {
    _profile(Package$initWithVersion)
        if (pool == NULL)
            pool_ = new CYPool();
        else {
            pool_ = pool;
            pooled_ = true;
        }

        database_ = database;
        era_ = [database era];

        version_ = version;

        pkgCache::PkgIterator iterator(version_.ParentPkg());
        iterator_ = iterator;

        _profile(Package$initWithVersion$Version)
            file_ = version_.FileList();
        _end

        _profile(Package$initWithVersion$Cache)
            pkgRecords::Parser &parser([database records]->Lookup(file_));
            CydiaAPT::PackageRecord record(&parser);
            name_.set(NULL, record.DisplayName());

            latest_.set(NULL, StripVersion_(version_.VerStr()));

            pkgCache::VerIterator current(iterator.CurrentVer());
            if (!current.end())
                installed_.set(NULL, StripVersion_(current.VerStr()));
        _end

        _profile(Package$initWithVersion$Transliterate) do {
            if (CollationTransl_ == NULL)
                break;
            if (name_.empty())
                break;

            _profile(Package$initWithVersion$Transliterate$utf8)
            const uint8_t *data(reinterpret_cast<const uint8_t *>(name_.data()));
            for (size_t i(0), e(name_.size()); i != e; ++i)
                if (data[i] >= 0x80)
                    goto extended;
            break; extended:;
            _end

            UErrorCode code(U_ZERO_ERROR);
            int32_t length;

            _profile(Package$initWithVersion$Transliterate$u_strFromUTF8WithSub)
            CollationString_.resize(name_.size());
            u_strFromUTF8WithSub(&CollationString_[0], CollationString_.size(), &length, name_.data(), name_.size(), 0xfffd, NULL, &code);
            if (!U_SUCCESS(code))
                break;
            CollationString_.resize(length);
            _end

            _profile(Package$initWithVersion$Transliterate$utrans_trans)
            length = CollationString_.size();
            utrans_trans(CollationTransl_, reinterpret_cast<UReplaceable *>(&CollationString_), &CollationUCalls_, 0, &length, &code);
            if (!U_SUCCESS(code))
                break;
            _assert(CollationString_.size() == length);
            _end

            _profile(Package$initWithVersion$Transliterate$u_strToUTF8WithSub$preflight)
            u_strToUTF8WithSub(NULL, 0, &length, CollationString_.data(), CollationString_.size(), 0xfffd, NULL, &code);
            if (code == U_BUFFER_OVERFLOW_ERROR)
                code = U_ZERO_ERROR;
            else if (!U_SUCCESS(code))
                break;
            _end

            char *transform;
            _profile(Package$initWithVersion$Transliterate$apr_palloc)
            transform = pool_->malloc<char>(length);
            _end
            _profile(Package$initWithVersion$Transliterate$u_strToUTF8WithSub$transform)
            u_strToUTF8WithSub(transform, length, NULL, CollationString_.data(), CollationString_.size(), 0xfffd, NULL, &code);
            if (!U_SUCCESS(code))
                break;
            _end

            transform_.set(NULL, transform, length);
        } while (false); _end

        _profile(Package$initWithVersion$Tags)
            pkgRecords::Parser &tagParser([database records]->Lookup(file_));
            CydiaAPT::PackageRecord tagRecord(&tagParser);
            std::vector<std::string> aptTags(tagRecord.Tags());
            if (!aptTags.empty()) {
                tags_ = [NSMutableArray arrayWithCapacity:8];

                for (std::vector<std::string>::const_iterator tag(aptTags.begin()); tag != aptTags.end(); ++tag) {
                    const char *name(tag->c_str());
                    NSString *string(CFBridgingRelease(CYStringCreate(name)));
                    if (string == nil)
                        continue;

                    [tags_ addObject:string];

                    if (role_ == 0 && strncmp(name, "role::", 6) == 0 /*&& strcmp(name, "role::leaper") != 0*/) {
                        if (strcmp(name + 6, "enduser") == 0)
                            role_ = 1;
                        else if (strcmp(name + 6, "hacker") == 0)
                            role_ = 2;
                        else if (strcmp(name + 6, "developer") == 0)
                            role_ = 3;
                        else if (strcmp(name + 6, "cydia") == 0)
                            role_ = 7;
                        else
                            role_ = 4;
                    }

                    if (strncmp(name, "cydia::", 7) == 0) {
                        if (strcmp(name + 7, "essential") == 0)
                            essential_ = true;
                        else if (strcmp(name + 7, "obsolete") == 0)
                            obsolete_ = true;
                    }
                }
            }
        _end

        _profile(Package$initWithVersion$Metadata)
            const char *mixed(iterator.Name());
            size_t size(strlen(mixed));
            char lower[size + 1];

            for (size_t i(0); i != size; ++i)
                lower[i] = mixed[i] | 0x20;
            lower[size] = '\0';

            if (!installed_.empty()) {
                const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
                const std::string infoPath(paths.DpkgInfoFile(lower, ".list"));
                if (!infoPath.empty()) {
                    struct stat info;
                    if (stat(infoPath.c_str(), &info) != -1)
                        upgraded_ = info.st_birthtime;
                }
            }

            PackageValue *metadata(PackageFind(lower, size));
            if (metadata == NULL)
                return nil;

            metadata_ = metadata;

            id_.set(NULL, metadata->name_, size);

            const char *latest(version_.VerStr());
            size_t length(strlen(latest));

            uint16_t vhash(hashlittle(latest, length));

            size_t capped(std::min<size_t>(8, length));
            latest = latest + length - capped;

            if (metadata->first_ == 0)
                metadata->first_ = now_;

            if (metadata->vhash_ != vhash || strncmp(metadata->version_, latest, sizeof(metadata->version_)) != 0) {
                strncpy(metadata->version_, latest, sizeof(metadata->version_));
                metadata->vhash_ = vhash;
                metadata->last_ = now_;
            } else if (metadata->last_ == 0)
                metadata->last_ = metadata->first_;
        _end

        _profile(Package$initWithVersion$Section)
            section_ = version_.Section();
        _end

        _profile(Package$initWithVersion$Flags)
            essential_ |= ((iterator->Flags & pkgCache::Flag::Essential) == 0 ? NO : YES);
            ignored_ = iterator->SelectedState == pkgCache::State::Hold;
        _end

#if CYDIA_APT_MODERN
        _profile(Package$initWithVersion$Priority)
            // ignore "essential" tags from non-pinned repos
            if (essential_ && [database cache].Policy->GetPriority(version, true) == 500) {
                essential_ = NO;
            }
        _end
#endif

    _end } return self;
}

+ (instancetype) newPackageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database {
    pkgCache::VerIterator version;

    _profile(Package$packageWithIterator$GetCandidateVer)
#if CYDIA_APT_MODERN
        version = [database cache]->GetCandidateVersion(iterator);
#else
        version = [database policy]->GetCandidateVer(iterator);
#endif
    _end

    if (version.end())
        return nil;

    Package *package;

    _profile(Package$packageWithIterator$Allocate)
        package = [Package allocWithZone:zone];
    _end

    _profile(Package$packageWithIterator$Initialize)
        package = [package
            initWithVersion:version
            withZone:zone
            inPool:pool
            database:database
        ];
    _end

    return package;
}

// XXX: just in case a Cydia extension is using this (I bet this is unlikely, though, due to CYPool?)
+ (instancetype) packageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database {
    return [self newPackageWithIterator:iterator withZone:zone inPool:pool database:database];
}

- (pkgCache::PkgIterator) iterator {
    return iterator_;
}

@end
#pragma clang diagnostic pop
/* }}} */
