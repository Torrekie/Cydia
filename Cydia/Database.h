/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_Database_H
#define Cydia_Database_H

#include "Cydia/AptCompatibility.hpp"
#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"
#include "Menes/Pooling.hpp"

#include <Foundation/Foundation.h>

#include <cstdio>
#include <map>

@class Database;
@class Package;
@class Source;
@class CydiaProgressEvent;
@protocol ProgressDelegate;

namespace CydiaAPT {
class AptBackend;
}

class CancelStatus;
class CydiaStatus;

@protocol DatabaseDelegate
- (void) repairWithSelector:(SEL)selector;
- (void) setConfigurationData:(NSString *)data;
- (void) addProgressEventOnMainThread:(CydiaProgressEvent *)event forTask:(NSString *)task;
@end

@protocol FetchDelegate
- (bool) isSourceCancelled;
- (void) startSourceFetch:(NSString *)uri;
- (void) stopSourceFetch:(NSString *)uri;
@end

/* These application-owned values are shared with the database worker. */
extern int PulseInterval_;
extern int Finish_;
extern bool UICache_;
extern bool RestartSubstrate_;
extern NSArray *Finishes_;
extern NSDictionary *SectionMap_;
extern NSString *Colon_;

/* Kept here until the remaining application helpers are split out. */
NSString *ShellEscape(NSString *value);

typedef std::map<unsigned long, _H<Source> > SourceMap;

@interface Database : NSObject {
    NSZone *zone_;
    CYPool pool_;

    unsigned era_;
    _H<NSDate> delock_;

    CydiaAPT::AptBackend *apt_;

    SourceMap sourceMap_;
    _H<NSMutableArray> sourceList_;

    _H<NSArray> packages_;

    __weak NSObject<DatabaseDelegate> *delegate_;
    __weak NSObject<ProgressDelegate> *progress_;

    CydiaStatus *status_;

    int cydiafd_;
    int statusfd_;
    FILE *input_;

    std::map<const char *, _H<NSString> > sections_;
}

+ (Database *) sharedInstance;
- (unsigned) era;
- (bool) hasPackages;

- (FILE *) input;
- (Package *) packageWithName:(NSString *)name;
- (CydiaAPT::PackageSnapshot) packageSnapshot:(CydiaAPT::PackageHandle)handle;
- (CydiaAPT::PackageRecordData) packageRecord:(CydiaAPT::PackageHandle)handle;
- (CydiaAPT::PackageStateData) packageState:(CydiaAPT::PackageHandle)handle;
- (std::vector<CydiaAPT::RelationData>) packageRelations:(CydiaAPT::PackageHandle)handle;
- (std::vector<CydiaAPT::PackageHandle>) packageDowngrades:(CydiaAPT::PackageHandle)handle;
- (bool) clearPackageHandle:(CydiaAPT::PackageHandle)handle;
- (bool) installPackageHandle:(CydiaAPT::PackageHandle)handle;
- (bool) removePackageHandle:(CydiaAPT::PackageHandle)handle;

- (NSArray *) packages;
- (NSArray *) sources;
- (Source *) sourceWithKey:(NSString *)key;
- (Source *) sourceWithFileID:(unsigned long)identifier;
- (void) reloadDataWithInvocation:(NSInvocation *)invocation;

- (void) clear;
- (void) configure;
- (bool) clean;
- (bool) prepare;
- (void) perform;
- (bool) delocked;
- (bool) upgrade;
- (void) update;
- (void) updateWithStatus:(CancelStatus &)status;

- (void) setDelegate:(NSObject<DatabaseDelegate> *)delegate;
- (void) setProgressDelegate:(NSObject<ProgressDelegate> *)delegate;
- (NSObject<ProgressDelegate> *) progressDelegate;

- (void) setFetch:(bool)fetch forURI:(const char *)uri;
- (void) resetFetch;
- (NSString *) mappedSectionForPointer:(const char *)pointer;

@end

#endif//Cydia_Database_H
