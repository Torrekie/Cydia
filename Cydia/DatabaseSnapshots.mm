/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/DatabaseSnapshots.h"
#include "Cydia/AptCompatibility.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/PrivilegedClient.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *CurrentListsSnapshot() {
    NSMutableData *bytes([NSMutableData data]);
    NSString *lists([NSString stringWithUTF8String:CydiaAPT::ListsDirectory().c_str()]);
    NSArray *names([[NSFileManager defaultManager] contentsOfDirectoryAtPath:lists error:NULL]);
    if (names == nil) return nil;
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name isEqualToString:@"lock"] || [name isEqualToString:@"partial"] ||
            [name isEqualToString:@"auxfiles"]) continue;
        @autoreleasepool {
            NSString *path([lists stringByAppendingPathComponent:name]);
            struct stat before, after;
            if (lstat([path fileSystemRepresentation], &before) != 0 || !S_ISREG(before.st_mode)) return nil;
            int descriptor(open([path fileSystemRepresentation], O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
            if (descriptor < 0) return nil;
            const std::string fingerprint(CydiaAPT::FingerprintFileDescriptor(descriptor));
            struct stat opened;
            const bool stable(fstat(descriptor, &opened) == 0 && opened.st_dev == before.st_dev &&
                opened.st_ino == before.st_ino && opened.st_size == before.st_size &&
                opened.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec &&
                opened.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec &&
                opened.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec &&
                opened.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec);
            close(descriptor);
            if (fingerprint.empty() || !stable || lstat([path fileSystemRepresentation], &after) != 0 ||
                before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
                before.st_size != after.st_size || before.st_mtime != after.st_mtime ||
                before.st_ctime != after.st_ctime ||
                before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
                before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) return nil;
            const std::string field(CydiaRuntime::Privileged::SerializeFields({[name UTF8String], fingerprint}));
            [bytes appendBytes:field.data() length:field.size()];
        }
    }
    NSArray *after([[NSFileManager defaultManager] contentsOfDirectoryAtPath:lists error:NULL]);
    if (after == nil || ![[names sortedArrayUsingSelector:@selector(compare:)]
        isEqual:[after sortedArrayUsingSelector:@selector(compare:)]]) return nil;
    const std::string result(CydiaAPT::Fingerprint([bytes bytes], [bytes length]));
    return result.empty() ? nil : [NSString stringWithUTF8String:result.c_str()];
}

static std::string SelectedRuntimeIdentity(bool packageState) {
    const auto descriptor(CydiaAPT::ActiveRuntimeDescriptor());
    if (!descriptor) return CydiaAPT::RepositorySecurityModeName(CydiaAPT::GetRepositorySecurityMode());
    const auto &binding(descriptor->binding);
    return CydiaRuntime::Privileged::SerializeFields({binding.providerIdentifier, binding.session,
        binding.libraryIdentity, binding.frontendIdentity, binding.configurationIdentity,
        binding.policyIdentity, binding.methodsIdentity, packageState ? binding.packageStateIdentity : "",
        CydiaAPT::RepositorySecurityModeName(descriptor->repositorySecurityMode)});
}

std::string CurrentTrustContext() {
    const auto result(CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-trust-snapshot", "", 128));
    if (!result.succeeded()) return "";
    std::string token(result.output);
    if (!token.empty() && token.back() == '\n') token.pop_back();
    if (token.empty()) return "";
    const std::string bytes(CydiaRuntime::Privileged::SerializeFields({token, SelectedRuntimeIdentity(false)}));
    return CydiaAPT::Fingerprint(bytes.data(), bytes.size());
}

NSString *CurrentTransactionSnapshot() {
    const auto result(CydiaRuntime::PrivilegedClient::RunNativeCommand("--cydia-runtime-snapshot", "", 128));
    NSString *indexes(CurrentListsSnapshot());
    if (!result.succeeded() || result.output.empty() || indexes == nil) return nil;
    const std::string bytes(CydiaRuntime::Privileged::SerializeFields({result.output, [indexes UTF8String], SelectedRuntimeIdentity(true)}));
    const std::string token(CydiaAPT::Fingerprint(bytes.data(), bytes.size()));
    return token.empty() ? nil : [NSString stringWithUTF8String:token.c_str()];
}
