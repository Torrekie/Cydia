#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#define ASWebAuthenticationSessionErrorDomain @"FixtureASWebAuthenticationSession"
typedef NS_ENUM(NSInteger, ASWebAuthenticationSessionErrorCode) {
    ASWebAuthenticationSessionErrorCodeCanceledLogin = 1,
};
typedef UIWindow *ASPresentationAnchor;
@class ASWebAuthenticationSession;
@protocol ASWebAuthenticationPresentationContextProviding <NSObject>
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session;
@end
@interface ASWebAuthenticationSession : NSObject
@property(nonatomic, weak) id<ASWebAuthenticationPresentationContextProviding> presentationContextProvider;
@property(nonatomic, copy) NSURL *testURL;
@property(nonatomic, copy) NSString *testScheme;
@property(nonatomic, copy) void (^testCompletion)(NSURL *, NSError *);
@property(nonatomic) NSUInteger testStarts, testCancels;
- (instancetype)initWithURL:(NSURL *)URL callbackURLScheme:(NSString *)scheme
         completionHandler:(void (^)(NSURL *, NSError *))completion;
- (BOOL)start;
- (void)cancel;
- (void)testEmitURL:(NSURL *)URL error:(NSError *)error;
@end
