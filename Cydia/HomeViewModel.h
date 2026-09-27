/* Cydia Refurbished native Home snapshot.
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_HomeViewModel_H
#define Cydia_HomeViewModel_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, CydiaHomeStatus) {
    CydiaHomeStatusLoading,
    CydiaHomeStatusReady,
    CydiaHomeStatusUpdating,
    CydiaHomeStatusOffline,
};

FOUNDATION_EXPORT NSString *CydiaHomeVisibleVersion(NSString *version);
FOUNDATION_EXPORT NSString *CydiaHomeFooterText(NSString *hardwareModel,
    NSString *systemVersion, NSUInteger bitness, NSString *cydiaVersion,
    NSString *language, NSString *deviceIdentifier);

/* The Home controller owns this immutable, database-independent snapshot so
 * the dashboard can be rendered and probed without retaining APT objects. */
@interface CydiaHomeViewModel : NSObject

@property (nonatomic, readonly) NSUInteger sourceCount;
@property (nonatomic, readonly) NSUInteger packageCount;
@property (nonatomic, readonly) NSUInteger installedCount;
@property (nonatomic, readonly) NSUInteger upgradeCount;
@property (nonatomic, readonly) NSUInteger halfInstalledCount;
@property (nonatomic, readonly) NSUInteger databaseEra;
@property (nonatomic, readonly, getter=isDatabaseReady) BOOL databaseReady;
@property (nonatomic, readonly) CydiaHomeStatus status;
@property (nonatomic, readonly, copy) NSString *statusMessage;

- (instancetype) initWithSourceCount:(NSUInteger)sourceCount
                         packageCount:(NSUInteger)packageCount
                        installedCount:(NSUInteger)installedCount
                          upgradeCount:(NSUInteger)upgradeCount
                    halfInstalledCount:(NSUInteger)halfInstalledCount
                         databaseReady:(BOOL)databaseReady
                          databaseEra:(NSUInteger)databaseEra
                               status:(CydiaHomeStatus)status
                        statusMessage:(NSString *)statusMessage NS_DESIGNATED_INITIALIZER;

- (instancetype) init NS_UNAVAILABLE;
+ (instancetype) new NS_UNAVAILABLE;

@end

#endif // Cydia_HomeViewModel_H
