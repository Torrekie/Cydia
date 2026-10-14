/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/RepositoryLibraryItem.h"
#import "Cydia/PackageArchitecturePresentation.h"
#include "Cydia/AptCompatibility.hpp"

namespace {
NSString *DisplayValue(NSString *value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 || value.length > limit ||
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    return [value copy];
}

NSString *DisplayValue(const std::string &value, NSUInteger limit) {
    /* initWithBytes also rejects invalid UTF-8 without stopping at an embedded
     * NUL. Control characters and excessive lengths then use the safe fallback. */
    if (value.empty() || value.size() > limit * 4) return nil;
    return DisplayValue([[NSString alloc] initWithBytes:value.data() length:value.size()
        encoding:NSUTF8StringEncoding], limit);
}

NSString *ArchitectureValue(NSString *value) {
    NSString *name(DisplayValue(value, 128));
    NSCharacterSet *characters = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyz0123456789-"];
    return name != nil && [name rangeOfCharacterFromSet:characters.invertedSet].location == NSNotFound ? name : nil;
}

NSArray<NSString *> *RegisteredArchitectures(NSArray<NSString *> *values) {
    NSMutableArray<NSString *> *architectures = [NSMutableArray array];
    for (id value in values) {
        NSString *name(ArchitectureValue(value));
        if (name != nil && ![name isEqualToString:@"all"] && ![name isEqualToString:@"any"] &&
            ![architectures containsObject:name]) [architectures addObject:name];
    }
    return [architectures copy];
}

NSString *UnsupportedArchitectureCaption(const std::vector<std::string> &values,
    NSArray<NSString *> *registeredArchitectures) {
    NSMutableArray<NSString *> *captions = [NSMutableArray array];
    for (const std::string &value : values) {
        NSString *name(ArchitectureValue(DisplayValue(value, 128)));
        NSString *caption(CydiaPackageArchitectureCaption(name, registeredArchitectures));
        if (caption != nil && ![captions containsObject:caption]) [captions addObject:caption];
    }
    return captions.count == 0 ? nil : [captions componentsJoinedByString:@", "];
}
} // namespace

@implementation CydiaRepositoryLibraryItem
- (instancetype)initWithIdentifier:(NSString *)identifier
                     availability:(const CydiaAPT::RepositoryPackageAvailabilityData &)availability
                     selectedName:(NSString *)selectedName
            selectedRouteIdentity:(NSString *)selectedRouteIdentity
                  selectedVersion:(NSString *)selectedVersion
             selectedArchitecture:(NSString *)selectedArchitecture
               selectedFromSource:(BOOL)selectedFromSource
                 versionAvailable:(BOOL)versionAvailable
            architectureSupported:(BOOL)architectureSupported
          registeredArchitectures:(NSArray<NSString *> *)registeredArchitectures {
    if ((self = [super init])) {
        _identifier = DisplayValue(identifier, 256) ?: @"";
        _displayName = (availability.known ? DisplayValue(availability.displayName, 512) : nil) ?:
            (selectedFromSource ? DisplayValue(selectedName, 512) : nil) ?: _identifier;
        NSArray<NSString *> *architectures(RegisteredArchitectures(registeredArchitectures));
        if (selectedFromSource) {
            _version = DisplayValue(selectedVersion, 256);
            _architectureCaption = [CydiaPackageArchitectureCaption(
                ArchitectureValue(selectedArchitecture), architectures) copy];
        }
        _statusLocalizationKey = @"ACCOUNT_ITEM_NOT_IN_SOURCE";
        NSString *route(selectedFromSource && versionAvailable && architectureSupported ?
            DisplayValue(selectedRouteIdentity, 512) : nil);
        if (route && (!availability.known ||
            (availability.hasCompatibleVersion && availability.hasDownloadableVersion))) {
            // Existing providers need no new metadata IPC to preserve their
            // verified, same-source current package navigation.
            _state = CydiaRepositoryLibraryItemStateAvailable;
            _routeIdentity = route;
            _statusLocalizationKey = @"ACCOUNT_OWNED";
        } else if (!availability.known || (architectures.count == 0 &&
            !availability.architectures.empty() && !availability.hasCompatibleVersion)) {
            _state = CydiaRepositoryLibraryItemStateUnknown;
        } else if (!availability.architectures.empty() && !availability.hasCompatibleVersion) {
            _state = CydiaRepositoryLibraryItemStateUnsupportedArchitecture;
            _statusLocalizationKey = @"ACCOUNT_ITEM_ARCHITECTURE_UNSUPPORTED";
            /* This inventory is source-scoped even when the selected package
             * belongs to another repository or no visible package exists. */
            _architectureCaption = [UnsupportedArchitectureCaption(availability.architectures, architectures) copy];
        } else if (!availability.hasCompatibleVersion || !availability.hasDownloadableVersion) {
            _state = CydiaRepositoryLibraryItemStateNoDownloadableVersion;
            _statusLocalizationKey = @"ACCOUNT_ITEM_NO_VERSION";
        } else {
            _state = CydiaRepositoryLibraryItemStateNotSelected;
        }
    }
    return self;
}
@end
