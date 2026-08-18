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
 */
/* }}} */

#include "Cydia/CydiaWebViewController.h"

#include "Cydia/AppState.h"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "CyteKit/countByEnumeratingWithState.h"
#include "CyteKit/extern.h"
#include "CyteKit/Localize.h"
#include "iPhonePrivate.h"

#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <sys/sysctl.h>

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

@implementation AppCacheController

- (void) didReceiveMemoryWarning {
    // XXX: this doesn't work
}

- (bool) retainsNetworkActivityIndicator {
    return false;
}

@end
/* }}} */
