/* Cydia Refurbished native first-party FAQ.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/FAQController.h"

namespace {

NSDictionary *FAQDocument(void) {
    NSURL *URL([[NSBundle mainBundle] URLForResource:@"FAQGuide" withExtension:@"json"]);
    NSData *data(URL == nil ? nil : [NSData dataWithContentsOfURL:URL]);
    NSDictionary *document(data == nil ? nil :
        [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]);
    if (![document isKindOfClass:[NSDictionary class]] ||
        ![document[@"schema"] isEqual:@1] ||
        ![document[@"pages"] isKindOfClass:[NSDictionary class]] ||
        ![document[@"aliases"] isKindOfClass:[NSDictionary class]])
        return nil;
    return document;
}

} // namespace

@interface FAQController ()
@property(nonatomic, copy) NSString *questionIdentifier;
@end

@implementation FAQController

- (instancetype)init {
    return [super initWithPageIdentifier:@"faq" page:FAQDocument()[@"pages"][@"root"]];
}

- (instancetype)initWithQuestionIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0)
        return nil;
    NSDictionary *document(FAQDocument());
    NSDictionary *target(document[@"aliases"][identifier]);
    if (![target isKindOfClass:[NSDictionary class]])
        return nil;
    NSDictionary *page(document[@"pages"][target[@"page"]]);
    if ((self = [super initWithPageIdentifier:@"faq" page:page]) != nil) {
        _questionIdentifier = [identifier copy];
        /* The web links opened a complete FAQ page at a named anchor, not an
         * isolated replacement answer. Keep that context with a native scroll. */
        [self scrollToRowIdentifier:target[@"anchor"]];
    }
    return self;
}

- (NSURL *)navigationURL {
    if ([_questionIdentifier length] == 0)
        return [NSURL URLWithString:@"cydia://home/faq"];
    return [NSURL URLWithString:[@"cydia://home/faq/"
        stringByAppendingString:[_questionIdentifier
            stringByAddingPercentEncodingWithAllowedCharacters:
                [NSCharacterSet URLPathAllowedCharacterSet]]]];
}

@end
