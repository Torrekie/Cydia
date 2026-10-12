/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/Database.h"
#include "Cydia/AptBackend.hpp"

@implementation Database (SourceOperations)
- (std::vector<CydiaAPT::SourceHandle>) sourceHandles {
    return apt_->sourceHandles();
}

- (CydiaAPT::SourceSnapshot) sourceSnapshot:(CydiaAPT::SourceHandle)handle {
    return apt_->sourceSnapshot(handle);
}

- (NSString *) sourceField:(CydiaAPT::SourceHandle)handle name:(NSString *)name {
    const std::string value(apt_->sourceField(handle, [name UTF8String]));
    return value.empty() ? (NSString *) [NSNull null] : [NSString stringWithUTF8String:value.c_str()];
}

- (std::vector<std::uint32_t>) sourceFileIDs:(CydiaAPT::SourceHandle)handle {
    return apt_->sourceFileIDs(handle);
}

- (CydiaAPT::SourcePreflightResult) sourcePreflight:(const CydiaAPT::SourcePreflightRequest &)request
    cancelled:(const std::function<bool()> &)cancelled {
    return apt_->sourcePreflight(request, cancelled);
}

- (CydiaAPT::SourceResourceResult) sourceResource:(const CydiaAPT::SourceResourceRequest &)request
    cancelled:(const std::function<bool()> &)cancelled {
    return apt_->sourceResource(request, cancelled);
}

- (CydiaAPT::SourceDiscoveryResult) discoverSourceOptions:(const std::string &)uri
    temporaryParent:(const std::string &)temporaryParent cancelled:(const std::function<bool()> &)cancelled {
    return CydiaAPT::DiscoverSourceOptions(*apt_, uri, temporaryParent, cancelled);
}

@end
