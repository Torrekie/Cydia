/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#include "Cydia/LockdownServices.h"

#include <dlfcn.h>

namespace {

void *LockdownHandle(void) {
    static void *handle = [] {
        void *result(dlopen("/usr/lib/liblockdown.dylib", RTLD_LAZY | RTLD_GLOBAL));
        if (result == nullptr)
            result = dlopen("/usr/lib/system/liblockdown.dylib", RTLD_LAZY | RTLD_GLOBAL);
        return result;
    }();
    return handle;
}

template <typename Function_>
Function_ Lookup(const char *name) {
    void *handle(LockdownHandle());
    return reinterpret_cast<Function_>(dlsym(handle ?: RTLD_DEFAULT, name));
}

} // namespace

extern "C" CFStringRef kLockdownUniqueDeviceIDKey = CFSTR("UniqueDeviceID");

extern "C" void *CydiaLockdownConnect(void) {
    using Function = void *(*)();
    static Function function(Lookup<Function>("lockdown_connect"));
    return function == nullptr ? nullptr : function();
}

extern "C" CFStringRef CydiaLockdownCopyValue(void *lockdown, void *null, CFStringRef key) {
    using Function = CFStringRef (*)(void *, void *, CFStringRef);
    static Function function(Lookup<Function>("lockdown_copy_value"));
    return function == nullptr ? nullptr : function(lockdown, null, key);
}

extern "C" void CydiaLockdownDisconnect(void *lockdown) {
    using Function = void (*)(void *);
    static Function function(Lookup<Function>("lockdown_disconnect"));
    if (function != nullptr)
        function(lockdown);
}
