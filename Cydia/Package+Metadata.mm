#include "Cydia/Package.h"
#include "Cydia/Database.h"
#include "Cydia/Source.h"
#include "Cydia/Profile.hpp"
#include "CyteKit/Localize.h"
#include "iPhonePrivate.h"

#include <unicode/uchar.h>

#include <cctype>
#include <cstring>
#include <limits>
#include <string>

static bool PackageIsLetterCharacter_(UniChar character) {
    return [[NSCharacterSet letterCharacterSet] characterIsMember:character];
}

@interface Package (Metadata)
@end

@implementation Package (Metadata)

- (NSArray *) downgrades {
    NSMutableArray *versions([NSMutableArray arrayWithCapacity:4]);

    std::vector<CydiaAPT::PackageHandle> handles([database_ packageDowngrades:handle_]);
    for (std::vector<CydiaAPT::PackageHandle>::const_iterator handle(handles.begin()); handle != handles.end(); ++handle) {
        Package *package([[Package allocWithZone:NULL] initWithHandle:*handle withZone:NULL inPool:NULL database:database_]);
        if ([package source] == nil)
            continue;
        [versions addObject:package];
    }

    return versions;
}

- (NSString *) section {
    if (section$_ == nil) {
        if (section_.empty())
            return nil;

        _profile(Package$section$mappedSectionForPointer)
            section$_ = [database_ mappedSectionForPointer:section_.data()];
        _end
    } return section$_;
}

- (NSString *) simpleSection {
    if (NSString *section = [self section])
        return Simplify(section);
    else
        return nil;
}

- (NSString *) longSection {
    if (NSString *section = [self section])
        return LocalizeSection(section);
    else
        return nil;
}

- (NSString *) shortSection {
    return [[NSBundle mainBundle] localizedStringForKey:[self simpleSection] value:nil table:@"Sections"];
}

- (NSString *) uri {
    return nil;
}

- (MIMEAddress *) maintainer {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return nil;

    CydiaAPT::PackageRecordData record([database_ packageRecord:handle_]);
    const std::string &maintainer(record.maintainer);
    return maintainer.empty() ? nil : [MIMEAddress addressWithString:[NSString stringWithUTF8String:maintainer.c_str()]];
} }

- (NSString *) md5sum {
    return parsed_ == NULL ? nil : (id) parsed_->md5sum_;
}

- (size_t) size {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return 0;

    return installedSize_;
} }

- (NSString *) longDescription {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return nil;

    CydiaAPT::PackageRecordData record([database_ packageRecord:handle_]);
    NSString *description([NSString stringWithUTF8String:record.longDescription.c_str()]);

    NSArray *lines = [description componentsSeparatedByString:@"\n"];
    NSMutableArray *trimmed = [NSMutableArray arrayWithCapacity:([lines count] - 1)];
    if ([lines count] < 2)
        return nil;

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
    for (size_t i(1), e([lines count]); i != e; ++i) {
        NSString *trim = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:whitespace];
        [trimmed addObject:trim];
    }

    return [trimmed componentsJoinedByString:@"\n"];
} }

- (NSString *) shortDescription {
    if (parsed_ != NULL)
        return static_cast<NSString *>(parsed_->tagline_);

@synchronized (database_) {
    CydiaAPT::PackageRecordData record([database_ packageRecord:handle_]);
    std::string value(record.shortDescription);
    if (value.empty())
        return nil;
    if (value.size() > 200)
        value.resize(200);
    return CFBridgingRelease(CYStringCreate(value));
} }

- (unichar) index {
    _profile(Package$index)
        CFStringRef name((__bridge CFStringRef) [self name]);
        if (CFStringGetLength(name) == 0)
            return '#';
        UniChar character(CFStringGetCharacterAtIndex(name, 0));
        if (!PackageIsLetterCharacter_(character))
            return '#';
        return u_toupper(character);
    _end
}

- (PackageValue *) metadata {
    return metadata_;
}

- (time_t) seen {
    PackageValue *metadata([self metadata]);
    return metadata == NULL ? 0 : metadata->subscribed_ ? metadata->last_ : metadata->first_;
}

- (bool) subscribed {
    PackageValue *metadata([self metadata]);
    return metadata != NULL && metadata->subscribed_;
}

- (bool) setSubscribed:(bool)subscribed {
    PackageValue *metadata([self metadata]);
    if (metadata == NULL)
        return false;
    if (metadata->subscribed_ == subscribed)
        return false;
    metadata->subscribed_ = subscribed;
    return true;
}

- (BOOL) ignored {
    return ignored_;
}

- (NSString *) latest {
    return latest_;
}

- (NSString *) installed {
    return installed_;
}

- (BOOL) uninstalled {
    return installed_.empty();
}

- (BOOL) upgradableAndEssential:(BOOL)essential {
    _profile(Package$upgradableAndEssential)
        CydiaAPT::PackageStateData state([database_ packageState:handle_]);
        if (!state.hasCurrent) {
            if (essential && essential_) {
                const char *architecture(selectedArchitecture_);
                return architecture != NULL && CydiaAPT::IsNativeOrArchitectureIndependent(
                    architecture, common_arch == NULL ? std::string() : common_arch);
            } else {
                return false;
            }
        } else {
            return state.upgradable;
        }
    _end
}

- (BOOL) essential {
    return essential_;
}

- (BOOL) broken {
    @synchronized (database_) {
        if ([database_ era] != era_ || !handle_.valid())
            return NO;
        return [database_ packageState:handle_].broken;
    }
}

- (BOOL) unfiltered {
    _profile(Package$unfiltered$obsolete)
        if (_unlikely(obsolete_))
            return false;
    _end

    _profile(Package$unfiltered$role)
        if (_unlikely(role_ > 3))
            return false;
    _end

    return true;
}

- (BOOL) visible {
    if (![self unfiltered])
        return false;

    NSString *section;

    _profile(Package$visible$section)
        section = [self section];
    _end

    _profile(Package$visible$isSectionVisible)
        if (!isSectionVisible(section))
            return false;
    _end

    return true;
}

- (BOOL) half {
    return [database_ packageState:handle_].half;
}

- (BOOL) halfConfigured {
    return [database_ packageState:handle_].halfConfigured;
}

- (BOOL) halfInstalled {
    return [database_ packageState:handle_].halfInstalled;
}

- (BOOL) hasMode {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return NO;

    return [database_ packageState:handle_].hasMode;
} }

- (NSString *) mode {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return nil;

    CydiaAPT::PackageStateData state([database_ packageState:handle_]);
    return state.mode.empty() ? nil : [NSString stringWithUTF8String:state.mode.c_str()];
} }

- (NSString *) id {
    return id_;
}

- (NSString *) baseId {
    return baseId_;
}

- (NSString *) aptId {
    return aptId_;
}

- (NSString *) dpkgId {
    return installedDpkgId_.empty() ? (NSString *) dpkgId_ : (NSString *) installedDpkgId_;
}

- (NSString *) multiArch {
    switch (multiArch_) {
        case CydiaAPT::MultiArchMode::Same:
            return @"same";
        case CydiaAPT::MultiArchMode::Foreign:
            return @"foreign";
        case CydiaAPT::MultiArchMode::Allowed:
            return @"allowed";
        case CydiaAPT::MultiArchMode::None:
            return @"no";
    }

    return @"no";
}

- (NSString *) name {
    return name_.empty() ? id_ : name_;
}

- (UIImage *) icon {
    NSString *section = [self simpleSection];

    UIImage *icon(nil);
    if (parsed_ != NULL)
        if (NSString *href = parsed_->icon_)
            if ([href hasPrefix:@"file:///"])
                icon = [UIImage imageAtPath:[[href substringFromIndex:7] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    if (icon == nil) if (section != nil)
        icon = [UIImage imageAtPath:[NSString stringWithFormat:@"%@/Sections/%@.png", App_, [section stringByReplacingOccurrencesOfString:@" " withString:@"_"]]];
    if (icon == nil) if (Source *source = [self source]) if (NSString *dicon = [source defaultIcon])
        if ([dicon hasPrefix:@"file:///"])
            icon = [UIImage imageAtPath:[[dicon substringFromIndex:7] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    if (icon == nil)
        icon = [UIImage imageNamed:@"unknown.png"];
    return icon;
}

- (NSString *) homepage {
    return parsed_ == NULL ? nil : static_cast<NSString *>(parsed_->homepage_);
}

- (NSString *) depiction {
    return parsed_ != NULL && !parsed_->depiction_.empty() ? parsed_->depiction_ : [[self source] depictionForPackage:baseId_];
}

- (MIMEAddress *) author {
    return parsed_ == NULL || parsed_->author_.empty() ? nil : [MIMEAddress addressWithString:parsed_->author_];
}

- (NSString *) support {
    return parsed_ != NULL && !parsed_->support_.empty() ? parsed_->support_ : [[self source] supportForPackage:baseId_];
}


- (Source *) source {
    if (source_ == nil) {
        @synchronized (database_) {
            if ([database_ era] != era_ || !handle_.valid() || !hasSourceFile_)
                source_ = (Source *) [NSNull null];
            else
                source_ = [database_ sourceWithFileID:sourceFileID_] ?: (Source *) [NSNull null];
        }
    }

    return source_ == (Source *) [NSNull null] ? nil : source_;
}

- (time_t) upgraded {
    return upgraded_;
}

- (uint32_t) recent {
    return std::numeric_limits<uint32_t>::max() - upgraded_;
}

@end
