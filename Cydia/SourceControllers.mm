/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Modified work Copyright (C) 2026       Torrekie
 */

#include "CyteKit/UCPlatform.h"
#include "Cydia/SourceControllers.h"

#include "Cydia/Appearance.h"
#include "Cydia/AppState.h"
#include "Cydia/CydiaDelegate.h"
#include "Cydia/Database.h"
#include "Cydia/LegacyUICompatibilityNativeCaller.h"
#include "Cydia/SectionControllers.h"
#include "Cydia/Source.h"
#include "Cydia/SourceVerificationRequestPolicy.h"
#include "Cydia/MoreSourcesModel.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/URLHelpers.h"
#include "Sources.h"
#include "CyteKit/Localize.h"
#include "CyteKit/TableViewCell.h"
#include "CyteKit/extern.h"
#include "Menes/Menes.h"
#include "Menes/ObjectHandle.h"
#include "iPhonePrivate.h"

#include <QuartzCore/QuartzCore.h>

#include <objc/runtime.h>

#include <cstdio>

#define lprintf(args...) fprintf(stderr, args)

// Match MobileCydia's release build: trace logging is disabled.
#undef _trace
#define _trace(args...)

/* Source Cell {{{ */
@interface SourceCell : CyteTableViewCell <CyteTableViewCellDelegate, SourceDelegate> {
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

- (void) applyColorAppearance {
    UIColor *color([UIColor cydiaColorForRole:CydiaColorRoleBackground
                              traitCollection:self.traitCollection]);
    [self setBackgroundColor:color];
    [self.content setBackgroundColor:color];
    [indicator_ setColor:[UIColor cydiaColorForRole:CydiaColorRoleFolderLabel
                                    traitCollection:self.traitCollection]];
}

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
        [self applyColorAppearance];
        [self.content setOpaque:YES];

        indicator_ = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGraySmall];
        [indicator_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin];// | UIViewAutoresizingFlexibleBottomMargin];
        [[self contentView] addSubview:indicator_];

        [self applyColorAppearance];

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
        CydiaSetColor(CydiaColorRoleSelectedLabel, self.traitCollection);

    if (!highlighted)
        CydiaSetColor(CydiaColorRoleLabel, self.traitCollection);
    [origin_ drawAtPoint:CGPointMake(52, 8) forWidth:(width - 49) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (!highlighted)
        CydiaSetColor(CydiaColorRoleSecondaryLabel, self.traitCollection);
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
@protocol SourcesControllerApplicationDelegate <CydiaDelegate, NSObject>
- (CydiaLegacyUICompatibilityNativeSession *) legacyUICompatibilitySessionForSource:(Source *)source
                                                                              presenter:(id)presenter;
@end

@interface SourcesController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation SourcesController {
    __weak Database *database_;
    unsigned era_;

    _H<UITableView, 2> list_;
    _H<NSMutableArray> sources_;
    int offset_;

    _H<NSString> href_;
    _H<UIProgressHUD> hud_;
    _H<NSError> error_;

    __strong NSURLConnection *trivial_bz2_;
    __strong NSURLConnection *trivial_gz_;
    __strong NSURLConnection *trivial_xz_;
    __strong NSMapTable *source_verification_trackers_;

    __strong CydiaLegacyUICompatibilityNativeSession *legacyCompatibilitySession_;

    BOOL cydia_;
    NSDictionary *restoration_;
    void (^restorationCompletion_)(BOOL);
    UIAlertView *restorationAlert_;
    BOOL restorationConfirmed_;
    NSUInteger restorationGeneration_;
}

- (void) invalidateLegacyCompatibilitySession {
    [legacyCompatibilitySession_ invalidate];
    legacyCompatibilitySession_ = nil;
}

- (BOOL) sourceIsCanonical:(Source *)source {
    BOOL exactSource(object_getClass(source) == [Source class]);
    if (database_ == nil || !exactSource)
        return NO;
    @synchronized (database_) {
        if ([database_ era] != era_)
            return NO;
        for (id candidate in [database_ sources])
            if (candidate == source)
                return YES;
    }
    return NO;
}

- (void) bindLegacyCompatibilitySessionForSource:(Source *)source {
    id delegate([self delegate]);
    NSString *sourceKey([source key]);
    BOOL validKey([sourceKey isKindOfClass:[NSString class]] &&
        [sourceKey length] != 0 &&
        [sourceKey rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound);
    if (!validKey || ![self sourceIsCanonical:source] || delegate == nil ||
        ![delegate respondsToSelector:@selector(
            legacyUICompatibilitySessionForSource:presenter:)]) {
        [self invalidateLegacyCompatibilitySession];
        return;
    }

    if (legacyCompatibilitySession_ != nil &&
        [legacyCompatibilitySession_ isActive] &&
        [legacyCompatibilitySession_ target] == source &&
        [[legacyCompatibilitySession_ sourceKey] isEqualToString:sourceKey])
        return;

    [self invalidateLegacyCompatibilitySession];
    CydiaLegacyUICompatibilityNativeSession *session(
        [(id<SourcesControllerApplicationDelegate>)delegate
            legacyUICompatibilitySessionForSource:source presenter:nil]);
    if (session == nil || ![session isActive] || [session target] != source) {
        [session invalidate];
        return;
    }

    id identity([session invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    if (![identity isKindOfClass:[NSString class]] ||
        ![identity isEqualToString:sourceKey] ||
        ![[session sourceKey] isEqualToString:sourceKey]) {
        [session invalidate];
        return;
    }
    legacyCompatibilitySession_ = session;
}

- (void) _cancelConnection:(NSURLConnection *)connection {
    if (connection != nil) {
        [connection cancel];
        //[connection setDelegate:nil];
    }
}

- (void) dealloc {
    [self invalidateLegacyCompatibilitySession];
    [self _cancelConnection:trivial_gz_];
    [self _cancelConnection:trivial_bz2_];
    [self _cancelConnection:trivial_xz_];
    [source_verification_trackers_ removeAllObjects];
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
    Source *source([self sourceAtIndexPath:indexPath]);
    [self bindLegacyCompatibilitySessionForSource:source];
    SectionsController *controller([[SectionsController alloc]
        initWithDatabase:database_
        source:source
    ]);

    [controller setDelegate:self.delegate];
    [[self navigationController] pushViewController:controller animated:YES];
}

- (BOOL) tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!CydiaCanEditManagedSources() || [indexPath section] != 1)
        return false;
    Source *source = [self sourceAtIndexPath:indexPath];
    /* The ownership marker, rather than the optional Sources_ metadata
     * record, is authoritative.  Keep an owned row deletable even if its
     * preference record disappeared during a migration. */
    return source != nil && CydiaManagedSourceKeyIsOwned([source key]);
}

- (void) tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    _assert([indexPath section] == 1);
    if (!CydiaCanEditManagedSources())
        return;
    if (editingStyle ==  UITableViewCellEditingStyleDelete) {
        Source *source = [self sourceAtIndexPath:indexPath];
        if (source == nil || !CydiaManagedSourceKeyIsOwned([source key])) return;

        CydiaRemoveSource([source key]);

        [(NSObject<CydiaDelegate> *) [self delegate] syncData];
    }
}

- (void) tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    [self updateButtonsForEditingStatusAnimated:YES];
}

- (void) complete {
    if (!CydiaCanEditManagedSources() || [href_ length] == 0) {
        href_ = nil;
        [self finishDefaultSourceRestoration:NO];
        return;
    }
    // Consume before calling out: duplicate warning/network callbacks cannot
    // repeat a write, and the later refresh cannot revive the pending tuple.
    NSString *href = href_;
    NSDictionary *restoration = restoration_;
    href_ = nil;
    if (restoration != nil) {
        [(NSObject<CydiaDelegate> *) [self delegate] addSource:@{
            @"Type":@"deb", @"URI":href, @"Distribution":restoration[@"distribution"],
            @"Sections":restoration[@"components"]}];
        [self finishDefaultSourceRestoration:YES];
    } else
        [(NSObject<CydiaDelegate> *) [self delegate] addTrivialSource:href];
    [(NSObject<CydiaDelegate> *) [self delegate] syncData];
}

- (void) finishDefaultSourceRestoration:(BOOL)added {
    void (^completion)(BOOL) = restorationCompletion_;
    restorationCompletion_ = nil; restoration_ = nil;
    restorationAlert_ = nil; restorationConfirmed_ = NO;
    ++restorationGeneration_;
    if (completion) completion(added);
}

- (void) cancelDefaultSourceRestoration {
    if (restoration_ == nil) return;
    [restorationAlert_ setDelegate:nil];
    [restorationAlert_ dismissWithClickedButtonIndex:-1 animated:NO];
    [self _cancelConnection:trivial_bz2_];
    [self _cancelConnection:trivial_gz_];
    [self _cancelConnection:trivial_xz_];
    trivial_bz2_ = nil; trivial_gz_ = nil; trivial_xz_ = nil;
    [source_verification_trackers_ removeAllObjects];
    if (hud_ != nil) {
        [(NSObject<CydiaDelegate> *)self.delegate releaseNetworkActivityIndicator];
        [(NSObject<CydiaDelegate> *)self.delegate removeProgressHUD:hud_];
        hud_ = nil;
    }
    href_ = nil; error_ = nil;
    [self finishDefaultSourceRestoration:NO];
}

- (void) showRestoreDefaultSourcePrompt:(NSString *)identifier completion:(void (^)(BOOL))completion {
    NSDictionary *row = CydiaDefaultSourceForIdentifier(identifier);
    if (row == nil || restoration_ != nil || [href_ length] != 0 ||
        !CydiaCanEditManagedSources() || self.delegate == nil) {
        if (completion) completion(NO);
        return;
    }
    // Recheck actual database sources at activation, not only the Home snapshot.
    @synchronized (database_) {
        for (Source *source in [database_ sources])
            if (![CydiaMissingDefaultSources(@[@{@"rooturi":[source rooturi] ?: @"",
                @"distribution":[source distribution] ?: @""}]) containsObject:row]) {
                if (completion) completion(NO);
                return;
            }
    }
    restoration_ = row; restorationCompletion_ = [completion copy];
    restorationConfirmed_ = NO;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:UCLocalize("ADD_SOURCE")
        message:[NSString stringWithFormat:@"%@\n%@\n%@ %@", row[@"name"], row[@"rooturi"],
            row[@"distribution"], [row[@"components"] componentsJoinedByString:@" "]]
        delegate:self cancelButtonTitle:UCLocalize("CANCEL")
        otherButtonTitles:UCLocalize("ADD_SOURCE"), nil];
    [alert setContext:@"restore-default-source"];
    restorationAlert_ = alert; [alert show];
}

- (void) verifyDefaultSourceRestoration {
    if (restoration_ == nil || !CydiaCanEditManagedSources()) {
        [self cancelDefaultSourceRestoration]; return;
    }
    NSString *href = VerifySource(restoration_[@"rooturi"]);
    NSString *architecture = [NSString stringWithUTF8String:CydiaAPT::Architecture().c_str()];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
    if (href == nil || architecture.length == 0 || [architecture rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        [self cancelDefaultSourceRestoration]; return;
    }
    href_ = href; error_ = nil; cydia_ = NO;
    NSString *base = [href stringByAppendingFormat:@"dists/%@/%@/binary-%@/Packages",
        restoration_[@"distribution"], [restoration_[@"components"] firstObject], architecture];
    trivial_bz2_ = [self _requestHRef:[base stringByAppendingString:@".bz2"] method:@"HEAD"];
    trivial_gz_ = [self _requestHRef:[base stringByAppendingString:@".gz"] method:@"HEAD"];
    trivial_xz_ = [self _requestHRef:[base stringByAppendingString:@".xz"] method:@"HEAD"];
    if (trivial_bz2_ == nil && trivial_gz_ == nil && trivial_xz_ == nil) {
        [self cancelDefaultSourceRestoration]; return;
    }
    hud_ = [(NSObject<CydiaDelegate> *)self.delegate addProgressHUD];
    [hud_ setText:UCLocalize("VERIFYING_URL")];
    [(NSObject<CydiaDelegate> *)self.delegate retainNetworkActivityIndicator];
    [trivial_bz2_ start]; [trivial_gz_ start]; [trivial_xz_ start];
}

- (NSString *) getWarningForSource:(NSDictionary *)snapshot {
    // yieldToSelector runs off-main-thread. Never read pending UI state here;
    // it can be cleared by Back/Cancel while the request is in flight.
    NSString *href(snapshot[@"href"]);
    NSRange colon([href rangeOfString:@"://"]);
    if (colon.location != NSNotFound)
        href = [href substringFromIndex:(colon.location + 3)];
    href = [href stringByAddingPercentEscapes];
    href = [CydiaURL(@"api/repotag/") stringByAppendingString:href];

    NSURL *url([NSURL URLWithString:href]);

    if ([snapshot[@"bounded"] boolValue]) {
        // This newly exposed Home action must not wait indefinitely on the
        // historical warning service. Keep its warning text, with a deadline.
        NSURLRequest *request = [NSURLRequest requestWithURL:url
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
        NSURLResponse *response = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:NULL];
        if (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] != 200) return nil;
        NSString *warning = data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return warning.length == 0 ? nil : warning;
    }

    NSStringEncoding encoding;
    NSError *error(nil);

    if (NSString *warning = [NSString stringWithContentsOfURL:url usedEncoding:&encoding error:&error])
        return [warning length] == 0 ? nil : warning;
    return nil;
}

- (void) _endConnection:(NSURLConnection *)connection {
    // XXX: the memory management in this method is horribly awkward
    if ([source_verification_trackers_ objectForKey:connection] == nil) return;
    [source_verification_trackers_ removeObjectForKey:connection];

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
        NSUInteger generation = restorationGeneration_;
        NSDictionary *snapshot = @{@"href":(NSString *)href_ ?: @"", @"bounded":@(restoration_ != nil)};
        NSString *warning(cydia_ ? [self yieldToSelector:@selector(getWarningForSource:) withObject:snapshot] : nil);
        if (generation != restorationGeneration_) return; // Cancel while warning lookup yielded.

        [(NSObject<CydiaDelegate> *) [self delegate] releaseNetworkActivityIndicator];

        [(NSObject<CydiaDelegate> *) [self delegate] removeProgressHUD:hud_];
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
                if (restoration_ != nil) restorationAlert_ = alert;
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
            if (restoration_ != nil) restorationAlert_ = alert;
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
            if (restoration_ != nil) restorationAlert_ = alert;
            [alert show];

            href_ = nil;
        }

        error_ = nil;
    }
}

- (void) connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
    if ([source_verification_trackers_ objectForKey:connection] == nil) return;
    switch ([response statusCode]) {
        case 200:
            cydia_ = YES;
    }
}

- (NSURLRequest *) connection:(NSURLConnection *)connection
              willSendRequest:(NSURLRequest *)request
             redirectResponse:(NSURLResponse *)response {
    CydiaSourceVerificationRedirectTracker *tracker(
        [source_verification_trackers_ objectForKey:connection]);
    if (tracker == nil)
        return CydiaSourceVerificationRedirectRequest(request);
    return [tracker requestForProposedRequest:request redirectResponse:response];
}

- (void) connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if ([source_verification_trackers_ objectForKey:connection] == nil) return;
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

    NSString *machine(Machine_ == NULL ? nil :
        [NSString stringWithUTF8String:Machine_]);
    NSURLRequest *verified(CydiaSourceVerificationInitialRequest(
        request, machine, UniqueID_));
    NSURLConnection *connection([[NSURLConnection alloc]
        initWithRequest:verified delegate:self startImmediately:NO]);
    if (connection == nil)
        return nil;

    CydiaSourceVerificationRedirectTracker *tracker(
        [[CydiaSourceVerificationRedirectTracker alloc]
            initWithInitialURL:[verified URL]]);
    [source_verification_trackers_ setObject:tracker forKey:connection];
    return connection;
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);
    if ([context isEqualToString:@"restore-default-source"]) {
        if (restoration_ == nil || restorationAlert_ != alert || restorationConfirmed_) return;
        restorationAlert_ = nil;
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
        if (button == 1) {
            restorationConfirmed_ = YES;
            [self verifyDefaultSourceRestoration];
        } else [self cancelDefaultSourceRestoration];
    } else if ([context isEqualToString:@"source"]) {
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
                hud_ = [(NSObject<CydiaDelegate> *) [self delegate] addProgressHUD];
                [hud_ setText:UCLocalize("VERIFYING_URL")];
                [(NSObject<CydiaDelegate> *) [self delegate] retainNetworkActivityIndicator];

                /* All ivars and UI state must be installed before a deferred
                 * connection can deliver a delegate callback. */
                [trivial_bz2_ start];
                [trivial_gz_ start];
                [trivial_xz_ start];
            } break;

            case 0:
            break;

            _nodefault
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"trivial"]) {
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
        if (restorationAlert_ == alert) [self cancelDefaultSourceRestoration];
    } else if ([context isEqualToString:@"urlerror"]) {
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
        if (restorationAlert_ == alert) [self cancelDefaultSourceRestoration];
    } else if ([context isEqualToString:@"warning"]) {
        if (restoration_ != nil && restorationAlert_ != alert) return;
        restorationAlert_ = nil;
        switch (button) {
            case 1: {
                NSUInteger generation = restorationGeneration_;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == restorationGeneration_) [self complete];
                });
            }
            break;

            case 0:
                [self cancelDefaultSourceRestoration];
            break;

            _nodefault
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}

- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated {
    if (!CydiaCanEditManagedSources()) {
        [list_ setEditing:NO animated:animated];
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("REFRESH")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(refreshButtonClicked)
        ] animated:animated];
        [[self navigationItem] setRightBarButtonItem:nil animated:animated];
        return;
    }

    BOOL editing([list_ isEditing]);

    if (editing)
        [[self navigationItem] setLeftBarButtonItem:[[UIBarButtonItem alloc]
            initWithTitle:UCLocalize("ADD")
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(addButtonClicked)
        ] animated:animated];
    else if ([(NSObject<CydiaDelegate> *) [self delegate] updating])
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
    [list_ setAutoresizingMask:CydiaAutoresizingFlexibleBoth];
    [list_ setRowHeight:53];
    [(UITableView *) list_ setDataSource:self];
    [list_ setDelegate:self];
    [self setView:list_];
}

- (void) viewDidLoad {
    [super viewDidLoad];
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
        source_verification_trackers_ = [NSMapTable weakToStrongObjectsMapTable];
    } return self;
}

- (NSDictionary *) cydiaNativeCompatibilitySourceSessionDiagnosticWithDelegate:(id)delegate {
    Source *source(nil);
    for (id candidate in [database_ sources])
        if (object_getClass(candidate) == [Source class]) {
            source = (Source *)candidate;
            break;
        }
    if (source == nil || delegate == nil ||
        ![delegate respondsToSelector:@selector(
            legacyUICompatibilitySessionForSource:presenter:)])
        return @{
            @"sourceControllerCaller": NSStringFromClass([self class]),
            @"sourceControllerTarget": @NO,
            @"sourceControllerTypedRead": @NO,
            @"sourceControllerRetained": @NO,
            @"sourceControllerReloadInvalidationDenied": @NO,
            @"sourceControllerDisappearanceInvalidationDenied": @NO,
            @"sourceControllerDeallocInvalidationDenied": @NO,
        };

    SourcesController *controller([[SourcesController alloc] initWithDatabase:database_]);
    [controller setDelegate:delegate];
    [controller reloadData];
    [controller bindLegacyCompatibilitySessionForSource:source];
    CydiaLegacyUICompatibilityNativeSession *initialSession(
        controller->legacyCompatibilitySession_);
    id initialKey([initialSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL initialRead([initialKey isKindOfClass:[NSString class]] &&
        [initialKey isEqualToString:[source key]]);
    BOOL retained(initialSession != nil && [initialSession isActive] &&
        [initialSession target] == source);

    [controller reloadData];
    id reloadedKey([initialSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL reloadInvalidationDenied(![initialSession isActive] &&
        reloadedKey == [CydiaLegacyUIUndefinedValue value] &&
        [initialSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);

    CydiaLegacyUICompatibilityNativeSession *reboundSession(
        controller->legacyCompatibilitySession_);
    [controller bindLegacyCompatibilitySessionForSource:nil];
    id disappearedKey([reboundSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL disappearanceInvalidationDenied(reboundSession != nil &&
        ![reboundSession isActive] &&
        disappearedKey == [CydiaLegacyUIUndefinedValue value] &&
        [reboundSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);

    /* Keep the lifetime probe in its own scope.  ARC may otherwise extend a
     * strong Objective-C++ local through the rest of this diagnostic method,
     * making the weak check observe the probe's own compiler lifetime rather
     * than the controller's actual teardown.  Explicitly invalidate the
     * session and view before the scope ends, then inspect only the weak
     * identity and the caller-retained session. */
    __weak SourcesController *weakController(nil);
    CydiaLegacyUICompatibilityNativeSession *deallocSession(nil);
    @autoreleasepool {
        SourcesController *probe([[SourcesController alloc]
            initWithDatabase:database_]);
        probe->era_ = [database_ era];
        [probe setDelegate:delegate];
        [probe bindLegacyCompatibilitySessionForSource:source];
        deallocSession = probe->legacyCompatibilitySession_;
        weakController = probe;
        [probe setDelegate:nil];
        [probe invalidateLegacyCompatibilitySession];
        [probe setView:nil];
        probe = nil;
    }
    BOOL controllerDeallocated(weakController == nil);
    id deallocatedKey([deallocSession invokeScope:@"Source"
        memberKind:CydiaLegacyBridgeMemberKindAttribute memberName:@"key"
        arguments:@[] targetOrigin:nil]);
    BOOL deallocInvalidationDenied(controllerDeallocated && deallocSession != nil &&
        ![deallocSession isActive] &&
        deallocatedKey == [CydiaLegacyUIUndefinedValue value] &&
        [deallocSession lastDenialReason] ==
            CydiaLegacyUICompatibilityNativeDenialReasonInvalidCapability);

    return @{
        @"sourceControllerCaller": NSStringFromClass([self class]),
        @"sourceControllerTarget": @YES,
        @"sourceControllerTypedRead": @(initialRead),
        @"sourceControllerRetained": @(retained),
        @"sourceControllerReloadInvalidationDenied": @(reloadInvalidationDenied),
        @"sourceControllerDisappearanceInvalidationDenied": @(disappearanceInvalidationDenied),
        @"sourceControllerDeallocInvalidationDenied": @(deallocInvalidationDenied),
        @"sourceControllerDeallocControllerDeallocated": @(controllerDeallocated),
        @"sourceControllerDeallocSessionAvailable": @(deallocSession != nil),
        @"sourceControllerDeallocSessionActive": @(
            deallocSession != nil && [deallocSession isActive]),
        @"sourceControllerDeallocUndefinedRead": @(
            deallocatedKey == [CydiaLegacyUIUndefinedValue value]),
        @"sourceControllerDeallocDenialReason": @(deallocSession == nil ?
            CydiaLegacyUICompatibilityNativeDenialReasonNone :
            [deallocSession lastDenialReason]),
    };
}

- (void) reloadData {
    NSString *boundSourceKey([legacyCompatibilitySession_ sourceKey]);
    [self invalidateLegacyCompatibilitySession];
    [super reloadData];
    [self updateButtonsForEditingStatusAnimated:YES];

    Source *sourceToRebind(nil);
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

    if ([boundSourceKey isKindOfClass:[NSString class]] &&
        [boundSourceKey length] != 0)
        for (id candidate in (NSArray *)sources_)
            if (object_getClass(candidate) == [Source class] &&
                [[(Source *)candidate key] isEqualToString:boundSourceKey]) {
                sourceToRebind = (Source *)candidate;
                break;
            }

    [list_ reloadData];
}
    if (boundSourceKey != nil)
        [self bindLegacyCompatibilitySessionForSource:sourceToRebind];
}

- (void) showAddSourcePrompt {
    if (!CydiaCanEditManagedSources())
        return;
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
    if ([(NSObject<CydiaDelegate> *) [self delegate] requestUpdate])
        [self updateButtonsForEditingStatusAnimated:YES];
}

- (void) cancelButtonClicked {
    [(NSObject<CydiaDelegate> *) [self delegate] cancelUpdate];
}

- (void) editButtonClicked {
    if (!CydiaCanEditManagedSources())
        return;
    [list_ setEditing:![list_ isEditing] animated:YES];
    [self updateButtonsForEditingStatusAnimated:YES];
}

@end
/* }}} */
