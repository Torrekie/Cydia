/* Focused native data tests; no UIKit/runtime acceptance claim. GPL-3.0-or-later. */
#import "Cydia/ApplicationExtensionsModel.h"
#include <cstdlib>
#include <cstdio>

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "[extensions-model] FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSData *Bytes(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static NSArray *Packages(NSString *HTML, NSError **error) { return CydiaExtensionPackageRows(Bytes(HTML), error); }
int main(int argc, char **argv) {
    @autoreleasepool {
        NSError *error = nil;
        NSDictionary *names = @{@"com.test.z":@"Zulu", @"com.test.a":@"Alpha",
            @"com.test.none":@"Unlisted", @"com.test.unnamed":@""};
        NSArray *rows = CydiaExtensionApplicationRows(Bytes(@"{\"com.test.z\":2,\"com.test.a\":0,\"com.test.remote\":5,\"com.test.unnamed\":1}"),
            names, @{@"com.test.a":@"/local/icon.png"}, &error);
        Check(error == nil && rows.count == 2, @"filter count map locally and omit unnamed/uninstalled apps");
        CydiaApplicationExtensionRow *first = rows[0];
        Check([first.identifier isEqual:@"com.test.a"] && first.extensionCount == 0 &&
            [first.localIconPath isEqual:@"/local/icon.png"], @"localized sort, zero count and local icon");
        Check(CydiaExtensionApplicationRows(Bytes(@"{}"), names, @{}, &error).count == 0 && !error,
            @"successful empty result differs from error");
        for (NSString *bad in @[@"[]", @"{", @"{\"com.test.a\":true}", @"{\"com.test.a\":-1}", @"{\"com.test.a\":1.2}", @"{\"com.test.a\":\"5\"}"])
            Check(CydiaExtensionApplicationRows(Bytes(bad), names, @{}, &error) == nil && error != nil,
                [@"invalid catalog: " stringByAppendingString:bad]);
        rows = CydiaExtensionApplicationRows(Bytes(@"{\"\":1,\"bad typo\":1,\"com.test.a\":4}"), names, @{}, &error);
        Check(rows.count == 1 && !error, @"ignore unrelated malformed catalog keys as original local intersection did");
        NSString *card = @"<a href='http://cydia.saurik.com/package/com.test.z'><img src='/icon/com.test.z.png'>"
            "<label class='title'>Zed &amp; More</label><label class='author'>A</label>"
            "<label class='description'>First<br>Second</label><span class='extra free'>Free</span></a>";
        NSString *HTML = [NSString stringWithFormat:@"<html><script>throw 'must not execute';</script>"
            "<fieldset class='editorial'>%@%@</fieldset></html>", card, card];
        rows = Packages(HTML, &error);
        Check(rows.count == 2 && !error, @"extract package rows, preserve duplicates, never execute scripts");
        first = rows[0];
        Check([first.name isEqual:@"Zed & More"] && [first.author isEqual:@"A"] &&
            [first.price isEqual:@"Free"] && [first.identifier isEqual:@"com.test.z"] &&
            [first.iconURL.absoluteString isEqual:@"https://cydia.saurik.com/icon/com.test.z.png"],
            @"entity decoding, metadata, package destination and original icon path");
        Check(Packages(@"<fieldset class='editorial'></fieldset>", &error).count == 0 && !error,
            @"empty package list");
        for (NSString *bad in @[@"", @"<h1>Service error</h1>", @"<fieldset class='editorial'><div>Changed schema</div></fieldset>",
            @"<fieldset class='editorial'><a href='https://evil.example/package/a'><label class='title'>X</label></a></fieldset>",
            @"<fieldset class='editorial'><a href='https://cydia.saurik.com/package/a/b'><label class='title'>X</label></a></fieldset>"])
            Check(Packages(bad, &error) == nil && error != nil, @"reject malformed/foreign package data without partial success");
        for (NSString *bad in @[@"https://evil.example/icon/a.png", @"file:///icon/a.png", @"/icon/a.svg",
            @"https://user@cydia.saurik.com/icon/a.png", @"/icon/a.png?track=1", @"/icon/a/b.png"])
            Check(CydiaExtensionIconURL(bad) == nil, @"reject unsafe icon origin/path");
        puts("[extensions-model] PASS: local filtering, ordering, metadata, empty/error and URL boundaries");
        if (argc == 2) {
            error = nil;
            NSString *directory = [NSString stringWithUTF8String:argv[1]];
            NSDictionary *index = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:
                [directory stringByAppendingPathComponent:@"frozen-inputs.json"]] options:0 error:&error];
            Check(index != nil && error == nil, @"read frozen index");
            rows = CydiaExtensionApplicationRows([NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"api-application.json"]],
                @{@"com.apple.mobilemail":@"Mail", @"com.apple.mobilesafari":@"Safari", @"com.test.unlisted":@"Unlisted"}, @{}, &error);
            Check(rows.count == 2 && !error && [(CydiaApplicationExtensionRow *)rows[0] extensionCount] == 74 &&
                [(CydiaApplicationExtensionRow *)rows[1] extensionCount] == 139, @"complete real count map retains usable local apps despite historical typo keys");
            NSUInteger total = 0;
            for (NSString *page in @[@"safari", @"mail"]) {
                rows = CydiaExtensionPackageRows([NSData dataWithContentsOfFile:[directory
                    stringByAppendingPathComponent:[page stringByAppendingString:@".html"]]], &error);
                NSArray *expected = index[@"pages"][page];
                Check(rows != nil && !error && rows.count == expected.count, [@"full frozen list: " stringByAppendingString:page]);
                for (NSUInteger i = 0; i < rows.count; ++i) {
                    CydiaApplicationExtensionRow *row = rows[i]; NSDictionary *entry = expected[i];
                    Check([row.identifier isEqual:entry[@"package"]] && [row.name isEqual:entry[@"title"]] &&
                        [row.author isEqual:entry[@"author"]] && [row.summary isEqual:entry[@"description"]] &&
                        [row.price isEqual:entry[@"extra"]] &&
                        [row.iconURL isEqual:CydiaExtensionIconURL(entry[@"icon"])] ,
                        [NSString stringWithFormat:@"all metadata and order: %@[%lu] %@", page, (unsigned long)i, row.identifier]);
                }
                total += rows.count;
            }
            printf("[extensions-model] PASS: all %lu frozen package cards, fields, assets and service order\n", (unsigned long)total);
        }
    }
    return 0;
}
