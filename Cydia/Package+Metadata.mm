#include "Cydia/Package.h"
#include "Cydia/Database.h"
#include "Cydia/Profile.hpp"
#include "CyteKit/Localize.h"
#include "iPhonePrivate.h"

#include <unicode/uchar.h>

#include <apt-pkg/pkgrecords.h>

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

    for (auto version(iterator_.VersionList()); !version.end(); ++version) {
        if (version == version_)
            continue;
        Package *package([[Package allocWithZone:NULL] initWithVersion:version withZone:NULL inPool:NULL database:database_]);
        if ([package source] == nil)
            continue;
        [versions addObject:package];
    }

    return versions;
}

- (NSString *) section {
    if (section$_ == nil) {
        if (section_ == NULL)
            return nil;

        _profile(Package$section$mappedSectionForPointer)
            section$_ = [database_ mappedSectionForPointer:section_];
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
#if 0
    pkgIndexFile *index;
    pkgCache::PkgFileIterator file(file_.File());
    if (![database_ list].FindIndex(file, index))
        return nil;
    return [NSString stringWithUTF8String:iterator_->Path];
    //return [NSString stringWithUTF8String:file.Site()];
    //return [NSString stringWithUTF8String:index->ArchiveURI(file.FileName()).c_str()];
#endif
}

- (MIMEAddress *) maintainer {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser *parser = &[database_ records]->Lookup(file_);
    const std::string &maintainer(parser->Maintainer());
    return maintainer.empty() ? nil : [MIMEAddress addressWithString:[NSString stringWithUTF8String:maintainer.c_str()]];
} }

- (NSString *) md5sum {
    return parsed_ == NULL ? nil : (id) parsed_->md5sum_;
}

- (size_t) size {
@synchronized (database_) {
    if ([database_ era] != era_ || version_.end())
        return 0;

    return version_->InstalledSize;
} }

- (NSString *) longDescription {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser *parser = &[database_ records]->Lookup(file_);
    NSString *description([NSString stringWithUTF8String:parser->LongDesc().c_str()]);

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
    pkgRecords::Parser &parser([database_ records]->Lookup(file_));
    std::string value(parser.ShortDesc());
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
        pkgCache::VerIterator current(iterator_.CurrentVer());
        if (current.end()) {
            if (essential && essential_) {
                return (strcmp(version_.Arch(), common_arch)==0);
            } else {
                return false;
            }
        } else {
            return (version_ != current && [database_ cache][iterator_].Status != 0);
        }
    _end
}

- (BOOL) essential {
    return essential_;
}

- (BOOL) broken {
    return [database_ cache][iterator_].InstBroken();
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
    unsigned char current(iterator_->CurrentState);
    return current == pkgCache::State::HalfConfigured || current == pkgCache::State::HalfInstalled;
}

- (BOOL) halfConfigured {
    return iterator_->CurrentState == pkgCache::State::HalfConfigured;
}

- (BOOL) halfInstalled {
    return iterator_->CurrentState == pkgCache::State::HalfInstalled;
}

- (BOOL) hasMode {
@synchronized (database_) {
    if ([database_ era] != era_ || iterator_.end())
        return NO;

    pkgDepCache::StateCache &state([database_ cache][iterator_]);
    return state.Mode != pkgDepCache::ModeKeep;
} }

- (NSString *) mode {
@synchronized (database_) {
    if ([database_ era] != era_ || iterator_.end())
        return nil;

    pkgDepCache::StateCache &state([database_ cache][iterator_]);

    switch (state.Mode) {
        case pkgDepCache::ModeDelete:
            if ((state.iFlags & pkgDepCache::Purge) != 0)
                return @"PURGE";
            else
                return @"REMOVE";
        case pkgDepCache::ModeKeep:
            if ((state.iFlags & pkgDepCache::ReInstall) != 0)
                return @"REINSTALL";
            /*else if ((state.iFlags & pkgDepCache::AutoKept) != 0)
                return nil;*/
            else
                return nil;
        case pkgDepCache::ModeInstall:
            /*if ((state.iFlags & pkgDepCache::ReInstall) != 0)
                return @"REINSTALL";
            else*/ switch (state.Status) {
                case -1:
#if CYDIA_APT_MODERN
                    return [database_ cache].Policy->GetCandidateVer(iterator_)==state.CandidateVerIter([database_ cache])?@"UPGRADE":@"DOWNGRADE";
#else
                    return @"DOWNGRADE";
#endif
                case 0:
                    return @"INSTALL";
                case 1:
                    return @"UPGRADE";
                case 2:
                    return @"NEW_INSTALL";
                _nodefault
            }
        _nodefault
    }
} }

- (NSString *) id {
    return id_;
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
    return parsed_ != NULL && !parsed_->depiction_.empty() ? parsed_->depiction_ : [[self source] depictionForPackage:id_];
}

- (MIMEAddress *) author {
    return parsed_ == NULL || parsed_->author_.empty() ? nil : [MIMEAddress addressWithString:parsed_->author_];
}

- (NSString *) support {
    return parsed_ != NULL && !parsed_->support_.empty() ? parsed_->support_ : [[self source] supportForPackage:id_];
}


- (Source *) source {
    if (source_ == nil) {
        @synchronized (database_) {
            if ([database_ era] != era_ || file_.end())
                source_ = (Source *) [NSNull null];
            else
                source_ = [database_ getSource:file_.File()] ?: (Source *) [NSNull null];
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
