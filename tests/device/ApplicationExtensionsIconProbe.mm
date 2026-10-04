/* Run only on an explicitly authorized device. No UI, network or file writes.
 * Links the real provider/model/private-services/resource-policy implementations.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#import <UIKit/UIKit.h>
#include "Cydia/ApplicationExtensionsProvider.h"
#include "Cydia/URLProtocolPolicy.h"
#include <unistd.h>

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) return 2;
    if (geteuid() == 0 && (setgid(501) || setuid(501))) return 2;
    if (geteuid() != 501) return 2;
    CydiaApplicationExtensionsProvider *provider = [CydiaApplicationExtensionsProvider new];
    for (NSString *bad in @[@"", @"../icon", @"com.apple/mobilesafari"])
        if ([provider localIconDataForBundleIdentifier:bad] != nil) return 3;
    for (int i = 1; i < argc; ++i) {
        NSString *identifier = [NSString stringWithUTF8String:argv[i]];
        NSData *data = [provider localIconDataForBundleIdentifier:identifier];
        UIImage *image = [UIImage imageWithData:data];
        if (!CydiaURLResourcePNGDataIsAllowed(data) || image.size.width < 32 || image.size.height < 32)
            return 4;
        printf("PRODUCTION_PROVIDER_PASS %s bytes=%lu size=%.0fx%.0f\n",
            identifier.UTF8String, (unsigned long)data.length, image.size.width, image.size.height);
    }
    puts("INVALID_IDENTIFIER_REJECTION_PASS");
    return 0;
} }
