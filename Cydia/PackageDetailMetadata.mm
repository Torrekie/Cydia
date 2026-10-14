/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/PackageDetailMetadata.h"
#import "Cydia/PackageDetailViewModel.h"
#import "Cydia/ExternalURLPolicy.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"

namespace {
NSString *Text(id value, NSUInteger limit = 8192) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > limit ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    NSString *text([value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    return text.length == 0 ? nil : [text copy];
}

NSString *WebURL(id value) {
    NSString *text(Text(value));
    NSURL *URL(text == nil ? nil : [NSURL URLWithString:text]);
    return CydiaExternalURLIsValidWebURL(URL) ? URL.absoluteString : nil;
}

NSString *MailURL(NSString *value) {
    NSString *address(Text(value, 512));
    if (address == nil || [address rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
        [address rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"<>?&#,;:\\/"]].location != NSNotFound)
        return nil;
    NSRange at([address rangeOfString:@"@"]);
    if (at.location == NSNotFound || at.location == 0 || NSMaxRange(at) == address.length ||
        [address rangeOfString:@"@" options:0 range:NSMakeRange(NSMaxRange(at), address.length - NSMaxRange(at))].location != NSNotFound)
        return nil;
    NSURLComponents *parts([[NSURLComponents alloc] init]);
    parts.scheme = @"mailto";
    parts.path = address;
    CydiaExternalURLPolicy *policy([[CydiaExternalURLPolicy alloc] initWithURL:parts.URL]);
    return policy.presentationKind == CydiaExternalURLPresentationKindSystem ? policy.destinationURL.absoluteString : nil;
}

void AddRow(NSMutableArray<NSDictionary *> *rows, NSString *identifier, NSString *title,
    NSString *detail, NSString *URL = nil) {
    if (detail.length == 0) return;
    NSMutableDictionary *row([@{@"id": identifier, @"title": title, @"detail": detail} mutableCopy]);
    if (URL.length != 0) row[@"url"] = URL;
    [rows addObject:[row copy]];
}

void AddContact(NSMutableArray<NSDictionary *> *rows, NSString *identifier, NSString *title,
    NSString *nameValue, NSString *addressValue) {
    NSString *name(Text(nameValue, 512)), *address(Text(addressValue, 512));
    NSString *detail(name && address && ![name isEqual:address] ? [NSString stringWithFormat:@"%@ <%@>", name, address] : name ?: address);
    AddRow(rows, identifier, title, detail, MailURL(address));
}

NSString *ActionText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"Actions"];
}
}

NSArray<NSDictionary *> *CydiaPackageDetailMetadataRows(CydiaPackageDetailViewModel *viewModel) {
    NSMutableArray<NSDictionary *> *rows([NSMutableArray array]);
    AddContact(rows, @"author", UCLocalize("AUTHOR"), viewModel.authorName, viewModel.authorAddress);
    AddContact(rows, @"maintainer", UCLocalize("MAINTAINER"), viewModel.maintainerName, viewModel.maintainerAddress);
    NSString *sponsor(Text(viewModel.sponsorName, 512)), *sponsorURL(WebURL(viewModel.sponsorURLString));
    AddRow(rows, @"sponsor", ActionText(@"PACKAGE_SPONSOR"),
        sponsor && sponsorURL && ![sponsor isEqual:sponsorURL] ? [NSString stringWithFormat:@"%@\n%@", sponsor, sponsorURL] : sponsor ?: sponsorURL, sponsorURL);
    NSString *homepage(WebURL(viewModel.homepageURLString));
    AddRow(rows, @"homepage", UCLocalize("MORE_INFORMATION"), homepage, homepage);
    NSMutableOrderedSet<NSString *> *tags([NSMutableOrderedSet orderedSet]);
    for (id value in viewModel.tags) {
        NSString *tag(Text(value, 256));
        if (tag != nil) [tags addObject:tag];
    }
    AddRow(rows, @"tags", ActionText(@"PACKAGE_TAGS"), [tags.array componentsJoinedByString:@", "]);
    NSString *icon(WebURL(viewModel.iconURLString));
    AddRow(rows, @"icon", ActionText(@"PACKAGE_ICON"), icon, icon);
    NSString *support(WebURL(viewModel.supportURLString));
    AddRow(rows, @"support", UCLocalize("PACKAGE_SUPPORT"), support, support);
    return [rows copy];
}

@interface CydiaPackageDetailMetadataTableCell : UITableViewCell
@property(nonatomic, strong, readonly) UILabel *metadataTitleLabel;
@property(nonatomic, strong, readonly) UILabel *metadataDetailLabel;
@end

@implementation CydiaPackageDetailMetadataTableCell
- (instancetype)initWithReuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier])) {
        _metadataTitleLabel = [[UILabel alloc] init];
        _metadataDetailLabel = [[UILabel alloc] init];
        for (UILabel *label in @[_metadataTitleLabel, _metadataDetailLabel]) {
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.numberOfLines = 0;
            label.adjustsFontForContentSizeCategory = YES;
            label.lineBreakMode = NSLineBreakByWordWrapping;
            [self.contentView addSubview:label];
        }
        _metadataTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _metadataDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        UILayoutGuide *margins(self.contentView.layoutMarginsGuide);
        [NSLayoutConstraint activateConstraints:@[
            [_metadataTitleLabel.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [_metadataTitleLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_metadataTitleLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_metadataDetailLabel.topAnchor constraintEqualToAnchor:_metadataTitleLabel.bottomAnchor constant:4],
            [_metadataDetailLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_metadataDetailLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [_metadataDetailLabel.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        ]];
        self.isAccessibilityElement = YES;
    }
    return self;
}
@end

UITableViewCell *CydiaPackageDetailMetadataCell(UITableView *table, NSDictionary *row, UITraitCollection *traits) {
    static NSString *identifier = @"CydiaPackageDetailMetadata";
    CydiaPackageDetailMetadataTableCell *cell((id)[table dequeueReusableCellWithIdentifier:identifier]);
    if (cell == nil) cell = [[CydiaPackageDetailMetadataTableCell alloc] initWithReuseIdentifier:identifier];
    NSString *title([row[@"title"] isKindOfClass:NSString.class] ? row[@"title"] : @"");
    NSString *detail([row[@"detail"] isKindOfClass:NSString.class] ? row[@"detail"] : @"");
    NSString *URL([row[@"url"] isKindOfClass:NSString.class] ? row[@"url"] : nil);
    cell.metadataTitleLabel.text = title;
    cell.metadataDetailLabel.text = detail;
    cell.metadataTitleLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:traits];
    cell.metadataDetailLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:traits];
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:traits];
    cell.selectionStyle = URL.length ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryType = URL.length ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier = [@"cydia.package.metadata." stringByAppendingString:Text(row[@"id"], 128) ?: @"value"];
    cell.accessibilityLabel = title;
    cell.accessibilityValue = detail;
    cell.accessibilityTraits = URL.length ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    return cell;
}
