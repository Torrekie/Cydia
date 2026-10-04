/* Native data extraction, never HTML rendering or script execution.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ApplicationExtensionsModel.h"
#include <libxml/HTMLparser.h>
#include <libxml/xpath.h>
#include <cmath>

@interface CydiaApplicationExtensionRow ()
@property(nonatomic, copy, readwrite) NSString *identifier, *name, *author, *summary, *price;
@property(nonatomic, readwrite) NSUInteger extensionCount;
@property(nonatomic, strong, readwrite) NSURL *iconURL;
@property(nonatomic, copy, readwrite) NSString *localIconPath;
@end
@implementation CydiaApplicationExtensionRow
- (instancetype)init {
    if ((self = [super init])) { _author = @""; _summary = @""; _price = @""; }
    return self;
}
@end

namespace {
NSError *CatalogError(NSString *message) {
    return [NSError errorWithDomain:@"CydiaApplicationExtensions" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
}
BOOL Fail(NSError **error, NSString *message) {
    if (error != NULL) *error = CatalogError(message);
    return NO;
}
NSString *Attribute(xmlNodePtr node, const char *name) {
    if (node == NULL) return nil;
    xmlChar *value = xmlGetProp(node, BAD_CAST name);
    NSString *result = value == NULL ? nil : [NSString stringWithUTF8String:(const char *)value];
    if (value) xmlFree(value);
    return result;
}
NSString *Text(xmlNodePtr node) {
    xmlChar *value = node == NULL ? NULL : xmlNodeGetContent(node);
    NSString *result = value == NULL ? @"" : [NSString stringWithUTF8String:(const char *)value];
    if (value) xmlFree(value);
    return [result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}
xmlNodePtr First(xmlXPathContextPtr context, const char *expression) {
    xmlXPathObjectPtr object = xmlXPathEvalExpression(BAD_CAST expression, context);
    xmlNodePtr result = object && object->nodesetval && object->nodesetval->nodeNr ?
        object->nodesetval->nodeTab[0] : NULL;
    if (object) xmlXPathFreeObject(object);
    return result;
}
NSString *PackageIdentifier(NSString *value) {
    NSURLComponents *URL = [NSURLComponents componentsWithString:value ?: @""];
    if (![@[@"http", @"https"] containsObject:URL.scheme.lowercaseString] ||
        ![URL.host.lowercaseString isEqual:@"cydia.saurik.com"] ||
        URL.user != nil || URL.password != nil || URL.port != nil ||
        URL.query != nil || URL.fragment != nil || ![URL.path hasPrefix:@"/package/"])
        return nil;
    NSString *identifier = [URL.path substringFromIndex:9];
    return CydiaExtensionIdentifierIsValid(identifier) ? identifier : nil;
}
}

BOOL CydiaExtensionIdentifierIsValid(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length || identifier.length > 1024)
        return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier isEqual:@"."] && ![identifier isEqual:@".."];
}

NSURL *CydiaExtensionIconURL(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSURL *base = [NSURL URLWithString:@"https://cydia.saurik.com/"];
    NSURLComponents *URL = [NSURLComponents componentsWithURL:
        [NSURL URLWithString:value relativeToURL:base].absoluteURL resolvingAgainstBaseURL:YES];
    if (![@[@"http", @"https"] containsObject:URL.scheme.lowercaseString] ||
        ![URL.host.lowercaseString isEqual:@"cydia.saurik.com"] ||
        URL.user != nil || URL.password != nil || URL.port != nil ||
        URL.query != nil || URL.fragment != nil || ![URL.path hasPrefix:@"/icon/"])
        return nil;
    NSString *file = [URL.path substringFromIndex:6];
    if (![file.pathExtension.lowercaseString isEqual:@"png"] ||
        !CydiaExtensionIdentifierIsValid(file.stringByDeletingPathExtension)) return nil;
    URL.scheme = @"https";
    return URL.URL;
}

NSArray<CydiaApplicationExtensionRow *> *CydiaExtensionApplicationRows(
        NSData *data, NSDictionary<NSString *, NSString *> *names,
        NSDictionary<NSString *, NSString *> *iconPaths, NSError **error) {
    if (error) *error = nil;
    id counts = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![counts isKindOfClass:NSDictionary.class] || ![names isKindOfClass:NSDictionary.class]) {
        Fail(error, @"Unable to read the application extension catalog."); return nil;
    }
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *identifier in names) {
        NSString *name = names[identifier];
        if (!CydiaExtensionIdentifierIsValid(identifier) || ![name isKindOfClass:NSString.class] ||
            !name.length || counts[identifier] == nil) continue;
        // The real legacy catalog has unrelated typo/empty keys. The original
        // page intersects it with locally named apps; don't reject usable apps
        // because an uninstalled/unaddressable entry is malformed.
        id value = counts[identifier];
        double number = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : -1;
        if (![value isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
            !std::isfinite(number) || number < 0 || std::floor(number) != number ||
            number >= (double)NSUIntegerMax) {
            Fail(error, @"The application extension catalog has invalid counts."); return nil;
        }
        CydiaApplicationExtensionRow *row = [[CydiaApplicationExtensionRow alloc] init];
        row.identifier = identifier; row.name = name;
        row.extensionCount = [counts[identifier] unsignedIntegerValue];
        row.localIconPath = iconPaths[identifier];
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(CydiaApplicationExtensionRow *a,
                                                   CydiaApplicationExtensionRow *b) {
        NSComparisonResult result = [a.name localizedCompare:b.name];
        return result == NSOrderedSame ? [a.identifier compare:b.identifier] : result;
    }];
    return [rows copy];
}

NSArray<CydiaApplicationExtensionRow *> *CydiaExtensionPackageRows(NSData *data, NSError **error) {
    if (error) *error = nil;
    if (!data.length || data.length > 4 * 1024 * 1024) {
        Fail(error, @"Unable to read the application extension list."); return nil;
    }
    // HTML4-compatible system parser, with no DTD fetch, network or script engine.
    htmlDocPtr document = htmlReadMemory((const char *)data.bytes, (int)data.length,
        NULL, "UTF-8", HTML_PARSE_NONET | HTML_PARSE_NODEFDTD | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING);
    xmlXPathContextPtr context = document ? xmlXPathNewContext(document) : NULL;
    NSMutableArray *rows = [NSMutableArray array];
    BOOL valid = context != NULL;
    if (valid) {
        xmlNodePtr list = First(context,
            "//fieldset[contains(concat(' ', normalize-space(@class), ' '), ' editorial ')]");
        valid = list != NULL;
        for (xmlNodePtr node = list ? list->children : NULL; node && valid; node = node->next) {
            if (node->type != XML_ELEMENT_NODE) continue;
            if (xmlStrcmp(node->name, BAD_CAST "a") != 0) { valid = NO; break; }
            NSString *identifier = PackageIdentifier(Attribute(node, "href"));
            context->node = node;
            CydiaApplicationExtensionRow *row = [[CydiaApplicationExtensionRow alloc] init];
            row.identifier = identifier;
            row.name = Text(First(context, "./label[@class='title']"));
            row.author = Text(First(context, "./label[@class='author']"));
            row.summary = Text(First(context, "./label[@class='description']"));
            row.price = Text(First(context, "./span[contains(concat(' ', normalize-space(@class), ' '), ' extra ')]"));
            row.iconURL = CydiaExtensionIconURL(Attribute(First(context, "./img"), "src"));
            if (identifier == nil || !row.name.length) { valid = NO; break; }
            [rows addObject:row]; // Preserve the service's order, including repeated rows.
        }
    }
    if (context) xmlXPathFreeContext(context);
    if (document) xmlFreeDoc(document);
    if (!valid) { Fail(error, @"The application extension list could not be read."); return nil; }
    return [rows copy];
}
