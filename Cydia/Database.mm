/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/Database.h"
#include "Cydia/FetchDiagnostics.h"
#include "Cydia/DatabaseStatus.h"
#include "Cydia/DatabaseRuntimeInternal.h"
#include "Cydia/DatabaseSnapshots.h"

#include "Cydia/AptCompatibility.hpp"
#include "Cydia/AptBackend.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/DpkgStatusParser.hpp"
#include "Cydia/Package.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/PackageMetadata.hpp"
#include "Cydia/Profile.hpp"
#include "Cydia/ProgressEvent.h"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/Source.h"
#include "Cydia/TransactionOutcomePolicy.hpp"
#include "CyteKit/Localize.h"
#include "CyteKit/RegEx.hpp"
#include "Menes/Menes.h"
#include "Sources.h"
#include "fdstream.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <iterator>
#include <string>
#include <vector>

#include <cstdio>
#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#define lprintf(args...) fprintf(stderr, args)
#define CacheState_ Cache("CacheState.plist")

static bool DpkgJournalNeedsRecovery() {
    // APT detects an interrupted dpkg by numeric entries in its updates
    // journal. Inspect that state independently of translated diagnostics;
    // an unreadable or unrelated database error cannot authorize repair.
    if (!CydiaAPT::MutationEnvironmentValid()) return false;
    const std::string path(CydiaAPT::DpkgAdminDirectory() + "/updates");
    const int descriptor(open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (descriptor < 0) return false;
    DIR *directory(fdopendir(descriptor));
    if (directory == NULL) { close(descriptor); return false; }
    bool pending(false);
    while (dirent *entry = readdir(directory)) {
        const char *name(entry->d_name);
        if (*name == '\0') continue;
        while (*name >= '0' && *name <= '9') ++name;
        if (*name != '\0') continue;
        struct stat info;
        if (fstatat(descriptor, entry->d_name, &info, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(info.st_mode)) {
            pending = true;
            break;
        }
    }
    closedir(directory);
    return pending;
}

static NSString * const kCydiaProgressEventTypeError = @"Error";
static NSString * const kCydiaProgressEventTypeInformation = @"Information";
static NSString * const kCydiaProgressEventTypeStatus = @"Status";
static NSString * const kCydiaProgressEventTypeWarning = @"Warning";

namespace {
class DatabaseOperation {
    NSRecursiveLock *__strong lock_;
public:
    explicit DatabaseOperation(NSRecursiveLock *lock) : lock_(lock) { [lock_ lock]; }
    ~DatabaseOperation() { [lock_ unlock]; }
    DatabaseOperation(const DatabaseOperation &) = delete;
    DatabaseOperation &operator=(const DatabaseOperation &) = delete;
};

// Package and Source callers may already own the database monitor. Never
// wait for the operation gate here: a worker can own that gate while waiting
// for the monitor or for a UIKit progress callback. Recursive reads by the
// active worker succeed; unrelated UI/background reads return owned empties.
class DatabaseReadOperation {
    NSRecursiveLock *__strong lock_;
public:
    explicit DatabaseReadOperation(NSRecursiveLock *lock) : lock_([lock tryLock] ? lock : nil) {}
    ~DatabaseReadOperation() { if (lock_) [lock_ unlock]; }
    bool held() const { return lock_ != nil; }
    DatabaseReadOperation(const DatabaseReadOperation &) = delete;
    DatabaseReadOperation &operator=(const DatabaseReadOperation &) = delete;
};

class PackageTransactionLock {
    CydiaAPT::AptBackend *apt_;
public:
    explicit PackageTransactionLock(CydiaAPT::AptBackend *apt) : apt_(NULL) {
        if (apt->lockForTransaction()) apt_ = apt;
    }
    ~PackageTransactionLock() { if (apt_ != NULL) apt_->unlockForTransaction(); }
    bool held() const { return apt_ != NULL; }
};

class ConfigureFrontendLock {
    int fd_;
public:
    ConfigureFrontendLock() : fd_(-1) {
        CydiaRuntime::Privileged::Error error;
        fd_ = CydiaRuntime::PrivilegedClient::OpenLock(CydiaAPT::PrivilegedHelperPath(),
            CydiaRuntime::PrivilegedClient::RuntimeRequest(""), "lock-frontend", &error);
        if (fd_ < 0) return;
        struct flock lock = {};
        lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
        if (fcntl(fd_, F_SETLK, &lock) != 0) { close(fd_); fd_ = -1; }
    }
    ~ConfigureFrontendLock() { if (fd_ >= 0) close(fd_); }
    bool held() const { return fd_ >= 0; }
};
}


static NSString *SettingsMessage(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Settings"];
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
- (bool) requirePackageChangesForTask:(NSString *)task;
- (void) updateWithStatus:(CydiaAPT::AcquireStatus &)status;
- (void) recheckRepositoryTrust;
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
    delete runtime_;
    runtime_ = NULL;
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
            if (index != INT_MAX && index > Finish_) {
                Finish_ = index;
                NSObject<ProgressDelegate> *progress(progress_);
                if ([progress respondsToSelector:@selector(progressFinishActionDidChange:)])
                    [progress performSelectorOnMainThread:
                        @selector(progressFinishActionDidChange:)
                        withObject:@(Finish_) waitUntilDone:NO];
            }
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
        } else {
            CydiaRuntime::Dpkg::PackageManagerProgressRecord record;
            if (!CydiaRuntime::Dpkg::ParsePackageManagerProgress(line, &record)) {
                lprintf("E:unknown status\n");
                continue;
            }

            NSString *package = [NSString stringWithUTF8String:record.package.c_str()];
            if ([package isEqualToString:@"dpkg-exec"])
                package = nil;

            [progress_ performSelectorOnMainThread:@selector(setProgressPercent:) withObject:[NSNumber numberWithDouble:(record.percent / 100)] waitUntilDone:YES];

            NSString *string = [NSString stringWithUTF8String:record.message.c_str()];

            if (record.type == "pmerror") {
                CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeError forPackage:package]);
                [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
            } else if (record.type == "pmstatus") {
                CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeStatus forPackage:package]);
                [progress_ performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
            } else if (record.type == "pmconffile")
                [delegate_ performSelectorOnMainThread:@selector(setConfigurationData:) withObject:string waitUntilDone:YES];
            else
                lprintf("E:unknown pmstatus\n");
        }
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

- (CydiaAPT::PackageLookupResult) lookupPackage:(NSString *)name {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return CydiaAPT::PackageLookupResult();
@synchronized (self) {
    return apt_->lookupPackage(name == nil ? "" : [name UTF8String], CydiaAPT::Architecture());
} }

- (Package *) packageWithName:(NSString *)name {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready() || name == nil)
        return nil;
@synchronized (self) {
    CydiaAPT::PackageLookupResult lookup([self lookupPackage:name]);
    CydiaAPT::PackageHandle handle(lookup.status == CydiaAPT::PackageLookupStatus::Found ?
        lookup.handle : CydiaAPT::PackageHandle());
    return !handle.valid() ? nil : [Package newPackageWithHandle:handle withZone:NULL inPool:NULL database:self];
} }

- (id) init {
    if ((self = [super init]) != nil) {
        operationLock_ = [[NSRecursiveLock alloc] init];
        status_ = new CydiaAPT::ProgressStatus();
        [self initializeRuntimeProvider];

        zone_ = NSCreateZone(1024 * 1024, 256 * 1024, NO);

        sourceList_ = [NSMutableArray arrayWithCapacity:16];

        int fds[2];

        _assert(pipe(fds) != -1);
        cydiafd_ = fds[1];

        CydiaAPT::AptBackend::KeepFileDescriptor(cydiafd_);
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

- (CydiaAPT::PackageSnapshot) packageSnapshot:(CydiaAPT::PackageHandle)handle {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return CydiaAPT::PackageSnapshot();
@synchronized (self) {
    return apt_->packageSnapshot(handle);
} }

- (CydiaAPT::PackageRecordData) packageRecord:(CydiaAPT::PackageHandle)handle {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return CydiaAPT::PackageRecordData();
@synchronized (self) {
    return apt_->recordData(handle);
} }

- (CydiaAPT::PackageStateData) packageState:(CydiaAPT::PackageHandle)handle {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return CydiaAPT::PackageStateData();
@synchronized (self) {
    return apt_->packageState(handle);
} }

- (std::vector<CydiaAPT::RelationData>) packageRelations:(CydiaAPT::PackageHandle)handle {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return {};
@synchronized (self) {
    return apt_->relations(handle);
} }

- (std::vector<CydiaAPT::PackageHandle>) packageDowngrades:(CydiaAPT::PackageHandle)handle {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return {};
@synchronized (self) {
    return apt_->downgradeHandles(handle);
} }

- (std::vector<CydiaAPT::PackageHandle>) packageVersions:(CydiaAPT::PackageHandle)handle {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return {};
@synchronized (self) {
    return apt_->versionHandles(handle);
} }

- (CydiaAPT::TransactionData) transactionData {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return CydiaAPT::TransactionData();
@synchronized (self) {
    return apt_->transactionData();
} }

- (bool) resolveDependencies {
    DatabaseOperation operation(operationLock_);
    return runtime_->ready() && apt_->resolveDependencies();
}

- (BOOL) beginSettingsChange { return [operationLock_ tryLock]; }
- (void) endSettingsChange { [operationLock_ unlock]; }

- (bool) canChangePackages {
    DatabaseReadOperation operation(operationLock_);
    return operation.held() && runtime_->ready() && runtime_->healthy() && CydiaAPT::MutationEnvironmentValid();
}

- (bool) hasPendingPackageChanges {
    DatabaseOperation operation(operationLock_);
    if (!runtime_->ready()) return false;
    const CydiaAPT::CacheStateSummary state(apt_->cacheState());
    return state.installs != 0 || state.deletes != 0;
}

- (bool) requirePackageChangesForTask:(NSString *)task {
    if ([self canChangePackages]) return true;
    NSString *message([[NSBundle mainBundle] localizedStringForKey:@"PACKAGE_CHANGES_UNAVAILABLE"
        value:@"PACKAGE_CHANGES_UNAVAILABLE" table:@"Settings"]);
    [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message
        ofType:kCydiaProgressEventTypeError] forTask:task];
    return false;
}

- (void) clearSelections {
    DatabaseOperation operation(operationLock_);
    [self invalidateConfirmationReview];
    if (runtime_->ready()) apt_->clearSelections();
}

- (bool) prepareDistUpgrade {
    DatabaseOperation operation(operationLock_);
    [self invalidateConfirmationReview];
    if (![self requirePackageChangesForTask:UCLocalize("UPGRADE")]) return false;
    return apt_->prepareDistUpgrade();
}

- (bool) clearPackageHandle:(CydiaAPT::PackageHandle)handle expectedEra:(unsigned)expectedEra {
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    if (era_ != expectedEra || !handle.valid()) return false;
    [self invalidateConfirmationReview];
    return runtime_->ready() && apt_->clearPackage(handle);
} }

- (bool) installPackageHandle:(CydiaAPT::PackageHandle)handle expectedEra:(unsigned)expectedEra {
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    if (era_ != expectedEra || !handle.valid()) return false;
    if (![self requirePackageChangesForTask:UCLocalize("INSTALL")]) return false;
    [self invalidateConfirmationReview];
    return apt_->installPackage(handle);
} }

- (bool) reinstallPackageHandle:(CydiaAPT::PackageHandle)handle expectedEra:(unsigned)expectedEra {
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    if (era_ != expectedEra || !handle.valid()) return false;
    if (![self requirePackageChangesForTask:UCLocalize("REINSTALL")]) return false;
    [self invalidateConfirmationReview];
    return apt_->reinstallPackage(handle);
} }

- (bool) removePackageHandle:(CydiaAPT::PackageHandle)handle expectedEra:(unsigned)expectedEra {
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    if (era_ != expectedEra || !handle.valid()) return false;
    if (![self requirePackageChangesForTask:UCLocalize("REMOVE")]) return false;
    [self invalidateConfirmationReview];
    return apt_->removePackage(handle);
} }

- (bool) purgePackageHandle:(CydiaAPT::PackageHandle)handle expectedEra:(unsigned)expectedEra {
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    if (era_ != expectedEra || !handle.valid()) return false;
    if (![self requirePackageChangesForTask:UCLocalize("PURGE")]) return false;
    [self invalidateConfirmationReview];
    return apt_->removePackage(handle, true);
} }

- (bool) setPackageHandle:(CydiaAPT::PackageHandle)handle held:(bool)held expectedEra:(unsigned)expectedEra {
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    if (era_ != expectedEra || !handle.valid()) return false;
    NSString *title(UCLocalize("SETTINGS"));
    if (![self requirePackageChangesForTask:title]) return false;
    const CydiaAPT::PackageSnapshot package(apt_->packageSnapshot(handle));
    if (!package.handle.valid() || !package.state.hasCurrent) return false;
    ConfigureFrontendLock frontend;
    if (!frontend.held()) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("DPKG_LOCKED")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    if (transactionSnapshot_ == nil || ![transactionSnapshot_ isEqualToString:CurrentTransactionSnapshot()]) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_STALE")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    std::vector<std::string> arguments(1, CydiaAPT::DpkgExecutablePath());
    arguments.insert(arguments.end(), CydiaAPT::DpkgOptions().begin(), CydiaAPT::DpkgOptions().end());
    arguments.push_back("--root=" + CydiaAPT::DpkgRootDirectory());
    arguments.push_back("--admindir=" + CydiaAPT::DpkgAdminDirectory());
    arguments.push_back("--set-selections");
    const std::string name(package.installedIdentity.dpkgName);
    if (name.empty()) return false;
    const std::string input(name + (held ? " hold\n" : " install\n"));
    const CydiaRuntime::Dpkg::Result result(CydiaRuntime::PrivilegedClient::RunSelectedDpkg(arguments, -1, &input));
    transactionSnapshot_ = nil;
    std::string selection;
    CydiaRuntime::Dpkg::Runner query(CydiaAPT::DpkgQueryExecutablePath());
    const CydiaRuntime::Dpkg::Result checked(query.RunAndCapture({
        "--admindir=" + CydiaAPT::DpkgAdminDirectory(), "--show",
        "--showformat=${db:Status-Want}", name}, &selection, 64));
    const bool success(result.succeeded() && checked.succeeded() &&
        selection == (held ? "hold" : "install"));
    if (!success) [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:
        [[NSBundle mainBundle] localizedStringForKey:@"PACKAGE_HOLD_FAILED" value:@"PACKAGE_HOLD_FAILED" table:@"Actions"]
        ofType:kCydiaProgressEventTypeError] forTask:title];
    return success;
} }

- (NSArray *) packages {
    return packages_;
}

- (NSArray *) sources {
    return sourceList_;
}

- (BOOL) sourceLoadFailed {
@synchronized (self) {
    return sourceLoadFailed_;
} }

- (NSString *) sourceLoadDiagnostic {
@synchronized (self) {
    return sourceLoadDiagnostic_;
} }

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

- (bool) popErrorWithTitle:(NSString *)title diagnostics:(NSMutableArray<NSString *> *)diagnostics {
    if (!runtime_->ready()) return true;
    bool fatal(false);

    const std::vector<CydiaAPT::ErrorData> errors(apt_->drainErrors());
    for (std::vector<CydiaAPT::ErrorData>::const_iterator item(errors.begin()); item != errors.end(); ++item) {
        if (!item->warning)
            fatal = true;

        lprintf("%c:[%s]\n", item->warning ? 'W' : 'E', item->message.c_str());

        NSString *message(CydiaAPTDiagnosticMessage(*item));
        [diagnostics addObject:message];
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:(item->warning ? kCydiaProgressEventTypeWarning : kCydiaProgressEventTypeError)] forTask:title];
    }

    return fatal;
}

- (bool) popErrorWithTitle:(NSString *)title {
    return [self popErrorWithTitle:title diagnostics:nil];
}

- (bool) popErrorWithTitle:(NSString *)title forOperation:(bool)success {
    return [self popErrorWithTitle:title] || !success;
}

- (void) reloadDataWithInvocation:(NSInvocation *)invocation {
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    bool attemptedDpkgRepair(false);
  reload:
    ++era_;

    [self clearPackages];

    sourceMap_.clear();
    [sourceList_ removeAllObjects];
    sourceLoadFailed_ = NO;
    sourceLoadDiagnostic_ = nil;

    [self selectRuntimeProviderForReload];
    if (!runtime_->ready()) {
        sourceLoadFailed_ = YES;
        sourceLoadDiagnostic_ = CydiaRuntimeProviderLocalize(@"BROKEN_HELP");
        return;
    }
    apt_->discardErrors();
    apt_->reset();

    pool_.~CYPool();
    new (&pool_) CYPool();

    NSRecycleZone(zone_);
    zone_ = NSCreateZone(1024 * 1024, 256 * 1024, NO);

    int chk(creat("/tmp/cydia.chk", 0644));
    if (chk != -1)
        close(chk);

    if (invocation != nil) {
        [invocation invoke];
        invocation = nil;
    }

    NSString *title(UCLocalize("DATABASE"));

    // Registration, source targets and the cache must describe one generation.
    // The protected snapshot includes dpkg's optional arch file, so a change
    // during either discovery or cache opening cannot authorize this queue.
    transactionSnapshot_ = nil;
    NSString *openingSnapshot(CurrentTransactionSnapshot());
    if (!runtime_->external() && !CydiaAPT::RefreshArchitectures()) {
        /* Keep browsing with the last verified acquisition state while the
         * runtime separately denies all package mutations. */
        [self requirePackageChangesForTask:title];
    }

    [self recheckRepositoryTrust];

    NSMutableArray<NSString *> *sourceErrors([NSMutableArray array]);
    _profile(reloadDataWithInvocation$ReadMainList)
    const bool sourcesLoaded(apt_->loadSources());
    const bool sourceErrorsFatal([self popErrorWithTitle:title diagnostics:sourceErrors]);
    if (!sourcesLoaded || sourceErrorsFatal) {
        // The source list was cleared for this generation. Keep the failure
        // visible after the progress alert is dismissed; an empty display is
        // not evidence that the administrator's repositories were removed.
        sourceLoadFailed_ = YES;
        sourceLoadDiagnostic_ = sourceErrors.count ? [sourceErrors componentsJoinedByString:@"\n\n"] :
            CydiaRuntimeProviderLocalize(@"BROKEN_HELP");
        return;
    }
    _end

    _trace();
    bool opened;
    _profile(reloadDataWithInvocation$AptBackend$openCache)
        opened = apt_->openCache() && runtime_->AcceptOpenedCache(*apt_);
    _end
    if (!opened) {
        [sourceErrors removeAllObjects];
        // XXX: this block should probably be merged with popError: in some way
        const std::vector<CydiaAPT::ErrorData> errors(apt_->drainErrors());
        for (std::vector<CydiaAPT::ErrorData>::const_iterator item(errors.begin()); item != errors.end(); ++item) {
            const std::string &error(item->message);
            const bool warning(item->warning);

            lprintf("cache.Open():[%s]\n", error.c_str());
            NSString *message(CydiaAPTDiagnosticMessage(*item));
            [sourceErrors addObject:message];
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:(warning ? kCydiaProgressEventTypeWarning : kCydiaProgressEventTypeError)] forTask:title];

        }

        if (!attemptedDpkgRepair && DpkgJournalNeedsRecovery()) {
            attemptedDpkgRepair = true;
            apt_->discardErrors();
            [delegate_ repairWithSelector:@selector(configure)];
            goto reload;
        }

        sourceLoadFailed_ = YES;
        sourceLoadDiagnostic_ = sourceErrors.count ? [sourceErrors componentsJoinedByString:@"\n\n"] :
            CydiaRuntimeProviderLocalize(@"BROKEN_HELP");
        return;
    } else if ([self popErrorWithTitle:title forOperation:true])
        return;
    // OpenCache advances the external cache epoch. Enumerate sources only
    // after that transition so retained Source handles belong to this cache.
    std::vector<CydiaAPT::SourceHandle> sourceHandles;
    _profile(reloadDataWithInvocation$Source$initWithMetaIndex)
    sourceHandles = apt_->sourceHandles();
    for (std::vector<CydiaAPT::SourceHandle>::const_iterator source(sourceHandles.begin()); source != sourceHandles.end(); ++source) {
        Source *object([[Source alloc] initWithHandle:*source forDatabase:self inPool:&pool_]);
        [sourceList_ addObject:object];
    }
    _end

    [sourceErrors removeAllObjects];
    if ([self popErrorWithTitle:title diagnostics:sourceErrors]) {
        [sourceList_ removeAllObjects]; sourceMap_.clear();
        sourceLoadFailed_ = YES;
        sourceLoadDiagnostic_ = sourceErrors.count ? [sourceErrors componentsJoinedByString:@"\n\n"] :
            CydiaRuntimeProviderLocalize(@"BROKEN_HELP");
        return;
    }
    NSString *openedSnapshot(CurrentTransactionSnapshot());
    if (openingSnapshot != nil && [openingSnapshot isEqualToString:openedSnapshot])
        transactionSnapshot_ = openedSnapshot;
    _trace();

    unlink("/tmp/cydia.chk");

    now_ = [[NSDate date] timeIntervalSince1970];

    apt_->createCacheViews();

    CydiaAPT::CacheStateSummary cacheState(apt_->cacheState());
    if (cacheState.deletes != 0 || cacheState.installs != 0) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("COUNTS_NONZERO_EX") ofType:kCydiaProgressEventTypeError] forTask:title];
        return;
    }

    _profile(reloadDataWithInvocation$pkgApplyStatus)
    if ([self popErrorWithTitle:title forOperation:apt_->applyStatus()])
        return;
    _end

    cacheState = apt_->cacheState();
    if (cacheState.broken != 0) {
        _profile(pkgApplyStatus$pkgFixBroken)
        if ([self popErrorWithTitle:title forOperation:apt_->fixBroken()])
            return;
        _end

        cacheState = apt_->cacheState();
        if (cacheState.broken != 0) {
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("STILL_BROKEN_EX") ofType:kCydiaProgressEventTypeError] forTask:title];
            return;
        }

        _profile(pkgApplyStatus$pkgMinimizeUpgrade)
        if ([self popErrorWithTitle:title forOperation:apt_->minimizeUpgrade()])
            return;
        _end
    }

    for (size_t index(0); index != sourceHandles.size() && index != [sourceList_ count]; ++index) {
        Source *object([sourceList_ objectAtIndex:index]);
        std::vector<std::uint32_t> fileIDs(apt_->sourceFileIDs(sourceHandles[index]));
        for (std::vector<std::uint32_t>::const_iterator file(fileIDs.begin()); file != fileIDs.end(); ++file)
            sourceMap_[*file] = object;
    }

    [sourceErrors removeAllObjects];
    if ([self popErrorWithTitle:title diagnostics:sourceErrors]) {
        [sourceList_ removeAllObjects]; sourceMap_.clear();
        sourceLoadFailed_ = YES;
        sourceLoadDiagnostic_ = [sourceErrors componentsJoinedByString:@"\n\n"];
        return;
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
    DatabaseOperation operation(operationLock_);
@synchronized (self) {
    [self invalidateConfirmationReview];
    if (runtime_->ready()) apt_->clearSelections();
} }

- (CydiaRuntime::TransactionResult) lastTransactionResult { return transactionResult_; }

- (bool) configure {
    DatabaseOperation operation(operationLock_);
    transactionResult_ = CydiaRuntime::TransactionResult();
    transactionResult_.outcome = CydiaRuntime::TransactionOutcome::Failed;
    NSString *title(UCLocalize("DATABASE"));
    if (![self requirePackageChangesForTask:title]) return false;
    ConfigureFrontendLock frontend;
    if (!frontend.held()) {
        transactionResult_.outcome = CydiaRuntime::TransactionOutcome::Busy;
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("DPKG_LOCKED")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    std::vector<std::string> arguments(1, CydiaAPT::DpkgExecutablePath());
    arguments.insert(arguments.end(), CydiaAPT::DpkgOptions().begin(), CydiaAPT::DpkgOptions().end());
    arguments.push_back("--root=" + CydiaAPT::DpkgRootDirectory());
    arguments.push_back("--admindir=" + CydiaAPT::DpkgAdminDirectory());
    arguments.push_back("--configure"); arguments.push_back("-a");
    transactionResult_.packageManagerStarted = true;
    const CydiaRuntime::Dpkg::Result result(CydiaRuntime::PrivilegedClient::RunSelectedDpkg(arguments, statusfd_, nullptr));
    transactionResult_ = CydiaRuntime::ConfigureTransactionResult(result);
    if (!transactionResult_.succeeded()) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_FAILED")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    return true;
}

- (bool) clean {
    DatabaseReadOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || !runtime_->ready()) return false;
@synchronized (self) {
    NSString *title(UCLocalize("CLEAN_ARCHIVES"));
    if ([self popErrorWithTitle:title forOperation:apt_->cleanArchives()])
        return false;
    return true;
} }

- (bool) prepare {
    DatabaseOperation operation(operationLock_);
    [self invalidateConfirmationReview];
    NSString *title(UCLocalize("PREPARE_ARCHIVES"));
    if (![self requirePackageChangesForTask:title]) return false;
    if (transactionSnapshot_ == nil || ![transactionSnapshot_ isEqualToString:CurrentTransactionSnapshot()]) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_STALE")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    [self recheckRepositoryTrust];
    // External preparation needs a bound cache review and the parent's lock,
    // but the lock is released while the user reads the confirmation sheet.
    std::unique_ptr<PackageTransactionLock> transaction;
    if (runtime_->external()) {
        transaction.reset(new PackageTransactionLock(apt_));
        if (!transaction->held()) {
            if (![self popErrorWithTitle:title])
                [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("DPKG_LOCKED")
                    ofType:kCydiaProgressEventTypeError] forTask:title];
            return false;
        }
        if (![self captureConfirmationReview]) return false;
    }
    if ([self popErrorWithTitle:title forOperation:apt_->prepareArchives()]) return false;
    return runtime_->external() || [self captureConfirmationReview];
}

- (bool) perform {
    DatabaseOperation operation(operationLock_);
    transactionResult_ = CydiaRuntime::TransactionResult();
    transactionResult_.outcome = CydiaRuntime::TransactionOutcome::Failed;
    const bool substrate(RestartSubstrate_);
    RestartSubstrate_ = false;
    NSString *title(UCLocalize("PERFORM_SELECTIONS"));
    if (![self requirePackageChangesForTask:title]) return false;
    if (![self confirmedTransactionUnchanged]) {
        transactionResult_.outcome = CydiaRuntime::TransactionOutcome::Stale;
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_STALE")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    PackageTransactionLock transaction(apt_);
    if (!transaction.held()) {
        transactionResult_.outcome = CydiaRuntime::TransactionOutcome::Busy;
        [self popErrorWithTitle:title];
        return false;
    }
    auto requireUnchanged = [&]() -> bool {
        if (transactionSnapshot_ != nil && [transactionSnapshot_ isEqualToString:CurrentTransactionSnapshot()]) return true;
        transactionResult_.outcome = CydiaRuntime::TransactionOutcome::Stale;
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_STALE")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    };
    if (!requireUnchanged()) return false;
    CydiaRuntime::PrivilegedClient::Result sharedState = {};
    if (!runtime_->external()) sharedState = CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-extended-state-read", "");
    if (!runtime_->external() && !sharedState.succeeded()) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_FAILED")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    [self recheckRepositoryTrust];
    if ([self popErrorWithTitle:title forOperation:apt_->prepareArchives()]) return false;
    const CydiaAPT::TransactionData reviewed(runtime_->external() ? runtime_->review()->transaction : apt_->transactionData());
    if (!reviewed.issues.empty()) return false;
    const CydiaAPT::SourceListData before(apt_->sourceList());
    if ([self popErrorWithTitle:title forOperation:before.success]) return false;
    [delegate_ performSelectorOnMainThread:@selector(retainNetworkActivityIndicator) withObject:nil waitUntilDone:YES];
    const CydiaAPT::FetchResultData fetch(apt_->runFetcher(PulseInterval_));
    [delegate_ performSelectorOnMainThread:@selector(releaseNetworkActivityIndicator) withObject:nil waitUntilDone:YES];
    if (!fetch.completed) {
        if (status_->wasCancelled()) transactionResult_.outcome = CydiaRuntime::TransactionOutcome::Cancelled;
        else [self popErrorWithTitle:title];
        return false;
    }
    for (const CydiaAPT::FetchFailureData &failure : fetch.failures)
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:CydiaFetchDiagnosticMessage(failure)
            ofType:kCydiaProgressEventTypeError] forTask:title];
    for (const CydiaAPT::FetchFailureData &warning : fetch.warnings)
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:CydiaFetchDiagnosticMessage(warning)
            ofType:kCydiaProgressEventTypeWarning] forTask:title];
    if (!fetch.failures.empty() || !requireUnchanged()) return false;
    [self recheckRepositoryTrust];
    CydiaAPT::FetchResultData finalArchives;
    bool started(false);
    const CydiaAPT::PackageManagerResult result(apt_->runPackageManager(statusfd_, &finalArchives, &started));
    RestartSubstrate_ = started && substrate;
    transactionResult_.packageManagerStarted = started;
    if (!finalArchives.failures.empty()) {
        for (const CydiaAPT::FetchFailureData &failure : finalArchives.failures)
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:CydiaFetchDiagnosticMessage(failure)
                ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    const bool errors([self popErrorWithTitle:title]);
    const CydiaRuntime::TransactionResult executed(CydiaRuntime::PackageManagerTransactionResult(result, errors));
    if (!executed.succeeded() || !runtime_->executionComplete()) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_FAILED")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    const std::vector<CydiaAPT::AutoInstalledDelta> deltas(runtime_->external() ?
        std::vector<CydiaAPT::AutoInstalledDelta>() : apt_->autoInstalledDeltas());
    std::vector<std::string> fields = {CydiaAPT::ExtendedStatesPath(), sharedState.output};
    for (const CydiaAPT::AutoInstalledDelta &delta : deltas) {
        fields.push_back(delta.package); fields.push_back(delta.architecture);
        fields.push_back(delta.automatic ? "1" : "0");
    }
    if (!deltas.empty() && !CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-extended-state-commit",
            CydiaRuntime::Privileged::SerializeFields(fields)).succeeded()) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:SettingsMessage(@"TRANSACTION_STATE_SAVE_FAILED")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return false;
    }
    transactionSnapshot_ = nil;
    const CydiaAPT::SourceListData after(apt_->sourceList());
    if ([self popErrorWithTitle:title forOperation:after.success]) return false;
    if (before.uris != after.uris && Finish_ == 0) [self update];
    transactionResult_ = executed;
    return true;
}

- (bool) delocked {
    DatabaseOperation operation(operationLock_);
    return transactionSnapshot_ == nil || ![transactionSnapshot_ isEqualToString:CurrentTransactionSnapshot()];
}

- (bool) upgrade {
    DatabaseOperation operation(operationLock_);
    [self invalidateConfirmationReview];
    NSString *title(UCLocalize("UPGRADE"));
    if (![self requirePackageChangesForTask:title]) return false;
    if ([self popErrorWithTitle:title forOperation:apt_->prepareDistUpgrade()])
        return false;
    return true;
}

- (void) update {
    [self updateWithStatus:*status_];
}

- (void) updateWithFetchDelegate:(NSObject<FetchDelegate> *)fetchDelegate {
    if (fetchDelegate == nil) {
        [self updateWithStatus:*status_];
        return;
    }

    CydiaAPT::SourceStatus status(fetchDelegate, self);
    [self updateWithStatus:status];
}

- (void) updateWithStatus:(CydiaAPT::AcquireStatus &)status {
    DatabaseOperation operation(operationLock_);
    NSString *title(UCLocalize("REFRESHING_DATA"));
    if (!runtime_->ready()) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:CydiaRuntimeProviderLocalize(@"BROKEN_HELP")
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return;
    }
    const std::string beforeTrust(CurrentTrustContext());

    [delegate_ performSelectorOnMainThread:@selector(retainNetworkActivityIndicator) withObject:nil waitUntilDone:YES];

    CydiaAPT::UpdateResultData result(apt_->updateLists(status, PulseInterval_));
    if (!result.prepared) {
        [self popErrorWithTitle:title];
        [delegate_ performSelectorOnMainThread:@selector(releaseNetworkActivityIndicator) withObject:nil waitUntilDone:YES];
        [self recheckRepositoryTrust];
        return;
    }
    if (status.wasCancelled())
        apt_->discardErrors();
    else {
        for (const CydiaAPT::FetchFailureData &warning : result.warnings)
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
                eventWithMessage:CydiaFetchDiagnosticMessage(warning) ofType:kCydiaProgressEventTypeWarning] forTask:title];
        for (const CydiaAPT::FetchFailureData &failure : result.failures)
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
                eventWithMessage:CydiaFetchDiagnosticMessage(failure) ofType:kCydiaProgressEventTypeError] forTask:title];
        const bool failed([self popErrorWithTitle:title forOperation:result.success]);
        if (!failed && result.failures.empty()) {
            NSString *indexes(CurrentListsSnapshot());
            repositoryTrustProof_.RecordCompletedRefresh(beforeTrust, CurrentTrustContext(),
                indexes == nil ? "" : [indexes UTF8String], result.metadataComplete);
            [[NSDictionary dictionaryWithObjectsAndKeys:
                [NSDate date], @"LastUpdate",
            nil] writeToFile:CacheState_ atomically:YES];
        }
    }

    [self recheckRepositoryTrust];
    [delegate_ performSelectorOnMainThread:@selector(releaseNetworkActivityIndicator) withObject:nil waitUntilDone:YES];
}

- (void) recheckRepositoryTrust {
    NSString *indexes(CurrentListsSnapshot());
    const bool valid(repositoryTrustProof_.Matches(CurrentTrustContext(), indexes == nil ? "" : [indexes UTF8String]));
    const auto descriptor(CydiaAPT::ActiveRuntimeDescriptor());
    if (descriptor) CydiaAPT::SetRuntimeDescriptorTrustValid(descriptor->binding, valid);
    else CydiaAPT::SetCachedRepositoryTrustValid(valid);
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


@end
