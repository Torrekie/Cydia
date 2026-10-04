/* Cydia Refurbished native upgrading and jailbreaking guide. */
#ifndef Cydia_UpgradingGuideController_H
#define Cydia_UpgradingGuideController_H

#include "CyteKit/ViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface UpgradingGuideController : CyteViewController
+ (NSArray<NSString *> *)pageIdentifiers;
- (instancetype)init;
- (nullable instancetype)initWithPageIdentifier:(NSString *)identifier;
@property(nonatomic, copy, readonly) NSString *pageIdentifier;
/* Probe/coordinator hook for a regular-width split guide.  Compact-width
 * callers receive NO and continue using the normal navigation stack. */
- (BOOL)popDisplayedSplitPage;
- (BOOL)hasDisplayedSplitPage;
@end

NS_ASSUME_NONNULL_END
#endif
