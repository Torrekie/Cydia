/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/URLProtocolPolicy.h"

#include <cstdlib>
#include <stdint.h>
#include <string.h>

namespace {

void Expect(BOOL condition, NSString *message) {
    if (condition)
        return;
    fprintf(stderr, "[URLProtocolPolicyTests][FAIL] %s\n", [message UTF8String]);
    std::exit(1);
}

void WriteBigEndian32(uint8_t *bytes, uint32_t value) {
    bytes[0] = static_cast<uint8_t>(value >> 24);
    bytes[1] = static_cast<uint8_t>(value >> 16);
    bytes[2] = static_cast<uint8_t>(value >> 8);
    bytes[3] = static_cast<uint8_t>(value);
}

NSData *PNGHeader(uint32_t width, uint32_t height) {
    static const uint8_t signature[] = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    };
    uint8_t bytes[33] = {};
    memcpy(bytes, signature, sizeof(signature));
    WriteBigEndian32(bytes + 8, 13);
    memcpy(bytes + 12, "IHDR", 4);
    WriteBigEndian32(bytes + 16, width);
    WriteBigEndian32(bytes + 20, height);
    bytes[24] = 8; // bit depth; the policy does not need to decode pixels.
    bytes[25] = 2; // truecolor.
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

void ExpectIdentifier(NSString *command, NSString *raw, NSString *expected) {
    CydiaURLResourceKind kind(CydiaURLResourceKindForCommand(command));
    NSString *decoded(CydiaURLResourceDecodeIdentifier(raw, kind));
    Expect(decoded != nil && [decoded isEqualToString:expected],
        [NSString stringWithFormat:@"accepted identifier %@/%@", command, raw]);
}

void ExpectRejected(NSString *command, NSString *raw) {
    CydiaURLResourceKind kind(CydiaURLResourceKindForCommand(command));
    Expect(CydiaURLResourceDecodeIdentifier(raw, kind) == nil,
        [NSString stringWithFormat:@"rejected identifier %@/%@", command, raw]);
}

} // namespace


int main(void) {
    @autoreleasepool {
        NSArray *commands(@[
            @"application-icon", @"package-icon", @"uikit-image", @"section-icon",
        ]);
        for (NSString *command in commands)
            Expect(CydiaURLResourceKindForCommand(command) != CydiaURLResourceKindUnknown,
                [NSString stringWithFormat:@"allowlisted command %@", command]);
        Expect(CydiaURLResourceKindForCommand(@"unknown") == CydiaURLResourceKindUnknown,
            @"unknown command is not allowlisted");

        Expect([CydiaURLResourcePathForURL(
            [NSURL URLWithString:@"cydia://uikit-image/UIPinstripe.png"])
                isEqualToString:@"uikit-image/UIPinstripe.png"],
            @"WK custom-scheme URL preserves the encoded resource path");
        Expect([CydiaURLResourcePathForURL(
            [NSURL URLWithString:@"CYDIA://section-icon/Questions%3F%20Answers%23One"])
                isEqualToString:@"section-icon/Questions%3F%20Answers%23One"],
            @"custom scheme matching is case insensitive");
        Expect(CydiaURLResourcePathForURL(
            [NSURL URLWithString:@"https://example.test/uikit-image/icon"]) == nil,
            @"foreign URL scheme rejected");
        Expect(CydiaURLResourcePathForURL(
            [NSURL URLWithString:@"cydia:uikit-image/UIPinstripe.png"]) == nil,
            @"non-hierarchical cydia URL rejected");

        ExpectIdentifier(@"application-icon", @"com.example.App", @"com.example.App");
        ExpectIdentifier(@"application-icon", @"com.example%2DApp", @"com.example-App");
        ExpectIdentifier(@"package-icon", @"fixture:iphoneos-arm64", @"fixture:iphoneos-arm64");
        ExpectIdentifier(@"uikit-image", @"UIPinstripe.png", @"UIPinstripe.png");
        ExpectIdentifier(@"uikit-image", @"Artwork_Name-2x", @"Artwork_Name-2x");
        ExpectIdentifier(@"section-icon", @"Planet%20iPhones%20Mods", @"Planet iPhones Mods");
        ExpectIdentifier(@"section-icon", @"Questions%3F%20Answers%23One",
            @"Questions? Answers#One");

        for (NSString *command in commands) {
            for (NSString *raw in @[
                @"", @".", @"..", @"../etc/passwd", @"%2e%2e%2fetc",
                @"%2Fetc", @"%5cetc", @"nested/path", @"nested\\path",
                @"double%252fencoded", @"bad%ZZ", @"bad%00value",
                @"query?value", @"fragment#value",
            ])
                ExpectRejected(command, raw);
        }

        NSMutableString *boundaryIdentifier([NSMutableString string]);
        for (NSUInteger index = 0; index != 1024; ++index)
            [boundaryIdentifier appendString:@"x"];
        ExpectIdentifier(@"package-icon", boundaryIdentifier, boundaryIdentifier);
        [boundaryIdentifier appendString:@"x"];
        ExpectRejected(@"package-icon", boundaryIdentifier);
        Expect(CydiaURLResourceDecodeIdentifier(nil, CydiaURLResourceKindPackageIcon) == nil,
            @"nil identifier rejected");
        Expect(CydiaURLResourceDecodeIdentifier(@"fixture", CydiaURLResourceKindUnknown) == nil,
            @"unknown kind rejects identifier");

        Expect(CydiaURLResourcePNGDataIsAllowed(PNGHeader(64, 64)),
            @"ordinary PNG dimensions accepted");
        Expect(CydiaURLResourcePNGDataIsAllowed(PNGHeader(2048, 2048)),
            @"maximum decoded pixel budget accepted");
        Expect(CydiaURLResourcePNGDataIsAllowed(PNGHeader(4096, 1)),
            @"narrow maximum-dimension artwork accepted");
        Expect(!CydiaURLResourcePNGDataIsAllowed(PNGHeader(4097, 1)),
            @"oversized PNG width rejected");
        Expect(!CydiaURLResourcePNGDataIsAllowed(PNGHeader(2049, 2049)),
            @"oversized PNG pixel count rejected");
        NSMutableData *oversized([NSMutableData dataWithLength:8 * 1024 * 1024 + 1]);
        Expect(!CydiaURLResourcePNGDataIsAllowed(oversized),
            @"oversized PNG response data rejected");
        Expect(!CydiaURLResourcePNGDataIsAllowed([NSData data]),
            @"empty PNG rejected");
        Expect(!CydiaURLResourcePNGDataIsAllowed([NSData dataWithBytes:"not-png" length:7]),
            @"non-PNG response rejected");

        puts("[URLProtocolPolicyTests][ ok ] typed resource and image policy");
    }
    return 0;
}
