/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/Database.h"
#include "Cydia/DatabaseApt.h"
#include "Cydia/DatabaseStatus.h"

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/AptBackend.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/Package.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/PackageMetadata.hpp"
#include "Cydia/Profile.hpp"
#include "Cydia/ProgressEvent.h"
#include "Cydia/Source.h"
#include "CyteKit/Localize.h"
#include "CyteKit/RegEx.hpp"
#include "Menes/Menes.h"
#include "Sources.h"
#include "fdstream.hpp"

#include <apt-pkg/acquire-item.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/deb/debindexfile.h>
#include <apt-pkg/deb/debmetaindex.h>
#include <apt-pkg/error.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/progress.h>
#include <apt-pkg/update.h>

#include <algorithm>
#include <cstring>
#include <iterator>
#include <string>
#include <vector>

#include <cstdio>
#include <sys/stat.h>
#include <unistd.h>

#define lprintf(args...) fprintf(stderr, args)
#define CacheState_ Cache("CacheState.plist")

static NSString * const kCydiaProgressEventTypeError = @"Error";
static NSString * const kCydiaProgressEventTypeInformation = @"Information";
static NSString * const kCydiaProgressEventTypeStatus = @"Status";
static NSString * const kCydiaProgressEventTypeWarning = @"Warning";

static NSDate *GetStatusDate() {
    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    NSString *status([NSString stringWithUTF8String:paths.DpkgStatusPath().c_str()]);
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:status error:NULL] fileModificationDate];
}

template <typename Type_>
static size_t CFBSearch_(const Type_ &element, const Type_ *list, size_t count, CFComparisonResult (*comparator)(Type_, Type_, void *), void *context) {
    const Type_ *ptr = list;
    while (0 < count) {
        size_t half = count / 2;
        const Type_ *probe = ptr + half;
        CFComparisonResult cr = comparator(element, *probe, context);
        if (0 == cr) return probe - list;
        ptr = (cr < 0) ? ptr : probe + 1;
        count = (cr < 0) ? half : (half + (count & 1) - 1);
    }
    return ptr - list;
}

template <typename Type_>
static void CYArrayInsertionSortValues(Type_ *values, size_t length, CFComparisonResult (*comparator)(Type_, Type_, void *), void *context) {
    if (length == 0)
        return;

    for (size_t index(1); index != length; ++index) {
        Type_ value(values[index]);
        size_t correct(index);
        while (comparator(value, values[correct - 1], context) == kCFCompareLessThan) {
            if (--correct == 0)
                break;
            if (index - correct >= 8) {
                correct = CFBSearch_(value, values, correct, comparator, context);
                break;
            }
        }

        if (correct != index) {
            for (size_t move(index); move != correct; --move)
                values[move] = values[move - 1];
            values[correct] = value;
        }
    }
}

@interface Database ()
- (void) clearPackages;
- (void) _readCydia:(NSNumber *)fd;
- (void) _readStatus:(NSNumber *)fd;
- (void) _readOutput:(NSNumber *)fd;
- (bool) popErrorWithTitle:(NSString *)title;
- (bool) popErrorWithTitle:(NSString *)title forOperation:(bool)success;
- (bool) popErrorWithTitle:(NSString *)title forReadList:(pkgSourceList &)list;
@end

@implementation Database

+ (Database *) sharedInstance {
    static _H<Database> instance;
    if (instance == nil)
        instance = [[Database alloc] init];
    return instance;
}

- (unsigned) era {
    return era_;
}

- (void) clearPackages {
    packages_ = nil;
}

- (bool) hasPackages {
    return [packages_ count] != 0;
}

- (void) dealloc {
    delete apt_;
    apt_ = NULL;
    delete status_;
    status_ = NULL;
    _assert(false);
    [self clearPackages];
    NSRecycleZone(zone_);
}

- (void) _readCydia:(NSNumber *)fd {
    boost::fdistream is([fd intValue]);
    std::string line;

    static RegEx finish_r("finish:([^:]*)");
    static RegEx uicache_r("uicache:(1|[Yy][Ee][Ss])");

    while (std::getline(is, line)) {
        @autoreleasepool {

        const char *data(line.c_str());
        size_t size = line.size();
        lprintf("C:%s\n", data);

        if (finish_r(data, size)) {
            NSString *finish = finish_r[1];
            int index = [Finishes_ indexOfObject:finish];
            if (index != INT_MAX && index > Finish_)
                Finish_ = index;
        } else if (uicache_r(data, size)) {
            UICache_ = true;
        }
        }
    }

    _assume(false);
}

- (void) _readStatus:(NSNumber *)fd {
    boost::fdistream is([fd intValue]);
    std::string line;

    static RegEx conffile_r("status: [^ ]* : conffile-prompt : (.*?) *");
    static RegEx pmstatus_r("([^:]*):([^:]*):([^:]*):(.*)");

    while (std::getline(is, line)) {
        @autoreleasepool {

        const char *data(line.c_str());
        size_t size(line.size());
        lprintf("S:%s\n", data);

        if (conffile_r(data, size)) {
            // status: /fail : conffile-prompt : '/fail' '/fail.dpkg-new' 1 1
            [delegate_ performSelectorOnMainThread:@selector(setConfigurationData:) withObject:conffile_r[1] waitUntilDone:YES];
        } else if (strncmp(data, "status: ", 8) == 0) {
            // status: <package>: {unpacked,half-configured,installed}
            CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:(data + 8)] ofType:kCydiaProgressEventTypeStatus]);
            [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
        } else if (strncmp(data, "processing: ", 12) == 0) {
            // processing: configure: config-test
            CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:(data + 12)] ofType:kCydiaProgressEventTypeStatus]);
            [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
        } else if (pmstatus_r(data, size)) {
            std::string type([pmstatus_r[1] UTF8String]);

            NSString *package = pmstatus_r[2];
            if ([package isEqualToString:@"dpkg-exec"])
                package = nil;

            float percent([pmstatus_r[3] floatValue]);
            [progress_ performSelectorOnMainThread:@selector(setProgressPercent:) withObject:[NSNumber numberWithFloat:(percent / 100)] waitUntilDone:YES];

            NSString *string = pmstatus_r[4];

            if (type == "pmerror") {
                CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeError forPackage:package]);
                [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
            } else if (type == "pmstatus") {
                CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeStatus forPackage:package]);
                [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
            } else if (type == "pmconffile")
                [delegate_ performSelectorOnMainThread:@selector(setConfigurationData:) withObject:string waitUntilDone:YES];
            else
                lprintf("E:unknown pmstatus\n");
        } else
            lprintf("E:unknown status\n");
        }
    }

    _assume(false);
}

- (void) _readOutput:(NSNumber *)fd {
    boost::fdistream is([fd intValue]);
    std::string line;

    while (std::getline(is, line)) {
        @autoreleasepool {

        lprintf("O:%s\n", line.c_str());

        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:line.c_str()] ofType:kCydiaProgressEventTypeInformation]);
        [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
        }
    }

    _assume(false);
}

- (FILE *) input {
    return input_;
}

- (Package *) packageWithName:(NSString *)name {
    if (name == nil)
        return nil;
@synchronized (self) {
    CydiaAPT::PackageHandle handle(apt_->packageHandle([name UTF8String], common_arch));
    return !handle.valid() ? nil : [Package newPackageWithHandle:handle withZone:NULL inPool:NULL database:self];
} }

- (id) init {
    if ((self = [super init]) != nil) {
        status_ = new CydiaStatus();
        apt_ = new CydiaAPT::AptBackend(*status_);

        zone_ = NSCreateZone(1024 * 1024, 256 * 1024, NO);

        sourceList_ = [NSMutableArray arrayWithCapacity:16];

        int fds[2];

        _assert(pipe(fds) != -1);
        cydiafd_ = fds[1];

        _config->Set("APT::Keep-Fds::", cydiafd_);
        setenv("CYDIA", [[[[NSNumber numberWithInt:cydiafd_] stringValue] stringByAppendingString:@" 1"] UTF8String], _not(int));

        [NSThread
            detachNewThreadSelector:@selector(_readCydia:)
            toTarget:self
            withObject:[NSNumber numberWithInt:fds[0]]
        ];

        _assert(pipe(fds) != -1);
        statusfd_ = fds[1];

        [NSThread
            detachNewThreadSelector:@selector(_readStatus:)
            toTarget:self
            withObject:[NSNumber numberWithInt:fds[0]]
        ];

        _assert(pipe(fds) != -1);
        _assert(dup2(fds[0], 0) != -1);
        _assert(close(fds[0]) != -1);

        input_ = fdopen(fds[1], "a");

        _assert(pipe(fds) != -1);
        _assert(dup2(fds[1], 1) != -1);
        _assert(close(fds[1]) != -1);

        [NSThread
            detachNewThreadSelector:@selector(_readOutput:)
            toTarget:self
            withObject:[NSNumber numberWithInt:fds[0]]
        ];
    } return self;
}

- (pkgCacheFile &) cache {
    return apt_->cache();
}

- (CydiaAPT::PackageSnapshot) packageSnapshot:(CydiaAPT::PackageHandle)handle {
    return apt_->packageSnapshot(handle);
}

- (CydiaAPT::PackageRecordData) packageRecord:(CydiaAPT::PackageHandle)handle {
    return apt_->recordData(handle);
}

- (CydiaAPT::PackageStateData) packageState:(CydiaAPT::PackageHandle)handle {
    return apt_->packageState(handle);
}

- (std::vector<CydiaAPT::RelationData>) packageRelations:(CydiaAPT::PackageHandle)handle {
    return apt_->relations(handle);
}

- (std::vector<CydiaAPT::PackageHandle>) packageDowngrades:(CydiaAPT::PackageHandle)handle {
    return apt_->downgradeHandles(handle);
}

- (bool) clearPackageHandle:(CydiaAPT::PackageHandle)handle {
    return apt_->clearPackage(handle);
}

- (bool) installPackageHandle:(CydiaAPT::PackageHandle)handle {
    return apt_->installPackage(handle);
}

- (bool) removePackageHandle:(CydiaAPT::PackageHandle)handle {
    return apt_->removePackage(handle);
}

- (pkgCache::PkgIterator) iteratorForPackageHandle:(CydiaAPT::PackageHandle)handle {
    return apt_->packageIterator(handle);
}

- (pkgDepCache::Policy *) policy {
    return apt_->policy();
}

- (pkgRecords *) records {
    return apt_->records();
}

- (pkgProblemResolver *) resolver {
    return apt_->resolver();
}

- (pkgAcquire &) fetcher {
    return *apt_->fetcher();
}

- (pkgSourceList &) list {
    return *apt_->list();
}

- (NSArray *) packages {
    return packages_;
}

- (NSArray *) sources {
    return sourceList_;
}

- (Source *) sourceWithKey:(NSString *)key {
    for (Source *source in [self sources]) {
        if ([[source key] isEqualToString:key])
            return source;
    } return nil;
}

- (Source *) sourceWithFileID:(unsigned long)identifier {
    SourceMap::const_iterator source(sourceMap_.find(identifier));
    return source == sourceMap_.end() ? nil : source->second;
}

- (bool) popErrorWithTitle:(NSString *)title {
    bool fatal(false);

    while (!_error->empty()) {
        std::string error;
        bool warning(!_error->PopMessage(error));
        if (!warning)
            fatal = true;

        for (;;) {
            size_t size(error.size());
            if (size == 0 || error[size - 1] != '\n')
                break;
            error.resize(size - 1);
        }

        lprintf("%c:[%s]\n", warning ? 'W' : 'E', error.c_str());

        static RegEx no_pubkey("GPG error:.* NO_PUBKEY .*");
        if (warning && no_pubkey(error.c_str()))
            continue;

        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:error.c_str()] ofType:(warning ? kCydiaProgressEventTypeWarning : kCydiaProgressEventTypeError)] forTask:title];
    }

    return fatal;
}

- (bool) popErrorWithTitle:(NSString *)title forOperation:(bool)success {
    return [self popErrorWithTitle:title] || !success;
}

- (bool) popErrorWithTitle:(NSString *)title forReadList:(pkgSourceList &)list {
    return [self popErrorWithTitle:title forOperation:list.ReadMainList()];
}

- (void) reloadDataWithInvocation:(NSInvocation *)invocation {
@synchronized (self) {
    ++era_;

    [self clearPackages];

    sourceMap_.clear();
    [sourceList_ removeAllObjects];

    _error->Discard();

    apt_->reset();
    pkgCacheFile &cache(apt_->cache());

    pool_.~CYPool();
    new (&pool_) CYPool();

    NSRecycleZone(zone_);
    zone_ = NSCreateZone(1024 * 1024, 256 * 1024, NO);

    int chk(creat("/tmp/cydia.chk", 0644));
    if (chk != -1)
        close(chk);

    if (invocation != nil)
        [invocation invoke];

    NSString *title(UCLocalize("DATABASE"));

    pkgSourceList *list(apt_->createSourceList());
    _profile(reloadDataWithInvocation$ReadMainList)
    if ([self popErrorWithTitle:title forReadList:*list])
        return;
    _end

    pkgAcquire *fetcher(apt_->createFetcher());

    _profile(reloadDataWithInvocation$Source$initWithMetaIndex)
    for (pkgSourceList::const_iterator source = list->begin(); source != list->end(); ++source) {
        Source *object([[Source alloc] initWithMetaIndex:*source forDatabase:self inPool:&pool_ withAcquire:fetcher]);
        [sourceList_ addObject:object];
    }
    _end

    _trace();
    OpProgress progress;
    bool opened;
  open:
    delock_ = GetStatusDate();
    _profile(reloadDataWithInvocation$pkgCacheFile)
        opened = cache.Open(&progress, false);
    _end
    if (!opened) {
        // XXX: this block should probably be merged with popError: in some way
        while (!_error->empty()) {
            std::string error;
            bool warning(!_error->PopMessage(error));

            lprintf("cache.Open():[%s]\n", error.c_str());

            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:error.c_str()] ofType:(warning ? kCydiaProgressEventTypeWarning : kCydiaProgressEventTypeError)] forTask:title];

            SEL repair(NULL);
            if (false);
            else if (error == "dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem. ")
                repair = @selector(configure);
            //else if (error == "The package lists or status file could not be parsed or opened.")
            //    repair = @selector(update);
            // else if (error == "Could not get lock /var/lib/dpkg/lock - open (35 Resource temporarily unavailable)")
            // else if (error == "Could not open lock file /var/lib/dpkg/lock - open (13 Permission denied)")
            // else if (error == "Malformed Status line")
            // else if (error == "The list of sources could not be read.")

            if (repair != NULL) {
                _error->Discard();
                [delegate_ repairWithSelector:repair];
                goto open;
            }
        }

        return;
    } else if ([self popErrorWithTitle:title forOperation:true])
        return;
    _trace();

    unlink("/tmp/cydia.chk");

    now_ = [[NSDate date] timeIntervalSince1970];

    apt_->createCacheViews();

    if (cache->DelCount() != 0 || cache->InstCount() != 0) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("COUNTS_NONZERO_EX") ofType:kCydiaProgressEventTypeError] forTask:title];
        return;
    }

    _profile(reloadDataWithInvocation$pkgApplyStatus)
    if ([self popErrorWithTitle:title forOperation:pkgApplyStatus(cache)])
        return;
    _end

    if (cache->BrokenCount() != 0) {
        _profile(pkgApplyStatus$pkgFixBroken)
        if ([self popErrorWithTitle:title forOperation:pkgFixBroken(cache)])
            return;
        _end

        if (cache->BrokenCount() != 0) {
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("STILL_BROKEN_EX") ofType:kCydiaProgressEventTypeError] forTask:title];
            return;
        }

        _profile(pkgApplyStatus$pkgMinimizeUpgrade)
        if ([self popErrorWithTitle:title forOperation:CydiaAPT::MinimizeUpgrade(*cache)])
            return;
        _end
    }

    for (Source *object in (id) sourceList_) {
        metaIndex *source([object metaIndex]);
        std::vector<pkgIndexFile *> *indices = source->GetIndexFiles();
        for (std::vector<pkgIndexFile *>::const_iterator index = indices->begin(); index != indices->end(); ++index)
            // XXX: this could be more intelligent
            if (dynamic_cast<debPackagesIndex *>(*index) != NULL) {
                pkgCache::PkgFileIterator cached((*index)->FindInCache(*cache));
                if (!cached.end())
                    sourceMap_[cached->ID] = object;
            }
    }

    {
        size_t capacity(MetaFile_->active_);
        if (capacity == 0)
            capacity = 128*1024;
        else
            capacity += 1024;

        std::vector<Package *> packages;
        packages.reserve(capacity);
        size_t lost(0);

        size_t last(0);
        _profile(reloadDataWithInvocation$packageWithHandle)
        std::vector<CydiaAPT::PackageHandle> handles(apt_->packageHandles());
        for (std::vector<CydiaAPT::PackageHandle>::const_iterator handle(handles.begin()); handle != handles.end(); ++handle)
            if (Package *package = [Package newPackageWithHandle:*handle withZone:zone_ inPool:&pool_ database:self]) {
                if (unsigned index = package.metadata->index_) {
                    --index;
                    if (packages.size() == index) {
                        packages.push_back(package);
                    } else if (packages.size() <= index) {
                        packages.resize(index + 1, nil);
                        packages[index] = package;
                        continue;
                    } else {
                        std::swap(package, packages[index]);
                        if (package != nil) {
                            if (package.metadata->index_ == index + 1)
                                ++lost;
                            goto lost;
                        }
                        if (last != index)
                            continue;
                    }
                } else {
                    ++lost;
                    lost: if (last == packages.size())
                        packages.push_back(package);
                    else
                        packages[last] = package;
                    ++last;
                }

                for (; last != packages.size(); ++last)
                    if (packages[last] == nil)
                        break;
            }
        _end

        for (size_t next(last + 1); last != packages.size(); ++last, ++next) {
            while (true) {
                if (next == packages.size())
                    goto done;
                if (packages[next] != nil)
                    break;
                ++next;
            }

            std::swap(packages[last], packages[next]);
        } done:;

        packages.resize(last);

        if (lost > 128) {
            NSLog(@"lost = %zu", lost);

            _profile(reloadDataWithInvocation$radix$8)
            CYRadixSortUsingFunction(reinterpret_cast<id __strong *>(packages.data()), packages.size(), reinterpret_cast<MenesRadixSortFunction>(&PackagePrefixRadix), reinterpret_cast<void *>(8));
            _end

            _profile(reloadDataWithInvocation$radix$4)
            CYRadixSortUsingFunction(reinterpret_cast<id __strong *>(packages.data()), packages.size(), reinterpret_cast<MenesRadixSortFunction>(&PackagePrefixRadix), reinterpret_cast<void *>(4));
            _end

            _profile(reloadDataWithInvocation$radix$0)
            CYRadixSortUsingFunction(reinterpret_cast<id __strong *>(packages.data()), packages.size(), reinterpret_cast<MenesRadixSortFunction>(&PackagePrefixRadix), reinterpret_cast<void *>(0));
            _end
        }

        _profile(reloadDataWithInvocation$insertion)
        CYArrayInsertionSortValues(packages.data(), packages.size(), &PackageNameCompare, NULL);
        _end

        packages_ = [[NSArray alloc] initWithObjects:packages.data() count:packages.size()];

        /*_profile(reloadDataWithInvocation$CFQSortArray)
        CFQSortArray(&packages.front(), packages.size(), sizeof(packages.front()), reinterpret_cast<CFComparatorFunction>(&PackageNameCompare_), NULL);
        _end*/

        /*_profile(reloadDataWithInvocation$stdsort)
        std::sort(packages.begin(), packages.end(), PackageNameOrdering());
        _end*/

        /*_profile(reloadDataWithInvocation$CFArraySortValues)
        CFArraySortValues((CFMutableArrayRef) packages_, CFRangeMake(0, [packages_ count]), reinterpret_cast<CFComparatorFunction>(&PackageNameCompare), NULL);
        _end*/

        /*_profile(reloadDataWithInvocation$sortUsingFunction)
        [packages_ sortUsingFunction:reinterpret_cast<NSComparisonResult (*)(id, id, void *)>(&PackageNameCompare) context:NULL];
        _end*/

        MetaFile_->active_ = packages.size();
        for (size_t index(0), count(packages.size()); index != count; ++index) {
            auto package(packages[index]);
            [package setIndex:index];
        }
    }
} }

- (void) clear {
@synchronized (self) {
    delete apt_->resolver();
    apt_->resolver() = new pkgProblemResolver(apt_->cache());

    for (pkgCache::PkgIterator iterator(apt_->cache()->PkgBegin()); !iterator.end(); ++iterator)
        if (!apt_->cache()[iterator].Keep())
            apt_->cache()->MarkKeep(iterator, false);
        else if ((apt_->cache()[iterator].iFlags & pkgDepCache::ReInstall) != 0)
            apt_->cache()->SetReInstall(iterator, false);
} }

- (void) configure {
    _trace();
    CydiaRuntime::Dpkg::Runner runner(CydiaRuntime::Dpkg::Executable::Cydo);
    CydiaRuntime::Dpkg::Result result(runner.Run({"--configure", "-a"}, statusfd_));
    if (!result.succeeded())
        _trace();
    _trace();
}

- (bool) clean {
@synchronized (self) {
    // XXX: I don't remember this condition
    if (apt_->lock() != NULL)
        return false;

    FileFd Lock = FileFd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"), true);

    NSString *title(UCLocalize("CLEAN_ARCHIVES"));

    if ([self popErrorWithTitle:title])
        return false;

    pkgAcquire fetcher;
    fetcher.Clean(_config->FindDir("Dir::Cache::Archives"));

    if ([self popErrorWithTitle:title forOperation:CydiaAPT::CleanArchives(
        _config->FindDir("Dir::Cache::Archives") + "partial/",
        static_cast<pkgCache &>(apt_->cache()))])
        return false;

    return true;
} }

- (bool) prepare {
    apt_->fetcher()->Shutdown();

    pkgRecords records(apt_->cache());

    apt_->lock() = new FileFd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"), true);

    NSString *title(UCLocalize("PREPARE_ARCHIVES"));

    if ([self popErrorWithTitle:title])
        return false;

    pkgSourceList list;
    if ([self popErrorWithTitle:title forReadList:list])
        return false;

    apt_->manager().reset(_system->CreatePM(apt_->cache()));
    if ([self popErrorWithTitle:title forOperation:apt_->manager()->GetArchives(apt_->fetcher(), &list, &records)])
        return false;

    return true;
}

- (void) perform {
    bool substrate(RestartSubstrate_);
    RestartSubstrate_ = false;

    NSString *title(UCLocalize("PERFORM_SELECTIONS"));

    NSMutableArray *before = [NSMutableArray arrayWithCapacity:16]; {
        pkgSourceList list;
        if ([self popErrorWithTitle:title forReadList:list])
            return;
        for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source)
            [before addObject:[NSString stringWithUTF8String:(*source)->GetURI().c_str()]];
    }

    [delegate_ performSelectorOnMainThread:@selector(retainNetworkActivityIndicator) withObject:nil waitUntilDone:YES];

    if (apt_->fetcher()->Run(PulseInterval_) != pkgAcquire::Continue) {
        _trace();
        [self popErrorWithTitle:title];
        return;
    }

    bool failed = false;
    for (pkgAcquire::ItemIterator item = apt_->fetcher()->ItemsBegin(); item != apt_->fetcher()->ItemsEnd(); item++) {
        if ((*item)->Status == pkgAcquire::Item::StatDone && (*item)->Complete)
            continue;
        if ((*item)->Status == pkgAcquire::Item::StatIdle)
            continue;

        std::string uri = (*item)->DescURI();
        std::string error = (*item)->ErrorText;

        lprintf("pAf:%s:%s\n", uri.c_str(), error.c_str());
        failed = true;

        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:error.c_str()] ofType:kCydiaProgressEventTypeError]);
        [delegate_ addProgressEventOnMainThread:event forTask:title];
    }

    [delegate_ performSelectorOnMainThread:@selector(releaseNetworkActivityIndicator) withObject:nil waitUntilDone:YES];

    if (failed) {
        _trace();
        return;
    }

    if (substrate)
        RestartSubstrate_ = true;

    if (![delock_ isEqual:GetStatusDate()]) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("DPKG_LOCKED") ofType:kCydiaProgressEventTypeError] forTask:title];
        return;
    }

    delock_ = nil;

    CydiaAPT::PackageManagerResult result(CydiaAPT::RunPackageManager(*apt_->manager(), statusfd_));

    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    NSString *oextended([NSString stringWithUTF8String:paths.AptExtendedStatesPath().c_str()]);
    NSString *nextended(Cache("extended_states"));

    struct stat info;
    if (stat([nextended UTF8String], &info) != -1 && (info.st_mode & S_IFMT) == S_IFREG) {
        CydiaRuntime::Dpkg::Runner runner(CydiaRuntime::Dpkg::Executable::Cydo);
        (void) runner.Run({"/bin/cp", "--remove-destination",
                           [nextended UTF8String], [oextended UTF8String]});
    }

    unlink([nextended UTF8String]);
    symlink([oextended UTF8String], [nextended UTF8String]);

    if ([self popErrorWithTitle:title])
        return;

    if (result == CydiaAPT::PackageManagerResult::Failed) {
        _trace();
        return;
    }

    if (result != CydiaAPT::PackageManagerResult::Completed) {
        _trace();
        return;
    }

    NSMutableArray *after = [NSMutableArray arrayWithCapacity:16]; {
        pkgSourceList list;
        if ([self popErrorWithTitle:title forReadList:list])
            return;
        for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source)
            [after addObject:[NSString stringWithUTF8String:(*source)->GetURI().c_str()]];
    }

    if (![before isEqualToArray:after] && Finish_ == 0)
        [self update];
}

- (bool) delocked {
    return ![delock_ isEqual:GetStatusDate()];
}

- (bool) upgrade {
    NSString *title(UCLocalize("UPGRADE"));
    if ([self popErrorWithTitle:title forOperation:CydiaAPT::PrepareDistUpgrade(
        static_cast<pkgDepCache &>(apt_->cache()))])
        return false;
    return true;
}

- (void) update {
    [self updateWithStatus:*status_];
}

- (void) updateWithStatus:(CancelStatus &)status {
    NSString *title(UCLocalize("REFRESHING_DATA"));

    pkgSourceList list;
    if ([self popErrorWithTitle:title forReadList:list])
        return;

    FileFd lock = FileFd(GetLock(_config->FindDir("Dir::State::Lists") + "lock"), true);
    if ([self popErrorWithTitle:title])
        return;

    [delegate_ performSelectorOnMainThread:@selector(retainNetworkActivityIndicator) withObject:nil waitUntilDone:YES];

    bool success(ListUpdate(status, list, PulseInterval_));
    if (status.WasCancelled())
        _error->Discard();
    else {
        [self popErrorWithTitle:title forOperation:success];

        [[NSDictionary dictionaryWithObjectsAndKeys:
            [NSDate date], @"LastUpdate",
        nil] writeToFile:CacheState_ atomically:YES];
    }

    [delegate_ performSelectorOnMainThread:@selector(releaseNetworkActivityIndicator) withObject:nil waitUntilDone:YES];
}

- (void) setDelegate:(NSObject<DatabaseDelegate> *)delegate {
    delegate_ = delegate;
}

- (void) setProgressDelegate:(NSObject<ProgressDelegate> *)delegate {
    progress_ = delegate;
    status_->setDelegate(delegate);
}

- (NSObject<ProgressDelegate> *) progressDelegate {
    return progress_;
}

- (void) setFetch:(bool)fetch forURI:(const char *)uri {
    for (Source *source in (id) sourceList_)
        [source setFetch:fetch forURI:uri];
}

- (void) resetFetch {
    for (Source *source in (id) sourceList_)
        [source resetFetch];
}

- (NSString *) mappedSectionForPointer:(const char *)section {
    _H<NSString> *mapped;

    _profile(Database$mappedSectionForPointer$Cache)
        mapped = &sections_[section];
    _end

    if (*mapped == NULL) {
        size_t length(strlen(section));
        char spaced[length + 1];

        _profile(Database$mappedSectionForPointer$Replace)
            for (size_t index(0); index != length; ++index)
                spaced[index] = section[index] == '_' ? ' ' : section[index];
            spaced[length] = '\0';
        _end

        NSString *string;

        _profile(Database$mappedSectionForPointer$stringWithUTF8String)
            string = [NSString stringWithUTF8String:spaced];
        _end

        _profile(Database$mappedSectionForPointer$Map)
            string = [SectionMap_ objectForKey:string] ?: string;
        _end

        *mapped = string;
    } return *mapped;
}

@end
