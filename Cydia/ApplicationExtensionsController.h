/* Native Home Application Extensions. GPL-3.0-or-later. */
#ifndef Cydia_ApplicationExtensionsController_H
#define Cydia_ApplicationExtensionsController_H
#include "CyteKit/ViewController.h"
#include "Cydia/ApplicationExtensionsProvider.h"
NS_ASSUME_NONNULL_BEGIN
@interface ApplicationExtensionsController : CyteViewController
- (instancetype)init;
- (nullable instancetype)initWithBundleIdentifier:(nullable NSString *)identifier;
- (nullable instancetype)initWithBundleIdentifier:(nullable NSString *)identifier
    provider:(id<CydiaApplicationExtensionsProviding>)provider;
@property(nonatomic, copy, readonly, nullable) NSString *bundleIdentifier;
@end
NS_ASSUME_NONNULL_END
#endif
