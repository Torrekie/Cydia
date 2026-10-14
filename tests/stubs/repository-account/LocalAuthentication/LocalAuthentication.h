#pragma once
#import <Foundation/Foundation.h>
#define LAErrorDomain @"FixtureLocalAuthentication"
typedef NS_ENUM(NSInteger, LAPolicy) { LAPolicyDeviceOwnerAuthentication = 2 };
typedef NS_ENUM(NSInteger, LAError) {
    LAErrorAuthenticationFailed = -1,
    LAErrorUserCancel = -2,
    LAErrorAppCancel = -9,
    LAErrorSystemCancel = -4,
    LAErrorPasscodeNotSet = -5,
    LAErrorBiometryNotAvailable = -6,
};
@interface LAContext : NSObject
@property(nonatomic, copy) NSString *localizedReason;
@property(nonatomic, copy) NSString *localizedCancelTitle;
@property(nonatomic, copy) NSString *localizedFallbackTitle;
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error;
- (void)invalidate;
@end
