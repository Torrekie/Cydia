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
#include "Cydia/CYString.hpp"
#include "Cydia/Collation.hpp"
#include "Cydia/Appearance.h"
#include "Cydia/Application.h"
#include "Cydia/ApplicationInternal.h"
#include "Cydia/AppState.h"
#include "Cydia/ChangeControllers.h"
#include "Cydia/ConfirmationController.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/CydiaWebViewController.h"
#include "Cydia/ControllerState.h"
#include "Cydia/HomeController.h"
#include "Cydia/LoadingViewController.h"
#include "Cydia/NSString+Cydia.h"
#include "Cydia/Package.h"
#include "Cydia/PackageControllers.h"
#include "Cydia/PackageFeatureControllers.h"
#include "Cydia/PackageMetadata.hpp"
#include "Cydia/PackageViews.h"
#include "Cydia/Profile.hpp"
#include "Cydia/Database.h"
#include "Cydia/ProgressData.h"
#include "Cydia/ProgressController.h"
#include "Cydia/ProgressEvent.h"
#include "Cydia/Relations.h"
#include "Cydia/Section.h"
#include "Cydia/SectionControllers.h"
#include "Cydia/Source.h"
#include "Cydia/SourceControllers.h"
#include "Cydia/StashController.h"
#include "Cydia/TabBarController.h"
#include "Cydia/URLHelpers.h"
#include "Cydia/URLProtocol.h"
/* }}} */

const char *common_arch=NULL;

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
NSString *Error_;
NSString *Warning_;

static void (*$SBSSetInterceptsMenuButtonForever)(bool);
extern NSData *(*$SBSCopyIconImagePNGDataForDisplayIdentifier)(NSString *);

static CFStringRef (*$MGCopyAnswer)(CFStringRef);

void CydiaSetMenuButtonIntercepted(bool intercepted) {
    if ($SBSSetInterceptsMenuButtonForever != NULL)
        (*$SBSSetInterceptsMenuButtonForever)(intercepted);
}

NSString *UniqueIdentifier(UIDevice *device) {
    if (kCFCoreFoundationVersionNumber < 800) // iOS 7.x
        return [device ?: [UIDevice currentDevice] uniqueIdentifier];
    else
        return CFBridgingRelease($MGCopyAnswer(CFSTR("UniqueDeviceID")));
}

NSString *ShellEscape(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

void UpdateExternalStatus(uint64_t newStatus) {
    int notify_token;
    if (notify_register_check("com.saurik.Cydia.status", &notify_token) == NOTIFY_STATUS_OK) {
        notify_set_state(notify_token, newStatus);
        notify_cancel(notify_token);
    }
    notify_post("com.saurik.Cydia.status");
}

pid_t launch_get_job_pid(const char *job)
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
const NSStringCompareOptions MatchCompareOptions_ = NSLiteralSearch | NSCaseInsensitiveSearch;

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

/* Random Global Variables {{{ */
int PulseInterval_ = 500000;

const NSString *UI_;

int Finish_;
bool UICache_ = false;
bool RestartSubstrate_;
NSArray *Finishes_;

#define SpringBoard_ "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
#define NotifyConfig_ "/etc/notify.conf"

bool Queuing_;

CYColor Blue_;
CYColor Blueish_;
CYColor Black_;
CYColor Folder_;
CYColor Off_;
CYColor White_;
CYColor Gray_;
CYColor Green_;
CYColor Purple_;
CYColor Purplish_;

UIColor *InstallingColor_;
UIColor *RemovingColor_;

static NSInteger CydiaUserInterfaceStyle;
UIColor *whiteIfNotDark(bool white)
{
  UIColor *color = (white) ? [UIColor whiteColor] : [UIColor blackColor];
  if (CydiaUserInterfaceStyle == UIUserInterfaceStyleDark)
  {
    color = (white) ? [UIColor blackColor] : [UIColor whiteColor];
  }
  return color;
}

void overrideUserInterfaceStyle(NSInteger style)
{
    CydiaUserInterfaceStyle = style;
}

NSString *App_;

BOOL Advanced_;
BOOL Ignored_;

_H<UIFont> Font12_;
_H<UIFont> Font12Bold_;
_H<UIFont> Font14_;
_H<UIFont> Font18_;
_H<UIFont> Font18Bold_;
_H<UIFont> Font22Bold_;

_H<NSString> UniqueID_;

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

CFLocaleRef Locale_;
static NSArray *Languages_;
static CGColorSpaceRef space_;

#define CacheState_ Cache("CacheState.plist")
#define SavedState_ Cache("SavedState.plist")

NSDictionary *SectionMap_;
_H<NSDate> Backgrounded_;
_transient NSMutableDictionary *Values_;
NSMutableDictionary *Sections_;
_H<NSMutableDictionary> Sources_;
static _transient NSNumber *Version_;
time_t now_;

_H<NSMutableDictionary> SessionData_;
_H<NSMutableSet> BridgedHosts_;
_H<NSMutableSet> InsecureHosts_;

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

NSString *VerifySource(NSString *href) {
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
/* }}} */


void SaveConfig(NSObject *lock) {
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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation Cydia

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

@end
#pragma clang diagnostic pop

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

int main_http(int, const char *argv[]);

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
        return main_http(argc, const_cast<const char **>(argv));
    else if (!strcmp(argv0, "https"))
        return main_http(argc, const_cast<const char **>(argv));
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
