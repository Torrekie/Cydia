/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import "Cydia/CopyingFilesGuideController.h"

@implementation CopyingFilesGuideController
- (instancetype)init {
    NSURL *URL([[NSBundle mainBundle] URLForResource:@"CopyingFilesGuide" withExtension:@"json"]);
    NSData *data(URL == nil ? nil : [NSData dataWithContentsOfURL:URL]);
    NSDictionary *page(data == nil ? nil :
        [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]);
    if (![page isKindOfClass:[NSDictionary class]] || ![page[@"schema"] isEqual:@1])
        return nil;
    /* First-party paragraphs, emphasis and inline links use the shared native
     * guide surface. Instructions remain inert: links only navigate. */
    return [super initWithPageIdentifier:@"copying-files" page:page];
}

- (NSURL *)navigationURL {
    return [NSURL URLWithString:@"cydia://home/copying-files"];
}
@end
