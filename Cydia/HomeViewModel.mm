/* Cydia Refurbished native Home snapshot.
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Cydia/HomeViewModel.h"

NSString *CydiaHomeVisibleVersion(NSString *version) {
    if ([version length] == 0)
        return @"";

    NSUInteger plus(NSNotFound);
    for (NSUInteger index(0); index != [version length]; ++index) {
        unichar character([version characterAtIndex:index]);
        if (character == '+') {
            plus = index;
            break;
        }
        if (character != '.' && !(character >= '0' && character <= '9'))
            return version;
    }
    if (plus == NSNotFound)
        return version;

    NSUInteger end(plus + 1);
    while (end != [version length] &&
            [version characterAtIndex:end] >= '0' &&
            [version characterAtIndex:end] <= '9')
        ++end;
    return [version substringToIndex:end];
}

NSString *CydiaHomeFooterText(NSString *hardwareModel, NSString *systemVersion,
    NSUInteger bitness, NSString *cydiaVersion, NSString *language,
    NSString *deviceIdentifier) {
    NSString *summary([NSString stringWithFormat:@"%@, iOS %@, Cydia%lu_%@ (%@)",
        hardwareModel ?: @"", systemVersion ?: @"", (unsigned long)bitness,
        CydiaHomeVisibleVersion(cydiaVersion), language ?: @""]);
    return [deviceIdentifier length] == 0 ? summary :
        [NSString stringWithFormat:@"%@\n%@", summary, deviceIdentifier];
}

@implementation CydiaHomeViewModel

- (instancetype) initWithSourceCount:(NSUInteger)sourceCount
                         packageCount:(NSUInteger)packageCount
                        installedCount:(NSUInteger)installedCount
                          upgradeCount:(NSUInteger)upgradeCount
                    halfInstalledCount:(NSUInteger)halfInstalledCount
                         databaseReady:(BOOL)databaseReady
                          databaseEra:(NSUInteger)databaseEra
                               status:(CydiaHomeStatus)status
                        statusMessage:(NSString *)statusMessage {
    if ((self = [super init]) != nil) {
        _sourceCount = sourceCount;
        _packageCount = packageCount;
        _installedCount = installedCount;
        _upgradeCount = upgradeCount;
        _halfInstalledCount = halfInstalledCount;
        _databaseReady = databaseReady;
        _databaseEra = databaseEra;
        _status = status;
        _statusMessage = [statusMessage copy] ?: @"";
    }
    return self;
}

@end
