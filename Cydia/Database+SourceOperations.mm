/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/Database.h"
#include "Cydia/AptBackend.hpp"
#include "Cydia/RuntimeProviderCoordinator.hpp"

namespace {
// Source getters are also called under @synchronized(database). A try-lock
// avoids inverting that monitor with the worker's operation gate.
class SourceOperation {
    NSRecursiveLock *__strong lock_;
public:
    explicit SourceOperation(NSRecursiveLock *lock) : lock_([lock tryLock] ? lock : nil) {}
    ~SourceOperation() { if (lock_) [lock_ unlock]; }
    bool held() const { return lock_ != nil; }
    SourceOperation(const SourceOperation &) = delete;
    SourceOperation &operator=(const SourceOperation &) = delete;
};
}

@implementation Database (SourceOperations)
- (std::vector<CydiaAPT::SourceHandle>) sourceHandles {
    SourceOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || runtime_ == nullptr || !runtime_->ready()) return {};
    return apt_->sourceHandles();
}

- (CydiaAPT::SourceSnapshot) sourceSnapshot:(CydiaAPT::SourceHandle)handle {
    SourceOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || runtime_ == nullptr || !runtime_->ready()) return CydiaAPT::SourceSnapshot();
    return apt_->sourceSnapshot(handle);
}

- (NSString *) sourceField:(CydiaAPT::SourceHandle)handle name:(NSString *)name {
    SourceOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || runtime_ == nullptr || !runtime_->ready() || name == nil) return nil;
    const std::string value(apt_->sourceField(handle, [name UTF8String]));
    return value.empty() ? (NSString *) [NSNull null] : [NSString stringWithUTF8String:value.c_str()];
}

- (std::vector<std::uint32_t>) sourceFileIDs:(CydiaAPT::SourceHandle)handle {
    SourceOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || runtime_ == nullptr || !runtime_->ready()) return {};
    return apt_->sourceFileIDs(handle);
}

- (CydiaAPT::SourcePreflightResult) sourcePreflight:(const CydiaAPT::SourcePreflightRequest &)request
    cancelled:(const std::function<bool()> &)cancelled {
    SourceOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || runtime_ == nullptr || !runtime_->ready()) {
        CydiaAPT::SourcePreflightResult result;
        result.status = CydiaAPT::SourceCheckStatus::Unavailable;
        result.errors.push_back({"", false, "provider_operation_unavailable"});
        return result;
    }
    return apt_->sourcePreflight(request, cancelled);
}

- (CydiaAPT::SourceResourceResult) sourceResource:(const CydiaAPT::SourceResourceRequest &)request
    cancelled:(const std::function<bool()> &)cancelled {
    SourceOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || runtime_ == nullptr || !runtime_->ready()) {
        CydiaAPT::SourceResourceResult result;
        result.status = CydiaAPT::SourceCheckStatus::Unavailable;
        result.errors.push_back({"", false, "provider_operation_unavailable"});
        return result;
    }
    return apt_->sourceResource(request, cancelled);
}

- (CydiaAPT::SourceDiscoveryResult) discoverSourceOptions:(const std::string &)uri
    temporaryParent:(const std::string &)temporaryParent cancelled:(const std::function<bool()> &)cancelled {
    SourceOperation operation(operationLock_);
    if (!operation.held() || apt_ == nullptr || runtime_ == nullptr || !runtime_->ready()) {
        CydiaAPT::SourceDiscoveryResult result;
        result.status = CydiaAPT::SourceCheckStatus::Unavailable;
        return result;
    }
    return CydiaAPT::DiscoverSourceOptions(*apt_, uri, temporaryParent, cancelled);
}

- (NSString *)mappedSectionForPointer:(const char *)section {
    _H<NSString> &mapped(sections_[section]);
    if (mapped == nil) {
        std::string name(section);
        for (char &byte : name) if (byte == '_') byte = ' ';
        NSString *text([NSString stringWithUTF8String:name.c_str()]);
        mapped = [SectionMap_ objectForKey:text] ?: text;
    }
    return mapped;
}
@end
