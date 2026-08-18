/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
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

#include "Cydia/ConfirmationController.h"

#include "Cydia/AppState.h"
#include "Cydia/Database.h"
#include "Cydia/DatabaseApt.h"
#include "Cydia/Package.h"
#include "CyteKit/Localize.h"
#include "CyteKit/RegEx.hpp"
#include "CyteKit/webScriptObjectInContext.h"
#include "iPhonePrivate.h"

#include <apt-pkg/cachefile.h>
#include <apt-pkg/depcache.h>
#include <apt-pkg/policy.h>

#include <cstring>

#define AlwaysReload 0

static bool DepSubstrate(const pkgCache::VerIterator &iterator) {
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
            pkgCache::PkgIterator iterator([database_ iteratorForPackageHandle:[package handle]]);
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
