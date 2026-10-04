/* Native Application Extensions catalog values. GPL-3.0-or-later. */
#ifndef Cydia_ApplicationExtensionsModel_H
#define Cydia_ApplicationExtensionsModel_H
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface CydiaApplicationExtensionRow : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *author;
@property(nonatomic, copy, readonly) NSString *summary;
@property(nonatomic, copy, readonly) NSString *price;
@property(nonatomic, readonly) NSUInteger extensionCount;
@property(nonatomic, strong, readonly, nullable) NSURL *iconURL;
@property(nonatomic, copy, readonly, nullable) NSString *localIconPath;
@end

FOUNDATION_EXPORT BOOL CydiaExtensionIdentifierIsValid(NSString * _Nullable identifier);
FOUNDATION_EXPORT NSURL * _Nullable CydiaExtensionIconURL(NSString * _Nullable value);
/* nil denotes malformed/unavailable data; an empty array is a successful empty result.
 * Application names are local only and are never part of a network request. */
FOUNDATION_EXPORT NSArray<CydiaApplicationExtensionRow *> * _Nullable
CydiaExtensionApplicationRows(NSData *data, NSDictionary<NSString *, NSString *> *names,
                             NSDictionary<NSString *, NSString *> *iconPaths, NSError **error);
FOUNDATION_EXPORT NSArray<CydiaApplicationExtensionRow *> * _Nullable
CydiaExtensionPackageRows(NSData *HTMLData, NSError **error);
NS_ASSUME_NONNULL_END
#endif
