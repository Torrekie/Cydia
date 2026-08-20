//
//  SDURLCache.m
//  SDURLCache
//
//  Created by Olivier Poitrey on 15/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import "SDURLCache.h"
#import "SDURLCache+CachePolicy.h"

static NSTimeInterval const kSDURLCacheInfoDefaultMinCacheInterval = 5 * 60; // 5 minute
static NSString *const kSDURLCacheInfoFileName = @"cacheInfo.plist";
static NSString *const kSDURLCacheInfoDiskUsageKey = @"diskUsage";
static NSString *const kSDURLCacheInfoAccessesKey = @"accesses";
static NSString *const kSDURLCacheInfoSizesKey = @"sizes";

@implementation NSCachedURLResponse(NSCoder)

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDataObject:self.data];
    [coder encodeObject:self.response forKey:@"response"];
    [coder encodeObject:self.userInfo forKey:@"userInfo"];
    [coder encodeInt:self.storagePolicy forKey:@"storagePolicy"];
}

- (id)initWithCoder:(NSCoder *)coder
{
    return [self initWithResponse:[coder decodeObjectForKey:@"response"]
                             data:[coder decodeDataObject]
                         userInfo:[coder decodeObjectForKey:@"userInfo"]
                    storagePolicy:[coder decodeIntForKey:@"storagePolicy"]];
}

@end


@interface SDURLCache ()
@property (nonatomic, strong) NSString *diskCachePath;
@property (nonatomic, readonly) NSMutableDictionary *diskCacheInfo;
@property (nonatomic, strong) NSOperationQueue *ioQueue;
@property (nonatomic, strong) NSOperation *periodicMaintenanceOperation;
- (void)periodicMaintenance;
@end

@implementation SDURLCache

@synthesize diskCachePath, minCacheInterval, ioQueue, periodicMaintenanceOperation, ignoreMemoryOnlyStoragePolicy, breakURLCacheCompatibility;
@dynamic diskCacheInfo;

#pragma mark SDURLCache (private)

- (NSMutableDictionary *)diskCacheInfo
{
    if (!diskCacheInfo)
    {
        @synchronized(self)
        {
            if (!diskCacheInfo) // Check again, maybe another thread created it while waiting for the mutex
            {
                diskCacheInfo = [[NSMutableDictionary alloc] initWithContentsOfFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName]];
                if (!diskCacheInfo)
                {
                    diskCacheInfo = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                     [NSNumber numberWithUnsignedInt:0], kSDURLCacheInfoDiskUsageKey,
                                     [NSMutableDictionary dictionary], kSDURLCacheInfoAccessesKey,
                                     [NSMutableDictionary dictionary], kSDURLCacheInfoSizesKey,
                                     nil];
                }
                diskCacheInfoDirty = NO;

                diskCacheUsage = [[diskCacheInfo objectForKey:kSDURLCacheInfoDiskUsageKey] unsignedIntValue];

                periodicMaintenanceTimer = [NSTimer scheduledTimerWithTimeInterval:5
                                                                            target:self
                                                                          selector:@selector(periodicMaintenance)
                                                                          userInfo:nil
                                                                           repeats:YES];
            }
        }
    }

    return diskCacheInfo;
}

- (NSString *) diskCachePath {
    return diskCachePath;
}

- (void)createDiskCachePath
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    if (![fileManager fileExistsAtPath:diskCachePath])
    {
        [fileManager createDirectoryAtPath:diskCachePath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
    }
}

- (void)saveCacheInfo
{
    [self createDiskCachePath];
    @synchronized(self.diskCacheInfo)
    {
        NSData *data = [NSPropertyListSerialization dataFromPropertyList:self.diskCacheInfo format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
        if (data)
        {
            [data writeToFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName] atomically:YES];
        }

        diskCacheInfoDirty = NO;
    }
}

- (void)removeCachedResponseForCachedKeys:(NSArray *)cacheKeys
{
    @autoreleasepool {
        NSEnumerator *enumerator = [cacheKeys objectEnumerator];
        NSString *cacheKey;

        @synchronized(self.diskCacheInfo)
        {
            NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
            NSMutableDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];
            NSFileManager *fileManager = [[NSFileManager alloc] init];

            while ((cacheKey = [enumerator nextObject]))
            {
                NSUInteger cacheItemSize = [[sizes objectForKey:cacheKey] unsignedIntegerValue];
                [accesses removeObjectForKey:cacheKey];
                [sizes removeObjectForKey:cacheKey];
                [fileManager removeItemAtPath:[diskCachePath stringByAppendingPathComponent:cacheKey] error:NULL];

                diskCacheUsage -= cacheItemSize;
                [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];
            }
        }
    }
}

- (void)balanceDiskUsage
{
    if (diskCacheUsage < self.diskCapacity)
    {
        // Already done
        return;
    }

    NSMutableArray *keysToRemove = [NSMutableArray array];

    @synchronized(self.diskCacheInfo)
    {
        // Apply LRU cache eviction algorithm while disk usage outreach capacity
        NSDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];

        NSInteger capacityToSave = diskCacheUsage - self.diskCapacity;
        NSArray *sortedKeys = [[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] keysSortedByValueUsingSelector:@selector(compare:)];
        NSEnumerator *enumerator = [sortedKeys objectEnumerator];
        NSString *cacheKey;

        while (capacityToSave > 0 && (cacheKey = [enumerator nextObject]))
        {
            [keysToRemove addObject:cacheKey];
            capacityToSave -= [(NSNumber *)[sizes objectForKey:cacheKey] unsignedIntegerValue];
        }
    }

    [self removeCachedResponseForCachedKeys:keysToRemove];
    [self saveCacheInfo];
}


- (void)storeToDisk:(NSDictionary *)context
{
    NSURLRequest *request = [context objectForKey:@"request"];
    NSCachedURLResponse *cachedResponse = [context objectForKey:@"cachedResponse"];

    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
    NSString *cacheFilePath = [diskCachePath stringByAppendingPathComponent:cacheKey];

    [self createDiskCachePath];

    // Archive the cached response on disk
    if (![NSKeyedArchiver archiveRootObject:cachedResponse toFile:cacheFilePath])
    {
        // Caching failed for some reason
        return;
    }

    // Update disk usage info
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSNumber *cacheItemSize = [[fileManager attributesOfItemAtPath:cacheFilePath error:NULL] objectForKey:NSFileSize];
    @synchronized(self.diskCacheInfo)
    {
        diskCacheUsage += [cacheItemSize unsignedIntegerValue];
        [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];


        // Update cache info for the stored item
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] setObject:[NSDate date] forKey:cacheKey];
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey] setObject:cacheItemSize forKey:cacheKey];
    }

    [self saveCacheInfo];
}

- (void)periodicMaintenance
{
    // If another maintenance operation is already sceduled, cancel it so this new operation will be executed after other
    // operations of the queue, so we can group more work together
    [periodicMaintenanceOperation cancel];
    self.periodicMaintenanceOperation = nil;

    // If disk usage exceeds capacity, run the cache eviction operation and if cacheInfo dictionary is dirty, save it in an operation
    if (diskCacheUsage > self.diskCapacity)
    {
        NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithTarget:self selector:@selector(balanceDiskUsage) object:nil];
        self.periodicMaintenanceOperation = operation;
        [ioQueue addOperation:periodicMaintenanceOperation];
    }
    else if (diskCacheInfoDirty)
    {
        NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithTarget:self selector:@selector(saveCacheInfo) object:nil];
        self.periodicMaintenanceOperation = operation;
        [ioQueue addOperation:periodicMaintenanceOperation];
    }
}

#pragma mark SDURLCache

+ (NSString *)defaultCachePath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"SDURLCache"];
}

- (void) logEvent:(NSString *)event forRequest:(NSURLRequest *)request {
}

#pragma mark NSURLCache

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString *)path
{
    if ((self = [super initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:nil]))
    {
        self.minCacheInterval = kSDURLCacheInfoDefaultMinCacheInterval;
        self.diskCachePath = path;

        // Init the operation queue
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        self.ioQueue = queue;
        
        ioQueue.maxConcurrentOperationCount = 1; // used to streamline operations in a separate thread
        self.ignoreMemoryOnlyStoragePolicy = YES;
        self.breakURLCacheCompatibility = NO;
	}

    return self;
}

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    request = [SDURLCache canonicalRequestForRequest:request];

    if (request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringLocalAndRemoteCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringCacheData)
    {
        // When cache is ignored for read, it's a good idea not to store the result as well as this option
        // have big chance to be used every times in the future for the same request.
        // NOTE: This is a change regarding default URLCache behavior and therefore breaks things and should not be done
        if (breakURLCacheCompatibility)
            return;
    }

    [super storeCachedResponse:cachedResponse forRequest:request];

    NSURLCacheStoragePolicy storagePolicy = cachedResponse.storagePolicy;
    if ((storagePolicy == NSURLCacheStorageAllowed || (storagePolicy == NSURLCacheStorageAllowedInMemoryOnly && ignoreMemoryOnlyStoragePolicy))
        && [cachedResponse.response isKindOfClass:[NSHTTPURLResponse self]]
        && cachedResponse.data.length < self.diskCapacity)
    {
        NSDictionary *headers = [(NSHTTPURLResponse *)cachedResponse.response allHeaderFields];
        // RFC 2616 section 13.3.4 says clients MUST use Etag in any cache-conditional request if provided by server
        if (![headers objectForKey:@"Etag"])
        {
            NSDate *expirationDate = [SDURLCache expirationDateFromHeaders:headers
                                                            withStatusCode:((NSHTTPURLResponse *)cachedResponse.response).statusCode];
            if (!expirationDate || [expirationDate timeIntervalSinceNow] - minCacheInterval <= 0)
            {
                // This response is not cacheable, headers said
                [self logEvent:@"no-cache" forRequest:request];
                return;
            }
        }

        [self logEvent:@"store" forRequest:request];

        NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithTarget:self
                                                                            selector:@selector(storeToDisk:)
                                                                              object:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                                      cachedResponse, @"cachedResponse",
                                                                                      request, @"request",
                                                                                      nil]];
        [ioQueue addOperation:operation];
    }
    else
        [self logEvent:@"invalid" forRequest:request];
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    request = [SDURLCache canonicalRequestForRequest:request];

    NSCachedURLResponse *memoryResponse = [super cachedResponseForRequest:request];
    if (memoryResponse)
    {
        [self logEvent:@"memory" forRequest:request];
        return memoryResponse;
    }

    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];

    // NOTE: We don't handle expiration here as even staled cache data is necessary for NSURLConnection to handle cache revalidation.
    //       Staled cache data is also needed for cachePolicies which force the use of the cache.
    @synchronized(self.diskCacheInfo)
    {
        NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
        if ([accesses objectForKey:cacheKey]) // OPTI: Check for cache-hit in a in-memory dictionary before hitting the file system
        {
            NSString *path = [diskCachePath stringByAppendingPathComponent:cacheKey];
            NSCachedURLResponse *diskResponse;

            // SRK: archiving objects that are very very large sometimes results in invalid plists
            // http://stackoverflow.com/questions/2026720/archiving-unarchiving-results-in-initforreadingwithdata-incomprehensible-archi

            @try {
                diskResponse = [NSKeyedUnarchiver unarchiveObjectWithFile:path];
            } @catch (NSException *e) { // NSInvalidArgumentException
                diskResponse = nil;

                NSFileManager *fileManager = [[NSFileManager alloc] init];
                [fileManager removeItemAtPath:path error:NULL];
            }

            if (diskResponse)
            {
                // OPTI: Log the entry last access time for LRU cache eviction algorithm but don't save the dictionary
                //       on disk now in order to save IO and time
                [accesses setObject:[NSDate date] forKey:cacheKey];
                diskCacheInfoDirty = YES;

                // OPTI: Store the response to memory cache for potential future requests
                [super storeCachedResponse:diskResponse forRequest:request];

                // SRK: Work around an interesting retainCount bug in CFNetwork on iOS << 3.2.
                if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iPhoneOS_3_2)
                {
                    diskResponse = [super cachedResponseForRequest:request];
                }

                if (diskResponse)
                {
                    [self logEvent:@"disk" forRequest:request];
                    return diskResponse;
                }
            }
        }
    }

    [self logEvent:@"miss" forRequest:request];
    return nil;
}

- (NSUInteger)currentDiskUsage
{
    if (!diskCacheInfo)
    {
        [self diskCacheInfo];
    }
    return diskCacheUsage;
}

- (void)removeCachedResponseForRequest:(NSURLRequest *)request
{
    request = [SDURLCache canonicalRequestForRequest:request];

    [super removeCachedResponseForRequest:request];
    [self removeCachedResponseForCachedKeys:[NSArray arrayWithObject:[SDURLCache cacheKeyForURL:request.URL]]];
    [self saveCacheInfo];
}

- (void)removeAllCachedResponses
{
    [super removeAllCachedResponses];
    
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    [fileManager removeItemAtPath:diskCachePath error:NULL];
    @synchronized(self)
    {
        diskCacheInfo = nil;
    }
}

- (BOOL)isCached:(NSURL *)url
{
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    request = [SDURLCache canonicalRequestForRequest:request];

    if ([super cachedResponseForRequest:request])
    {
        return YES;
    }
    
    NSString *cacheKey = [SDURLCache cacheKeyForURL:url];
    NSString *cacheFile = [diskCachePath stringByAppendingPathComponent:cacheKey];
    NSFileManager *manager = [[NSFileManager alloc] init];
    
    BOOL exists = [manager fileExistsAtPath:cacheFile];
    if (exists)
    {
        return YES;
    }
    return NO;
}

#pragma mark NSObject

- (void)dealloc
{
    [periodicMaintenanceTimer invalidate];
    [periodicMaintenanceOperation cancel];
}


@end
