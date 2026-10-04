/* Native catalog transport/local application provider. GPL-3.0-or-later. */
#ifndef Cydia_ApplicationExtensionsProvider_H
#define Cydia_ApplicationExtensionsProvider_H
#import "Cydia/ApplicationExtensionsModel.h"
NS_ASSUME_NONNULL_BEGIN
@protocol CydiaExtensionsRequest <NSObject>
- (void)cancel;
@end
typedef void (^CydiaExtensionsRowsCompletion)(NSArray<CydiaApplicationExtensionRow *> * _Nullable,
                                             NSError * _Nullable);
@protocol CydiaApplicationExtensionsProviding <NSObject>
- (id<CydiaExtensionsRequest>)loadRowsForBundleIdentifier:(NSString * _Nullable)identifier
    completion:(CydiaExtensionsRowsCompletion)completion;
- (NSString * _Nullable)localizedNameForBundleIdentifier:(NSString *)identifier;
- (NSData * _Nullable)localIconDataForBundleIdentifier:(NSString *)identifier;
- (id<CydiaExtensionsRequest>)loadIconURL:(NSURL *)URL
    completion:(void (^)(NSData * _Nullable))completion;
@end
@interface CydiaApplicationExtensionsProvider : NSObject <CydiaApplicationExtensionsProviding>
@end
NS_ASSUME_NONNULL_END
#endif
