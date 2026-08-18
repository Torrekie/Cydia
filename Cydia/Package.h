#ifndef Cydia_Package_H
#define Cydia_Package_H

#include "Cydia/Collation.hpp"
#include "Cydia/CYString.hpp"
#include "Cydia/MIMEAddress.h"
#include "Cydia/PackageMetadata.hpp"
#include "Cydia/Relations.h"
#include "Cydia/Source.h"
#include "Menes/ObjectHandle.h"

#include <UIKit/UIKit.h>

#include <apt-pkg/cachefile.h>
#include <apt-pkg/depcache.h>
#include <apt-pkg/pkgcache.h>

#include <cstddef>
#include <ctime>

// The supported apt64 input exposes the modern candidate/version APIs.
#define CYDIA_APT_MODERN 1

@class Database;

extern const char *common_arch;
extern NSString *App_;
extern time_t now_;

NSString *LocalizeSection(NSString *section);
NSString *Simplify(NSString *title);
bool isSectionVisible(NSString *section);

struct ParsedPackage {
    CYString md5sum_;
    CYString tagline_;

    CYString architecture_;
    CYString icon_;

    CYString depiction_;
    CYString homepage_;
    CYString author_;

    CYString support_;
};

@interface Package : NSObject {
    uint32_t era_ : 25;
    @public uint32_t role_ : 3;
    uint32_t essential_ : 1;
    uint32_t obsolete_ : 1;
    uint32_t ignored_ : 1;
    uint32_t pooled_ : 1;

    CYPool *pool_;
    uint32_t rank_;
    __weak Database *database_;

    pkgCache::VerIterator version_;
    pkgCache::PkgIterator iterator_;
    pkgCache::VerFileIterator file_;

    CYString id_;
    CYString name_;
    CYString transform_;
    CYString latest_;
    CYString installed_;
    time_t upgraded_;

    const char *section_;
    __strong NSString *section$_;
    _H<Source> source_;
    PackageValue *metadata_;
    ParsedPackage *parsed_;
    _H<NSMutableArray> tags_;
}

- (instancetype) initWithVersion:(pkgCache::VerIterator)version withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database;
+ (instancetype) newPackageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database;
+ (instancetype) packageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database;

- (pkgCache::PkgIterator) iterator;
- (void) parse;
- (NSArray *) relations;
- (NSString *) architecture;
- (NSString *) getField:(NSString *)name;
- (NSString *) getRecord;
- (NSArray *) downgrades;

- (NSString *) section;
- (NSString *) simpleSection;
- (NSString *) longSection;
- (NSString *) shortSection;
- (NSString *) uri;
- (MIMEAddress *) maintainer;
- (size_t) size;
- (NSString *) md5sum;
- (NSString *) longDescription;
- (NSString *) shortDescription;
- (unichar) index;
- (PackageValue *) metadata;
- (time_t) seen;
- (bool) subscribed;
- (bool) setSubscribed:(bool)subscribed;
- (BOOL) ignored;
- (NSString *) latest;
- (NSString *) installed;
- (BOOL) uninstalled;
- (BOOL) upgradableAndEssential:(BOOL)essential;
- (BOOL) essential;
- (BOOL) broken;
- (BOOL) unfiltered;
- (BOOL) visible;
- (BOOL) half;
- (BOOL) halfConfigured;
- (BOOL) halfInstalled;
- (BOOL) hasMode;
- (NSString *) mode;
- (NSString *) id;
- (NSString *) name;
- (UIImage *) icon;
- (NSString *) homepage;
- (NSString *) depiction;
- (MIMEAddress *) author;
- (NSString *) support;
- (NSArray *) files;
- (NSString *) state;
- (NSString *) selection;
- (NSArray *) warnings;
- (NSArray *) applications;
- (Source *) source;
- (time_t) upgraded;
- (uint32_t) recent;
- (uint32_t) rank;
- (BOOL) matches:(NSArray *)query;
- (NSArray *) tags;
- (BOOL) hasTag:(NSString *)tag;
- (NSString *) primaryPurpose;
- (NSArray *) purposes;
- (bool) isCommercial;
- (void) setIndex:(size_t)index;
- (CYString &) cyname;
- (uint32_t) compareBySection:(NSArray *)sections;
- (void) clear;
- (void) install;
- (void) remove;

@end

extern CYString &(*PackageName)(Package *self, SEL sel);
uint32_t PackageChangesRadix(Package *self, void *context);
uint32_t PackagePrefixRadix(Package *self, void *context);
CFComparisonResult StringNameCompare(CFStringRef lhs, CFStringRef rhs, size_t length);
CFComparisonResult StringNameCompare(NSString *lhs, NSString *rhs, size_t length);
CFComparisonResult PackageNameCompare(Package *lhs, Package *rhs, void *context);
CFComparisonResult PackageNameCompare_(Package **lhs, Package **rhs, void *context);

struct PackageNameOrdering {
    bool operator ()(Package *lhs, Package *rhs) const;
};

#endif//Cydia_Package_H
