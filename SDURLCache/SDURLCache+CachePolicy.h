#import "SDURLCache.h"

@interface SDURLCache (CachePolicy)

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request;
+ (NSString *)cacheKeyForURL:(NSURL *)url;
+ (NSDate *)dateFromHttpDateString:(NSString *)httpDate;
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status;

@end
