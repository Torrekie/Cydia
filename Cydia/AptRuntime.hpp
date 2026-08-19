/* Cydia - iPhone UIKit Front-End for Debian APT
 * Stable startup configuration boundary for the embedded APT runtime.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_AptRuntime_HPP
#define Cydia_AptRuntime_HPP

#include <string>

namespace CydiaAPT {

struct InitializationOptions {
    std::string aptConfigDirectory;
    std::string methodsDirectory;
    std::string cacheDirectory;
    std::string stateDirectory;
    std::string listsDirectory;
    std::string logDirectory;
    std::string dpkgPath;
    std::string translation;
    std::string languages;
    int maxParallel;
    bool allowInsecureRepositories;
    bool checkValidUntil;
    bool forceEssential;

    InitializationOptions();
};

/* Initializes the process-wide APT configuration and returns its selected
 * architecture.  The implementation is the only place that calls the APT
 * init/configuration API. */
bool Initialize(const InitializationOptions &options, std::string *architecture);
const std::string &Architecture();

} // namespace CydiaAPT

#endif // Cydia_AptRuntime_HPP
