/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/MoreSourcesProvider.h"
#import "Cydia/SourceControllers.h"
#import "Cydia/Database.h"
#import "Cydia/Source.h"
#import "Sources.h"

@implementation CydiaMoreSourcesProvider {
    __weak Database *_database;
    SourcesController *_restoration;
}
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init])) _database = database;
    return self;
}
- (NSArray<NSDictionary *> *)configuredSources {
    NSMutableArray *records = [NSMutableArray array];
    @synchronized (_database) {
        for (Source *source in [_database sources])
            if ([source rooturi] && [source distribution])
                [records addObject:@{@"rooturi":[source rooturi], @"distribution":[source distribution]}];
    }
    return records;
}
- (BOOL)canEditSources { return _database != nil && CydiaCanEditManagedSources(); }
- (void)restoreSourceIdentifier:(NSString *)identifier presenter:(CyteViewController *)presenter
    completion:(void (^)(BOOL))completion {
    if (_restoration != nil || ![self canEditSources]) { completion(NO); return; }
    // Compatibility callers cannot recreate the retired default catalogue.
    // Explicit repository URLs use the native Add Source draft flow.
    _restoration = [[SourcesController alloc] initWithDatabase:_database];
    [_restoration setDelegate:presenter.delegate];
    __weak CydiaMoreSourcesProvider *weakSelf = self;
    __weak SourcesController *weakRestoration = _restoration;
    [_restoration showRestoreDefaultSourcePrompt:identifier completion:^(BOOL added) {
        CydiaMoreSourcesProvider *self = weakSelf;
        if (!self) return;
        SourcesController *finished = weakRestoration;
        // Retain through the verifier's callback stack, including syncData.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_restoration == finished) self->_restoration = nil;
        });
        completion(added);
    }];
}
- (void)cancelRestoration {
    SourcesController *restoration = _restoration;
    _restoration = nil;
    [restoration cancelDefaultSourceRestoration];
}
- (void)dealloc { [_restoration cancelDefaultSourceRestoration]; }
@end
