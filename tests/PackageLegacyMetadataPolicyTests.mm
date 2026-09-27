/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PackageLegacyMetadataPolicy.h"

#include <cstdlib>
#include <stdint.h>
#include <string.h>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    fprintf(stderr, "[PackageLegacyMetadataPolicyTests][FAIL] %s\n",
        [message UTF8String]);
    std::exit(1);
}

NSData *UTF8(NSString *value) {
    return [value dataUsingEncoding:NSUTF8StringEncoding];
}

void WriteBigEndian32(uint8_t *bytes, uint32_t value) {
    bytes[0] = static_cast<uint8_t>(value >> 24);
    bytes[1] = static_cast<uint8_t>(value >> 16);
    bytes[2] = static_cast<uint8_t>(value >> 8);
    bytes[3] = static_cast<uint8_t>(value);
}

NSMutableData *PNGHeader(NSUInteger length, uint32_t width, uint32_t height) {
    NSMutableData *data([NSMutableData dataWithLength:length]);
    uint8_t *bytes(static_cast<uint8_t *>([data mutableBytes]));
    static const uint8_t signature[] = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    };
    memcpy(bytes, signature, sizeof(signature));
    WriteBigEndian32(bytes + 8, 13);
    memcpy(bytes + 12, "IHDR", 4);
    WriteBigEndian32(bytes + 16, width);
    WriteBigEndian32(bytes + 20, height);
    bytes[24] = 8;
    bytes[25] = 6;
    return data;
}

void ExpectMetadataRejected(NSString *response, NSString *name) {
    Expect(CydiaPackageLegacyAlternateIconURL(UTF8(response)) == nil, name);
}

void ExpectIconURLRejected(NSString *URLString, NSString *name) {
    Expect(!CydiaPackageLegacyIconURLIsAllowed([NSURL URLWithString:URLString]), name);
}

} // namespace


int main(int argc, char *argv[]) {
    @autoreleasepool {
        Expect(argc == 2, @"captured response fixture path supplied");
        NSURL *metadata(CydiaPackageLegacyMetadataURL(@"com.opa334.choicy"));
        Expect([[metadata absoluteString] isEqualToString:
            @"https://cydia.saurik.com/api/package/com.opa334.choicy"],
            @"exact first-party metadata endpoint");
        for (NSString *identity in @[
            @"", @"A.Package", @"package_name", @"package/name",
            @"package:iphoneos-arm64", @"package?query", @"package#fragment",
            @" package", @"pack age", @"páckage",
        ])
            Expect(CydiaPackageLegacyMetadataURL(identity) == nil,
                [NSString stringWithFormat:@"rejected package identity %@", identity]);

        NSMutableString *boundary([NSMutableString stringWithString:@"a"]);
        while ([boundary length] != 1024)
            [boundary appendString:@"a"];
        Expect(CydiaPackageLegacyMetadataURL(boundary) != nil,
            @"1024-byte identity admitted");
        [boundary appendString:@"a"];
        Expect(CydiaPackageLegacyMetadataURL(boundary) == nil,
            @"1025-byte identity rejected before copies");

        NSString *captured(@"({\"icon\":\"http://cydia.saurik.com/icon@2x/com.opa334.choicy.png\"})");
        NSData *capturedFixture([NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:argv[1]]]);
        Expect([capturedFixture length] != 0,
            @"captured Choicy response fixture is readable");
        NSURL *icon(CydiaPackageLegacyAlternateIconURL(UTF8(captured)));
        Expect([[icon absoluteString] isEqualToString:
            @"https://cydia.saurik.com/icon@2x/com.opa334.choicy.png"],
            @"captured legacy HTTP icon canonicalized to HTTPS");
        Expect([[CydiaPackageLegacyAlternateIconURL(capturedFixture) absoluteString]
            isEqualToString:[icon absoluteString]],
            @"captured response fixture exercises the production parser");
        icon = CydiaPackageLegacyAlternateIconURL(UTF8(
            @" \n ( { \"ignored\": 1, \"icon\": \"https://cydia.saurik.com/icon/com.example.tool.png\" } ) \t"));
        Expect([[icon absoluteString] isEqualToString:
            @"https://cydia.saurik.com/icon/com.example.tool.png"],
            @"bounded wrapped JSON accepts optional whitespace and ignored keys");

        for (NSArray<NSString *> *fixture in @[
            @[@"{\"icon\":\"https://cydia.saurik.com/icon/a.png\"}", @"bare JSON rejected"],
            @[@"callback({\"icon\":\"https://cydia.saurik.com/icon/a.png\"})", @"callback rejected"],
            @[@"({\"icon\":\"https://cydia.saurik.com/icon/a.png\"});", @"trailing statement rejected"],
            @[@"(null)", @"non-object JSON rejected"],
            @[@"({\"icon\":null})", @"null icon rejected"],
            @[@"({\"icon\":1})", @"non-string icon rejected"],
            @[@"({})", @"missing icon rejected"],
        ])
            ExpectMetadataRejected(fixture[0], fixture[1]);
        const uint8_t invalidUTF8[] = {'(', '{', '"', 'i', 'c', 'o', 'n', '"', ':', '"', 0xff, '"', '}', ')'};
        Expect(CydiaPackageLegacyAlternateIconURL(
            [NSData dataWithBytes:invalidUTF8 length:sizeof(invalidUTF8)]) == nil,
            @"invalid UTF-8 rejected");
        NSMutableData *oversizedMetadata([NSMutableData dataWithLength:
            CydiaPackageLegacyMetadataMaximumBytes() + 1]);
        Expect(CydiaPackageLegacyAlternateIconURL(oversizedMetadata) == nil,
            @"oversized metadata rejected");

        for (NSString *allowed in @[
            @"http://cydia.saurik.com/icon/com.example.tool.png",
            @"https://cydia.saurik.com/icon@2x/com.opa334.choicy.png",
        ])
            Expect(CydiaPackageLegacyIconURLIsAllowed([NSURL URLWithString:allowed]),
                [NSString stringWithFormat:@"allowed legacy icon URL %@", allowed]);
        for (NSArray<NSString *> *fixture in @[
            @[@"https://example.test/icon/a.png", @"foreign host rejected"],
            @[@"https://cache.cydia.saurik.com/icon/a.png", @"unobserved cache host rejected"],
            @[@"https://cydia.saurik.com:443/icon/a.png", @"explicit port rejected"],
            @[@"https://user@cydia.saurik.com/icon/a.png", @"credentials rejected"],
            @[@"https://cydia.saurik.com/icon/a.png?x", @"query rejected"],
            @[@"https://cydia.saurik.com/icon/a.png#x", @"fragment rejected"],
            @[@"ftp://cydia.saurik.com/icon/a.png", @"foreign scheme rejected"],
            @[@"https://cydia.saurik.com/other/a.png", @"foreign path rejected"],
            @[@"https://cydia.saurik.com/icon/nested/a.png", @"nested path rejected"],
            @[@"https://cydia.saurik.com/icon/%61.png", @"encoded alias rejected"],
            @[@"https://cydia.saurik.com/icon/a.PNG", @"noncanonical extension rejected"],
            @[@"https://cydia.saurik.com/icon/a_b.png", @"non-package identifier rejected"],
        ])
            ExpectIconURLRejected(fixture[0], fixture[1]);

        Expect(CydiaPackageLegacyIconPNGDataIsAllowed(PNGHeader(33, 116, 116)),
            @"captured icon dimensions accepted");
        Expect(CydiaPackageLegacyIconPNGDataIsAllowed(PNGHeader(
            CydiaPackageLegacyIconMaximumBytes(), 512, 512)),
            @"bounded icon byte and pixel limits accepted");
        Expect(!CydiaPackageLegacyIconPNGDataIsAllowed(PNGHeader(33, 513, 1)),
            @"oversized dimension rejected");
        Expect(!CydiaPackageLegacyIconPNGDataIsAllowed(PNGHeader(33, 0, 116)),
            @"zero dimension rejected");
        Expect(!CydiaPackageLegacyIconPNGDataIsAllowed(PNGHeader(
            CydiaPackageLegacyIconMaximumBytes() + 1, 116, 116)),
            @"oversized icon data rejected");
        Expect(!CydiaPackageLegacyIconPNGDataIsAllowed(UTF8(@"not a png")),
            @"non-PNG data rejected");

        puts("[PackageLegacyMetadataPolicyTests][ ok ] bounded legacy icon policy");
    }
    return 0;
}
