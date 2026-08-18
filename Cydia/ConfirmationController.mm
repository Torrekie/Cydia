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
#include "Cydia/Package.h"
#include "CyteKit/Localize.h"
#include "CyteKit/RegEx.hpp"
#include "CyteKit/webScriptObjectInContext.h"
#include "iPhonePrivate.h"

#include <cstring>

#define AlwaysReload 0

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

        const CydiaAPT::TransactionData transaction([database_ transactionData]);
        for (std::vector<std::string>::const_iterator value(transaction.installs.begin()); value != transaction.installs.end(); ++value)
            [installs addObject:[NSString stringWithUTF8String:value->c_str()]];
        for (std::vector<std::string>::const_iterator value(transaction.reinstalls.begin()); value != transaction.reinstalls.end(); ++value)
            [reinstalls addObject:[NSString stringWithUTF8String:value->c_str()]];
        for (std::vector<std::string>::const_iterator value(transaction.upgrades.begin()); value != transaction.upgrades.end(); ++value)
            [upgrades addObject:[NSString stringWithUTF8String:value->c_str()]];
        for (std::vector<std::string>::const_iterator value(transaction.downgrades.begin()); value != transaction.downgrades.end(); ++value)
            [downgrades addObject:[NSString stringWithUTF8String:value->c_str()]];
        for (std::vector<std::string>::const_iterator value(transaction.removes.begin()); value != transaction.removes.end(); ++value)
            [removes addObject:[NSString stringWithUTF8String:value->c_str()]];

        issues_ = [NSMutableArray arrayWithCapacity:transaction.issues.size()];
        for (std::vector<CydiaAPT::TransactionIssueData>::const_iterator issue(transaction.issues.begin()); issue != transaction.issues.end(); ++issue) {
            NSMutableArray *reasons([NSMutableArray arrayWithCapacity:issue->reasons.size()]);
            for (std::vector<CydiaAPT::TransactionReasonData>::const_iterator reason(issue->reasons.begin()); reason != issue->reasons.end(); ++reason) {
                NSMutableArray *clauses([NSMutableArray arrayWithCapacity:reason->clauses.size()]);
                for (std::vector<CydiaAPT::TransactionClauseData>::const_iterator clause(reason->clauses.begin()); clause != reason->clauses.end(); ++clause) {
                    NSDictionary *version(clause->version.empty() ? (NSDictionary *) [NSNull null] : (NSDictionary *) [NSDictionary dictionaryWithObjectsAndKeys:
                        [NSString stringWithUTF8String:clause->comparison.c_str()], @"operator",
                        [NSString stringWithUTF8String:clause->version.c_str()], @"value",
                    nil]);
                    NSString *installed(clause->installed.empty() ? (NSString *) [WebUndefined undefined] : [NSString stringWithUTF8String:clause->installed.c_str()]);
                    [clauses addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        [NSString stringWithUTF8String:clause->package.c_str()], @"package",
                        version, @"version",
                        [NSString stringWithUTF8String:clause->reason.c_str()], @"reason",
                        installed, @"installed",
                    nil]];
                }
                [reasons addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    [NSString stringWithUTF8String:reason->relationship.c_str()], @"relationship",
                    clauses, @"clauses",
                nil]];
            }
            id package(issue->package.empty() ? (id) [NSNull null] : (id) [NSString stringWithUTF8String:issue->package.c_str()]);
            [issues_ addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                package, @"package",
                reasons, @"reasons",
            nil]];
        }

        const bool remove(transaction.removesEssential);
        substrate_ = transaction.substrate;

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
            [NSNumber numberWithUnsignedLongLong:transaction.downloading], @"downloading",
            [NSNumber numberWithUnsignedLongLong:transaction.resuming], @"resuming",
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
