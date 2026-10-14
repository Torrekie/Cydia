/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RepositoryIdentity.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <locale>
#include <sstream>
#include <sys/utsname.h>
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#include <sys/sysctl.h>
#if __has_include("Version.h")
#include "Version.h"
#endif
#endif

namespace CydiaRuntime {
namespace {
#if defined(__APPLE__)
std::string Text(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return {};
    CFStringRef string = static_cast<CFStringRef>(value);
    const CFIndex length = CFStringGetLength(string);
    const CFIndex capacity = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    if (capacity <= 0 || capacity > 4096) return {};
    std::string result(static_cast<std::size_t>(capacity), '\0');
    CFIndex used = 0;
    if (CFStringGetBytes(string, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, false,
        reinterpret_cast<UInt8 *>(&result[0]), capacity, &used) != length) return {};
    result.resize(static_cast<std::size_t>(used)); return result;
}
std::string SystemValue(const char *key) {
    char value[256] = {}; std::size_t size = sizeof(value);
    return sysctlbyname(key, value, &size, nullptr, 0) == 0 && size && value[0] ? std::string(value) : std::string();
}
std::string SystemVersion() {
    std::string version = SystemValue("kern.osproductversion");
    if (!version.empty()) return version;
    CFURLRef URL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
        CFSTR("/System/Library/CoreServices/SystemVersion.plist"), kCFURLPOSIXPathStyle, false);
    CFReadStreamRef stream = URL ? CFReadStreamCreateWithFile(kCFAllocatorDefault, URL) : nullptr;
    CFPropertyListRef values = nullptr;
    if (stream && CFReadStreamOpen(stream)) {
        values = CFPropertyListCreateWithStream(kCFAllocatorDefault, stream, 0, kCFPropertyListImmutable, nullptr, nullptr);
        CFReadStreamClose(stream);
    }
    if (values && CFGetTypeID(values) == CFDictionaryGetTypeID())
        version = Text(CFDictionaryGetValue(static_cast<CFDictionaryRef>(values), CFSTR("ProductVersion")));
    if (values) CFRelease(values);
    if (stream) CFRelease(stream);
    if (URL) CFRelease(URL);
    return version;
}
std::string CydiaVersion() {
#ifdef CYDIA_VERSION
    return CYDIA_VERSION;
#else
    CFBundleRef bundle = CFBundleGetMainBundle();
    return bundle ? Text(CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleShortVersionString"))) : std::string();
#endif
}
#endif
}

std::string RepositoryUserAgent(const std::string &requested, const std::string &custom, bool download) {
    const std::string identity = ValidRepositoryIdentity(requested) &&
        (requested != "custom" || ValidRepositoryUserAgent(custom)) ? requested : "cydia";
    if (identity == "custom") return custom;
#if defined(__APPLE__)
    if (identity == "sileo") {
        // Sileo 2.5.1, c9f70158, URLManager.urlRequest: the released UA has
        // CoreFoundation and Darwin versions, without a device/iOS token.
        std::ostringstream coreFoundation;
        coreFoundation.imbue(std::locale::classic());
        coreFoundation << std::fixed << std::setprecision(3) << kCFCoreFoundationVersionNumber;
        struct utsname kernel = {}; uname(&kernel);
        return std::string("Sileo/2.5.1 CoreFoundation/") + coreFoundation.str() + " " + kernel.sysname + "/" + kernel.release;
    }
    if (identity == "zebra") {
        const std::string version = SystemVersion();
        // Zebra v1.1.37, 61ba43b5, ZBDevice userAgent/downloadUserAgent.
        if (download && std::strtol(version.c_str(), nullptr, 10) < 15)
            return "Telesphoreo (Zebra) APT-HTTP/1.0.592";
        std::string machine = SystemValue("hw.machine");
#if TARGET_OS_SIMULATOR
        const char *simulated = std::getenv("SIMULATOR_MODEL_IDENTIFIER");
        if (simulated && *simulated) machine = simulated;
#endif
        const std::string device = machine.compare(0, 6, "iPhone") == 0 ? "iPhone" :
            machine.compare(0, 4, "iPad") == 0 ? "iPad" : machine.compare(0, 4, "iPod") == 0 ? "iPod touch" : "iPhone/iPod";
        return "Zebra/1.1.37 (" + device + "; iOS/" + version + ")";
    }
    const std::string version = CydiaVersion();
#else
    const std::string version;
#endif
    return std::string("Cydia") + (version.empty() ? "" : "/" + version) + (download ? "" : " RepositoryAccounts/1");
}

std::string RepositoryDownloadUserAgent() {
    std::string identity, custom;
#if defined(__APPLE__) && !defined(CYDIA_REPOSITORY_ACCOUNT_TESTING)
    // The unprivileged bundled worker runs as the same user as Cydia. Reading
    // this domain supplies HTTP text only, never worker authority or paths.
    // Refresh a long-lived worker's preference cache before each acquisition.
    CFPreferencesAppSynchronize(CFSTR("com.saurik.Cydia"));
    CFPropertyListRef settings = CFPreferencesCopyAppValue(CFSTR("CydiaSettings"), CFSTR("com.saurik.Cydia"));
    if (settings && CFGetTypeID(settings) == CFDictionaryGetTypeID()) {
        const auto dictionary = static_cast<CFDictionaryRef>(settings);
        identity = Text(CFDictionaryGetValue(dictionary, CFSTR("RepositoryIdentity")));
        custom = Text(CFDictionaryGetValue(dictionary, CFSTR("RepositoryCustomUserAgent")));
    }
    if (settings) CFRelease(settings);
#endif
    return RepositoryUserAgent(identity, custom, true);
}
}
