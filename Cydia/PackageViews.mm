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

#include "Cydia/PackageViews.h"

#include "Cydia/Appearance.h"
#include "Cydia/AppState.h"
#include "Cydia/Database.h"
#include "Cydia/NSString+Cydia.h"
#include "Cydia/Package.h"
#include "Cydia/Section.h"
#include "Cydia/Source.h"
#include "CyteKit/extern.h"
#include "CyteKit/Localize.h"
#include "iPhonePrivate.h"

@implementation PackageCell

#if TARGET_OS_SIMULATOR
- (void) configureAppearanceProbe {
    summarized_ = false;
    name_ = @"Semantic Package Row";
    source_ = @"From Cydia Appearance Probe";
    description_ = @"Already-visible custom drawing updates live";
    commercial_ = false;
    installing_ = true;
    removing_ = false;
    icon_ = [UIImage imageNamed:@"folder.png"];
    badge_ = nil;
    placard_ = nil;
    [self applyColorAppearance];
    [self.content setNeedsDisplay];
}
#endif

- (void) applyColorAppearance {
    UIColor *color = [UIColor cydiaColorForRole:CydiaColorRoleBackground
                                traitCollection:self.traitCollection];
    if (installing_)
        color = [UIColor cydiaColorForRole:CydiaColorRoleInstallingBackground
                            traitCollection:self.traitCollection];
    else if (removing_)
        color = [UIColor cydiaColorForRole:CydiaColorRoleRemovingBackground
                            traitCollection:self.traitCollection];
    [self setBackgroundColor:color];
    [self.content setBackgroundColor:color];
}

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
    installing_ = false;
    removing_ = false;

    if (package == nil)
        [self applyColorAppearance];
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

        NSString *placard;

        if (NSString *mode = [package mode]) {
            if ([mode isEqualToString:@"REMOVE"] || [mode isEqualToString:@"PURGE"]) {
                removing_ = true;
                placard = @"removing";
            } else {
                installing_ = true;
                placard = @"installing";
            }
        } else {
            if ([package installed] != nil)
                placard = @"installed";
            else
                placard = nil;
        }

        if (placard != nil)
            placard_ = [UIImage imageAtPath:[NSString stringWithFormat:@"%@/%@.png", App_, placard]];
    }

    [self applyColorAppearance];
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
        CydiaSetColor(CydiaColorRoleSelectedLabel, self.traitCollection);

    if (!highlighted)
        CydiaSetColor(commercial_ ? CydiaColorRoleCommercialLabel : CydiaColorRoleLabel, self.traitCollection);
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
        CydiaSetColor(CydiaColorRoleSelectedLabel, self.traitCollection);

    if (!highlighted)
        CydiaSetColor(commercial_ ? CydiaColorRoleCommercialLabel : CydiaColorRoleLabel, self.traitCollection);
    [name_ drawAtPoint:CGPointMake(48, 8) forWidth:(width - (placard_ == nil ? 80 : 106)) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];
    [source_ drawAtPoint:CGPointMake(58, 29) forWidth:(width - 95) withFont:Font12_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (!highlighted)
        CydiaSetColor(commercial_ ? CydiaColorRoleCommercialSecondaryLabel : CydiaColorRoleSecondaryLabel, self.traitCollection);
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

@implementation SectionCell

- (void) applyColorAppearance {
    UIColor *color([UIColor cydiaColorForRole:CydiaColorRoleBackground
                              traitCollection:self.traitCollection]);
    [self setBackgroundColor:color];
    [self.content setBackgroundColor:color];
}

- (id) initWithFrame:(CGRect)frame reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithFrame:frame reuseIdentifier:reuseIdentifier]) != nil) {
        icon_ = [UIImage imageNamed:@"folder.png"];
        // XXX: this initial frame is wrong, but is fixed later
        switch_ = [[UISwitch alloc] initWithFrame:CGRectMake(218, 9, 60, 25)];
        [switch_ addTarget:self action:@selector(onSwitch:) forEvents:UIControlEventValueChanged];

        [self applyColorAppearance];
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
        CydiaSetColor(CydiaColorRoleSelectedLabel, self.traitCollection);

    float width(rect.size.width);
    if (editing_)
        width -= 9 + [switch_ frame].size.width;

    if (!highlighted)
        CydiaSetColor(CydiaColorRoleLabel, self.traitCollection);
    [name_ drawAtPoint:CGPointMake(48, 12) forWidth:(width - 58) withFont:Font18_ lineBreakMode:NSLineBreakByTruncatingTail];

    CGSize size = [count_ sizeWithFont:Font14_];

    CydiaSetColor(CydiaColorRoleFolderLabel, self.traitCollection);
    if (count_ != nil)
        [count_ drawAtPoint:CGPointMake(Retina(10 + (30 - size.width) / 2), 18) withFont:Font12Bold_];
}

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
