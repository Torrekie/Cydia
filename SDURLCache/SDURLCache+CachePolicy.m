#import "SDURLCache+CachePolicy.h"

#import <CommonCrypto/CommonDigest.h>

static const NSTimeInterval kSDURLCacheLastModifiedFraction = 0.1;
static const NSTimeInterval kSDURLCacheDefaultExpirationInterval = 60 * 60;

static NSDateFormatter *SDCreateDateFormatter(NSString *format)
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];

    dateFormatter.locale = locale;
    dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    dateFormatter.dateFormat = format;
    return dateFormatter;
}

@implementation SDURLCache (CachePolicy)

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    NSString *string = request.URL.absoluteString;
    NSRange fragment = [string rangeOfString:@"#"];
    if (fragment.location == NSNotFound)
        return request;

    NSMutableURLRequest *canonicalRequest = [request mutableCopy];
    canonicalRequest.URL = [NSURL URLWithString:[string substringToIndex:fragment.location]];
    return canonicalRequest;
}

+ (NSString *)cacheKeyForURL:(NSURL *)url
{
    const char *string = url.absoluteString.UTF8String;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(string, (CC_LONG)strlen(string), digest);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]];
}

+ (NSDate *)dateFromHttpDateString:(NSString *)httpDate
{
    static NSDateFormatter *rfc1123DateFormatter;
    static NSDateFormatter *ansiCDateFormatter;
    static NSDateFormatter *rfc850DateFormatter;
    NSDate *date = nil;

    @synchronized(self) {
        if (rfc1123DateFormatter == nil)
            rfc1123DateFormatter = SDCreateDateFormatter(@"EEE, dd MMM yyyy HH:mm:ss z");
        date = [rfc1123DateFormatter dateFromString:httpDate];

        if (date == nil) {
            if (ansiCDateFormatter == nil)
                ansiCDateFormatter = SDCreateDateFormatter(@"EEE MMM d HH:mm:ss yyyy");
            date = [ansiCDateFormatter dateFromString:httpDate];
        }

        if (date == nil) {
            if (rfc850DateFormatter == nil)
                rfc850DateFormatter = SDCreateDateFormatter(@"EEEE, dd-MMM-yy HH:mm:ss z");
            date = [rfc850DateFormatter dateFromString:httpDate];
        }
    }

    return date;
}

+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status
{
    if (status != 200 && status != 203 && status != 300 && status != 301 &&
        status != 302 && status != 307 && status != 410)
        return nil;

    NSString *pragma = [headers objectForKey:@"Pragma"];
    if ([pragma isEqualToString:@"no-cache"])
        return nil;

    NSString *dateHeader = [headers objectForKey:@"Date"];
    NSDate *now = dateHeader == nil ? [NSDate date] : [self dateFromHttpDateString:dateHeader];

    NSString *cacheControl = [[headers objectForKey:@"Cache-Control"] lowercaseString];
    if (cacheControl != nil) {
        if ([cacheControl rangeOfString:@"no-store"].length > 0)
            return nil;

        NSRange maxAgeRange = [cacheControl rangeOfString:@"max-age"];
        if (maxAgeRange.length > 0) {
            NSScanner *scanner = [NSScanner scannerWithString:cacheControl];
            scanner.scanLocation = maxAgeRange.location + maxAgeRange.length;
            [scanner scanString:@"=" intoString:nil];

            NSInteger maxAge;
            if ([scanner scanInteger:&maxAge])
                return maxAge > 0 ? [[NSDate alloc] initWithTimeInterval:maxAge sinceDate:now] : nil;
        }
    }

    NSString *expires = [headers objectForKey:@"Expires"];
    if (expires != nil) {
        NSDate *expirationDate = [self dateFromHttpDateString:expires];
        NSTimeInterval expirationInterval = [expirationDate timeIntervalSinceDate:now];
        return expirationInterval > 0 ? [NSDate dateWithTimeIntervalSinceNow:expirationInterval] : nil;
    }

    if (status == 302 || status == 307)
        return nil;

    NSString *lastModified = [headers objectForKey:@"Last-Modified"];
    if (lastModified != nil) {
        NSDate *lastModifiedDate = [self dateFromHttpDateString:lastModified];
        NSTimeInterval age = lastModifiedDate == nil ? 0 : [now timeIntervalSinceDate:lastModifiedDate];
        return age > 0 ? [NSDate dateWithTimeIntervalSinceNow:(age * kSDURLCacheLastModifiedFraction)] : nil;
    }

    return [[NSDate alloc] initWithTimeInterval:kSDURLCacheDefaultExpirationInterval sinceDate:now];
}

@end
