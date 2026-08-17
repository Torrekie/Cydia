/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_Database_H
#define Cydia_Database_H

#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"
#include "Menes/Pooling.hpp"

#include <Foundation/Foundation.h>

#include <apt-pkg/acquire.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/contrib/fileutl.h>
#include <apt-pkg/packagemanager.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/sptr.h>

#include <cstdio>
#include <map>
#include <set>
#include <string>

@class Database;
@class Package;
@class Source;
@class CydiaProgressEvent;
@protocol ProgressDelegate;

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

class CancelStatus :
    public pkgAcquireStatus
{
  private:
    bool cancelled_;

  public:
    CancelStatus();
    virtual bool MediaChange(std::string media, std::string drive);
    virtual void IMSHit(pkgAcquire::ItemDesc &desc);
    virtual bool Pulse_(pkgAcquire *Owner) = 0;
    virtual bool Pulse(pkgAcquire *Owner);
    bool WasCancelled() const;
};

class CydiaStatus :
    public CancelStatus
{
  private:
    _transient NSObject<ProgressDelegate> *delegate_;

  public:
    CydiaStatus();
    void setDelegate(NSObject<ProgressDelegate> *delegate);

    virtual void Fetch(pkgAcquire::ItemDesc &desc);
    virtual void Done(pkgAcquire::ItemDesc &desc);
    virtual void Fail(pkgAcquire::ItemDesc &desc);
    virtual bool Pulse_(pkgAcquire *Owner);
    virtual void Start();
    virtual void Stop();
};

class SourceStatus :
    public CancelStatus
{
  private:
    _transient NSObject<FetchDelegate> *delegate_;
    _transient Database *database_;
    std::set<std::string> fetches_;

  public:
    SourceStatus(NSObject<FetchDelegate> *delegate, Database *database);
    void Set(bool fetch, const std::string &uri);
    void Set(bool fetch, pkgAcquire::Item *item);
    void Log(const char *tag, pkgAcquire::Item *item);

    virtual void Fetch(pkgAcquire::ItemDesc &desc);
    virtual void Done(pkgAcquire::ItemDesc &desc);
    virtual void Fail(pkgAcquire::ItemDesc &desc);
    virtual bool Pulse_(pkgAcquire *Owner);
    virtual void Stop();
};

typedef std::map<unsigned long, _H<Source> > SourceMap;

@interface Database : NSObject {
    NSZone *zone_;
    CYPool pool_;

    unsigned era_;
    _H<NSDate> delock_;

    pkgCacheFile cache_;
    pkgDepCache::Policy *policy_;
    pkgRecords *records_;
    pkgProblemResolver *resolver_;
    pkgAcquire *fetcher_;
    FileFd *lock_;
    SPtr<pkgPackageManager> manager_;
    pkgSourceList *list_;

    SourceMap sourceMap_;
    _H<NSMutableArray> sourceList_;

    _H<NSArray> packages_;

    _transient NSObject<DatabaseDelegate> *delegate_;
    _transient NSObject<ProgressDelegate> *progress_;

    CydiaStatus status_;

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

- (pkgCacheFile &) cache;
- (pkgDepCache::Policy *) policy;
- (pkgRecords *) records;
- (pkgProblemResolver *) resolver;
- (pkgAcquire &) fetcher;
- (pkgSourceList &) list;
- (NSArray *) packages;
- (NSArray *) sources;
- (Source *) sourceWithKey:(NSString *)key;
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

- (Source *) getSource:(pkgCache::PkgFileIterator)file;
- (void) setFetch:(bool)fetch forURI:(const char *)uri;
- (void) resetFetch;
- (NSString *) mappedSectionForPointer:(const char *)pointer;

@end

#endif//Cydia_Database_H
