#pragma once
#import <Foundation/Foundation.h>
@interface UIWindow : NSObject
@end
@interface UIView : NSObject
@property(nonatomic, strong) UIWindow *window;
@end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *view;
@end
