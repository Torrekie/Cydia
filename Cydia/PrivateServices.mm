/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/PrivateServices.h"

#include <dlfcn.h>

namespace {

void *SpringBoardServicesHandle() {
    static void *handle(dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_LAZY | RTLD_LOCAL));
    return handle;
}

template <typename Function_>
Function_ LookupSpringBoardService(const char *name) {
    void *symbol(NULL);
    if (void *handle = SpringBoardServicesHandle())
        symbol = dlsym(handle, name);
    if (symbol == NULL)
        symbol = dlsym(RTLD_DEFAULT, name);
    return reinterpret_cast<Function_>(symbol);
}

template <typename Function_>
Function_ LookupDefault(const char *name) {
    return reinterpret_cast<Function_>(dlsym(RTLD_DEFAULT, name));
}

} // namespace

mach_port_t CydiaSpringBoardServerPort(void) {
    using Function = mach_port_t (*)();
    static Function function(LookupSpringBoardService<Function>("SBSSpringBoardServerPort"));
    return function == nullptr ? MACH_PORT_NULL : function();
}

int CydiaBundlePathForDisplayIdentifier(mach_port_t port, const char *identifier, char *path) {
    using Function = int (*)(mach_port_t, const char *, char *);
    static Function function(LookupSpringBoardService<Function>("SBBundlePathForDisplayIdentifier"));
    return function == nullptr ? -1 : function(port, identifier, path);
}

NSArray *CydiaCopyApplicationDisplayIdentifiers(bool active, bool debuggable) {
    using Function = NSArray *(*)(bool, bool);
    static Function function(LookupSpringBoardService<Function>("SBSCopyApplicationDisplayIdentifiers"));
    return function == nullptr ? nil : function(active, debuggable);
}

NSString *CydiaCopyLocalizedApplicationName(NSString *identifier) {
    using Function = NSString *(*)(NSString *);
    static Function function(LookupSpringBoardService<Function>("SBSCopyLocalizedApplicationNameForDisplayIdentifier"));
    return function == nullptr ? nil : function(identifier);
}

NSString *CydiaCopyIconImagePath(NSString *identifier) {
    using Function = NSString *(*)(NSString *);
    static Function function(LookupSpringBoardService<Function>("SBSCopyIconImagePathForDisplayIdentifier"));
    return function == nullptr ? nil : function(identifier);
}

bool CydiaReboot(uint64_t flags) {
    using SpringBoardFunction = void (*)(mach_port_t);
    static SpringBoardFunction springboard(LookupSpringBoardService<SpringBoardFunction>("SBReboot"));
    if (springboard != nullptr) {
        springboard(CydiaSpringBoardServerPort());
        return true;
    }

    using RebootFunction = void (*)(uint64_t);
    static RebootFunction reboot(LookupDefault<RebootFunction>("reboot2"));
    if (reboot == nullptr)
        return false;

    reboot(flags);
    return true;
}
