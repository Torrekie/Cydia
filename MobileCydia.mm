/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

// XXX: wtf/FastMalloc.h... wtf?
#define USE_SYSTEM_MALLOC 1

/* #include Directives {{{ */
#include "CyteKit/UCPlatform.h"
#include "CyteKit/Localize.h"

#include <unicode/ustring.h>
#include "Cydia/ICUTransliterator.h"

#include <objc/objc.h>
#include <objc/runtime.h>

#include <launch.h>

#include <CoreGraphics/CoreGraphics.h>
#include <Foundation/Foundation.h>

#if 0
#define DEPLOYMENT_TARGET_MACOSX 1
#define CF_BUILDING_CF 1
#include <CoreFoundation/CFInternal.h>
#endif

#include <SystemConfiguration/SystemConfiguration.h>

#include <UIKit/UIKit.h>
#include "iPhonePrivate.h"

#include <QuartzCore/CALayer.h>

#include "CyteKit/WebCore/WebCoreThread.h"

#include <algorithm>
#include <fstream>
#include <iomanip>
#include <set>
#include <sstream>
#include <string>

#include "fdstream.hpp"

#undef ABS

#include "apt.h"
#include <apt-pkg/acquire.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/debindexfile.h>
#include <apt-pkg/debmetaindex.h>
#include <apt-pkg/error.h>
#include <apt-pkg/init.h>
#include <apt-pkg/mmap.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sha1.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/sptr.h>
#include <apt-pkg/strutl.h>
#include <apt-pkg/tagfile.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/reboot.h>

#include <dirent.h>
#include <fcntl.h>
#include <notify.h>
#include <dlfcn.h>

extern "C" {
#include <mach-o/nlist.h>
}

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <errno.h>

#include <Cytore.hpp>
#include "Sources.h"

#include "Substrate.hpp"
#include "Menes/Menes.h"

#include "CyteKit/CyteKit.h"
#include "CyteKit/RegEx.hpp"

#include "Cydia/MIMEAddress.h"
#include "Cydia/CYColor.hpp"
#include "Cydia/CYString.hpp"
#include "Cydia/Collation.hpp"
#include "Cydia/CydiaWebViewController.h"
#include "Cydia/LoadingViewController.h"
#include "Cydia/NSString+Cydia.h"
#include "Cydia/Package.h"
#include "Cydia/PackageMetadata.hpp"
#include "Cydia/Profile.hpp"
#include "Cydia/Database.h"
#include "Cydia/ProgressData.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/Relations.h"
#include "Cydia/Section.h"
#include "Cydia/Source.h"
/* }}} */

const char *common_arch=NULL;

extern NSString *Cydia_;

#define lprintf(args...) fprintf(stderr, args)

#define ForRelease 1
#define TraceLogging (1 && !ForRelease)
#define HistogramInsertionSort (0 && !ForRelease)
#define ProfileTimes (0 && !ForRelease)
#define ForSaurik (0 && !ForRelease)
#define LogBrowser (0 && !ForRelease)
#define TrackResize (0 && !ForRelease)
#define ManualRefresh (1 && !ForRelease)
#define ShowInternals (0 && !ForRelease)
#define AlwaysReload (0 && !ForRelease)

#if !TraceLogging
#undef _trace
#define _trace(args...)
#endif

#if !ProfileTimes
#undef _profile
#define _profile(name) {
#undef _end
#define _end }
#define PrintTimes() do {} while (false)
#endif

NSString *Colon_;
NSString *Elision_;
static NSString *Error_;
static NSString *Warning_;

static void (*$SBSSetInterceptsMenuButtonForever)(bool);
static NSData *(*$SBSCopyIconImagePNGDataForDisplayIdentifier)(NSString *);

static CFStringRef (*$MGCopyAnswer)(CFStringRef);

static NSString *UniqueIdentifier(UIDevice *device = nil) {
    if (kCFCoreFoundationVersionNumber < 800) // iOS 7.x
        return [device ?: [UIDevice currentDevice] uniqueIdentifier];
    else
        return CFBridgingRelease($MGCopyAnswer(CFSTR("UniqueDeviceID")));
}

static const NSUInteger UIViewAutoresizingFlexibleBoth(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);

static _finline NSString *CydiaURL(NSString *path) {
    char page[26];
    page[0] = 'h'; page[1] = 't'; page[2] = 't'; page[3] = 'p'; page[4] = 's';
    page[5] = ':'; page[6] = '/'; page[7] = '/'; page[8] = 'c'; page[9] = 'y';
    page[10] = 'd'; page[11] = 'i'; page[12] = 'a'; page[13] = '.'; page[14] = 's';
    page[15] = 'a'; page[16] = 'u'; page[17] = 'r'; page[18] = 'i'; page[19] = 'k';
    page[20] = '.'; page[21] = 'c'; page[22] = 'o'; page[23] = 'm'; page[24] = '/';
    page[25] = '\0';
    return [[NSString stringWithUTF8String:page] stringByAppendingString:path];
}

NSString *ShellEscape(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static _finline void UpdateExternalStatus(uint64_t newStatus) {
    int notify_token;
    if (notify_register_check("com.saurik.Cydia.status", &notify_token) == NOTIFY_STATUS_OK) {
        notify_set_state(notify_token, newStatus);
        notify_cancel(notify_token);
    }
    notify_post("com.saurik.Cydia.status");
}

static _finline pid_t launch_get_job_pid(const char * job)
{
    launch_data_t resp;
    launch_data_t msg;

    msg = launch_data_alloc(LAUNCH_DATA_DICTIONARY);
    if (msg == NULL) {
        return -1;
    }

    launch_data_dict_insert(msg, launch_data_new_string(job), LAUNCH_KEY_GETJOB);

    resp = launch_msg(msg);
    launch_data_free(msg);

    if (resp == NULL) {
        return -1;
    }

    if (launch_data_get_type(resp) != LAUNCH_DATA_DICTIONARY) return -1;

    launch_data_t pid_data = launch_data_dict_lookup(resp, "PID");
    if (launch_data_get_type(pid_data) != LAUNCH_DATA_INTEGER) return -1;

    pid_t pid = (pid_t)launch_data_get_integer(pid_data);
    launch_data_free(resp);
    return pid;
}

/* NSForcedOrderingSearch doesn't work on the iPhone */
static const NSStringCompareOptions MatchCompareOptions_ = NSLiteralSearch | NSCaseInsensitiveSearch;

/* Insertion Sort {{{ */

template <typename Type_>
size_t CFBSearch_(const Type_ &element, const Type_ *list, size_t count, CFComparisonResult (*comparator)(Type_, Type_, void *), void *context) {
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
void CYArrayInsertionSortValues(Type_ *values, size_t length, CFComparisonResult (*comparator)(Type_, Type_, void *), void *context) {
    if (length == 0)
        return;

#if HistogramInsertionSort > 0
    uint32_t total(0), *offsets(new uint32_t[length]);
#endif

    for (size_t index(1); index != length; ++index) {
        Type_ value(values[index]);
#if 0
        size_t correct(CFBSearch_(value, values, index, comparator, context));
#else
        size_t correct(index);
        while (comparator(value, values[correct - 1], context) == kCFCompareLessThan) {
#if HistogramInsertionSort > 1
            NSLog(@"%@ < %@", value, values[correct - 1]);
#endif
            if (--correct == 0)
                break;
            if (index - correct >= 8) {
                correct = CFBSearch_(value, values, correct, comparator, context);
                break;
            }
        }
#endif
        if (correct != index) {
#if HistogramInsertionSort
            size_t offset(index - correct);
            total += offset;
            ++offsets[offset];
            if (offset > 10)
                NSLog(@"Heavy Insertion Displacement: %u = %@", offset, value);
#endif
            for (size_t move(index); move != correct; --move)
                values[move] = values[move - 1];
            values[correct] = value;
        }
    }

#if HistogramInsertionSort > 0
    for (size_t index(0); index != range.length; ++index)
        if (offsets[index] != 0)
            NSLog(@"Insertion Displacement [%u]: %u", index, offsets[index]);
    NSLog(@"Average Insertion Displacement: %f", double(total) / range.length);
    delete [] offsets;
#endif
}

/* }}} */

@interface FBSSystemService
+(id)sharedService;
-(void)sendActions:(NSSet*)actions withResult:(id)result;
@end

typedef enum {
    None                   = 0,
    RestartRenderServer    = (1 << 0), // also relaunch backboardd
    SnapshotTransition     = (1 << 1),
    FadeToBlackTransition  = (1 << 2),
} SBSRelaunchActionStyle;

@interface SBSRelaunchAction
+(id)actionWithReason:(id)reason options:(int64_t)options targetURL:(NSURL*)url;
@end

/* Random Global Variables {{{ */
int PulseInterval_ = 500000;

static const NSString *UI_;

int Finish_;
bool UICache_ = false;
bool RestartSubstrate_;
NSArray *Finishes_;

#define SpringBoard_ "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
#define NotifyConfig_ "/etc/notify.conf"

static bool Queuing_;

static CYColor Blue_;
static CYColor Blueish_;
static CYColor Black_;
static CYColor Folder_;
static CYColor Off_;
static CYColor White_;
static CYColor Gray_;
static CYColor Green_;
static CYColor Purple_;
static CYColor Purplish_;

static UIColor *InstallingColor_;
static UIColor *RemovingColor_;

static NSInteger CydiaUserInterfaceStyle;
static UIColor *whiteIfNotDark(bool white)
{
  UIColor *color = (white) ? [UIColor whiteColor] : [UIColor blackColor];
  if (CydiaUserInterfaceStyle == UIUserInterfaceStyleDark)
  {
    color = (white) ? [UIColor blackColor] : [UIColor whiteColor];
  }
  return color;
}

static void overrideUserInterfaceStyle(NSInteger style)
{
  CydiaUserInterfaceStyle = style;
}

NSString *App_;

static BOOL Advanced_;
static BOOL Ignored_;

static _H<UIFont> Font12_;
static _H<UIFont> Font12Bold_;
static _H<UIFont> Font14_;
static _H<UIFont> Font18_;
static _H<UIFont> Font18Bold_;
static _H<UIFont> Font22Bold_;

static _H<NSString> UniqueID_;

_H<NSLocale> CollationLocale_;
_H<NSArray> CollationThumbs_;
std::vector<NSInteger> CollationOffset_;
_H<NSArray> CollationTitles_;
_H<NSArray> CollationStarts_;
UTransliterator *CollationTransl_;
//static Function<NSString *, NSString *> CollationModify_;

typedef CydiaUString ustring;
ustring CollationString_;

#define CUC const ustring &str(*reinterpret_cast<const ustring *>(rep))
#define UC ustring &str(*reinterpret_cast<ustring *>(rep))
struct UReplaceableCallbacks CollationUCalls_ = {
    .length = [](const UReplaceable *rep) -> int32_t { CUC;
        return str.size();
    },

    .charAt = [](const UReplaceable *rep, int32_t offset) -> UChar { CUC;
        //fprintf(stderr, "charAt(%d) : %d\n", offset, str.size());
        if (offset >= str.size())
            return 0xffff;
        return str[offset];
    },

    .char32At = [](const UReplaceable *rep, int32_t offset) -> UChar32 { CUC;
        //fprintf(stderr, "char32At(%d) : %d\n", offset, str.size());
        if (offset >= str.size())
            return 0xffff;
        UChar32 c;
        U16_GET(str.data(), 0, offset, str.size(), c);
        return c;
    },

    .replace = [](UReplaceable *rep, int32_t start, int32_t limit, const UChar *text, int32_t length) -> void { UC;
        //fprintf(stderr, "replace(%d, %d, %d) : %d\n", start, limit, length, str.size());
        str.replace(start, limit - start, text, length);
    },

    .extract = [](UReplaceable *rep, int32_t start, int32_t limit, UChar *dst) -> void { UC;
        //fprintf(stderr, "extract(%d, %d) : %d\n", start, limit, str.size());
        str.copy(dst, limit - start, start);
    },

    .copy = [](UReplaceable *rep, int32_t start, int32_t limit, int32_t dest) -> void { UC;
        //fprintf(stderr, "copy(%d, %d, %d) : %d\n", start, limit, dest, str.size());
        str.replace(dest, 0, str, start, limit - start);
    },
};

static CFLocaleRef Locale_;
static NSArray *Languages_;
static CGColorSpaceRef space_;

#define CacheState_ Cache("CacheState.plist")
#define SavedState_ Cache("SavedState.plist")

NSDictionary *SectionMap_;
static _H<NSDate> Backgrounded_;
static _transient NSMutableDictionary *Values_;
static _transient NSMutableDictionary *Sections_;
_H<NSMutableDictionary> Sources_;
static _transient NSNumber *Version_;
time_t now_;

static _H<NSMutableDictionary> SessionData_;
static _H<NSMutableSet> BridgedHosts_;
static _H<NSMutableSet> InsecureHosts_;

static NSString *kCydiaProgressEventTypeError = @"Error";
static NSString *kCydiaProgressEventTypeInformation = @"Information";
static NSString *kCydiaProgressEventTypeStatus = @"Status";
static NSString *kCydiaProgressEventTypeWarning = @"Warning";
/* }}} */

/* Display Helpers {{{ */
NSString *LocalizeSection(NSString *section) {
    static RegEx title_r("(.*?) \\((.*)\\)");
    if (title_r(section)) {
        NSString *parent(title_r[1]);
        NSString *child(title_r[2]);

        return [NSString stringWithFormat:UCLocalize("PARENTHETICAL"),
            LocalizeSection(parent),
            LocalizeSection(child)
        ];
    }

    return [[NSBundle mainBundle] localizedStringForKey:section value:nil table:@"Sections"];
}

NSString *Simplify(NSString *title) {
    const char *data = [title UTF8String];
    size_t size = [title lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    static RegEx square_r("\\[(.*)\\]");
    if (square_r(data, size))
        return Simplify(square_r[1]);

    static RegEx paren_r("\\((.*)\\)");
    if (paren_r(data, size))
        return Simplify(paren_r[1]);

    static RegEx title_r("(.*?) \\((.*)\\)");
    if (title_r(data, size))
        return Simplify(title_r[1]);

    return title;
}
/* }}} */

bool isSectionVisible(NSString *section) {
    NSDictionary *metadata([Sections_ objectForKey:(section ?: @"")]);
    NSNumber *hidden(metadata == nil ? nil : [metadata objectForKey:@"Hidden"]);
    return hidden == nil || ![hidden boolValue];
}

static NSString *VerifySource(NSString *href) {
    static RegEx href_r("(http(s?)://|file:///)[^# ]*");
    if (!href_r(href)) {
        [[[UIAlertView alloc]
            initWithTitle:[NSString stringWithFormat:Colon_, Error_, UCLocalize("INVALID_URL")]
            message:UCLocalize("INVALID_URL_EX")
            delegate:nil
            cancelButtonTitle:UCLocalize("OK")
            otherButtonTitles:nil
        ] show];

        return nil;
    }

    if (![href hasSuffix:@"/"])
        href = [href stringByAppendingString:@"/"];
    return href;
}

@class Cydia;

@class CYPackageController;

@protocol CydiaDelegate
- (void) returnToCydia;
- (void) saveState;
- (void) retainNetworkActivityIndicator;
- (void) releaseNetworkActivityIndicator;
- (void) clearPackage:(Package *)package;
- (void) installPackage:(Package *)package;
- (void) installPackages:(NSArray *)packages;
- (void) removePackage:(Package *)package;
- (void) beginUpdate;
- (BOOL) updating;
- (bool) requestUpdate;
- (void) distUpgrade;
- (void) loadData;
- (void) updateData;
- (void) _saveConfig;
- (void) syncData;
- (void) addSource:(NSDictionary *)source;
- (BOOL) addTrivialSource:(NSString *)href;
- (UIProgressHUD *) addProgressHUD;
- (void) removeProgressHUD:(UIProgressHUD *)hud;
- (void) showActionSheet:(UIActionSheet *)sheet fromItem:(UIBarButtonItem *)item;
- (void) reloadDataWithInvocation:(NSInvocation *)invocation;
@end
/* }}} */

/* ProgressEvent Implementation {{{ */
@implementation CydiaProgressEvent

+ (CydiaProgressEvent *) eventWithMessage:(NSString *)message ofType:(NSString *)type {
    return [[CydiaProgressEvent alloc] initWithMessage:message ofType:type];
}

+ (CydiaProgressEvent *) eventWithMessage:(NSString *)message ofType:(NSString *)type forPackage:(NSString *)package {
    CydiaProgressEvent *event([self eventWithMessage:message ofType:type]);
    [event setPackage:package];
    return event;
}

+ (CydiaProgressEvent *) eventWithMessage:(NSString *)message ofType:(NSString *)type forItemDesc:(pkgAcquire::ItemDesc &)desc {
    CydiaProgressEvent *event([self eventWithMessage:message ofType:type]);

    NSString *description([NSString stringWithUTF8String:desc.Description.c_str()]);
    NSArray *fields([description componentsSeparatedByString:@" "]);
    [event setItem:fields];

    if ([fields count] > 3) {
        [event setPackage:[fields objectAtIndex:2]];
        [event setVersion:[fields objectAtIndex:3]];
    }

    [event setURL:[NSString stringWithUTF8String:desc.URI.c_str()]];

    return event;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"item",
        @"message",
        @"package",
        @"type",
        @"url",
        @"version",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (id) initWithMessage:(NSString *)message ofType:(NSString *)type {
    if ((self = [super init]) != nil) {
        message_ = message;
        type_ = type;
    } return self;
}

- (NSString *) message {
    return message_;
}

- (NSString *) type {
    return type_;
}

- (NSArray *) item {
    return (id) item_ ?: [NSNull null];
}

- (void) setItem:(NSArray *)item {
    item_ = item;
}

- (NSString *) package {
    return (id) package_ ?: [NSNull null];
}

- (void) setPackage:(NSString *)package {
    package_ = package;
}

- (NSString *) url {
    return (id) url_ ?: [NSNull null];
}

- (void) setURL:(NSString *)url {
    url_ = url;
}

- (void) setVersion:(NSString *)version {
    version_ = version;
}

- (NSString *) version {
    return (id) version_ ?: [NSNull null];
}

- (NSString *) compound:(NSString *)value {
    if (value != nil) {
        NSString *mode(nil); {
            NSString *type([self type]);
            if ([type isEqualToString:kCydiaProgressEventTypeError])
                mode = UCLocalize("ERROR");
            else if ([type isEqualToString:kCydiaProgressEventTypeWarning])
                mode = UCLocalize("WARNING");
        }

        if (mode != nil)
            value = [NSString stringWithFormat:UCLocalize("COLON_DELIMITED"), mode, value];
    }

    return value;
}

- (NSString *) compoundMessage {
    return [self compound:[self message]];
}

- (NSString *) compoundTitle {
    NSString *title;

    if (package_ == nil)
        title = nil;
    else if (Package *package = [[Database sharedInstance] packageWithName:package_])
        title = [package name];
    else
        title = package_;

    return [self compound:title];
}

@end
/* }}} */

static void SaveConfig(NSObject *lock) {
    @synchronized (lock) {
        _trace();
        MetaFile_.Sync();
        _trace();
    }

    CFPreferencesSetMultiple((CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
        Values_, @"CydiaValues",
        Sections_, @"CydiaSections",
        (id) Sources_, @"CydiaSources",
        Version_, @"CydiaVersion",
    nil], NULL, CFSTR("com.saurik.Cydia"), kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);

    if (!CFPreferencesAppSynchronize(CFSTR("com.saurik.Cydia")))
        NSLog(@"CFPreferencesAppSynchronize(com.saurik.Cydia) == false");

    CydiaWriteSources();
}


/* Web Scripting {{{ */
@implementation CydiaObject

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

- (NSArray *) attributeKeys {
    return [[NSArray arrayWithObjects:
        @"cells",
        @"device",
        @"mcc",
        @"mnc",
        @"operator",
        @"role",
        @"version",
    nil] arrayByAddingObjectsFromArray:[super attributeKeys]];
}

- (NSString *) version {
    return Cydia_;
}

- (NSString *) device {
    return UniqueIdentifier();
}

- (NSArray *) cells {
    auto *$_CTServerConnectionCreate(reinterpret_cast<CFTypeRef (*)(void *, void *, void *)>(dlsym(RTLD_DEFAULT, "_CTServerConnectionCreate")));
    if ($_CTServerConnectionCreate == NULL)
        return nil;

    struct CTResult { int flag; int error; };
    auto *$_CTServerConnectionCellMonitorCopyCellInfo(reinterpret_cast<CTResult (*)(CFTypeRef, void *, CFArrayRef *)>(dlsym(RTLD_DEFAULT, "_CTServerConnectionCellMonitorCopyCellInfo")));
    if ($_CTServerConnectionCellMonitorCopyCellInfo == NULL)
        return nil;

    id connection(CFBridgingRelease($_CTServerConnectionCreate(NULL, NULL, NULL)));
    if (connection == nil)
        return nil;

    int count(0);
    CFArrayRef cells(NULL);
    auto result($_CTServerConnectionCellMonitorCopyCellInfo((__bridge CFTypeRef) connection, &count, &cells));
    if (result.flag != 0)
        return nil;

    return CFBridgingRelease(cells);
}

- (NSString *) mcc {
    if (CFStringRef (*$CTSIMSupportCopyMobileSubscriberCountryCode)(CFAllocatorRef) = reinterpret_cast<CFStringRef (*)(CFAllocatorRef)>(dlsym(RTLD_DEFAULT, "CTSIMSupportCopyMobileSubscriberCountryCode")))
        return CFBridgingRelease((*$CTSIMSupportCopyMobileSubscriberCountryCode)(kCFAllocatorDefault));
    return nil;
}

- (NSString *) mnc {
    if (CFStringRef (*$CTSIMSupportCopyMobileSubscriberNetworkCode)(CFAllocatorRef) = reinterpret_cast<CFStringRef (*)(CFAllocatorRef)>(dlsym(RTLD_DEFAULT, "CTSIMSupportCopyMobileSubscriberNetworkCode")))
        return CFBridgingRelease((*$CTSIMSupportCopyMobileSubscriberNetworkCode)(kCFAllocatorDefault));
    return nil;
}

- (NSString *) operator {
    if (CFStringRef (*$CTRegistrationCopyOperatorName)(CFAllocatorRef) = reinterpret_cast<CFStringRef (*)(CFAllocatorRef)>(dlsym(RTLD_DEFAULT, "CTRegistrationCopyOperatorName")))
        return CFBridgingRelease((*$CTRegistrationCopyOperatorName)(kCFAllocatorDefault));
    return nil;
}

- (NSString *) role {
    return (id) [NSNull null];
}

+ (NSString *) webScriptNameForSelector:(SEL)selector {
    if (false);
    else if (selector == @selector(addBridgedHost:))
        return @"addBridgedHost";
    else if (selector == @selector(addInsecureHost:))
        return @"addInsecureHost";
    else if (selector == @selector(addSource:::))
        return @"addSource";
    else if (selector == @selector(addTrivialSource:))
        return @"addTrivialSource";
    else if (selector == @selector(du:))
        return @"du";
    else if (selector == @selector(getAllSources))
        return @"getAllSources";
    else if (selector == @selector(getApplicationInfo:value:))
        return @"getApplicationInfoValue";
    else if (selector == @selector(getDisplayIdentifiers))
        return @"getDisplayIdentifiers";
    else if (selector == @selector(getLocalizedNameForDisplayIdentifier:))
        return @"getLocalizedNameForDisplayIdentifier";
    else if (selector == @selector(getInstalledPackages))
        return @"getInstalledPackages";
    else if (selector == @selector(getPackageById:))
        return @"getPackageById";
    else if (selector == @selector(getMetadataKeys))
        return @"getMetadataKeys";
    else if (selector == @selector(getMetadataValue:))
        return @"getMetadataValue";
    else if (selector == @selector(getSessionValue:))
        return @"getSessionValue";
    else if (selector == @selector(installPackages:))
        return @"installPackages";
    else if (selector == @selector(refreshSources))
        return @"refreshSources";
    else if (selector == @selector(saveConfig))
        return @"saveConfig";
    else if (selector == @selector(setMetadataValue::))
        return @"setMetadataValue";
    else if (selector == @selector(setSessionValue::))
        return @"setSessionValue";
    else if (selector == @selector(substitutePackageNames:))
        return @"substitutePackageNames";
    else if (selector == @selector(setToken:))
        return @"setToken";
    else
        return nil;
}

+ (BOOL) isSelectorExcludedFromWebScript:(SEL)selector {
    return [self webScriptNameForSelector:selector] == nil;
}

- (NSDictionary *) getApplicationInfo:(NSString *)display value:(NSString *)key {
    char path[1024];
    if (SBBundlePathForDisplayIdentifier(SBSSpringBoardServerPort(), [display UTF8String], path) != 0)
        return (id) [NSNull null];
    NSDictionary *info([NSDictionary dictionaryWithContentsOfFile:[[NSString stringWithUTF8String:path] stringByAppendingString:@"/Info.plist"]]);
    if (info == nil)
        return (id) [NSNull null];
    return [info objectForKey:key];
}

- (NSArray *) getDisplayIdentifiers {
    return SBSCopyApplicationDisplayIdentifiers(false, false);
}

- (NSString *) getLocalizedNameForDisplayIdentifier:(NSString *)identifier {
    return SBSCopyLocalizedApplicationNameForDisplayIdentifier(identifier) ?: (id) [NSNull null];
}

- (NSNumber *) getKernelNumber:(NSString *)name {
    const char *string([name UTF8String]);

    size_t size;
    if (sysctlbyname(string, NULL, &size, NULL, 0) == -1)
        return (id) [NSNull null];

    if (size != sizeof(int))
        return (id) [NSNull null];

    int value;
    if (sysctlbyname(string, &value, &size, NULL, 0) == -1)
        return (id) [NSNull null];

    return [NSNumber numberWithInt:value];
}

- (NSArray *) getMetadataKeys {
@synchronized (Values_) {
    return [Values_ allKeys];
} }

- (id) getMetadataValue:(NSString *)key {
@synchronized (Values_) {
    return [Values_ objectForKey:key];
} }

- (void) setMetadataValue:(NSString *)key :(NSString *)value {
@synchronized (Values_) {
    if (value == nil || value == (id) [WebUndefined undefined] || value == (id) [NSNull null])
        [Values_ removeObjectForKey:key];
    else
        [Values_ setObject:value forKey:key];
} }

- (id) getSessionValue:(NSString *)key {
@synchronized (SessionData_) {
    return [SessionData_ objectForKey:key];
} }

- (void) setSessionValue:(NSString *)key :(NSString *)value {
@synchronized (SessionData_) {
    if (value == (id) [WebUndefined undefined])
        [SessionData_ removeObjectForKey:key];
    else
        [SessionData_ setObject:value forKey:key];
} }

- (void) addBridgedHost:(NSString *)host {
@synchronized (BridgedHosts_) {
    [BridgedHosts_ addObject:host];
} }

- (void) addInsecureHost:(NSString *)host {
@synchronized (InsecureHosts_) {
    [InsecureHosts_ addObject:host];
} }

- (void) addSource:(NSString *)href :(NSString *)distribution :(WebScriptObject *)sections {
    NSMutableArray *array([NSMutableArray arrayWithCapacity:[sections count]]);

    for (NSString *section in sections)
        [array addObject:section];

    [delegate_ performSelectorOnMainThread:@selector(addSource:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"deb", @"Type",
        href, @"URI",
        distribution, @"Distribution",
        array, @"Sections",
    nil] waitUntilDone:NO];
}

- (BOOL) addTrivialSource:(NSString *)href {
    href = VerifySource(href);
    if (href == nil)
        return NO;
    [delegate_ performSelectorOnMainThread:@selector(addTrivialSource:) withObject:href waitUntilDone:NO];
    return YES;
}

- (void) refreshSources {
    [delegate_ performSelectorOnMainThread:@selector(syncData) withObject:nil waitUntilDone:NO];
}

- (void) saveConfig {
    [delegate_ performSelectorOnMainThread:@selector(_saveConfig) withObject:nil waitUntilDone:NO];
}

- (NSArray *) getAllSources {
    return [[Database sharedInstance] sources];
}

- (NSArray *) getInstalledPackages {
    Database *database([Database sharedInstance]);
@synchronized (database) {
    NSArray *packages([database packages]);
    NSMutableArray *installed([NSMutableArray arrayWithCapacity:1024]);
    for (Package *package in packages)
        if (![package uninstalled])
            [installed addObject:package];
    return installed;
} }

- (Package *) getPackageById:(NSString *)id {
    if (Package *package = [[Database sharedInstance] packageWithName:id]) {
        [package parse];
        return package;
    } else
        return (Package *) [NSNull null];
}

- (NSNumber *) du:(NSString *)path {
    NSNumber *value(nil);

    FILE *du(popen([[NSString stringWithFormat:@"/usr/libexec/cydia/cydo /usr/libexec/cydia/du -ks %@", ShellEscape(path)] UTF8String], "r"));
    if (du != NULL) {
        char line[1024];
        while (fgets(line, sizeof(line), du) != NULL) {
            size_t length(strlen(line));
            while (length != 0 && line[length - 1] == '\n')
                line[--length] = '\0';
            if (char *tab = strchr(line, '\t')) {
                *tab = '\0';
                value = [NSNumber numberWithUnsignedLong:strtoul(line, NULL, 0)];
            }
        }
        pclose(du);
    }

    return value;
}

- (void) installPackages:(NSArray *)packages {
    [delegate_ performSelectorOnMainThread:@selector(installPackages:) withObject:packages waitUntilDone:NO];
}

- (NSString *) substitutePackageNames:(NSString *)message {
    auto database([Database sharedInstance]);

    // XXX: this check is less racy than you'd expect, but this entire concept is a little awkward
    if (![database hasPackages])
        return message;

    NSMutableArray *words([[message componentsSeparatedByString:@" "] mutableCopy]);
    for (size_t i(0), e([words count]); i != e; ++i) {
        NSString *word([words objectAtIndex:i]);
        if (Package *package = [database packageWithName:word])
            [words replaceObjectAtIndex:i withObject:[package name]];
    }

    return [words componentsJoinedByString:@" "];
}

- (void) setToken:(NSString *)token {
    // XXX: the website expects this :/
}

@end
/* }}} */

@interface NSURL (CydiaSecure)
@end

@implementation NSURL (CydiaSecure)

- (bool) isCydiaSecure {
    if ([[[self scheme] lowercaseString] isEqualToString:@"https"])
        return true;

    @synchronized (InsecureHosts_) {
        if ([InsecureHosts_ containsObject:[self host]])
            return true;
    }

    return false;
}

@end

/* Cydia Browser Controller {{{ */
@implementation CydiaWebViewController

- (NSURL *) navigationURL {
    if (NSURLRequest *request = self.request)
        return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://url/%@", [[request URL] absoluteString]]];
    else
        return nil;
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
    [super webView:view didClearWindowObject:window forFrame:frame];
    [CydiaWebViewController didClearWindowObject:window forFrame:frame withCydia:cydia_];
}

+ (void) didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame withCydia:(CydiaObject *)cydia {
    WebDataSource *source([frame dataSource]);
    NSURLResponse *response([source response]);
    NSURL *url([response URL]);
    NSString *scheme([[url scheme] lowercaseString]);

    bool bridged(false);

    @synchronized (BridgedHosts_) {
        if ([scheme isEqualToString:@"file"])
            bridged = true;
        else if ([scheme isEqualToString:@"https"])
            if ([BridgedHosts_ containsObject:[url host]])
                bridged = true;
    }

    if (bridged)
        [window setValue:cydia forKey:@"cydia"];
}

- (void) _setupMail:(MFMailComposeViewController *)controller {
    [controller addAttachmentData:[NSData dataWithContentsOfFile:@"/tmp/cydia.log"] mimeType:@"text/plain" fileName:@"cydia.log"];

    system("/usr/bin/dpkg -l >/tmp/dpkgl.log");
    [controller addAttachmentData:[NSData dataWithContentsOfFile:@"/tmp/dpkgl.log"] mimeType:@"text/plain" fileName:@"dpkgl.log"];
}

- (NSURLRequest *) webView:(WebView *)view resource:(id)resource willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    return [CydiaWebViewController requestWithHeaders:[super webView:view resource:resource willSendRequest:request redirectResponse:response fromDataSource:source]];
}

- (NSURLRequest *) webThreadWebView:(WebView *)view resource:(id)resource willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    return [CydiaWebViewController requestWithHeaders:[super webThreadWebView:view resource:resource willSendRequest:request redirectResponse:response fromDataSource:source]];
}

+ (NSURLRequest *) requestWithHeaders:(NSURLRequest *)request {
    NSMutableURLRequest *copy([request mutableCopy]);

    NSURL *url([copy URL]);
    NSString *href([url absoluteString]);
    NSString *host([url host]);

    if ([href hasPrefix:@"https://cydia.saurik.com/TSS/"]) {
        if (NSString *agent = [copy valueForHTTPHeaderField:@"X-User-Agent"]) {
            [copy setValue:agent forHTTPHeaderField:@"User-Agent"];
            [copy setValue:nil forHTTPHeaderField:@"X-User-Agent"];
        }

        [copy setValue:nil forHTTPHeaderField:@"Referer"];
        [copy setValue:nil forHTTPHeaderField:@"Origin"];

        [copy setURL:[NSURL URLWithString:[@"http://gs.apple.com/TSS/" stringByAppendingString:[href substringFromIndex:29]]]];
        return copy;
    }

    if ([copy valueForHTTPHeaderField:@"X-Cydia-Cf"] == nil)
        [copy setValue:[NSString stringWithFormat:@"%.2f", kCFCoreFoundationVersionNumber] forHTTPHeaderField:@"X-Cydia-Cf"];
    if (Machine_ != NULL && [copy valueForHTTPHeaderField:@"X-Machine"] == nil)
        [copy setValue:[NSString stringWithUTF8String:Machine_] forHTTPHeaderField:@"X-Machine"];

    bool bridged; @synchronized (BridgedHosts_) {
        bridged = [BridgedHosts_ containsObject:host];
    }

    if ([url isCydiaSecure] && bridged && UniqueID_ != nil && [copy valueForHTTPHeaderField:@"X-Cydia-Id"] == nil)
        [copy setValue:UniqueID_ forHTTPHeaderField:@"X-Cydia-Id"];

    return copy;
}

- (void) setDelegate:(id)delegate {
    [super setDelegate:delegate];
    [cydia_ setDelegate:delegate];
}

- (id) init {
    if ((self = [super initWithWidth:0 ofClass:[CydiaWebViewController class]]) != nil) {
        cydia_ = [[CydiaObject alloc] initWithDelegate:self.indirect];
    } return self;
}

@end

@interface AppCacheController : CydiaWebViewController {
}

@end

@implementation AppCacheController

- (void) didReceiveMemoryWarning {
    // XXX: this doesn't work
}

- (bool) retainsNetworkActivityIndicator {
    return false;
}

@end
/* }}} */

/* Confirmation Controller {{{ */
bool DepSubstrate(const pkgCache::VerIterator &iterator) {
    if (!iterator.end())
        for (pkgCache::DepIterator dep(iterator.DependsList()); !dep.end(); ++dep) {
            if (dep->Type != pkgCache::Dep::Depends && dep->Type != pkgCache::Dep::PreDepends)
                continue;
            pkgCache::PkgIterator package(dep.TargetPkg());
            if (package.end())
                continue;
            if (strcmp(package.Name(), "mobilesubstrate") == 0 ||
                strcmp(package.Name(), "com.ex.substitute") == 0)
                return true;
        }

    return false;
}

@protocol ConfirmationControllerDelegate
- (void) cancelAndClear:(bool)clear;
- (void) confirmWithNavigationController:(UINavigationController *)navigation;
- (void) queue;
@end

@interface ConfirmationController : CydiaWebViewController {
    _transient Database *database_;

    _H<UIAlertView> essential_;

    _H<NSDictionary> changes_;
    _H<NSMutableArray> issues_;
    _H<NSDictionary> sizes_;

    BOOL substrate_;
}

- (id) initWithDatabase:(Database *)database;

@end

@implementation ConfirmationController

- (void) complete {
    if (substrate_)
        RestartSubstrate_ = true;
    [self.delegate confirmWithNavigationController:[self navigationController]];
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"remove"]) {
        if (button == [alert cancelButtonIndex])
            [self _doContinue];
        else if (button == [alert firstOtherButtonIndex]) {
            [self performSelector:@selector(complete) withObject:nil afterDelay:0];
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"unable"]) {
        [self dismissModalViewControllerAnimated:YES];
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else {
        [super alertView:alert clickedButtonAtIndex:button];
    }
}

- (void) _doContinue {
    [self.delegate cancelAndClear:NO];
    [self dismissModalViewControllerAnimated:YES];
}

- (id) invokeDefaultMethodWithArguments:(NSArray *)args {
    [self performSelectorOnMainThread:@selector(_doContinue) withObject:nil waitUntilDone:NO];
    return nil;
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
    [super webView:view didClearWindowObject:window forFrame:frame];

    [window setValue:[[NSDictionary dictionaryWithObjectsAndKeys:
        (id) changes_, @"changes",
        (id) issues_, @"issues",
        (id) sizes_, @"sizes",
        self, @"queue",
    nil] Cydia$webScriptObjectInContext:window] forKey:@"cydiaConfirm"];
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;

        NSMutableArray *installs([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *reinstalls([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *upgrades([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *downgrades([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *removes([NSMutableArray arrayWithCapacity:16]);

        bool remove(false);

        pkgCacheFile &cache([database_ cache]);
        NSArray *packages([database_ packages]);
#ifdef __arm__
        pkgDepCache::Policy *policy([database_ policy]);
#endif

        issues_ = [NSMutableArray arrayWithCapacity:4];

        for (Package *package in packages) {
            pkgCache::PkgIterator iterator([package iterator]);
            NSString *name([package id]);

            if ([package broken]) {
                NSMutableArray *reasons([NSMutableArray arrayWithCapacity:4]);

                [issues_ addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    name, @"package",
                    reasons, @"reasons",
                nil]];

                pkgCache::VerIterator ver(cache[iterator].InstVerIter(cache));
                if (ver.end())
                    continue;

                for (pkgCache::DepIterator dep(ver.DependsList()); !dep.end(); ) {
                    pkgCache::DepIterator start;
                    pkgCache::DepIterator end;
                    dep.GlobOr(start, end); // ++dep

                    if (!cache->IsImportantDep(end))
                        continue;
                    if ((cache[end] & pkgDepCache::DepGInstall) != 0)
                        continue;

                    NSMutableArray *clauses([NSMutableArray arrayWithCapacity:4]);

                    [reasons addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        [NSString stringWithUTF8String:start.DepType()], @"relationship",
                        clauses, @"clauses",
                    nil]];

                    _forever {
                        NSString *reason, *installed((NSString *) [WebUndefined undefined]);

                        pkgCache::PkgIterator target(start.TargetPkg());
                        if (target->ProvidesList != 0)
                            reason = @"missing";
                        else {
                            pkgCache::VerIterator ver(cache[target].InstVerIter(cache));
                            if (!ver.end()) {
                                reason = @"installed";
                                installed = [NSString stringWithUTF8String:ver.VerStr()];
                            } else if (!cache[target].CandidateVerIter(cache).end())
                                reason = @"uninstalled";
                            else if (target->ProvidesList == 0)
                                reason = @"uninstallable";
                            else
                                reason = @"virtual";
                        }

                        NSDictionary *version(start.TargetVer() == 0 ? (NSDictionary *) [NSNull null] : [NSDictionary dictionaryWithObjectsAndKeys:
                            [NSString stringWithUTF8String:start.CompType()], @"operator",
                            [NSString stringWithUTF8String:start.TargetVer()], @"value",
                        nil]);

                        [clauses addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            [NSString stringWithUTF8String:start.TargetPkg().Name()], @"package",
                            version, @"version",
                            reason, @"reason",
                            installed, @"installed",
                        nil]];

                        // yes, seriously. (wtf?)
                        if (start == end)
                            break;
                        ++start;
                    }
                }
            }

            pkgDepCache::StateCache &state(cache[iterator]);

            static RegEx special_r("(firmware|gsc\\..*|cy\\+.*)");

            if (state.NewInstall())
                [installs addObject:name];
            // XXX: else if (state.Install())
            else if (!state.Delete() && (state.iFlags & pkgDepCache::ReInstall) == pkgDepCache::ReInstall)
                [reinstalls addObject:name];
            // XXX: move before previous if
#ifndef __arm__
            else if (state.Upgrade() || (state.Downgrade() && state.CandidateVerIter(cache) == cache.Policy->GetCandidateVer(iterator)))
#else
            else if (state.Upgrade())
#endif
                [upgrades addObject:name];
            else if (state.Downgrade())
                [downgrades addObject:name];
            else if (!state.Delete())
                // XXX: _assert(state.Keep());
                continue;
            else if (special_r(name))
                [issues_ addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    [NSNull null], @"package",
                    [NSArray arrayWithObjects:
                        [NSDictionary dictionaryWithObjectsAndKeys:
                            @"Conflicts", @"relationship",
                            [NSArray arrayWithObjects:
                                [NSDictionary dictionaryWithObjectsAndKeys:
                                    name, @"package",
                                    [NSNull null], @"version",
                                    @"installed", @"reason",
                                nil],
                            nil], @"clauses",
                        nil],
                    nil], @"reasons",
                nil]];
            else {
                if ([package essential])
                    remove = true;
                [removes addObject:name];
            }

#ifndef __arm__
            substrate_ |= DepSubstrate(cache->GetCandidateVersion(iterator));
#else
            substrate_ |= DepSubstrate(policy->GetCandidateVer(iterator));
#endif
            substrate_ |= DepSubstrate(iterator.CurrentVer());
        }

        if (!remove)
            essential_ = nil;
        else if (Advanced_) {
            NSString *parenthetical(UCLocalize("PARENTHETICAL"));

            essential_ = [[UIAlertView alloc]
                initWithTitle:UCLocalize("REMOVING_ESSENTIALS")
                message:UCLocalize("REMOVING_ESSENTIALS_EX")
                delegate:self
                cancelButtonTitle:[NSString stringWithFormat:parenthetical, UCLocalize("CANCEL_OPERATION"), UCLocalize("SAFE")]
                otherButtonTitles:
                    [NSString stringWithFormat:parenthetical, UCLocalize("FORCE_REMOVAL"), UCLocalize("UNSAFE")],
                nil
            ];

            [essential_ setContext:@"remove"];
            [essential_ setNumberOfRows:2];
        } else {
            essential_ = [[UIAlertView alloc]
                initWithTitle:UCLocalize("UNABLE_TO_COMPLY")
                message:UCLocalize("UNABLE_TO_COMPLY_EX")
                delegate:self
                cancelButtonTitle:UCLocalize("OKAY")
                otherButtonTitles:nil
            ];

            [essential_ setContext:@"unable"];
        }

        changes_ = [NSDictionary dictionaryWithObjectsAndKeys:
            installs, @"installs",
            reinstalls, @"reinstalls",
            upgrades, @"upgrades",
            downgrades, @"downgrades",
            removes, @"removes",
        nil];

        sizes_ = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInteger:[database_ fetcher].FetchNeeded()], @"downloading",
            [NSNumber numberWithInteger:[database_ fetcher].PartialPresent()], @"resuming",
        nil];

        [self setURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/confirm/", UI_]]];
    } return self;
}

- (UIBarButtonItem *) leftButton {
    return [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CANCEL")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(cancelButtonClicked)
    ];
}

#if !AlwaysReload
- (void) applyRightButton {
    if ([issues_ count] == 0 && ![self isLoading])
        [[self navigationItem] setRightBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CONFIRM")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(confirmButtonClicked)
        ]];
    else
        [[self navigationItem] setRightBarButtonItem:nil];
}
#endif

- (void) cancelButtonClicked {
    [self.delegate cancelAndClear:YES];
    [self dismissModalViewControllerAnimated:YES];
}

#if !AlwaysReload
- (void) confirmButtonClicked {
    if (essential_ != nil)
        [essential_ show];
    else
        [self complete];
}
#endif

@end
/* }}} */

/* Progress Controller {{{ */
@interface ProgressController : CydiaWebViewController <
    ProgressDelegate
> {
    _transient Database *database_;
    _H<CydiaProgressData, 1> progress_;
    unsigned cancel_;
}

- (id) initWithDatabase:(Database *)database delegate:(id)delegate;

- (void) invoke:(NSInvocation *)invocation withTitle:(NSString *)title;

- (void) setTitle:(NSString *)title;
- (void) setCancellable:(bool)cancellable;

@end

@implementation ProgressController

- (void) dealloc {
    [database_ setProgressDelegate:nil];
}

- (UIBarButtonItem *) leftButton {
    return cancel_ == 1 ? [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CANCEL")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(cancel)
    ] : nil;
}

- (void) updateCancel {
    [super applyLeftButton];
}

- (id) initWithDatabase:(Database *)database delegate:(id)delegate {
    if ((self = [super init]) != nil) {
        database_ = database;
        self.delegate = delegate;

        [database_ setProgressDelegate:self];

        progress_ = [[CydiaProgressData alloc] init];
        [progress_ setDelegate:self];

        [self setURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/progress/", UI_]]];

        [self setPageColor:whiteIfNotDark(0)];

        [[self navigationItem] setHidesBackButton:YES];

        [self updateCancel];
    } return self;
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
    [super webView:view didClearWindowObject:window forFrame:frame];
    [window setValue:progress_ forKey:@"cydiaProgress"];
}

- (void) updateProgress {
    [self dispatchEvent:@"CydiaProgressUpdate"];
}

- (void) viewWillAppear:(BOOL)animated {
    [[[self navigationController] navigationBar] setBarStyle:UIBarStyleBlack];
    [super viewWillAppear:animated];
}

- (void) close {
    UpdateExternalStatus(0);

    if (Finish_ > 1)
        [self.delegate saveState];

    switch (Finish_) {
        case 0:
            [self.delegate returnToCydia];
        break;

        case 1:
            [self.delegate terminateWithSuccess];
            /*if ([self.delegate respondsToSelector:@selector(suspendWithAnimation:)])
                [self.delegate suspendWithAnimation:YES];
            else
                [self.delegate suspend];*/
        break;

        case 2:
            _trace();
            goto reload;

        case 3:
            _trace();
            goto reload;

        reload: {
            UIProgressHUD *hud([self.delegate addProgressHUD]);
            [hud setText:UCLocalize("LOADING")];
            [self.delegate performSelector:@selector(reloadSpringBoard) withObject:nil afterDelay:0.5];
            return;
        }

        case 4:
            _trace();
            if (void (*SBReboot)(mach_port_t) = reinterpret_cast<void (*)(mach_port_t)>(dlsym(RTLD_DEFAULT, "SBReboot")))
                SBReboot(SBSSpringBoardServerPort());
            else
                reboot2(RB_AUTOBOOT);
        break;
    }

    [super close];
}

- (void) setTitle:(NSString *)title {
    [progress_ setTitle:title];
    [self updateProgress];
}

- (UIBarButtonItem *) rightButton {
    return [[progress_ running] boolValue] ? [super rightButton] : [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CLOSE")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(close)
    ];
}

- (void) invoke:(NSInvocation *)invocation withTitle:(NSString *)title {
    UpdateExternalStatus(1);

    [progress_ setRunning:true];
    [self setTitle:title];
    // implicit updateProgress

    SHA1SumValue notifyconf; {
        FileFd file;
        if (!file.Open(NotifyConfig_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            notifyconf = sha1.Result();
        }
    }

    SHA1SumValue springlist; {
        FileFd file;
        if (!file.Open(SpringBoard_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            springlist = sha1.Result();
        }
    }

    if (invocation != nil) {
        [invocation yieldToSelector:@selector(invoke)];
        [self setTitle:@"COMPLETE"];
    }

    if (Finish_ < 4) {
        FileFd file;
        if (!file.Open(NotifyConfig_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            if (!(notifyconf == sha1.Result()))
                Finish_ = 4;
        }
    }

    if (Finish_ < 3) {
        FileFd file;
        if (!file.Open(SpringBoard_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            if (!(springlist == sha1.Result()))
                Finish_ = 3;
        }
    }

    if (Finish_ < 2) {
        if (RestartSubstrate_)
            Finish_ = 2;
    }

    RestartSubstrate_ = false;

    switch (Finish_) {
        case 0: [progress_ setFinish:UCLocalize("RETURN_TO_CYDIA")]; break; /* XXX: Maybe UCLocalize("DONE")? */
        case 1: [progress_ setFinish:UCLocalize("CLOSE_CYDIA")]; break;
        case 2: [progress_ setFinish:UCLocalize("RESTART_SPRINGBOARD")]; break;
        case 3: [progress_ setFinish:UCLocalize("RELOAD_SPRINGBOARD")]; break;
        case 4: [progress_ setFinish:UCLocalize("REBOOT_DEVICE")]; break;
    }

    UpdateExternalStatus(Finish_ == 0 ? 0 : 2);

    [progress_ setRunning:false];
    [self updateProgress];

    [self applyRightButton];
}

- (void) addProgressEvent:(CydiaProgressEvent *)event {
    [progress_ addEvent:event];
    [self updateProgress];
}

- (bool) isProgressCancelled {
    return cancel_ == 2;
}

- (void) cancel {
    cancel_ = 2;
    [self updateCancel];
}

- (void) setCancellable:(bool)cancellable {
    unsigned cancel(cancel_);

    if (!cancellable)
        cancel_ = 0;
    else if (cancel_ == 0)
        cancel_ = 1;

    if (cancel != cancel_)
        [self updateCancel];
}

- (void) setProgressCancellable:(NSNumber *)cancellable {
    [self setCancellable:[cancellable boolValue]];
}

- (void) setProgressPercent:(NSNumber *)percent {
    [progress_ setPercent:[percent floatValue]];
    [self updateProgress];
}

- (void) setProgressStatus:(NSDictionary *)status {
    if (status == nil) {
        [progress_ setCurrent:0];
        [progress_ setTotal:0];
        [progress_ setSpeed:0];
    } else {
        [progress_ setPercent:[[status objectForKey:@"Percent"] floatValue]];

        [progress_ setCurrent:[[status objectForKey:@"Current"] floatValue]];
        [progress_ setTotal:[[status objectForKey:@"Total"] floatValue]];
        [progress_ setSpeed:[[status objectForKey:@"Speed"] floatValue]];
    }

    [self updateProgress];
}

@end
/* }}} */

/* Package Cell {{{ */
@interface PackageCell : CyteTableViewCell <
    CyteTableViewCellDelegate
> {
    _H<UIImage> icon_;
    _H<NSString> name_;
    _H<NSString> description_;
    bool commercial_;
    _H<NSString> source_;
    _H<UIImage> badge_;
    _H<UIImage> placard_;
    bool summarized_;
}

- (PackageCell *) init;
- (void) setPackage:(Package *)package asSummary:(bool)summary;

- (void) drawContentRect:(CGRect)rect;

@end

@implementation PackageCell

- (PackageCell *) init {
    CGRect frame(CGRectMake(0, 0, 320, 74));
    if ((self = [super initWithFrame:frame reuseIdentifier:@"Package"]) != nil) {
        [self.content setOpaque:YES];
    } return self;
}

- (NSString *) accessibilityLabel {
    return name_;
}

- (void) setPackage:(Package *)package asSummary:(bool)summary {
    summarized_ = summary;

    icon_ = nil;
    name_ = nil;
    description_ = nil;
    source_ = nil;
    badge_ = nil;
    placard_ = nil;

    if (package == nil)
        [self.content setBackgroundColor:whiteIfNotDark(1)];
    else {
        [package parse];

        Source *source = [package source];

        icon_ = [package icon];

        if (NSString *name = [package name])
            name_ = [NSString stringWithString:name];

        if (NSString *description = [package shortDescription])
            description_ = [NSString stringWithString:description];

        commercial_ = [package isCommercial];

        NSString *label = nil;
        if (source != nil) {
            label = [source label];
        } else if ([[package id] isEqualToString:@"firmware"])
            label = UCLocalize("APPLE");
        else
            label = [NSString stringWithFormat:UCLocalize("SLASH_DELIMITED"), UCLocalize("UNKNOWN"), UCLocalize("LOCAL")];

        NSString *from(label);

        NSString *section = [package simpleSection];
        if (section != nil && ![section isEqualToString:label]) {
            section = [[NSBundle mainBundle] localizedStringForKey:section value:nil table:@"Sections"];
            from = [NSString stringWithFormat:UCLocalize("PARENTHETICAL"), from, section];
        }

        source_ = [NSString stringWithFormat:UCLocalize("FROM"), from];

        if (NSString *purpose = [package primaryPurpose])
            badge_ = [UIImage imageAtPath:[NSString stringWithFormat:@"%@/Purposes/%@.png", App_, purpose]];

        UIColor *color;
        NSString *placard;

        if (NSString *mode = [package mode]) {
            if ([mode isEqualToString:@"REMOVE"] || [mode isEqualToString:@"PURGE"]) {
                color = RemovingColor_;
                placard = @"removing";
            } else {
                color = InstallingColor_;
                placard = @"installing";
            }
        } else {
            color = whiteIfNotDark(1);

            if ([package installed] != nil)
                placard = @"installed";
            else
                placard = nil;
        }

        [self.content setBackgroundColor:color];

        if (placard != nil)
            placard_ = [UIImage imageAtPath:[NSString stringWithFormat:@"%@/%@.png", App_, placard]];
    }

    [self setNeedsDisplay];
    [self.content setNeedsDisplay];
}

- (void) drawSummaryContentRect:(CGRect)rect {
    bool highlighted(self.highlighted);
    float width([self bounds].size.width);

    if (icon_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) icon_ size];

        while (rect.size.width > 16 || rect.size.height > 16) {
            rect.size.width /= 2;
            rect.size.height /= 2;
        }

        rect.origin.x = 19 - rect.size.width / 2;
        rect.origin.y = 19 - rect.size.height / 2;

        [icon_ drawInRect:Retina(rect)];
    }

    if (badge_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) badge_ size];

        rect.size.width /= 4;
        rect.size.height /= 4;

        rect.origin.x = 25 - rect.size.width / 2;
        rect.origin.y = 25 - rect.size.height / 2;

        [badge_ drawInRect:Retina(rect)];
    }

    if (highlighted && kCFCoreFoundationVersionNumber < 800)
        UISetColor(White_);

    if (!highlighted)
        UISetColor(commercial_ ? Purple_ : Black_);
    [name_ drawAtPoint:CGPointMake(36, 8) forWidth:(width - (placard_ == nil ? 68 : 94)) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (placard_ != nil)
        [placard_ drawAtPoint:CGPointMake(width - 52, 11)];
}

- (void) drawNormalContentRect:(CGRect)rect {
    bool highlighted(self.highlighted);
    float width([self bounds].size.width);

    if (icon_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) icon_ size];

        while (rect.size.width > 32 || rect.size.height > 32) {
            rect.size.width /= 2;
            rect.size.height /= 2;
        }

        rect.origin.x = 25 - rect.size.width / 2;
        rect.origin.y = 25 - rect.size.height / 2;

        [icon_ drawInRect:Retina(rect)];
    }

    if (badge_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) badge_ size];

        rect.size.width /= 2;
        rect.size.height /= 2;

        rect.origin.x = 36 - rect.size.width / 2;
        rect.origin.y = 36 - rect.size.height / 2;

        [badge_ drawInRect:Retina(rect)];
    }

    if (highlighted && kCFCoreFoundationVersionNumber < 800)
        UISetColor(White_);

    if (!highlighted)
        UISetColor(commercial_ ? Purple_ : Black_);
    [name_ drawAtPoint:CGPointMake(48, 8) forWidth:(width - (placard_ == nil ? 80 : 106)) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];
    [source_ drawAtPoint:CGPointMake(58, 29) forWidth:(width - 95) withFont:Font12_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (!highlighted)
        UISetColor(commercial_ ? Purplish_ : Gray_);
    [description_ drawAtPoint:CGPointMake(12, 46) forWidth:(width - 46) withFont:Font14_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (placard_ != nil)
        [placard_ drawAtPoint:CGPointMake(width - 52, 9)];
}

- (void) drawContentRect:(CGRect)rect {
    if (summarized_)
        [self drawSummaryContentRect:rect];
    else
        [self drawNormalContentRect:rect];
}

@end
/* }}} */
/* Section Cell {{{ */
@interface SectionCell : CyteTableViewCell <
    CyteTableViewCellDelegate
> {
    _H<NSString> basic_;
    _H<NSString> section_;
    _H<NSString> name_;
    _H<NSString> count_;
    _H<UIImage> icon_;
    _H<UISwitch> switch_;
    BOOL editing_;
}

- (void) setSection:(Section *)section editing:(BOOL)editing;

@end

@implementation SectionCell

- (id) initWithFrame:(CGRect)frame reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithFrame:frame reuseIdentifier:reuseIdentifier]) != nil) {
        icon_ = [UIImage imageNamed:@"folder.png"];
        // XXX: this initial frame is wrong, but is fixed later
        switch_ = [[UISwitch alloc] initWithFrame:CGRectMake(218, 9, 60, 25)];
        [switch_ addTarget:self action:@selector(onSwitch:) forEvents:UIControlEventValueChanged];

        [self.content setBackgroundColor:whiteIfNotDark(1)];
    } return self;
}

- (void) onSwitch:(id)sender {
    NSMutableDictionary *metadata([Sections_ objectForKey:basic_]);
    if (metadata == nil) {
        metadata = [NSMutableDictionary dictionaryWithCapacity:2];
        [Sections_ setObject:metadata forKey:basic_];
    }

    [metadata setObject:[NSNumber numberWithBool:([switch_ isOn] == NO)] forKey:@"Hidden"];
}

- (void) setSection:(Section *)section editing:(BOOL)editing {
    if (editing != editing_) {
        if (editing_)
            [switch_ removeFromSuperview];
        else
            [self addSubview:switch_];
        editing_ = editing;
    }

    basic_ = nil;
    section_ = nil;
    name_ = nil;
    count_ = nil;

    if (section == nil) {
        name_ = UCLocalize("ALL_PACKAGES");
        count_ = nil;
    } else {
        basic_ = [section name];
        section_ = [section localized];

        name_  = section_ == nil || [section_ length] == 0 ? UCLocalize("NO_SECTION") : (NSString *) section_;
        count_ = [NSString stringWithFormat:@"%zd", [section count]];

        if (editing_)
            [switch_ setOn:(isSectionVisible(basic_) ? 1 : 0) animated:NO];
    }

    [self setAccessoryType:editing ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator];
    [self setSelectionStyle:editing ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleBlue];

    [self.content setNeedsDisplay];
}

- (void) setFrame:(CGRect)frame {
    [super setFrame:frame];

    CGRect rect([switch_ frame]);
    [switch_ setFrame:CGRectMake(frame.size.width - rect.size.width - 9, 9, rect.size.width, rect.size.height)];
}

- (NSString *) accessibilityLabel {
    return name_;
}

- (void) drawContentRect:(CGRect)rect {
    bool highlighted(self.highlighted && !editing_);

    [icon_ drawInRect:CGRectMake(7, 7, 32, 32)];

    if (highlighted && kCFCoreFoundationVersionNumber < 800)
        UISetColor(White_);

    float width(rect.size.width);
    if (editing_)
        width -= 9 + [switch_ frame].size.width;

    if (!highlighted)
        UISetColor(Black_);
    [name_ drawAtPoint:CGPointMake(48, 12) forWidth:(width - 58) withFont:Font18_ lineBreakMode:NSLineBreakByTruncatingTail];

    CGSize size = [count_ sizeWithFont:Font14_];

    UISetColor(Folder_);
    if (count_ != nil)
        [count_ drawAtPoint:CGPointMake(Retina(10 + (30 - size.width) / 2), 18) withFont:Font12Bold_];
}

@end
/* }}} */

/* File Table {{{ */
@interface FileTable : CyteListController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    _H<Package> package_;
    _H<NSString> name_;
    _H<NSMutableArray> files_;
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name;

@end

@implementation FileTable

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return files_ == nil ? 0 : [files_ count];
}

/*- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 24.0f;
}*/

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseIdentifier = @"Cell";

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithFrame:CGRectZero reuseIdentifier:reuseIdentifier];
        [cell setFont:[UIFont systemFontOfSize:16]];
    }
    [cell setText:[files_ objectAtIndex:indexPath.row]];
    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];

    return cell;
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@/files", [package_ id]]];
}

- (CGFloat) rowHeight {
    return 24;
}

- (void) releaseSubviews {
    package_ = nil;
    files_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name {
    if ((self = [super initWithTitle:UCLocalize("INSTALLED_FILES")]) != nil) {
        database_ = database;
        name_ = name;
    } return self;
}

- (bool) shouldYield {
    return false;
}

- (void) _reloadData {
    files_ = nil;

    package_ = [database_ packageWithName:name_];
    if (package_ != nil) {
        files_ = [NSMutableArray arrayWithCapacity:32];

        if (NSArray *files = [package_ files])
            [files_ addObjectsFromArray:files];

        if ([files_ count] != 0) {
            if ([[files_ objectAtIndex:0] isEqualToString:@"/."])
                [files_ removeObjectAtIndex:0];
            [files_ sortUsingSelector:@selector(compareByPath:)];

            NSMutableArray *stack = [NSMutableArray arrayWithCapacity:8];
            [stack addObject:@"/"];

            for (int i(0), e([files_ count]); i != e; ++i) {
                NSString *file = [files_ objectAtIndex:i];
                while (![file hasPrefix:[stack lastObject]])
                    [stack removeLastObject];
                NSString *directory = [stack lastObject];
                [stack addObject:[file stringByAppendingString:@"/"]];
                [files_ replaceObjectAtIndex:i withObject:[NSString stringWithFormat:@"%*s%@",
                    int(([stack count] - 2) * 3), "",
                    [file substringFromIndex:[directory length]]
                ]];
            }
        }
    }

    [super _reloadData];
}

@end
/* }}} */
/* Package Controller {{{ */
@interface CYPackageController : CydiaWebViewController <
    UIActionSheetDelegate
> {
    _transient Database *database_;
    _H<Package> package_;
    _H<NSString> name_;
    bool commercial_;
    std::vector<std::pair<_H<NSString>, _H<NSString>>> buttons_;
    _H<UIActionSheet> sheet_;
    _H<UIBarButtonItem> button_;
    _H<NSArray> versions_;
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name withReferrer:(NSString *)referrer;

@end

@implementation CYPackageController

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@", (id) name_]];
}

- (void) _clickButtonWithPackage:(Package *)package {
    [self.delegate installPackage:package];
}

- (void) _clickButtonWithName:(NSString *)name {
    if ([name isEqualToString:@"CLEAR"])
        return [self.delegate clearPackage:package_];
    else if ([name isEqualToString:@"REMOVE"])
        return [self.delegate removePackage:package_];
    else if ([name isEqualToString:@"DOWNGRADE"]) {
        sheet_ = [[UIActionSheet alloc]
            initWithTitle:nil
            delegate:self
            cancelButtonTitle:nil
            destructiveButtonTitle:nil
            otherButtonTitles:nil
        ];

        for (Package *version in (id) versions_)
            [sheet_ addButtonWithTitle:[version latest]];
        [sheet_ setContext:@"version"];

        [self.delegate showActionSheet:sheet_ fromItem:[[self navigationItem] rightBarButtonItem]];
        return;
    }

    else if ([name isEqualToString:@"INSTALL"]);
    else if ([name isEqualToString:@"REINSTALL"]);
    else if ([name isEqualToString:@"UPGRADE"]);
    else _assert(false);

    [self.delegate installPackage:package_];
}

- (void) actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)button {
    NSString *context([sheet context]);
    if (sheet_ == sheet)
        sheet_ = nil;

    if ([context isEqualToString:@"modify"]) {
        if (button != [sheet cancelButtonIndex]) {
            if (IsWildcat_)
                [self performSelector:@selector(_clickButtonWithName:) withObject:buttons_[button].first afterDelay:0];
            else
                [self _clickButtonWithName:buttons_[button].first];
        }

        [sheet dismissWithClickedButtonIndex:button animated:YES];
    } else if ([context isEqualToString:@"version"]) {
        if (button != [sheet cancelButtonIndex]) {
            Package *version([versions_ objectAtIndex:button]);
            if (IsWildcat_)
                [self performSelector:@selector(_clickButtonWithPackage:) withObject:version afterDelay:0];
            else
                [self _clickButtonWithPackage:version];
        }

        [sheet dismissWithClickedButtonIndex:button animated:YES];
    }
}

- (bool) _allowJavaScriptPanel {
    return commercial_;
}

#if !AlwaysReload
- (void) _customButtonClicked {
    if (commercial_ && self.isLoading && [package_ uninstalled])
        return [self reloadURLWithCache:NO];

    size_t count(buttons_.size());
    if (count == 0)
        return;

    if (count == 1)
        [self _clickButtonWithName:buttons_[0].first];
    else {
        NSMutableArray *buttons = [NSMutableArray arrayWithCapacity:count];
        for (const auto &button : buttons_)
            [buttons addObject:button.second];

        sheet_ = [[UIActionSheet alloc]
            initWithTitle:nil
            delegate:self
            cancelButtonTitle:nil
            destructiveButtonTitle:nil
            otherButtonTitles:nil
        ];

        for (NSString *button in buttons)
            [sheet_ addButtonWithTitle:button];
        [sheet_ setContext:@"modify"];

        [self.delegate showActionSheet:sheet_ fromItem:[[self navigationItem] rightBarButtonItem]];
    }
}

- (void) applyLoadingTitle {
    // Don't show "Loading" as the title. Ever.
}

- (UIBarButtonItem *) rightButton {
    return button_;
}
#endif

- (void) setPageColor:(UIColor *)color {
    return [super setPageColor:nil];
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name withReferrer:(NSString *)referrer {
    if ((self = [super init]) != nil) {
        database_ = database;
        name_ = name == nil ? @"" : [NSString stringWithString:name];
        [self setURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/package/%@", UI_, (id) name_]] withReferrer:referrer];
    } return self;
}

- (void) reloadData {
    [super reloadData];

    [sheet_ dismissWithClickedButtonIndex:[sheet_ cancelButtonIndex] animated:YES];
    sheet_ = nil;

    package_ = [database_ packageWithName:name_];
    versions_ = [package_ downgrades];

    buttons_.clear();

    if (package_ != nil) {
        [(Package *) package_ parse];

        commercial_ = [package_ isCommercial];

        if ([package_ mode] != nil)
            buttons_.push_back(std::make_pair(@"CLEAR", UCLocalize("CLEAR")));
        if ([package_ source] == nil);
        else if ([package_ upgradableAndEssential:NO])
            buttons_.push_back(std::make_pair(@"UPGRADE", UCLocalize("UPGRADE")));
        else if ([package_ uninstalled])
            buttons_.push_back(std::make_pair(@"INSTALL", UCLocalize("INSTALL")));
        else
            buttons_.push_back(std::make_pair(@"REINSTALL", UCLocalize("REINSTALL")));
        if (![package_ uninstalled])
            buttons_.push_back(std::make_pair(@"REMOVE", UCLocalize("REMOVE")));
        if ([versions_ count] != 0)
            buttons_.push_back(std::make_pair(@"DOWNGRADE", UCLocalize("DOWNGRADE")));
    }

    NSString *title;
    switch (buttons_.size()) {
        case 0: title = nil; break;
        case 1: title = buttons_[0].second; break;
        default: title = UCLocalize("MODIFY"); break;
    }

    button_ = [[UIBarButtonItem alloc]
        initWithTitle:title
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(customButtonClicked)
    ];
}

- (bool) isLoading {
    return commercial_ ? [super isLoading] : false;
}

@end
/* }}} */

/* Package List Controller {{{ */
@interface PackageListController : CyteListController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    unsigned era_;
    _H<NSArray> packages_;
    _H<NSArray> sections_;

    _H<NSArray> thumbs_;
    std::vector<NSInteger> offset_;

    unsigned reloading_;
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title;

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages;

@end

@implementation PackageListController

- (NSURL *) referrerURL {
    return [self navigationURL];
}

- (bool) isSummarized {
    return false;
}

- (bool) showsSections {
    return true;
}

- (void) didSelectPackage:(Package *)package {
    CYPackageController *view([[CYPackageController alloc] initWithDatabase:database_ forPackage:[package id] withReferrer:[[self referrerURL] absoluteString]]);
    [view setDelegate:self.delegate];
    [[self navigationController] pushViewController:view animated:YES];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)list {
    NSInteger count([sections_ count]);
    return count == 0 ? 1 : count;
}

- (NSString *) tableView:(UITableView *)list titleForHeaderInSection:(NSInteger)section {
    if ([sections_ count] == 0 || [[sections_ objectAtIndex:section] count] == 0)
        return nil;
    return [[sections_ objectAtIndex:section] name];
}

- (NSInteger) tableView:(UITableView *)list numberOfRowsInSection:(NSInteger)section {
    if ([sections_ count] == 0)
        return 0;
    return [[sections_ objectAtIndex:section] count];
}

- (Package *) packageAtIndexPath:(NSIndexPath *)path {
@synchronized (database_) {
    if ([database_ era] != era_)
        return nil;

    Section *section([sections_ objectAtIndex:[path section]]);
    NSInteger row([path row]);
    Package *package([packages_ objectAtIndex:([section row] + row)]);
    return package;
} }

- (UITableViewCell *) tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    PackageCell *cell((PackageCell *) [table dequeueReusableCellWithIdentifier:@"Package"]);
    if (cell == nil)
        cell = [[PackageCell alloc] init];

    Package *package([database_ packageWithName:[[self packageAtIndexPath:path] id]]);
    [cell setPackage:package asSummary:[self isSummarized]];
    return cell;
}

- (void) tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    Package *package([self packageAtIndexPath:path]);
    package = [database_ packageWithName:[package id]];
    [self didSelectPackage:package];
}

- (NSArray *) sectionIndexTitlesForTableView:(UITableView *)tableView {
    return thumbs_;
}

- (NSInteger) tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    return offset_[index];
}

- (CGFloat) rowHeight {
    return [self isSummarized] ? 38 : 73;
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title {
    if ((self = [super initWithTitle:title]) != nil) {
        database_ = database;
    } return self;
}

- (void) releaseSubviews {
    packages_ = nil;
    sections_ = nil;

    thumbs_ = nil;
    offset_.clear();

    [super releaseSubviews];
}

- (bool) shouldBlock {
    return false;
}

- (NSMutableArray *) _reloadPackages {
@synchronized (database_) {
    era_ = [database_ era];
    NSArray *packages([database_ packages]);

    return [NSMutableArray arrayWithArray:packages];
} }

- (void) _reloadData {
    if (reloading_ != 0) {
        reloading_ = 2;
        return;
    }

    NSMutableArray *packages;

  reload:
    if ([self shouldYield]) {
        do {
            UIProgressHUD *hud;

            if (![self shouldBlock])
                hud = nil;
            else {
                hud = [self.delegate addProgressHUD];
                [hud setText:UCLocalize("LOADING")];
            }

            reloading_ = 1;
            packages = [self yieldToSelector:@selector(_reloadPackages)];

            if (hud != nil)
                [self.delegate removeProgressHUD:hud];
        } while (reloading_ == 2);
    } else {
        packages = [self _reloadPackages];
    }

@synchronized (database_) {
    if (era_ != [database_ era])
        goto reload;
    reloading_ = 0;

    thumbs_ = nil;
    offset_.clear();

    packages_ = packages;

    if ([self showsSections])
        sections_ = [self sectionsForPackages:packages];
    else {
        Section *section([[Section alloc] initWithName:nil row:0 localize:NO]);
        [section setCount:[packages_ count]];
        sections_ = [NSArray arrayWithObject:section];
    }

    [super _reloadData];
}

    PrintTimes();
}

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    Section *prefix([[Section alloc] initWithName:nil row:0 localize:NO]);
    size_t end([packages count]);

    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);
    Section *section(prefix);

    thumbs_ = CollationThumbs_;
    offset_ = CollationOffset_;

    size_t offset(0);
    size_t offsets([CollationStarts_ count]);

    NSString *start([CollationStarts_ objectAtIndex:offset]);
    size_t length([start length]);

    for (size_t index(0); index != end; ++index) {
        if (start != nil) {
            Package *package([packages objectAtIndex:index]);
            NSString *name(PackageName(package, @selector(cyname)));

            //while ([start compare:name options:NSNumericSearch range:NSMakeRange(0, length) locale:CollationLocale_] != NSOrderedDescending) {
            while (StringNameCompare(start, name, length) != kCFCompareGreaterThan) {
                NSString *title([CollationTitles_ objectAtIndex:offset]);
                section = [[Section alloc] initWithName:title row:index localize:NO];
                [sections addObject:section];

                start = ++offset == offsets ? nil : [CollationStarts_ objectAtIndex:offset];
                if (start == nil)
                    break;
                length = [start length];
            }
        }

        [section addToCount];
    }

    for (; offset != offsets; ++offset) {
        NSString *title([CollationTitles_ objectAtIndex:offset]);
        Section *section([[Section alloc] initWithName:title row:end localize:NO]);
        [sections addObject:section];
    }

    if ([prefix count] != 0) {
        Section *suffix([sections lastObject]);
        [prefix setName:[suffix name]];
        [suffix setName:nil];
        [sections insertObject:prefix atIndex:(offsets - 1)];
    }

    return sections;
}

@end
/* }}} */
/* Filtered Package List Controller {{{ */
typedef Function<bool, Package *> PackageFilter;
typedef Function<void, NSMutableArray *> PackageSorter;
@interface FilteredPackageListController : PackageListController {
    PackageFilter filter_;
    PackageSorter sorter_;
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title filter:(PackageFilter)filter;

- (void) setFilter:(PackageFilter)filter;
- (void) setSorter:(PackageSorter)sorter;

@end

@implementation FilteredPackageListController

- (void) setFilter:(PackageFilter)filter {
@synchronized (self) {
    filter_ = filter;
} }

- (void) setSorter:(PackageSorter)sorter {
@synchronized (self) {
    sorter_ = sorter;
} }

- (NSMutableArray *) _reloadPackages {
@synchronized (database_) {
    era_ = [database_ era];

    NSArray *packages([database_ packages]);
    NSMutableArray *filtered([NSMutableArray arrayWithCapacity:[packages count]]);

    PackageFilter filter;
    PackageSorter sorter;

    @synchronized (self) {
        filter = filter_;
        sorter = sorter_;
    }

    _profile(PackageTable$reloadData$Filter)
        for (Package *package in packages)
            if (filter(package))
                [filtered addObject:package];
    _end

    if (sorter)
        sorter(filtered);
    return filtered;
} }

- (id) initWithDatabase:(Database *)database title:(NSString *)title filter:(PackageFilter)filter {
    if ((self = [super initWithDatabase:database title:title]) != nil) {
        [self setFilter:filter];
    } return self;
}

@end
/* }}} */

/* Home Controller {{{ */
@interface HomeController : CydiaWebViewController {
    CFRunLoopRef runloop_;
    SCNetworkReachabilityRef reachability_;
}

@end

@implementation HomeController

static void HomeControllerReachabilityCallback(SCNetworkReachabilityRef reachability, SCNetworkReachabilityFlags flags, void *info) {
    [(__bridge HomeController *) info dispatchEvent:@"CydiaReachabilityCallback"];
}

- (id) init {
    if ((self = [super init]) != nil) {
        [self setURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/home/", UI_]]];
        [self reloadData];

        reachability_ = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, "cydia.saurik.com");
        if (reachability_ != NULL) {
            SCNetworkReachabilityContext context = {0, (__bridge void *) self, NULL, NULL, NULL};
            SCNetworkReachabilitySetCallback(reachability_, HomeControllerReachabilityCallback, &context);

            CFRunLoopRef runloop(CFRunLoopGetCurrent());
            if (SCNetworkReachabilityScheduleWithRunLoop(reachability_, runloop, kCFRunLoopDefaultMode))
                runloop_ = runloop;
        }
    } return self;
}

- (void) dealloc {
    if (reachability_ != NULL && runloop_ != NULL)
        SCNetworkReachabilityUnscheduleFromRunLoop(reachability_, runloop_, kCFRunLoopDefaultMode);
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://home"];
}

- (void) aboutButtonClicked {
    UIAlertView *alert([[UIAlertView alloc] init]);

    [alert setTitle:UCLocalize("ABOUT_CYDIA")];
    [alert addButtonWithTitle:UCLocalize("CLOSE")];
    [alert setCancelButtonIndex:0];

    [alert setMessage:
        @"Original work Copyright \u00a9 2008-2017\n"
        "SaurikIT, LLC\n"
        "\n"
        "Jay Freeman (saurik)\n"
        "saurik@saurik.com\n"
        "http://www.saurik.com/\n\n"
        "Modified work Copyright \u00a9 2018\n"
        "SB Designs, INC\n"
        "\n"
        "Sam Bingner (sbingner)\n"
        "sam@bingner.com\n"
        "http://www.bingner.com/"
    ];

    [alert show];
}

- (UIBarButtonItem *) leftButton {
    return [[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("ABOUT")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(aboutButtonClicked)
    ];
}

@end
/* }}} */

/* Cydia Tab Bar Controller {{{ */
@interface CydiaTabBarController : CyteTabBarController <
    UITabBarControllerDelegate,
    FetchDelegate
> {
    _transient Database *database_;

    _H<UIActivityIndicatorView> indicator_;

    bool updating_;
    // XXX: ok, "updatedelegate_"?...
    _transient NSObject<CydiaDelegate> *updatedelegate_;
}

- (void) beginUpdate;
- (BOOL) updating;

@end

@implementation CydiaTabBarController

- (id) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;
        [self setDelegate:self];

        indicator_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteTiny];
        [indicator_ setOrigin:CGPointMake(kCFCoreFoundationVersionNumber >= 800 ? 2 : 4, 2)];

        [[self view] setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    } return self;
}

- (void) beginUpdate {
    if (updating_)
        return;

    UIViewController *controller([[self viewControllers] objectAtIndex:1]);
    UITabBarItem *item([controller tabBarItem]);

    [item setBadgeValue:@""];
    UIView *badge(MSHookIvar<UIView *>([item view], "_badge"));

    [indicator_ startAnimating];
    [badge addSubview:indicator_];

    [updatedelegate_ retainNetworkActivityIndicator];
    updating_ = true;

    [NSThread
        detachNewThreadSelector:@selector(performUpdate)
        toTarget:self
        withObject:nil
    ];
}

- (void) performUpdate {
    @autoreleasepool {

    SourceStatus status(self, database_);
    [database_ updateWithStatus:status];

    [self
        performSelectorOnMainThread:@selector(completeUpdate)
        withObject:nil
        waitUntilDone:NO
    ];
    }
}

- (void) stopUpdateWithSelector:(SEL)selector {
    updating_ = false;
    [updatedelegate_ releaseNetworkActivityIndicator];

    UIViewController *controller([[self viewControllers] objectAtIndex:1]);
    [[controller tabBarItem] setBadgeValue:nil];

    [indicator_ removeFromSuperview];
    [indicator_ stopAnimating];

    [updatedelegate_ performSelector:selector withObject:nil afterDelay:0];
}

- (void) completeUpdate {
    if (!updating_)
        return;
    [self stopUpdateWithSelector:@selector(reloadData)];
}

- (void) cancelUpdate {
    [self stopUpdateWithSelector:@selector(updateDataAndLoad)];
}

- (void) cancelPressed {
    [self cancelUpdate];
}

- (BOOL) updating {
    return updating_;
}

- (bool) isSourceCancelled {
    return !updating_;
}

- (void) startSourceFetch:(NSString *)uri {
}

- (void) stopSourceFetch:(NSString *)uri {
}

- (void) setUpdateDelegate:(id)delegate {
    updatedelegate_ = delegate;
}

@end
/* }}} */

/* Cydia:// Protocol {{{ */
@interface CydiaURLProtocol : CyteURLProtocol {
}

@end

@implementation CydiaURLProtocol

+ (NSString *) scheme {
    return @"cydia";
}

- (bool) loadForPath:(NSString *)path ofRequest:(NSURLRequest *)request {
    NSRange slash([path rangeOfString:@"/"]);

    NSString *command;
    if (slash.location == NSNotFound) {
        command = path;
        path = nil;
    } else {
        command = [path substringToIndex:slash.location];
        path = [path substringFromIndex:(slash.location + 1)];
    }

    Database *database([Database sharedInstance]);

    if (false);
    else if ([command isEqualToString:@"application-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        UIImage *icon(nil);

        if (icon == nil && $SBSCopyIconImagePNGDataForDisplayIdentifier != NULL) {
            NSData *data($SBSCopyIconImagePNGDataForDisplayIdentifier(path));
            icon = [UIImage imageWithData:data];
        }

        if (icon == nil)
            if (NSString *file = SBSCopyIconImagePathForDisplayIdentifier(path))
                icon = [UIImage imageAtPath:file];

        if (icon == nil)
            icon = [UIImage imageNamed:@"unknown.png"];

        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"package-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        Package *package([database packageWithName:path]);
        if (package == nil)
            goto fail;
        [package parse];
        UIImage *icon([package icon]);
        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"uikit-image"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        UIImage *icon(_UIImageWithName(path));
        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"section-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        UIImage *icon([UIImage imageAtPath:[NSString stringWithFormat:@"%@/Sections/%@.png", App_, [path stringByReplacingOccurrencesOfString:@" " withString:@"_"]]]);
        if (icon == nil)
            icon = [UIImage imageNamed:@"unknown.png"];
        [self _returnPNGWithImage:icon forRequest:request];
    } else fail: {
        return [super loadForPath:path ofRequest:request];
    }

    return true;
}

@end
/* }}} */

/* Section Controller {{{ */
@interface SectionController : FilteredPackageListController {
    _H<NSString> key_;
    _H<NSString> section_;
}

- (id) initWithDatabase:(Database *)database source:(Source *)source section:(NSString *)section;

@end

@implementation SectionController

- (NSURL *) referrerURL {
    NSString *name(section_);
    name = name ?: @"*";
    NSString *key(key_);
    key = key ?: @"*";
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/sections/%@/%@", UI_, [key stringByAddingPercentEscapesIncludingReserved], [name stringByAddingPercentEscapesIncludingReserved]]];
}

- (NSURL *) navigationURL {
    NSString *name(section_);
    name = name ?: @"*";
    NSString *key(key_);
    key = key ?: @"*";
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://sections/%@/%@", [key stringByAddingPercentEscapesIncludingReserved], [name stringByAddingPercentEscapesIncludingReserved]]];
}

- (id) initWithDatabase:(Database *)database source:(Source *)source section:(NSString *)section {
    NSString *title;
    if (section == nil)
        title = UCLocalize("ALL_PACKAGES");
    else if (![section isEqual:@""])
        title = [[NSBundle mainBundle] localizedStringForKey:Simplify(section) value:nil table:@"Sections"];
    else
        title = UCLocalize("NO_SECTION");

    if ((self = [super initWithDatabase:database title:title]) != nil) {
        key_ = [source key];
        section_ = section;
    } return self;
}

- (void) reloadData {
    Source *source([database_ sourceWithKey:key_]);
    _H<NSString> name(section_);

    [self setFilter:[=](Package *package) {
        NSString *section([package section]);

        return (
            name == nil ||
            section == nil && [name length] == 0 ||
            [name isEqualToString:section]
        ) && (
            source == nil ||
            [package source] == source
        ) && [package visible];
    }];

    [super reloadData];
}

@end
/* }}} */
/* Sections Controller {{{ */
@interface SectionsController : CyteViewController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    _H<NSString> key_;
    _H<NSMutableArray> sections_;
    _H<NSMutableArray> filtered_;
    _H<UITableView, 2> list_;
}

- (id) initWithDatabase:(Database *)database source:(Source *)source;
- (void) editButtonClicked;

@end

@implementation SectionsController

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://sources/%@", [key_ stringByAddingPercentEscapesIncludingReserved]]];
}

- (Source *) source {
    if (key_ == nil)
        return nil;
    return [database_ sourceWithKey:key_];
}

- (void) updateNavigationItem {
    [[self navigationItem] setTitle:[self isEditing] ? UCLocalize("SECTION_VISIBILITY") : UCLocalize("SECTIONS")];
    if ([sections_ count] == 0) {
        [[self navigationItem] setRightBarButtonItem:nil];
    } else {
        [[self navigationItem] setRightBarButtonItem:[[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:([self isEditing] ? UIBarButtonSystemItemDone : UIBarButtonSystemItemEdit)
            target:self
            action:@selector(editButtonClicked)
        ] animated:([[self navigationItem] rightBarButtonItem] != nil)];
    }
}

- (void) setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];

    if (editing)
        [list_ reloadData];
    else
        [self.delegate updateData];

    [self updateNavigationItem];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [list_ deselectRowAtIndexPath:[list_ indexPathForSelectedRow] animated:animated];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self setEditing:NO];
}

- (Section *) sectionAtIndexPath:(NSIndexPath *)indexPath {
    Section *section = nil;
    int index = [indexPath row];
    if (![self isEditing]) {
        index -= 1;
        if (index >= 0)
            section = [filtered_ objectAtIndex:index];
    } else {
        section = [sections_ objectAtIndex:index];
    }
    return section;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self isEditing])
        return [sections_ count];
    else
        return [filtered_ count] + 1;
}

/*- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 45.0f;
}*/

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseIdentifier = @"SectionCell";

    SectionCell *cell = (SectionCell *)[tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (cell == nil)
        cell = [[SectionCell alloc] initWithFrame:CGRectZero reuseIdentifier:reuseIdentifier];

    [cell setSection:[self sectionAtIndexPath:indexPath] editing:[self isEditing]];

    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isEditing])
        return;

    Section *section = [self sectionAtIndexPath:indexPath];

    SectionController *controller = [[SectionController alloc]
        initWithDatabase:database_
        source:[self source]
        section:[section name]
    ];
    [controller setDelegate:self.delegate];

    [[self navigationController] pushViewController:controller animated:YES];
}

- (void) loadView {
    list_ = [[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]];
    if ([list_ respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        [list_ setCellLayoutMarginsFollowReadableWidth:NO];
    [list_ setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    [list_ setRowHeight:46];
    [(UITableView *) list_ setDataSource:self];
    [list_ setDelegate:self];
    [self setView:list_];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    overrideUserInterfaceStyle(self.traitCollection.userInterfaceStyle);
    [[self navigationItem] setTitle:UCLocalize("SECTIONS")];
}

- (void) releaseSubviews {
    list_ = nil;

    sections_ = nil;
    filtered_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database source:(Source *)source {
    if ((self = [super init]) != nil) {
        database_ = database;
        key_ = [source key];
    } return self;
}

- (void) reloadData {
    [super reloadData];

    NSArray *packages = [database_ packages];

    sections_ = [NSMutableArray arrayWithCapacity:16];
    filtered_ = [NSMutableArray arrayWithCapacity:16];

    NSMutableDictionary *sections([NSMutableDictionary dictionaryWithCapacity:32]);

    Source *source([self source]);

    _trace();
    for (Package *package in packages) {
        if (source != nil && [package source] != source)
            continue;

        NSString *name([package section]);
        NSString *key(name == nil ? @"" : name);

        Section *section;

        _profile(SectionsView$reloadData$Section)
            section = [sections objectForKey:key];
            if (section == nil) {
                _profile(SectionsView$reloadData$Section$Allocate)
                    section = [[Section alloc] initWithName:key localize:YES];
                    [sections setObject:section forKey:key];
                _end
            }
        _end

        [section addToCount];

        _profile(SectionsView$reloadData$Filter)
            if (![package visible])
                continue;
        _end

        [section addToRow];
    }
    _trace();

    [sections_ addObjectsFromArray:[sections allValues]];

    [sections_ sortUsingSelector:@selector(compareByLocalized:)];

    for (Section *sourceSection in (id) sections_) {
        size_t count([sourceSection row]);
        if (count == 0)
            continue;

        Section *section = [[Section alloc] initWithName:[sourceSection name] localized:[sourceSection localized]];
        [section setCount:count];
        [filtered_ addObject:section];
    }

    [self updateNavigationItem];
    [list_ reloadData];
    _trace();
}

- (void) editButtonClicked {
    [self setEditing:![self isEditing] animated:YES];
}

@end
/* }}} */

/* Changes Controller {{{ */
@interface ChangesController : FilteredPackageListController {
}

- (id) initWithDatabase:(Database *)database;

@end

@implementation ChangesController

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/changes/", UI_]];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://changes"];
}

- (Package *) packageAtIndexPath:(NSIndexPath *)path {
@synchronized (database_) {
    if ([database_ era] != era_)
        return nil;

    NSUInteger sectionIndex([path section]);
    if (sectionIndex >= [sections_ count])
        return nil;
    Section *section([sections_ objectAtIndex:sectionIndex]);
    NSInteger row([path row]);
    return [packages_ objectAtIndex:([section row] + row)];
} }

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"norefresh"])
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
}

- (void) setLeftBarButtonItem {
    if ([self.delegate updating])
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CANCEL")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(cancelButtonClicked)
        ] animated:YES];
    else
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("REFRESH")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(refreshButtonClicked)
        ] animated:YES];
}

- (void) refreshButtonClicked {
    if ([self.delegate requestUpdate])
        [self setLeftBarButtonItem];
}

- (void) cancelButtonClicked {
    [self.delegate cancelUpdate];
}

- (void) upgradeButtonClicked {
    [self.delegate distUpgrade];
    [[self navigationItem] setRightBarButtonItem:nil animated:YES];
}

- (bool) shouldYield {
    return true;
}

- (bool) shouldBlock {
    return true;
}

- (void) useFilter {
@synchronized (self) {
    [self setFilter:[](Package *package) {
        return [package upgradableAndEssential:YES] || [package visible];
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingFunction:reinterpret_cast<MenesRadixSortFunction>(&PackageChangesRadix) withContext:NULL];
    }];
} }

- (id) initWithDatabase:(Database *)database {
    if ((self = [super initWithDatabase:database title:UCLocalize("CHANGES")]) != nil) {
        [self useFilter];
    } return self;
}

- (void) viewDidLoad {
    [super viewDidLoad];
    overrideUserInterfaceStyle(self.traitCollection.userInterfaceStyle);
    [self setLeftBarButtonItem];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setLeftBarButtonItem];
}

- (void) reloadData {
    [self setLeftBarButtonItem];
    [super reloadData];
}

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);

    Section *upgradable = [[Section alloc] initWithName:UCLocalize("AVAILABLE_UPGRADES") localize:NO];
    Section *ignored = nil;
    Section *section = nil;
    time_t last = 0;

    size_t upgrades_ = 0;
    bool unseens = false;

    CFDateFormatterRef formatter(CFDateFormatterCreate(NULL, Locale_, kCFDateFormatterMediumStyle, kCFDateFormatterMediumStyle));

    for (size_t offset = 0, count = [packages count]; offset != count; ++offset) {
        Package *package = [packages objectAtIndex:offset];

        BOOL uae = [package upgradableAndEssential:YES];

        if (!uae) {
            unseens = true;
            time_t seen([package seen]);

            if (section == nil || last != seen) {
                last = seen;

                NSString *name;
                name = CFBridgingRelease(CFDateFormatterCreateStringWithDate(NULL, formatter, (CFDateRef) [NSDate dateWithTimeIntervalSince1970:seen]));

                _profile(ChangesController$reloadData$Allocate)
                    name = [NSString stringWithFormat:UCLocalize("NEW_AT"), name];
                    section = [[Section alloc] initWithName:name row:offset localize:NO];
                    [sections addObject:section];
                _end
            }

            [section addToCount];
        } else if ([package ignored]) {
            if (ignored == nil) {
                ignored = [[Section alloc] initWithName:UCLocalize("IGNORED_UPGRADES") row:offset localize:NO];
            }
            [ignored addToCount];
        } else {
            ++upgrades_;
            [upgradable addToCount];
        }
    }
    _trace();

    CFRelease(formatter);

    if (unseens) {
        Section *last = [sections lastObject];
        size_t count = [last count];
        [packages removeObjectsInRange:NSMakeRange([packages count] - count, count)];
        [sections removeLastObject];
    }

    if ([ignored count] != 0)
        [sections insertObject:ignored atIndex:0];
    if (upgrades_ != 0)
        [sections insertObject:upgradable atIndex:0];

    [[self navigationItem] setRightBarButtonItem:(upgrades_ == 0 ? nil : [[UIBarButtonItem alloc]
        initWithTitle:[NSString stringWithFormat:UCLocalize("PARENTHETICAL"), UCLocalize("UPGRADE"), [NSString stringWithFormat:@"%zu", upgrades_]]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(upgradeButtonClicked)
    ]) animated:YES];

    return sections;
}

@end
/* }}} */
/* Search Controller {{{ */
@interface SearchController : FilteredPackageListController <
    UISearchBarDelegate
> {
    _H<UISearchBar, 1> search_;
    BOOL searchloaded_;
    bool summary_;
}

- (id) initWithDatabase:(Database *)database query:(NSString *)query;
- (void) reloadData;

@end

@implementation SearchController

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/search?q=%@", UI_, [([search_ text] ?: @"") stringByAddingPercentEscapesIncludingReserved]]];
}

- (NSURL *) navigationURL {
    if ([search_ text] == nil || [[search_ text] isEqualToString:@""])
        return [NSURL URLWithString:@"cydia://search"];
    else
        return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://search/%@", [[search_ text] stringByAddingPercentEscapesIncludingReserved]]];
}

- (NSArray *) termsForQuery:(NSString *)query {
    NSMutableArray *terms([NSMutableArray arrayWithCapacity:2]);
    for (NSString *component in [query componentsSeparatedByString:@" "])
        if ([component length] != 0)
            [terms addObject:component];

    return terms;
}

- (void) useSearch {
    _H<NSArray> query([self termsForQuery:[search_ text]]);
    summary_ = false;

@synchronized (self) {
    [self setFilter:[=](Package *package) {
        if (![package unfiltered])
            return false;
        if (![package matches:query])
            return false;
        return true;
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingSelector:@selector(rank)];
    }];
}

    [self clearData];
    [self reloadData];
}

- (void) usePrefix:(NSString *)prefix {
    _H<NSString> query(prefix);
    summary_ = true;

@synchronized (self) {
    [self setFilter:[=](Package *package) {
        if ([query length] == 0)
            return false;
        if (![package unfiltered])
            return false;
        if ([query length] > [[package name] length])
            return false;
        if ([[package name] compare:query options:MatchCompareOptions_ range:NSMakeRange(0, [query length])] != NSOrderedSame)
            return false;
        return true;
    }];

    [self setSorter:nullptr];
}

    [self reloadData];
}

- (void) searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [self clearData];
    [self usePrefix:[search_ text]];
}

- (void) searchBarButtonClicked:(UISearchBar *)searchBar {
    [search_ resignFirstResponder];
    [self useSearch];
}

- (void) searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [search_ setText:@""];
    [self searchBarButtonClicked:searchBar];
}

- (void) searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self searchBarButtonClicked:searchBar];
}

- (void) searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    [self usePrefix:text];
}

- (bool) shouldYield {
    return YES;
}

- (bool) shouldBlock {
    return !summary_;
}

- (bool) isSummarized {
    return summary_;
}

- (bool) showsSections {
    return false;
}

- (id) initWithDatabase:(Database *)database query:(NSString *)query {
    if ((self = [super initWithDatabase:database title:UCLocalize("SEARCH")])) {
        search_ = [[UISearchBar alloc] init];
        [search_ setPlaceholder:UCLocalize("SEARCH_EX")];
        [search_ setDelegate:self];

        UITextField *textField;
        if ([search_ respondsToSelector:@selector(searchField)])
            textField = [search_ searchField];
        else
            textField = MSHookIvar<UITextField *>(search_, "_searchField");

        [textField setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin];
        [textField setEnablesReturnKeyAutomatically:NO];
        [[self navigationItem] setTitleView:textField];

        if (query != nil)
            [search_ setText:query];
        [self useSearch];
    } return self;
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (!searchloaded_) {
        searchloaded_ = YES;
        [search_ setFrame:CGRectMake(0, 0, [[self view] bounds].size.width, 44.0f)];
        [search_ layoutSubviews];
    }

    if ([self isSummarized])
        [search_ becomeFirstResponder];
}

- (void) reloadData {
    [self resetCursor];
    [super reloadData];
}

- (void) didSelectPackage:(Package *)package {
    [search_ resignFirstResponder];
    [super didSelectPackage:package];
}

@end
/* }}} */
/* Package Settings Controller {{{ */
@interface PackageSettingsController : CyteViewController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    _H<NSString> name_;
    _H<Package> package_;
    _H<UITableView, 2> table_;
    _H<UISwitch> subscribedSwitch_;
    _H<UISwitch> ignoredSwitch_;
    _H<UITableViewCell> subscribedCell_;
    _H<UITableViewCell> ignoredCell_;
}

- (id) initWithDatabase:(Database *)database package:(NSString *)package;

@end

@implementation PackageSettingsController

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@/settings", (id) name_]];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    if (package_ == nil)
        return 0;

    if ([package_ installed] == nil)
        return 1;
    else
        return 2;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (package_ == nil)
        return 0;

    // both sections contain just one item right now.
    return 1;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return nil;
}

- (NSString *) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return UCLocalize("SHOW_ALL_CHANGES_EX");
    else
        return UCLocalize("IGNORE_UPGRADES_EX");
}

- (void) onSubscribed:(id)control {
    bool value([control isOn]);
    if (package_ == nil)
        return;
    if ([package_ setSubscribed:value])
        [self.delegate updateData];
}

- (void) _updateIgnored {
    const char *package([name_ UTF8String]);
    bool on([ignoredSwitch_ isOn]);

    FILE *dpkg(popen("/usr/libexec/cydia/cydo --set-selections", "w"));
    fwrite(package, strlen(package), 1, dpkg);

    if (on)
        fwrite(" hold\n", 6, 1, dpkg);
    else
        fwrite(" install\n", 9, 1, dpkg);

    pclose(dpkg);
}

- (void) onIgnored:(id)control {
    NSInvocation *invocation([NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(_updateIgnored)]]);
    [invocation setTarget:self];
    [invocation setSelector:@selector(_updateIgnored)];

    [self.delegate reloadDataWithInvocation:invocation];
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (package_ == nil)
        return nil;

    switch ([indexPath section]) {
        case 0: return subscribedCell_;
        case 1: return ignoredCell_;

        _nodefault
    }

    return nil;
}

- (void) loadView {
    UIView *view([[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]]);
    [view setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    [self setView:view];

    table_ = [[UITableView alloc] initWithFrame:[[self view] bounds] style:UITableViewStyleGrouped];
    if ([table_ respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        [table_ setCellLayoutMarginsFollowReadableWidth:NO];
    [table_ setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    [(UITableView *) table_ setDataSource:self];
    [table_ setDelegate:self];
    [view addSubview:table_];

    subscribedSwitch_ = [[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 50, 20)];
    [subscribedSwitch_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [subscribedSwitch_ addTarget:self action:@selector(onSubscribed:) forEvents:UIControlEventValueChanged];

    ignoredSwitch_ = [[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 50, 20)];
    [ignoredSwitch_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [ignoredSwitch_ addTarget:self action:@selector(onIgnored:) forEvents:UIControlEventValueChanged];

    subscribedCell_ = [[UITableViewCell alloc] init];
    [subscribedCell_ setText:UCLocalize("SHOW_ALL_CHANGES")];
    [subscribedCell_ setAccessoryView:subscribedSwitch_];
    [subscribedCell_ setSelectionStyle:UITableViewCellSelectionStyleNone];

    ignoredCell_ = [[UITableViewCell alloc] init];
    [ignoredCell_ setText:UCLocalize("IGNORE_UPGRADES")];
    [ignoredCell_ setAccessoryView:ignoredSwitch_];
    [ignoredCell_ setSelectionStyle:UITableViewCellSelectionStyleNone];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    overrideUserInterfaceStyle(self.traitCollection.userInterfaceStyle);
    [[self navigationItem] setTitle:UCLocalize("SETTINGS")];
}

- (void) releaseSubviews {
    ignoredCell_ = nil;
    subscribedCell_ = nil;
    table_ = nil;
    ignoredSwitch_ = nil;
    subscribedSwitch_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database package:(NSString *)package {
    if ((self = [super init]) != nil) {
        database_ = database;
        name_ = package;
    } return self;
}

- (void) reloadData {
    [super reloadData];

    package_ = [database_ packageWithName:name_];

    if (package_ != nil) {
        [subscribedSwitch_ setOn:([package_ subscribed] ? 1 : 0) animated:NO];
        [ignoredSwitch_ setOn:([package_ ignored] ? 1 : 0) animated:NO];
    } // XXX: what now, G?

    [table_ reloadData];
}

@end
/* }}} */

/* Installed Controller {{{ */
@interface InstalledController : FilteredPackageListController {
    bool sectioned_;
}

- (id) initWithDatabase:(Database *)database;
- (void) queueStatusDidChange;

@end

@implementation InstalledController

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/installed/", UI_]];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://installed"];
}

- (void) useRecent {
    sectioned_ = false;

@synchronized (self) {
    [self setFilter:[](Package *package) {
        return ![package uninstalled] && package->role_ < 7;
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingSelector:@selector(recent)];
    }];
} }

- (void) useFilter:(UISegmentedControl *)segmented {
    NSInteger selected([segmented selectedSegmentIndex]);
    if (selected == 2)
        return [self useRecent];
    bool simple(selected == 0);
    sectioned_ = true;

@synchronized (self) {
    [self setFilter:[=](Package *package) {
        return ![package uninstalled] && package->role_ <= (simple ? 1 : 3);
    }];

    [self setSorter:nullptr];
} }

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    if (sectioned_)
        return [super sectionsForPackages:packages];

    CFDateFormatterRef formatter(CFDateFormatterCreate(NULL, Locale_, kCFDateFormatterLongStyle, kCFDateFormatterNoStyle));

    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);
    Section *section(nil);
    time_t last(0);

    for (size_t offset(0), count([packages count]); offset != count; ++offset) {
        Package *package([packages objectAtIndex:offset]);

        time_t upgraded([package upgraded]);
        if (upgraded < 1168364520)
            upgraded = 0;
        else
            upgraded -= upgraded % (60 * 60 * 24);

        if (section == nil || upgraded != last) {
            last = upgraded;

            NSString *name;
            if (upgraded == 0)
                continue; // XXX: name = UCLocalize("...");
            else {
                name = CFBridgingRelease(CFDateFormatterCreateStringWithDate(NULL, formatter, (CFDateRef) [NSDate dateWithTimeIntervalSince1970:upgraded]));
            }

            section = [[Section alloc] initWithName:name row:offset localize:NO];
            [sections addObject:section];
        }

        [section addToCount];
    }

    CFRelease(formatter);
    return sections;
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super initWithDatabase:database title:UCLocalize("INSTALLED")]) != nil) {
        UISegmentedControl *segmented([[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:UCLocalize("USER"), UCLocalize("EXPERT"), UCLocalize("RECENT"), nil]]);
        [segmented setSelectedSegmentIndex:0];
        [segmented setSegmentedControlStyle:UISegmentedControlStyleBar];
        [[self navigationItem] setTitleView:segmented];

        [segmented addTarget:self action:@selector(modeChanged:) forEvents:UIControlEventValueChanged];
        [self useFilter:segmented];

        [self queueStatusDidChange];
    } return self;
}

#if !AlwaysReload
- (void) queueButtonClicked {
    [self.delegate queue];
}
#endif

- (void) queueStatusDidChange {
#if !AlwaysReload
    if (Queuing_) {
        [[self navigationItem] setRightBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("QUEUE")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(queueButtonClicked)
        ]];
    } else {
        [[self navigationItem] setRightBarButtonItem:nil];
    }
#endif
}

- (void) modeChanged:(UISegmentedControl *)segmented {
    [self useFilter:segmented];
    [self reloadData];
}

@end
/* }}} */

/* Source Cell {{{ */
@interface SourceCell : CyteTableViewCell <
    CyteTableViewCellDelegate,
    SourceDelegate
> {
    _H<Source, 1> source_;
    _H<NSURL> url_;
    _H<UIImage> icon_;
    _H<NSString> origin_;
    _H<NSString> label_;
    _H<UIActivityIndicatorView> indicator_;
}

- (void) setSource:(Source *)source;
- (void) setFetch:(NSNumber *)fetch;

@end

@implementation SourceCell

- (void) _setImage:(NSArray *)data {
    if ([url_ isEqual:[data objectAtIndex:0]]) {
        icon_ = [data objectAtIndex:1];
        [self.content setNeedsDisplay];
    }
}

- (void) _setSource:(NSURL *) url {
    @autoreleasepool {

    if (NSData *data = [NSURLConnection
        sendSynchronousRequest:[NSURLRequest
            requestWithURL:url
            cachePolicy:NSURLRequestUseProtocolCachePolicy
            timeoutInterval:10
        ]

        returningResponse:NULL
        error:NULL
    ])
        if (UIImage *image = [UIImage imageWithData:data])
            [self performSelectorOnMainThread:@selector(_setImage:) withObject:[NSArray arrayWithObjects:url, image, nil] waitUntilDone:NO];
    }
}

- (void) setSource:(Source *)source {
    source_ = source;
    [source_ setDelegate:self];

    [self setFetch:[NSNumber numberWithBool:[source_ fetch]]];

    icon_ = [UIImage imageNamed:@"unknown.png"];

    origin_ = [source name];
    label_ = [source rooturi];

    [self.content setNeedsDisplay];

    url_ = [source iconURL];
    [NSThread detachNewThreadSelector:@selector(_setSource:) toTarget:self withObject:url_];
}

- (void) setAllSource {
    source_ = nil;
    [indicator_ stopAnimating];

    icon_ = [UIImage imageNamed:@"folder.png"];
    origin_ = UCLocalize("ALL_SOURCES");
    label_ = UCLocalize("ALL_SOURCES_EX");
    [self.content setNeedsDisplay];
}

- (SourceCell *) initWithFrame:(CGRect)frame reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithFrame:frame reuseIdentifier:reuseIdentifier]) != nil) {
        [self.content setBackgroundColor:whiteIfNotDark(1)];
        [self.content setOpaque:YES];

        indicator_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGraySmall];
        [indicator_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin];// | UIViewAutoresizingFlexibleBottomMargin];
        [[self contentView] addSubview:indicator_];

        [[self.content layer] setContentsGravity:kCAGravityTopLeft];
    } return self;
}

- (void) layoutSubviews {
    [super layoutSubviews];

    UIView *content([self contentView]);
    CGRect bounds([content bounds]);

    CGRect frame([indicator_ frame]);
    frame.origin.x = bounds.size.width - frame.size.width;
    frame.origin.y = Retina((bounds.size.height - frame.size.height) / 2);

    if (kCFCoreFoundationVersionNumber < 800)
        frame.origin.x -= 8;
    [indicator_ setFrame:frame];
}

- (NSString *) accessibilityLabel {
    return origin_;
}

- (void) drawContentRect:(CGRect)rect {
    bool highlighted(self.highlighted);
    float width(rect.size.width);

    if (icon_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) icon_ size];

        while (rect.size.width > 32 || rect.size.height > 32) {
            rect.size.width /= 2;
            rect.size.height /= 2;
        }

        rect.origin.x = 26 - rect.size.width / 2;
        rect.origin.y = 26 - rect.size.height / 2;

        [icon_ drawInRect:Retina(rect)];
    }

    if (highlighted && kCFCoreFoundationVersionNumber < 800)
        UISetColor(White_);

    if (!highlighted)
        UISetColor(Black_);
    [origin_ drawAtPoint:CGPointMake(52, 8) forWidth:(width - 49) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (!highlighted)
        UISetColor(Gray_);
    [label_ drawAtPoint:CGPointMake(52, 29) forWidth:(width - 49) withFont:Font12_ lineBreakMode:NSLineBreakByTruncatingTail];
}

- (void) setFetch:(NSNumber *)fetch {
    if ([fetch boolValue])
        [indicator_ startAnimating];
    else
        [indicator_ stopAnimating];
}

@end
/* }}} */
/* Sources Controller {{{ */
@interface SourcesController : CyteViewController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    unsigned era_;

    _H<UITableView, 2> list_;
    _H<NSMutableArray> sources_;
    int offset_;

    _H<NSString> href_;
    _H<UIProgressHUD> hud_;
    _H<NSError> error_;

    NSURLConnection *trivial_bz2_;
    NSURLConnection *trivial_gz_;
    NSURLConnection *trivial_xz_;

    BOOL cydia_;
}

- (id) initWithDatabase:(Database *)database;
- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated;

@end

@implementation SourcesController

- (void) _cancelConnection:(NSURLConnection *)connection {
    if (connection != nil) {
        [connection cancel];
        //[connection setDelegate:nil];
    }
}

- (void) dealloc {
    [self _cancelConnection:trivial_gz_];
    [self _cancelConnection:trivial_bz2_];
    [self _cancelConnection:trivial_xz_];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://sources"];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [list_ deselectRowAtIndexPath:[list_ indexPathForSelectedRow] animated:animated];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1)
        return UCLocalize("INDIVIDUAL_SOURCES");
    return nil;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: return [sources_ count];
        default: return 0;
    }
}

- (Source *) sourceAtIndexPath:(NSIndexPath *)indexPath {
@synchronized (database_) {
    if ([database_ era] != era_)
        return nil;
    if ([indexPath section] != 1)
        return nil;
    NSUInteger index([indexPath row]);
    if (index >= [sources_ count])
        return nil;
    return [sources_ objectAtIndex:index];
} }

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"SourceCell";

    SourceCell *cell = (SourceCell *) [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (cell == nil) cell = [[SourceCell alloc] initWithFrame:CGRectZero reuseIdentifier:cellIdentifier];
    [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];

    Source *source([self sourceAtIndexPath:indexPath]);
    if (source == nil)
        [cell setAllSource];
    else
        [cell setSource:source];

    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    SectionsController *controller([[SectionsController alloc]
        initWithDatabase:database_
        source:[self sourceAtIndexPath:indexPath]
    ]);

    [controller setDelegate:self.delegate];
    [[self navigationController] pushViewController:controller animated:YES];
}

- (BOOL) tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath section] != 1)
        return false;
    Source *source = [self sourceAtIndexPath:indexPath];
    return [source record] != nil;
}

- (void) tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    _assert([indexPath section] == 1);
    if (editingStyle ==  UITableViewCellEditingStyleDelete) {
        Source *source = [self sourceAtIndexPath:indexPath];
        if (source == nil) return;

        [Sources_ removeObjectForKey:[source key]];

        [self.delegate syncData];
    }
}

- (void) tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    [self updateButtonsForEditingStatusAnimated:YES];
}

- (void) complete {
    [self.delegate addTrivialSource:href_];
    href_ = nil;

    [self.delegate syncData];
}

- (NSString *) getWarning {
    NSString *href(href_);
    NSRange colon([href rangeOfString:@"://"]);
    if (colon.location != NSNotFound)
        href = [href substringFromIndex:(colon.location + 3)];
    href = [href stringByAddingPercentEscapes];
    href = [CydiaURL(@"api/repotag/") stringByAppendingString:href];

    NSURL *url([NSURL URLWithString:href]);

    NSStringEncoding encoding;
    NSError *error(nil);

    if (NSString *warning = [NSString stringWithContentsOfURL:url usedEncoding:&encoding error:&error])
        return [warning length] == 0 ? nil : warning;
    return nil;
}

- (void) _endConnection:(NSURLConnection *)connection {
    // XXX: the memory management in this method is horribly awkward

    if (connection == trivial_bz2_)
        trivial_bz2_ = nil;
    else if (connection == trivial_gz_)
        trivial_gz_ = nil;
    else if (connection == trivial_xz_)
        trivial_xz_ = nil;
    else
        _assert(false);

    if (
        trivial_bz2_ == nil &&
        trivial_gz_ == nil &&
        trivial_xz_ == nil
    ) {
        NSString *warning(cydia_ ? [self yieldToSelector:@selector(getWarning)] : nil);

        [self.delegate releaseNetworkActivityIndicator];

        [self.delegate removeProgressHUD:hud_];
        hud_ = nil;

        if (cydia_) {
            if (warning != nil) {
                UIAlertView *alert = [[UIAlertView alloc]
                    initWithTitle:UCLocalize("SOURCE_WARNING")
                    message:warning
                    delegate:self
                    cancelButtonTitle:UCLocalize("CANCEL")
                    otherButtonTitles:
                        UCLocalize("ADD_ANYWAY"),
                    nil
                ];

                [alert setContext:@"warning"];
                [alert setNumberOfRows:1];
                [alert show];

                // XXX: there used to be this great mechanism called yieldToPopup... who deleted it?
                error_ = nil;
                return;
            }

            [self complete];
        } else if (error_ != nil) {
            UIAlertView *alert = [[UIAlertView alloc]
                initWithTitle:UCLocalize("VERIFICATION_ERROR")
                message:[error_ localizedDescription]
                delegate:self
                cancelButtonTitle:UCLocalize("OK")
                otherButtonTitles:nil
            ];

            [alert setContext:@"urlerror"];
            [alert show];

            href_ = nil;
        } else {
            UIAlertView *alert = [[UIAlertView alloc]
                initWithTitle:UCLocalize("NOT_REPOSITORY")
                message:UCLocalize("NOT_REPOSITORY_EX")
                delegate:self
                cancelButtonTitle:UCLocalize("OK")
                otherButtonTitles:nil
            ];

            [alert setContext:@"trivial"];
            [alert show];

            href_ = nil;
        }

        error_ = nil;
    }
}

- (void) connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
    switch ([response statusCode]) {
        case 200:
            cydia_ = YES;
    }
}

- (void) connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    lprintf("connection:\"%s\" didFailWithError:\"%s\"\n", [href_ UTF8String], [[error localizedDescription] UTF8String]);
    error_ = error;
    [self _endConnection:connection];
}

- (void) connectionDidFinishLoading:(NSURLConnection *)connection {
    [self _endConnection:connection];
}

- (NSURLConnection *) _requestHRef:(NSString *)href method:(NSString *)method {
    NSURL *url([NSURL URLWithString:href]);

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:url
        cachePolicy:NSURLRequestUseProtocolCachePolicy
        timeoutInterval:10
    ];

    [request setHTTPMethod:method];

    if (Machine_ != NULL)
        [request setValue:[NSString stringWithUTF8String:Machine_] forHTTPHeaderField:@"X-Machine"];

    if (UniqueID_ != nil)
        [request setValue:UniqueID_ forHTTPHeaderField:@"X-Unique-ID"];

    if ([url isCydiaSecure]) {
        if (UniqueID_ != nil)
            [request setValue:UniqueID_ forHTTPHeaderField:@"X-Cydia-Id"];
    }

    return [[NSURLConnection alloc] initWithRequest:request delegate:self];
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"source"]) {
        switch (button) {
            case 1: {
                NSString *href = [[alert textField] text];
                href = VerifySource(href);
                if (href == nil)
                    break;
                href_ = href;

                trivial_bz2_ = [self _requestHRef:[href_ stringByAppendingString:@"Packages.bz2"] method:@"HEAD"];
                trivial_gz_ = [self _requestHRef:[href_ stringByAppendingString:@"Packages.gz"] method:@"HEAD"];
                trivial_xz_ = [self _requestHRef:[href_ stringByAppendingString:@"Packages.xz"] method:@"HEAD"];

                cydia_ = false;

                // XXX: this is stupid
                hud_ = [self.delegate addProgressHUD];
                [hud_ setText:UCLocalize("VERIFYING_URL")];
                [self.delegate retainNetworkActivityIndicator];
            } break;

            case 0:
            break;

            _nodefault
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"trivial"])
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    else if ([context isEqualToString:@"urlerror"])
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    else if ([context isEqualToString:@"warning"]) {
        switch (button) {
            case 1:
                [self performSelector:@selector(complete) withObject:nil afterDelay:0];
            break;

            case 0:
            break;

            _nodefault
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}

- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated {
    BOOL editing([list_ isEditing]);

    if (editing)
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("ADD")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(addButtonClicked)
        ] animated:animated];
    else if ([self.delegate updating])
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("CANCEL")
            style:UIBarButtonItemStyleDone
            target:self
            action:@selector(cancelButtonClicked)
        ] animated:animated];
    else
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("REFRESH")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(refreshButtonClicked)
        ] animated:animated];

    [[self navigationItem] setRightBarButtonItem:[[UIBarButtonItem alloc]
        initWithTitle:(editing ? UCLocalize("DONE") : UCLocalize("EDIT"))
        style:(editing ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain)
        target:self
        action:@selector(editButtonClicked)
    ] animated:animated];
}

- (void) loadView {
    list_ = [[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame] style:UITableViewStylePlain];
    if ([list_ respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)])
        [list_ setCellLayoutMarginsFollowReadableWidth:NO];
    [list_ setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    [list_ setRowHeight:53];
    [(UITableView *) list_ setDataSource:self];
    [list_ setDelegate:self];
    [self setView:list_];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    overrideUserInterfaceStyle(self.traitCollection.userInterfaceStyle);
    [[self navigationItem] setTitle:UCLocalize("SOURCES")];
    [self updateButtonsForEditingStatusAnimated:NO];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [list_ setEditing:NO];
    [self updateButtonsForEditingStatusAnimated:NO];
}

- (void) releaseSubviews {
    list_ = nil;

    sources_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;
    } return self;
}

- (void) reloadData {
    [super reloadData];
    [self updateButtonsForEditingStatusAnimated:YES];

@synchronized (database_) {
    era_ = [database_ era];

    sources_ = [NSMutableArray arrayWithCapacity:16];
    [sources_ addObjectsFromArray:[database_ sources]];
    _trace();
    [sources_ sortUsingSelector:@selector(compareByName:)];
    _trace();

    int count([sources_ count]);
    offset_ = 0;
    for (int i = 0; i != count; i++) {
        if ([[sources_ objectAtIndex:i] record] == nil)
            break;
        offset_++;
    }

    [list_ reloadData];
} }

- (void) showAddSourcePrompt {
    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:UCLocalize("ENTER_APT_URL")
        message:nil
        delegate:self
        cancelButtonTitle:UCLocalize("CANCEL")
        otherButtonTitles:
            UCLocalize("ADD_SOURCE"),
        nil
    ];

    [alert setContext:@"source"];

    [alert setNumberOfRows:1];
    [alert addTextFieldWithValue:@"https://" label:@""];

    NSObject<UITextInputTraits> *traits = [[alert textField] textInputTraits];
    [traits setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [traits setAutocorrectionType:UITextAutocorrectionTypeNo];
    [traits setKeyboardType:UIKeyboardTypeURL];
    // XXX: UIReturnKeyDone
    [traits setReturnKeyType:UIReturnKeyNext];

    [alert show];
}

- (void) addButtonClicked {
    [self showAddSourcePrompt];
}

- (void) refreshButtonClicked {
    if ([self.delegate requestUpdate])
        [self updateButtonsForEditingStatusAnimated:YES];
}

- (void) cancelButtonClicked {
    [self.delegate cancelUpdate];
}

- (void) editButtonClicked {
    [list_ setEditing:![list_ isEditing] animated:YES];
    [self updateButtonsForEditingStatusAnimated:YES];
}

@end
/* }}} */

/* Stash Controller {{{ */
@interface StashController : CyteViewController {
    _H<UIActivityIndicatorView> spinner_;
    _H<UILabel> status_;
    _H<UILabel> caption_;
}

@end

@implementation StashController

- (void) loadView {
    UIView *view([[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]]);
    [view setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    [self setView:view];

    [view setBackgroundColor:[UIColor viewFlipsideBackgroundColor]];

    spinner_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    CGRect spinrect = [spinner_ frame];
    spinrect.origin.x = Retina([[self view] frame].size.width / 2 - spinrect.size.width / 2);
    spinrect.origin.y = [[self view] frame].size.height - 80.0f;
    [spinner_ setFrame:spinrect];
    [spinner_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin];
    [view addSubview:spinner_];
    [spinner_ startAnimating];

    CGRect captrect;
    captrect.size.width = [[self view] frame].size.width;
    captrect.size.height = 40.0f;
    captrect.origin.x = 0;
    captrect.origin.y = Retina([[self view] frame].size.height / 2 - captrect.size.height * 2);
    caption_ = [[UILabel alloc] initWithFrame:captrect];
    [caption_ setText:UCLocalize("PREPARING_FILESYSTEM")];
    [caption_ setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin];
    [caption_ setFont:[UIFont boldSystemFontOfSize:28.0f]];
    [caption_ setTextColor:whiteIfNotDark(1)];
    [caption_ setBackgroundColor:[UIColor clearColor]];
    [caption_ setShadowColor:whiteIfNotDark(0)];
    [caption_ setTextAlignment:NSTextAlignmentCenter];
    [view addSubview:caption_];

    CGRect statusrect;
    statusrect.size.width = [[self view] frame].size.width;
    statusrect.size.height = 30.0f;
    statusrect.origin.x = 0;
    statusrect.origin.y = Retina([[self view] frame].size.height / 2 - statusrect.size.height);
    status_ = [[UILabel alloc] initWithFrame:statusrect];
    [status_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin];
    [status_ setText:UCLocalize("EXIT_WHEN_COMPLETE")];
    [status_ setFont:[UIFont systemFontOfSize:16.0f]];
    [status_ setTextColor:whiteIfNotDark(1)];
    [status_ setBackgroundColor:[UIColor clearColor]];
    [status_ setShadowColor:whiteIfNotDark(0)];
    [status_ setTextAlignment:NSTextAlignmentCenter];
    [view addSubview:status_];
}

- (void) releaseSubviews {
    spinner_ = nil;
    status_ = nil;
    caption_ = nil;

    [super releaseSubviews];
}

@end
/* }}} */

@interface Cydia : CyteApplication <
    ConfirmationControllerDelegate,
    DatabaseDelegate,
    CydiaDelegate
> {
    _H<CyteWindow> window_;
    _H<CydiaTabBarController> tabbar_;
    _H<CyteTabBarController> emulated_;
    _H<AppCacheController> appcache_;

    _H<NSMutableArray> essential_;
    _H<NSMutableArray> broken_;

    Database *database_;

    _H<NSURL> starturl_;

    unsigned locked_;

    _H<StashController> stash_;

    bool loaded_;
}

- (void) loadData;

@end

@implementation Cydia

- (void) lockSuspend {
    if (locked_++ == 0) {
        if ($SBSSetInterceptsMenuButtonForever != NULL)
            (*$SBSSetInterceptsMenuButtonForever)(true);

        [self setIdleTimerDisabled:YES];
    }
}

- (void) unlockSuspend {
    if (--locked_ == 0) {
        [self setIdleTimerDisabled:NO];

        if ($SBSSetInterceptsMenuButtonForever != NULL)
            (*$SBSSetInterceptsMenuButtonForever)(false);
    }
}

- (void) beginUpdate {
    [tabbar_ beginUpdate];
}

- (void) cancelUpdate {
    [tabbar_ cancelUpdate];
}

- (bool) requestUpdate {
    if (CyteIsReachable("cydia.saurik.com")) {
        [self beginUpdate];
        return true;
    } else {
        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:[NSString stringWithFormat:Colon_, Error_, UCLocalize("REFRESH")]
            message:@"Host Unreachable" // XXX: Localize
            delegate:self
            cancelButtonTitle:UCLocalize("OK")
            otherButtonTitles:nil
        ];

        [alert setContext:@"norefresh"];
        [alert show];

        return false;
    }
}

- (BOOL) updating {
    return [tabbar_ updating];
}

- (void) _loaded {
    if ([broken_ count] != 0) {
        int count = [broken_ count];

        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:(count == 1 ? UCLocalize("HALFINSTALLED_PACKAGE") : [NSString stringWithFormat:UCLocalize("HALFINSTALLED_PACKAGES"), count])
            message:UCLocalize("HALFINSTALLED_PACKAGE_EX")
            delegate:self
            cancelButtonTitle:[NSString stringWithFormat:UCLocalize("PARENTHETICAL"), UCLocalize("FORCIBLY_CLEAR"), UCLocalize("UNSAFE")]
            otherButtonTitles:
                UCLocalize("TEMPORARY_IGNORE"),
            nil
        ];

        [alert setContext:@"fixhalf"];
        [alert setNumberOfRows:2];
        [alert show];
    } else if (!Ignored_ && [essential_ count] != 0) {
        int count = [essential_ count];

        UIAlertView *alert = [[UIAlertView alloc]
            initWithTitle:(count == 1 ? UCLocalize("ESSENTIAL_UPGRADE") : [NSString stringWithFormat:UCLocalize("ESSENTIAL_UPGRADES"), count])
            message:UCLocalize("ESSENTIAL_UPGRADE_EX")
            delegate:self
            cancelButtonTitle:UCLocalize("TEMPORARY_IGNORE")
            otherButtonTitles:
                UCLocalize("UPGRADE_ESSENTIAL"),
                UCLocalize("COMPLETE_UPGRADE"),
            nil
        ];

        [alert setContext:@"upgrade"];
        [alert show];
    }
}

- (void) returnToCydia {
    [self _loaded];
}

- (void) reloadSpringBoard {
    if (kCFCoreFoundationVersionNumber >= 1443) { // XXX: iOS 11.x
        Class $SBSRelaunchAction = objc_getClass("SBSRelaunchAction");
        Class $FBSSystemService = objc_getClass("FBSSystemService");
        pid_t sb_pid = launch_get_job_pid("com.apple.SpringBoard");
        if ($SBSRelaunchAction && $FBSSystemService) {
            id action = [$SBSRelaunchAction actionWithReason:@"respring" options:RestartRenderServer targetURL:nil];
            id sharedService = [$FBSSystemService sharedService];
            [sharedService sendActions:[NSSet setWithObject:action] withResult:nil];
            for (int i=0; i<100; i++) {
                if (kill(sb_pid, 0)) {
                    break;
                }
                usleep(1000);
            }
            if (kill(sb_pid, 0)) sleep(5);
        }
    }
    if (kCFCoreFoundationVersionNumber >= 700) // XXX: iOS 6.x
        system("/usr/libexec/cydia/cydo /bin/launchctl stop com.apple.backboardd");
    else
        system("/usr/libexec/cydia/cydo /bin/launchctl stop com.apple.SpringBoard");
    sleep(15);
    system("/usr/bin/killall backboardd SpringBoard");
}

- (void) _saveConfig {
    SaveConfig(database_);
}

// Navigation controller for the queuing badge.
- (UINavigationController *) queueNavigationController {
    NSArray *controllers = [tabbar_ viewControllers];
    return [controllers objectAtIndex:3];
}

- (void) _updateData {
    [self _saveConfig];
    [window_ unloadData];

    UINavigationController *navigation = [self queueNavigationController];

    id queuedelegate = nil;
    if ([[navigation viewControllers] count] > 0)
        queuedelegate = [[navigation viewControllers] objectAtIndex:0];

    [queuedelegate queueStatusDidChange];
    [[navigation tabBarItem] setBadgeValue:(Queuing_ ? UCLocalize("Q_D") : nil)];
}

- (void) _refreshIfPossible {
    @autoreleasepool {

    NSDate *update([[NSDictionary dictionaryWithContentsOfFile:CacheState_] objectForKey:@"LastUpdate"]);

    bool recently = false;
    if (update != nil) {
        NSTimeInterval interval([update timeIntervalSinceNow]);
        if (interval > -(15*60))
            recently = true;
    }

    // Don't automatic refresh if:
    //  - We already refreshed recently.
    //  - We already auto-refreshed this launch.
    //  - Auto-refresh is disabled.
    //  - Cydia's server is not reachable
    if (recently || loaded_ || ManualRefresh || !CyteIsReachable("cydia.saurik.com")) {
        // If we are cancelling, we need to make sure it knows it's already loaded.
        loaded_ = true;

        [self performSelectorOnMainThread:@selector(_loaded) withObject:nil waitUntilDone:NO];
    } else {
        // We are going to load, so remember that.
        loaded_ = true;

        [tabbar_ performSelectorOnMainThread:@selector(beginUpdate) withObject:nil waitUntilDone:NO];
    }
    }
}

- (void) refreshIfPossible {
    [NSThread detachNewThreadSelector:@selector(_refreshIfPossible) toTarget:self withObject:nil];
}

- (void) reloadDataWithInvocation:(NSInvocation *)invocation {
_profile(reloadDataWithInvocation)
@synchronized (self) {
    UIProgressHUD *hud(loaded_ ? [self addProgressHUD] : nil);
    if (hud != nil)
        [hud setText:UCLocalize("RELOADING_DATA")];

    [database_ yieldToSelector:@selector(reloadDataWithInvocation:) withObject:invocation];

    size_t changes(0);

    [essential_ removeAllObjects];
    [broken_ removeAllObjects];

    _profile(reloadDataWithInvocation$Essential)
    NSArray *packages([database_ packages]);
    for (Package *package in packages) {
        if ([package half])
            [broken_ addObject:package];
        if ([package upgradableAndEssential:YES] && ![package ignored]) {
            if ([package essential] && [package installed] != nil)
                [essential_ addObject:package];
            ++changes;
        }
    }
    _end

    UITabBarItem *changesItem = [[[tabbar_ viewControllers] objectAtIndex:2] tabBarItem];
    if (changes != 0) {
        _trace();
        NSString *badge([[NSNumber numberWithInt:changes] stringValue]);
        [changesItem setBadgeValue:badge];
        [changesItem setAnimatedBadge:([essential_ count] > 0)];
        [self setApplicationIconBadgeNumber:changes];
    } else {
        _trace();
        [changesItem setBadgeValue:nil];
        [changesItem setAnimatedBadge:NO];
        [self setApplicationIconBadgeNumber:0];
    }

    Queuing_ = false;
    [self _updateData];

    if (hud != nil)
        [self removeProgressHUD:hud];
}
_end

    PrintTimes();
}

- (void) updateData {
    [self _updateData];
}

- (void) updateDataAndLoad {
    [self _updateData];
    if ([database_ progressDelegate] == nil)
        [self _loaded];
}

- (void) update_ {
    [database_ update];
    [self performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:YES];
}

- (void) disemulate {
    if (emulated_ == nil)
        return;

    [window_ setRootViewController:tabbar_];
    emulated_ = nil;

    [window_ setUserInteractionEnabled:YES];
}

- (void) presentModalViewController:(UIViewController *)controller force:(BOOL)force {
    UINavigationController *navigation([[UINavigationController alloc] initWithRootViewController:controller]);

    UIViewController *parent;
    if (emulated_ == nil)
        parent = tabbar_;
    else if (!force)
        parent = emulated_;
    else {
        [self disemulate];
        parent = tabbar_;
    }

    if (IsWildcat_)
        [navigation setModalPresentationStyle:UIModalPresentationFormSheet];
    [parent presentModalViewController:navigation animated:YES];
}

- (ProgressController *) invokeNewProgress:(NSInvocation *)invocation forController:(UINavigationController *)navigation withTitle:(NSString *)title {
    ProgressController *progress([[ProgressController alloc] initWithDatabase:database_ delegate:self]);

    if (navigation != nil)
        [navigation pushViewController:progress animated:YES];
    else
        [self presentModalViewController:progress force:YES];

    [progress invoke:invocation withTitle:title];
    return progress;
}

- (void) detachNewProgressSelector:(SEL)selector toTarget:(id)target forController:(UINavigationController *)navigation title:(NSString *)title {
    [self invokeNewProgress:[NSInvocation invocationWithSelector:selector forTarget:target] forController:navigation withTitle:title];
}

- (void) repairWithInvocation:(NSInvocation *)invocation {
    _trace();
    [self invokeNewProgress:invocation forController:nil withTitle:@"REPAIRING"];
    _trace();
}

- (void) repairWithSelector:(SEL)selector {
    [self performSelectorOnMainThread:@selector(repairWithInvocation:) withObject:[NSInvocation invocationWithSelector:selector forTarget:database_] waitUntilDone:YES];
}

- (void) reloadData {
    [self reloadDataWithInvocation:nil];
    if ([database_ progressDelegate] == nil)
        [self _loaded];
}

- (void) syncData {
    [self _saveConfig];
    [self detachNewProgressSelector:@selector(update_) toTarget:self forController:nil title:@"UPDATING_SOURCES"];
}

- (void) addSource:(NSDictionary *) source {
    CydiaAddSource(source);
}

- (void) addSource:(NSString *)href withDistribution:(NSString *)distribution andSections:(NSArray *)sections {
    CydiaAddSource(href, distribution, sections);
}

// XXX: this method should not return anything
- (BOOL) addTrivialSource:(NSString *)href {
    CydiaAddSource(href, @"./");
    return YES;
}

- (void) resolve {
    pkgProblemResolver *resolver = [database_ resolver];

    resolver->InstallProtect();
    if (!resolver->Resolve(true))
        _error->Discard();
}

- (bool) perform {
    // XXX: this is a really crappy way of doing this.
    // like, seriously: this state machine is still broken, and cancelling this here doesn't really /fix/ that.
    // for one, the user can still /start/ a reloading data event while they have a queue, which is stupid
    // for two, this just means there is a race condition between the refresh completing and the confirmation controller appearing.
    if ([tabbar_ updating])
        [tabbar_ cancelUpdate];

    if (![database_ prepare])
        return false;

    ConfirmationController *page([[ConfirmationController alloc] initWithDatabase:database_]);
    [page setDelegate:self];
    UINavigationController *confirm_([[UINavigationController alloc] initWithRootViewController:page]);

    if (IsWildcat_)
        [confirm_ setModalPresentationStyle:UIModalPresentationFormSheet];
    [tabbar_ presentModalViewController:confirm_ animated:YES];

    return true;
}

- (void) queue {
    @synchronized (self) {
        [self perform];
    }
}

- (void) clearPackage:(Package *)package {
    @synchronized (self) {
        [package clear];
        [self resolve];
        [self perform];
    }
}

- (void) installPackages:(NSArray *)packages {
    @synchronized (self) {
        for (Package *package in packages)
            [package install];
        [self resolve];
        [self perform];
    }
}

- (void) installPackage:(Package *)package {
    @synchronized (self) {
        [package install];
        [self resolve];
        [self perform];
    }
}

- (void) removePackage:(Package *)package {
    @synchronized (self) {
        [package remove];
        [self resolve];
        [self perform];
    }
}

- (void) distUpgrade {
    @synchronized (self) {
        if (![database_ upgrade])
            return;
        [self perform];
    }
}

- (void) _uicache {
    _trace();
    system("/usr/bin/uicache");
    _trace();
}

- (void) uicache {
    UIProgressHUD *hud([self addProgressHUD]);
    [hud setText:UCLocalize("LOADING")];
    [self yieldToSelector:@selector(_uicache)];
    [self removeProgressHUD:hud];
}

- (void) perform_ {
    [database_ perform];
    if (Finish_ == 0 && !RestartSubstrate_) {
        [self performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:YES];
    } else {
        // Reload data when we open up again
        if (NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:CacheState_]) {
            [cache removeObjectForKey:@"LastUpdate"];
            [cache writeToFile:CacheState_ atomically:YES];
        }
    }
    if (UICache_) {
        UICache_ = false;
        [self performSelectorOnMainThread:@selector(uicache) withObject:nil waitUntilDone:YES];
    }
}

- (void) confirmWithNavigationController:(UINavigationController *)navigation {
    Queuing_ = false;
    [self lockSuspend];
    [self detachNewProgressSelector:@selector(perform_) toTarget:self forController:navigation title:@"RUNNING"];
    [self unlockSuspend];
}

- (void) cancelAndClear:(bool)clear {
    @synchronized (self) {
        if (clear) {
            [database_ clear];
            Queuing_ = false;
        } else {
            Queuing_ = true;
        }

        [self _updateData];
    }
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"conffile"]) {
        FILE *input = [database_ input];
        if (button == [alert cancelButtonIndex])
            fprintf(input, "N\n");
        else if (button == [alert firstOtherButtonIndex])
            fprintf(input, "Y\n");
        fflush(input);

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"fixhalf"]) {
        if (button == [alert cancelButtonIndex]) {
            @synchronized (self) {
                for (Package *broken in (id) broken_) {
                    [broken remove];
                    NSString *id(ShellEscape([broken id]));
                    system([[NSString stringWithFormat:@"/usr/libexec/cydia/cydo /bin/rm -f"
                        " /var/lib/dpkg/info/%@.prerm"
                        " /var/lib/dpkg/info/%@.postrm"
                        " /var/lib/dpkg/info/%@.preinst"
                        " /var/lib/dpkg/info/%@.postinst"
                        " /var/lib/dpkg/info/%@.extrainst_"
                    "", id, id, id, id, id] UTF8String]);
                }

                [self resolve];
                [self perform];
            }
        } else if (button == [alert firstOtherButtonIndex]) {
            [broken_ removeAllObjects];
            [self _loaded];
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"upgrade"]) {
        if (button == [alert firstOtherButtonIndex]) {
            @synchronized (self) {
                for (Package *essential in (id) essential_)
                    [essential install];

                [self resolve];
                [self perform];
            }
        } else if (button == [alert firstOtherButtonIndex] + 1) {
            [self distUpgrade];
        } else if (button == [alert cancelButtonIndex]) {
            Ignored_ = YES;
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}

- (void) system:(NSString *)command {
    @autoreleasepool {

    _trace();
    system([command UTF8String]);
    _trace();
    }
}

- (void) applicationWillSuspend {
    [database_ clean];
    [super applicationWillSuspend];
}

- (BOOL) isSafeToSuspend {
    if (locked_ != 0) {
#if !ForRelease
        NSLog(@"isSafeToSuspend: locked_ != 0");
#endif
        return false;
    }

    if ([tabbar_ modalViewController] != nil)
        return false;

    // Use external process status API internally.
    // This is probably a really bad idea.
    // XXX: what is the point of this? does this solve anything at all?
    uint64_t status = 0;
    int notify_token;
    if (notify_register_check("com.saurik.Cydia.status", &notify_token) == NOTIFY_STATUS_OK) {
        notify_get_state(notify_token, &status);
        notify_cancel(notify_token);
    }

    if (status != 0) {
#if !ForRelease
        NSLog(@"isSafeToSuspend: status != 0");
#endif
        return false;
    }

#if !ForRelease
    NSLog(@"isSafeToSuspend: -> true");
#endif
    return true;
}

- (void) suspendReturningToLastApp:(BOOL)returning {
    if ([self isSafeToSuspend])
        [super suspendReturningToLastApp:returning];
}

- (void) suspend {
    if ([self isSafeToSuspend])
        [super suspend];
}

- (void) applicationSuspend {
    if ([self isSafeToSuspend])
        [super applicationSuspend];
}

- (void) applicationSuspend:(GSEventRef)event {
    if ([self isSafeToSuspend])
        [super applicationSuspend:event];
}

- (void) _animateSuspension:(BOOL)arg0 duration:(double)arg1 startTime:(double)arg2 scale:(float)arg3 {
    if ([self isSafeToSuspend])
        [super _animateSuspension:arg0 duration:arg1 startTime:arg2 scale:arg3];
}

- (void) _setSuspended:(BOOL)value {
    if ([self isSafeToSuspend])
        [super _setSuspended:value];
}

- (UIProgressHUD *) addProgressHUD {
    UIProgressHUD *hud([[UIProgressHUD alloc] init]);
    [hud setAutoresizingMask:UIViewAutoresizingFlexibleBoth];

    [window_ setUserInteractionEnabled:NO];

    UIViewController *target(tabbar_);
    if (UIViewController *modal = [target modalViewController])
        target = modal;

    [hud showInView:[target view]];

    [self lockSuspend];
    return hud;
}

- (void) removeProgressHUD:(UIProgressHUD *)hud {
    [self unlockSuspend];
    [hud hide];
    [hud removeFromSuperview];
    [window_ setUserInteractionEnabled:YES];
}

- (CyteViewController *) pageForPackage:(NSString *)name withReferrer:(NSString *)referrer {
    return [[CYPackageController alloc] initWithDatabase:database_ forPackage:name withReferrer:referrer];
}

- (CyteViewController *) pageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer {
    NSString *scheme([[url scheme] lowercaseString]);
    if ([[url absoluteString] length] <= [scheme length] + 3)
        return nil;
    NSString *path([[url absoluteString] substringFromIndex:[scheme length] + 3]);
    NSArray *components([path componentsSeparatedByString:@"/"]);

    if ([scheme isEqualToString:@"apptapp"] && [components count] > 0 && [[components objectAtIndex:0] isEqualToString:@"package"]) {
        CyteViewController *controller([self pageForPackage:[components objectAtIndex:1] withReferrer:referrer]);
        if (controller != nil)
            [controller setDelegate:self];
        return controller;
    }

    if ([components count] < 1 || ![scheme isEqualToString:@"cydia"])
        return nil;

    NSString *base([components objectAtIndex:0]);

    CyteViewController *controller = nil;

    if ([base isEqualToString:@"url"]) {
        // This kind of URL can contain slashes in the argument, so we can't parse them below.
        NSString *destination = [[url absoluteString] substringFromIndex:([scheme length] + [@"://" length] + [base length] + [@"/" length])];
        controller = [[CydiaWebViewController alloc] initWithURL:[NSURL URLWithString:destination]];
    } else if (!external && [components count] == 1) {
        if ([base isEqualToString:@"sources"]) {
            controller = [[SourcesController alloc] initWithDatabase:database_];
        }

        if ([base isEqualToString:@"home"]) {
            controller = [[HomeController alloc] init];
        }

        if ([base isEqualToString:@"sections"]) {
            controller = [[SectionsController alloc] initWithDatabase:database_ source:nil];
        }

        if ([base isEqualToString:@"search"]) {
            controller = [[SearchController alloc] initWithDatabase:database_ query:nil];
        }

        if ([base isEqualToString:@"changes"]) {
            controller = [[ChangesController alloc] initWithDatabase:database_];
        }

        if ([base isEqualToString:@"installed"]) {
            controller = [[InstalledController alloc] initWithDatabase:database_];
        }
    } else if ([components count] == 2) {
        NSString *argument = [[components objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        if ([base isEqualToString:@"package"]) {
            controller = [self pageForPackage:argument withReferrer:referrer];
        }

        if (!external && [base isEqualToString:@"search"]) {
            controller = [[SearchController alloc] initWithDatabase:database_ query:argument];
        }

        if (!external && [base isEqualToString:@"sections"]) {
            if ([argument isEqualToString:@"all"] || [argument isEqualToString:@"*"])
                argument = nil;
            controller = [[SectionController alloc] initWithDatabase:database_ source:nil section:argument];
        }

        if ([base isEqualToString:@"sources"]) {
            if ([argument isEqualToString:@"add"]) {
                controller = [[SourcesController alloc] initWithDatabase:database_];
                [(SourcesController *)controller showAddSourcePrompt];
            } else {
                Source *source([database_ sourceWithKey:argument]);
                controller = [[SectionsController alloc] initWithDatabase:database_ source:source];
            }
        }

        if (!external && [base isEqualToString:@"launch"]) {
            [self launchApplicationWithIdentifier:argument suspended:NO];
            return nil;
        }
    } else if (!external && [components count] == 3) {
        NSString *arg1 = [[components objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *arg2 = [[components objectAtIndex:2] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        if ([base isEqualToString:@"package"]) {
            if ([arg2 isEqualToString:@"settings"]) {
                controller = [[PackageSettingsController alloc] initWithDatabase:database_ package:arg1];
            } else if ([arg2 isEqualToString:@"files"]) {
                controller = [[FileTable alloc] initWithDatabase:database_ forPackage:arg1];
            }
        }

        if ([base isEqualToString:@"sections"]) {
            Source *source([arg1 isEqualToString:@"*"] ? nil : [database_ sourceWithKey:arg1]);
            NSString *section([arg2 isEqualToString:@"*"] ? nil : arg2);
            controller = [[SectionController alloc] initWithDatabase:database_ source:source section:section];
        }
    }

    [controller setDelegate:self];
    return controller;
}

- (BOOL) openCydiaURL:(NSURL *)url forExternal:(BOOL)external {
    CyteViewController *page([self pageForURL:url forExternal:external withReferrer:nil]);

    if (page != nil)
        [tabbar_ setUnselectedViewController:page];

    return page != nil;
}

- (void) applicationOpenURL:(NSURL *)url {
    [super applicationOpenURL:url];

    if (!loaded_)
        starturl_ = url;
    else
        [self openCydiaURL:url forExternal:YES];
}

- (void) applicationWillResignActive:(UIApplication *)application {
    // Stop refreshing if you get a phone call or lock the device.
    if ([tabbar_ updating])
        [tabbar_ cancelUpdate];

    if ([[self superclass] instancesRespondToSelector:@selector(applicationWillResignActive:)])
        [super applicationWillResignActive:application];
}

- (void) saveState {
    [[NSDictionary dictionaryWithObjectsAndKeys:
        @"InterfaceState", [tabbar_ navigationURLCollection],
        @"LastClosed", [NSDate date],
        @"InterfaceIndex", [NSNumber numberWithInt:[tabbar_ selectedIndex]],
    nil] writeToFile:SavedState_ atomically:YES];

    [self _saveConfig];
}

- (void) applicationWillTerminate:(UIApplication *)application {
    [self saveState];
}

- (void) applicationDidEnterBackground:(UIApplication *)application {
    if (kCFCoreFoundationVersionNumber < 1000 && [self isSafeToSuspend])
        return [self terminateWithSuccess];
    Backgrounded_ = [NSDate date];
    [self saveState];
}

- (void) applicationWillEnterForeground:(UIApplication *)application {
    if (Backgrounded_ == nil)
        return;

    NSTimeInterval interval([Backgrounded_ timeIntervalSinceNow]);

    if (interval <= -(30*60)) {
        [tabbar_ setSelectedIndex:0];
        [[[tabbar_ viewControllers] objectAtIndex:0] popToRootViewControllerAnimated:NO];
    }

    if (interval <= -(15*60)) {
        if (CyteIsReachable("cydia.saurik.com")) {
            [tabbar_ beginUpdate];
            [appcache_ reloadURLWithCache:YES];
        }
    }

    if ([database_ delocked])
        [self reloadData];
}

- (void) setConfigurationData:(NSString *)data {
    static RegEx conffile_r("'(.*)' '(.*)' ([01]) ([01])");

    if (!conffile_r(data)) {
        lprintf("E:invalid conffile\n");
        return;
    }

    NSString *ofile = conffile_r[1];
    //NSString *nfile = conffile_r[2];

    UIAlertView *alert = [[UIAlertView alloc]
        initWithTitle:UCLocalize("CONFIGURATION_UPGRADE")
        message:[NSString stringWithFormat:@"%@\n\n%@", UCLocalize("CONFIGURATION_UPGRADE_EX"), ofile]
        delegate:self
        cancelButtonTitle:UCLocalize("KEEP_OLD_COPY")
        otherButtonTitles:
            UCLocalize("ACCEPT_NEW_COPY"),
            // XXX: UCLocalize("SEE_WHAT_CHANGED"),
        nil
    ];

    [alert setContext:@"conffile"];
    [alert setNumberOfRows:2];
    [alert show];
}

- (void) addStashController {
    [self lockSuspend];
    stash_ = [[StashController alloc] init];
    [window_ addSubview:[stash_ view]];
}

- (void) removeStashController {
    [[stash_ view] removeFromSuperview];
    stash_ = nil;
    [self unlockSuspend];
}

- (void) stash {
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque];
    UpdateExternalStatus(1);
    [self yieldToSelector:@selector(system:) withObject:@"/usr/libexec/cydia/cydo /usr/libexec/cydia/free.sh"];
    UpdateExternalStatus(0);

    [self removeStashController];
    [self reloadSpringBoard];
}

- (void) applicationDidFinishLaunching:(id)unused {
    [super applicationDidFinishLaunching:unused];
    [CyteWebViewController _initialize];

    [BridgedHosts_ addObject:[[NSURL URLWithString:CydiaURL(@"")] host]];

    [NSURLProtocol registerClass:[CydiaURLProtocol class]];

    // this would disallow http{,s} URLs from accessing this data
    //[WebView registerURLSchemeAsLocal:@"cydia"];

    Font12_ = [UIFont systemFontOfSize:12];
    Font12Bold_ = [UIFont boldSystemFontOfSize:12];
    Font14_ = [UIFont systemFontOfSize:14];
    Font18_ = [UIFont systemFontOfSize:18];
    Font18Bold_ = [UIFont boldSystemFontOfSize:18];
    Font22Bold_ = [UIFont boldSystemFontOfSize:22];

    essential_ = [NSMutableArray arrayWithCapacity:4];
    broken_ = [NSMutableArray arrayWithCapacity:4];

    // XXX: I really need this thing... like, seriously... I'm sorry
    appcache_ = [[AppCacheController alloc] initWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@/appcache/", UI_]]];
    [appcache_ reloadData];

    window_ = [[CyteWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [window_ orderFront:self];
    [window_ makeKey:self];
    [window_ setHidden:NO];

    if (kCFCoreFoundationVersionNumber < 1349.56 && access("/.cydia_no_stash", F_OK) != 0) {

    if (false) stash: {
        [self addStashController];
        // XXX: this would be much cleaner as a yieldToSelector:
        // that way the removeStashController could happen right here inline
        // we also could no longer require the useless stash_ field anymore
        [self performSelector:@selector(stash) withObject:nil afterDelay:0];
        return;
    }

    struct stat root;
    int error(stat("/", &root));
    _assert(error != -1);

    #define Stash_(path) do { \
        struct stat folder; \
        int error(lstat((path), &folder)); \
        if (error != -1 && ( \
            folder.st_dev == root.st_dev && \
            S_ISDIR(folder.st_mode) \
        ) || error == -1 && ( \
            errno == ENOENT || \
            errno == ENOTDIR \
        )) goto stash; \
    } while (false)

    Stash_("/Applications");
    Stash_("/Library/Ringtones");
    Stash_("/Library/Wallpaper");
    //Stash_("/usr/bin");
    Stash_("/usr/include");
    Stash_("/usr/share");
    //Stash_("/var/lib");

    }

    database_ = [Database sharedInstance];
    [database_ setDelegate:self];

    [window_ setUserInteractionEnabled:NO];

    tabbar_ = [[CydiaTabBarController alloc] initWithDatabase:database_];

    [tabbar_ addViewControllers:nil,
        @"Cydia", @"home.png", @"home7.png", @"home7s.png",
        UCLocalize("SOURCES"), @"install.png", @"install7.png", @"install7s.png",
        UCLocalize("CHANGES"), @"changes.png", @"changes7.png", @"changes7s.png",
        UCLocalize("INSTALLED"), @"manage.png", @"manage7.png", @"manage7s.png",
        UCLocalize("SEARCH"), @"search.png", @"search7.png", @"search7s.png",
    nil];

    [tabbar_ setUpdateDelegate:self];

    CydiaLoadingViewController *loading([[CydiaLoadingViewController alloc] init]);
    UINavigationController *navigation([[UINavigationController alloc] init]);
    [navigation setViewControllers:[NSArray arrayWithObject:loading]];

    emulated_ = [[CyteTabBarController alloc] init];
    [emulated_ setViewControllers:[NSArray arrayWithObject:navigation]];
    [emulated_ setSelectedIndex:0];

    if ([emulated_ respondsToSelector:@selector(concealTabBarSelection)])
        [emulated_ concealTabBarSelection];

    [window_ setRootViewController:emulated_];

    [self performSelector:@selector(loadData) withObject:nil afterDelay:0];
_trace();
}

- (NSArray *) defaultStartPages {
    NSMutableArray *standard = [NSMutableArray array];
    [standard addObject:[NSArray arrayWithObject:@"cydia://home"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://sources"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://changes"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://installed"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://search"]];
    return standard;
}

- (void) loadData {
_trace();
    if ([emulated_ modalViewController] != nil)
        [emulated_ dismissModalViewControllerAnimated:YES];
    [window_ setUserInteractionEnabled:NO];

    [self reloadDataWithInvocation:nil];
    [self refreshIfPossible];
    [self disemulate];

    NSDictionary *state([NSDictionary dictionaryWithContentsOfFile:SavedState_]);

    int savedIndex = [[state objectForKey:@"InterfaceIndex"] intValue];
    NSArray *saved = [[state objectForKey:@"InterfaceState"] mutableCopy];
    int standardIndex = 0;
    NSArray *standard = [self defaultStartPages];

    BOOL valid = YES;

    if (saved == nil)
        valid = NO;

    NSDate *closed = [state objectForKey:@"LastClosed"];
    if (valid && closed != nil) {
        NSTimeInterval interval([closed timeIntervalSinceNow]);
        if (interval <= -(30*60))
            valid = NO;
    }

    if (valid && [saved count] != [standard count])
        valid = NO;

    if (valid) {
        for (unsigned int i = 0; i < [standard count]; i++) {
            NSArray *std = [standard objectAtIndex:i], *sav = [saved objectAtIndex:i];
            // XXX: The "hasPrefix" sanity check here could be, in theory, fooled,
            //      but it's good enough for now.
            if ([sav count] == 0 || ![[sav objectAtIndex:0] hasPrefix:[std objectAtIndex:0]]) {
                valid = NO;
                break;
            }
        }
    }

    NSArray *items = nil;
    if (valid) {
        [tabbar_ setSelectedIndex:savedIndex];
        items = saved;
    } else {
        [tabbar_ setSelectedIndex:standardIndex];
        items = standard;
    }

    for (unsigned int tab = 0; tab < [[tabbar_ viewControllers] count]; tab++) {
        NSArray *stack = [items objectAtIndex:tab];
        UINavigationController *navigation = [[tabbar_ viewControllers] objectAtIndex:tab];
        NSMutableArray *current = [NSMutableArray array];

        for (unsigned int nav = 0; nav < [stack count]; nav++) {
            NSString *addr = [stack objectAtIndex:nav];
            NSURL *url = [NSURL URLWithString:addr];
            CyteViewController *page = [self pageForURL:url forExternal:NO withReferrer:nil];
            if (page != nil)
                [current addObject:page];
        }

        [navigation setViewControllers:current];
    }

    // (Try to) show the startup URL.
    if (starturl_ != nil) {
        [self openCydiaURL:starturl_ forExternal:YES];
        starturl_ = nil;
    }
}

- (void) showActionSheet:(UIActionSheet *)sheet fromItem:(UIBarButtonItem *)item {
    if (!IsWildcat_) {
       [sheet addButtonWithTitle:UCLocalize("CANCEL")];
       [sheet setCancelButtonIndex:[sheet numberOfButtons] - 1];
    }

    if (item != nil && IsWildcat_) {
        [sheet showFromBarButtonItem:item animated:YES];
    } else {
        [sheet showInView:window_];
    }
}

- (void) addProgressEvent:(CydiaProgressEvent *)event forTask:(NSString *)task {
    id<ProgressDelegate> progress([database_ progressDelegate] ?: [self invokeNewProgress:nil forController:nil withTitle:task]);
    [progress setTitle:task];
    [progress addProgressEvent:event];
}

- (void) addProgressEventForTask:(NSArray *)data {
    CydiaProgressEvent *event([data objectAtIndex:0]);
    NSString *task([data count] < 2 ? nil : [data objectAtIndex:1]);
    [self addProgressEvent:event forTask:task];
}

- (void) addProgressEventOnMainThread:(CydiaProgressEvent *)event forTask:(NSString *)task {
    [self performSelectorOnMainThread:@selector(addProgressEventForTask:) withObject:[NSArray arrayWithObjects:event, task, nil] waitUntilDone:YES];
}

@end

/*IMP alloc_;
id Alloc_(id self, SEL selector) {
    id object = alloc_(self, selector);
    lprintf("[%s]A-%p\n", self->isa->name, object);
    return object;
}*/

/*IMP dealloc_;
id Dealloc_(id self, SEL selector) {
    id object = dealloc_(self, selector);
    lprintf("[%s]D-%p\n", self->isa->name, object);
    return object;
}*/

static NSMutableDictionary *DeepMutableCopyOfDictionary(CFTypeRef type) {
    if (type == NULL)
        return nil;
    if (CFGetTypeID(type) != CFDictionaryGetTypeID())
        return nil;
    CFTypeRef copy(CFPropertyListCreateDeepCopy(kCFAllocatorDefault, type, kCFPropertyListMutableContainers));
    CFRelease(type);
    return CFBridgingRelease(copy);
}

int main_copy();
int main_file();
int main_gpgv();
int main_rred(int, char *argv[]);

#ifndef __arm__
#define main_gzip main_store
#else
int main_gzip(int, char *argv[]);
#endif

int main_store(int, char *argv[]);

int main_http();

int main(int argc, char *argv[]) {
    const char *argv0(argv[0]);
    if (const char *slash = strrchr(argv0, '/'))
        argv0 = slash + 1;
    if (false);
    else if (!strcmp(argv0, "copy"))
        return main_copy();
    else if (!strcmp(argv0, "file"))
        return main_file();
    else if (!strcmp(argv0, "gpgv"))
        return main_gpgv();
    else if (!strcmp(argv0, "rred"))
        return main_rred(argc, argv);
#ifdef __arm__
    else if (!strcmp(argv0, "bzip2"))
        return main_gzip(argc, argv);
    else if (!strcmp(argv0, "gzip"))
        return main_gzip(argc, argv);
    else if (!strcmp(argv0, "lzma"))
        return main_gzip(argc, argv);
#endif
#ifndef __arm__
    else if (!strcmp(argv0, "store"))
        return main_store(argc, argv);
#endif
    else if (!strcmp(argv0, "http"))
        return main_http();
    else if (!strcmp(argv0, "https"))
        return main_http();
    else {}

    if ([WebPreferences respondsToSelector:@selector(setWebKitLinkTimeVersion:)])
                [WebPreferences setWebKitLinkTimeVersion:PACKED_VERSION(3453,0,0)];

    // Ensure we have a stdout and stderr
    int fd(open("/tmp/cydia.log", O_WRONLY | O_APPEND | O_CREAT, 0644));
    // Added this because stderr output ended up in metadata.cb0 somehow once
    // Perhaps we were spawned with stderr or stdout closed?
    //
    // Ensure we have a stdout and stderr
    if (fcntl(STDOUT_FILENO, F_GETFD) == -1) {
        dup2(fd, STDOUT_FILENO);
    }
    dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO) {
        close(fd);
    }

    @autoreleasepool {

    _trace();

    CyteInitialize([NSString stringWithFormat:@"Cydia/%@", Cydia_]);
    UpdateExternalStatus(0);

    SessionData_ = [NSMutableDictionary dictionaryWithCapacity:4];
    BridgedHosts_ = [NSMutableSet setWithCapacity:4];
    InsecureHosts_ = [NSMutableSet setWithCapacity:4];

    UI_ = CydiaURL([NSString stringWithFormat:@"ui/ios~%@/1.1", IsWildcat_ ? @"ipad" : @"iphone"]);
    PackageName = reinterpret_cast<CYString &(*)(Package *, SEL)>(method_getImplementation(class_getInstanceMethod([Package class], @selector(cyname))));

    /* Set Locale {{{ */
    Locale_ = CFLocaleCopyCurrent();
    Languages_ = [NSLocale preferredLanguages];

    std::string languages;
    const char *translation(NULL);

    // XXX: this isn't really a language, but this is compatible with older Cydia builds
    if (Locale_ != NULL)
        if (const char *language = [(NSString *) CFLocaleGetIdentifier(Locale_) UTF8String]) {
            RegEx pattern("([a-z][a-z])(?:-[A-Za-z]*)?(_[A-Z][A-Z])?");
            if (pattern(language)) {
                translation = strdup([pattern->*@"%1$@%2$@" UTF8String]);
                languages += translation;
                languages += ",";
            }
        }

    if (Languages_ != nil)
        for (NSString *locale : Languages_) {
            auto components([NSLocale componentsFromLocaleIdentifier:locale]);
            NSString *language([components objectForKey:(id)kCFLocaleLanguageCode]);
            if (NSString *script = [components objectForKey:(id)kCFLocaleScriptCode])
                language = [NSString stringWithFormat:@"%@-%@", language, script];
            languages += [language UTF8String];
            languages += ",";
        }

    languages += "en";
    NSLog(@"Setting Language: [%s] %s", translation, languages.c_str());
    /* }}} */
    /* Index Collation {{{ */
    if (Class $UILocalizedIndexedCollation = objc_getClass("UILocalizedIndexedCollation")) { @try {
        NSBundle *bundle([NSBundle bundleForClass:$UILocalizedIndexedCollation]);
        NSString *path([bundle pathForResource:@"UITableViewLocalizedSectionIndex" ofType:@"plist"]);
        //path = @"/System/Library/Frameworks/UIKit.framework/.lproj/UITableViewLocalizedSectionIndex.plist";
        NSDictionary *dictionary([NSDictionary dictionaryWithContentsOfFile:path]);
        _H<UILocalizedIndexedCollation> collation([[$UILocalizedIndexedCollation alloc] initWithDictionary:dictionary]);

        CollationLocale_ = MSHookIvar<NSLocale *>(collation, "_locale");

        if (kCFCoreFoundationVersionNumber >= 800 && [[CollationLocale_ localeIdentifier] isEqualToString:@"zh@collation=stroke"]) {
            CollationThumbs_ = [NSArray arrayWithObjects:@"1",@"•",@"4",@"•",@"7",@"•",@"10",@"•",@"13",@"•",@"16",@"•",@"19",@"A",@"•",@"E",@"•",@"I",@"•",@"M",@"•",@"R",@"•",@"V",@"•",@"Z",@"#",nil];
            for (NSInteger offset : (NSInteger[]) {0,1,3,4,6,7,9,10,12,13,15,16,18,25,26,29,30,33,34,37,38,42,43,46,47,50,51})
                CollationOffset_.push_back(offset);
            CollationTitles_ = [NSArray arrayWithObjects:@"1 畫",@"2 畫",@"3 畫",@"4 畫",@"5 畫",@"6 畫",@"7 畫",@"8 畫",@"9 畫",@"10 畫",@"11 畫",@"12 畫",@"13 畫",@"14 畫",@"15 畫",@"16 畫",@"17 畫",@"18 畫",@"19 畫",@"20 畫",@"21 畫",@"22 畫",@"23 畫",@"24 畫",@"25 畫以上",@"A",@"B",@"C",@"D",@"E",@"F",@"G",@"H",@"I",@"J",@"K",@"L",@"M",@"N",@"O",@"P",@"Q",@"R",@"S",@"T",@"U",@"V",@"W",@"X",@"Y",@"Z",@"#",nil];
            CollationStarts_ = [NSArray arrayWithObjects:@"一",@"丁",@"丈",@"不",@"且",@"丞",@"串",@"並",@"亭",@"乘",@"乾",@"傀",@"亂",@"僎",@"僵",@"儐",@"償",@"叢",@"儳",@"嚴",@"儷",@"儻",@"囌",@"囑",@"廳",@"a",@"b",@"c",@"d",@"e",@"f",@"g",@"h",@"i",@"j",@"k",@"l",@"m",@"n",@"o",@"p",@"q",@"r",@"s",@"t",@"u",@"v",@"w",@"x",@"y",@"z",@"ʒ",nil];
        } else {

        CollationThumbs_ = [collation sectionIndexTitles];
        for (size_t index(0), end([CollationThumbs_ count]); index != end; ++index)
            CollationOffset_.push_back([collation sectionForSectionIndexTitleAtIndex:index]);

        CollationTitles_ = [collation sectionTitles];
        CollationStarts_ = MSHookIvar<NSArray *>(collation, "_sectionStartStrings");

        NSString *__unsafe_unretained &transform(MSHookIvar<NSString *__unsafe_unretained>(collation, "_transform"));
        if (transform != nil) {
            /*if ([collation respondsToSelector:@selector(transformedCollationStringForString:)])
                CollationModify_ = [=](NSString *value) { return [collation transformedCollationStringForString:value]; };*/
            const UChar *uid(reinterpret_cast<const UChar *>([transform cStringUsingEncoding:NSUnicodeStringEncoding]));
            UErrorCode code(U_ZERO_ERROR);
            CollationTransl_ = utrans_openU(uid, -1, UTRANS_FORWARD, NULL, 0, NULL, &code);
            if (!U_SUCCESS(code))
                NSLog(@"%s", u_errorName(code));
        }

        }
    } @catch (NSException *e) {
        NSLog(@"%@", e);
        goto hard;
    } } else hard: {
        CollationLocale_ = [[NSLocale alloc] initWithLocaleIdentifier:@"en@collation=dictionary"];

        CollationThumbs_ = [NSArray arrayWithObjects:@"A",@"B",@"C",@"D",@"E",@"F",@"G",@"H",@"I",@"J",@"K",@"L",@"M",@"N",@"O",@"P",@"Q",@"R",@"S",@"T",@"U",@"V",@"W",@"X",@"Y",@"Z",@"#",nil];
        for (NSInteger offset(0); offset != 28; ++offset)
            CollationOffset_.push_back(offset);

        CollationTitles_ = [NSArray arrayWithObjects:@"A",@"B",@"C",@"D",@"E",@"F",@"G",@"H",@"I",@"J",@"K",@"L",@"M",@"N",@"O",@"P",@"Q",@"R",@"S",@"T",@"U",@"V",@"W",@"X",@"Y",@"Z",@"#",nil];
        CollationStarts_ = [NSArray arrayWithObjects:@"a",@"b",@"c",@"d",@"e",@"f",@"g",@"h",@"i",@"j",@"k",@"l",@"m",@"n",@"o",@"p",@"q",@"r",@"s",@"t",@"u",@"v",@"w",@"x",@"y",@"z",@"ʒ",nil];
    }
    /* }}} */

    App_ = [[NSBundle mainBundle] bundlePath];
    Advanced_ = YES;

    Cache_ = [NSString stringWithFormat:@"%@/Library/Caches/com.saurik.Cydia", @"/var/mobile"];
    mkdir([Cache_ UTF8String], 0755);

    /*Method alloc = class_getClassMethod([NSObject class], @selector(alloc));
    alloc_ = alloc->method_imp;
    alloc->method_imp = (IMP) &Alloc_;*/

    /*Method dealloc = class_getClassMethod([NSObject class], @selector(dealloc));
    dealloc_ = dealloc->method_imp;
    dealloc->method_imp = (IMP) &Dealloc_;*/

    void *gestalt(dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_GLOBAL | RTLD_LAZY));
    $MGCopyAnswer = reinterpret_cast<CFStringRef (*)(CFStringRef)>(dlsym(gestalt, "MGCopyAnswer"));
    UniqueID_ = UniqueIdentifier([UIDevice currentDevice]);

    /* System Information {{{ */
    size_t size;

    int maxproc;
    size = sizeof(maxproc);
    if (sysctlbyname("kern.maxproc", &maxproc, &size, NULL, 0) == -1)
        perror("sysctlbyname(\"kern.maxproc\", ?)");
    else if (maxproc < 64) {
        maxproc = 64;
        if (sysctlbyname("kern.maxproc", NULL, NULL, &maxproc, sizeof(maxproc)) == -1)
            perror("sysctlbyname(\"kern.maxproc\", #)");
    }
    /* }}} */
    /* Load Database {{{ */
    SectionMap_ = [[NSDictionary alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Sections" ofType:@"plist"]];

    _trace();
    mkdir("/var/mobile/Library/Cydia", 0755);
    MetaFile_.Open("/var/mobile/Library/Cydia/metadata.cb0");
    _trace();

    Values_ = DeepMutableCopyOfDictionary(CFPreferencesCopyAppValue(CFSTR("CydiaValues"), CFSTR("com.saurik.Cydia")));
    Sections_ = DeepMutableCopyOfDictionary(CFPreferencesCopyAppValue(CFSTR("CydiaSections"), CFSTR("com.saurik.Cydia")));
    Sources_ = DeepMutableCopyOfDictionary(CFPreferencesCopyAppValue(CFSTR("CydiaSources"), CFSTR("com.saurik.Cydia")));
    Version_ = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("CydiaVersion"), CFSTR("com.saurik.Cydia")));

    _trace();
    NSDictionary *metadata([[NSMutableDictionary alloc] initWithContentsOfFile:@"/var/lib/cydia/metadata.plist"]);

    if (Values_ == nil)
        Values_ = [metadata objectForKey:@"Values"];
    if (Values_ == nil)
        Values_ = [[NSMutableDictionary alloc] initWithCapacity:4];

    if (Sections_ == nil)
        Sections_ = [metadata objectForKey:@"Sections"];
    if (Sections_ == nil)
        Sections_ = [[NSMutableDictionary alloc] initWithCapacity:32];

    if (Sources_ == nil)
        Sources_ = [metadata objectForKey:@"Sources"];
    if (Sources_ == nil)
        Sources_ = [[NSMutableDictionary alloc] initWithCapacity:0];

    // XXX: this wrong, but in a way that doesn't matter :/
    if (Version_ == nil)
        Version_ = [metadata objectForKey:@"Version"];
    if (Version_ == nil)
        Version_ = [NSNumber numberWithUnsignedInt:0];

    if (NSDictionary *packages = [metadata objectForKey:@"Packages"]) {
        bool fail(false);
        CFDictionaryApplyFunction((CFDictionaryRef) packages, &PackageImport, &fail);
        _trace();
        if (fail)
            NSLog(@"unable to import package preferences... from 2010? oh well :/");
    }

    if ([Version_ unsignedIntValue] == 0) {
        CydiaAddSource(@"http://apt.thebigboss.org/repofiles/cydia/", @"stable", [NSMutableArray arrayWithObject:@"main"]);
        CydiaAddSource(@"http://apt.modmyi.com/", @"stable", [NSMutableArray arrayWithObject:@"main"]);
        CydiaAddSource(@"http://cydia.zodttd.com/repo/cydia/", @"stable", [NSMutableArray arrayWithObject:@"main"]);
        CydiaAddSource(@"https://repo.chariz.com/", @"./");
        CydiaAddSource(@"https://repo.dynastic.co/", @"./");

        Version_ = [NSNumber numberWithUnsignedInt:1];

        if (NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:CacheState_]) {
            [cache removeObjectForKey:@"LastUpdate"];
            [cache writeToFile:CacheState_ atomically:YES];
        }
    }

    _H<NSMutableArray> broken([NSMutableArray array]);
    for (NSString *key in (id) Sources_)
        if ([key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]].location != NSNotFound || ![([[Sources_ objectForKey:key] objectForKey:@"URI"] ?: @"/") hasSuffix:@"/"])
            [broken addObject:key];
    if ([broken count] != 0)
        for (NSString *key in (id) broken)
            [Sources_ removeObjectForKey:key];
    broken = nil;

    SaveConfig(nil);
    system("/usr/libexec/cydia/cydo /bin/rm -f /var/lib/cydia/metadata.plist");
    /* }}} */

    Finishes_ = [NSArray arrayWithObjects:@"return", @"reopen", @"restart", @"reload", @"reboot", nil];

    if (kCFCoreFoundationVersionNumber > 1000)
        system("/usr/libexec/cydia/cydo /usr/libexec/cydia/setnsfpn /var/lib");

    int version([[NSString stringWithContentsOfFile:@"/var/lib/cydia/firmware.ver"] intValue]);

    if (access("/User", F_OK) != 0 || version != 6) {
        _trace();
        system("/usr/libexec/cydia/cydo /usr/libexec/cydia/firmware.sh");
        _trace();
    }

    if (access("/tmp/cydia.chk", F_OK) == 0) {
        if (unlink([Cache("pkgcache.bin") UTF8String]) == -1)
            _assert(errno == ENOENT);
        if (unlink([Cache("srcpkgcache.bin") UTF8String]) == -1)
            _assert(errno == ENOENT);
    }

    system([[NSString stringWithFormat:@"/usr/libexec/cydia/cydo /bin/ln -sf %@ /etc/apt/sources.list.d/cydia.list", Cache("sources.list")] UTF8String]);

    /* APT Initialization {{{ */
    _assert(pkgInitConfig(*_config));
    _assert(pkgInitSystem(*_config, _system));

    const Configuration::Item *arch = _config->Tree("APT::Architecture");
    NSLog(@"Common Arch: %s\n", arch->Value.c_str());
    common_arch = arch->Value.c_str();
    _config->Set("Acquire::AllowInsecureRepositories", true);
    _config->Set("Acquire::Check-Valid-Until", false);

    _config->Set("Dir::Bin::Methods", "/Applications/Cydia.app");

    _config->Set("pkgCacheGen::ForceEssential", "");

    if (translation != NULL)
        _config->Set("APT::Acquire::Translation", translation);
    _config->Set("Acquire::Languages", languages);

    // XXX: this timeout might be important :(
    //_config->Set("Acquire::http::Timeout", 15);

    int64_t usermem(0);
    size = sizeof(usermem);
    if (sysctlbyname("hw.usermem", &usermem, &size, NULL, 0) == -1)
        usermem = 0;
    _config->Set("Acquire::http::MaxParallel", usermem >= 384 * 1024 * 1024 ? 16 : 3);

    mkdir([Cache("archives") UTF8String], 0755);
    mkdir([Cache("archives/partial") UTF8String], 0755);
    _config->Set("Dir::Cache", [Cache_ UTF8String]);

    symlink("/var/lib/apt/extended_states", [Cache("extended_states") UTF8String]);
    _config->Set("Dir::State", [Cache_ UTF8String]);

    mkdir([Cache("lists") UTF8String], 0755);
    mkdir([Cache("lists/partial") UTF8String], 0755);
    mkdir([Cache("periodic") UTF8String], 0755);
    _config->Set("Dir::State::Lists", [Cache("lists") UTF8String]);

    std::string logs("/var/mobile/Library/Logs/Cydia");
    mkdir(logs.c_str(), 0755);
    _config->Set("Dir::Log", logs);

    _config->Set("Dir::Bin::dpkg", "/usr/libexec/cydia/cydo");
    /* }}} */
    /* Color Choices {{{ */
    space_ = CGColorSpaceCreateDeviceRGB();

    Blue_.Set(space_, 0.2, 0.2, 1.0, 1.0);
    Blueish_.Set(space_, 0x19/255.f, 0x32/255.f, 0x50/255.f, 1.0);
    Black_.Set(space_, 0.0, 0.0, 0.0, 1.0);
    Folder_.Set(space_, 0x8e/255.f, 0x8e/255.f, 0x93/255.f, 1.0);
    Off_.Set(space_, 0.9, 0.9, 0.9, 1.0);
    White_.Set(space_, 1.0, 1.0, 1.0, 1.0);
    Gray_.Set(space_, 0.4, 0.4, 0.4, 1.0);
    Green_.Set(space_, 0.0, 0.5, 0.0, 1.0);
    Purple_.Set(space_, 0.0, 0.0, 0.7, 1.0);
    Purplish_.Set(space_, 0.4, 0.4, 0.8, 1.0);

    InstallingColor_ = [UIColor colorWithRed:0.88f green:1.00f blue:0.88f alpha:1.00f];
    RemovingColor_ = [UIColor colorWithRed:1.00f green:0.88f blue:0.88f alpha:1.00f];
    /* }}}*/
    /* UIKit Configuration {{{ */
    // XXX: I have a feeling this was important
    //UIKeyboardDisableAutomaticAppearance();
    /* }}} */

    $SBSSetInterceptsMenuButtonForever = reinterpret_cast<void (*)(bool)>(dlsym(RTLD_DEFAULT, "SBSSetInterceptsMenuButtonForever"));
    $SBSCopyIconImagePNGDataForDisplayIdentifier = reinterpret_cast<NSData *(*)(NSString *)>(dlsym(RTLD_DEFAULT, "SBSCopyIconImagePNGDataForDisplayIdentifier"));

    const char *symbol(kCFCoreFoundationVersionNumber >= 800 ? "MGGetBoolAnswer" : "GSSystemHasCapability");
    BOOL (*GSSystemHasCapability)(CFStringRef) = reinterpret_cast<BOOL (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, symbol));
    bool fast = GSSystemHasCapability != NULL && GSSystemHasCapability(CFSTR("armv7"));

    PulseInterval_ = fast ? 50000 : 500000;

    Colon_ = UCLocalize("COLON_DELIMITED");
    Elision_ = UCLocalize("ELISION");
    Error_ = UCLocalize("ERROR");
    Warning_ = UCLocalize("WARNING");

    _trace();
    int value(UIApplicationMain(argc, argv, @"Cydia", @"Cydia"));

    CGColorSpaceRelease(space_);
    CFRelease(Locale_);
    return value;
    }
}
