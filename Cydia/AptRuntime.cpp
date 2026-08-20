/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptRuntime.hpp"

#include <apt-pkg/aptconfiguration.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>

#include <algorithm>

namespace CydiaAPT {

namespace {
std::string gArchitecture;
std::vector<std::string> gArchitectures;

std::string JoinPath(const std::string &directory, const char *leaf) {
    std::string path(directory);
    path += '/';
    path += leaf;
    return path;
}

void ApplyBootstrapConfiguration(const InitializationOptions &options,
                                 bool resetArchitectureVector) {
    /* pkgInitConfig supplies compile-time defaults and then reads apt.conf.
     * Seed the selected bootstrap before that read, and call this again before
     * pkgInitSystem so a config file cannot redirect system discovery to the
     * other layout. */
    _config->Set("APT::Architecture", options.architecture);
    if (resetArchitectureVector)
        _config->Clear("APT::Architectures");
    _config->Set("Dir::Etc", options.aptConfigDirectory);
    _config->Set("Dir::Bin::Methods", options.methodsDirectory);
    _config->Set("Dir::Cache", options.cacheDirectory);
    _config->Set("Dir::State", options.stateDirectory);
    _config->Set("Dir::State::Lists", options.listsDirectory);
    _config->Set("Dir::State::status", options.dpkgStatusPath);
    _config->Set("Dir::Log", options.logDirectory);
    _config->Set("Dir::Bin::dpkg", options.dpkgPath);
    _config->Set("Dir::dpkg::cputable", JoinPath(options.dpkgDataDirectory, "cputable"));
    _config->Set("Dir::dpkg::tupletable", JoinPath(options.dpkgDataDirectory, "tupletable"));
    _config->Set("Dir::dpkg::triplettable", JoinPath(options.dpkgDataDirectory, "triplettable"));
    _config->Set("DPkg::Path", options.dpkgExecutableSearchPath);
}

void MaterializeArchitectures(const std::string &nativeArchitecture) {
    std::vector<std::string> discovered(
        APT::Configuration::getArchitectures(false));
    std::vector<std::string> normalized;
    if (!nativeArchitecture.empty())
        normalized.push_back(nativeArchitecture);

    for (std::vector<std::string>::const_iterator architecture(discovered.begin());
         architecture != discovered.end(); ++architecture) {
        if (architecture->empty() || *architecture == "all" || *architecture == "any" ||
            *architecture == nativeArchitecture ||
            std::find(normalized.begin(), normalized.end(), *architecture) != normalized.end())
            continue;
        normalized.push_back(*architecture);
    }

    /* Freeze exactly what the selected dpkg reported. Source parsing and
     * acquisition must not revive an architecture vector inherited from an
     * apt.conf belonging to another bootstrap layout. */
    _config->Clear("APT::Architectures");
    for (std::size_t index(0); index != normalized.size(); ++index) {
        const std::string key("APT::Architectures::" + std::to_string(index));
        _config->Set(key.c_str(), normalized[index]);
    }
    gArchitectures.swap(normalized);
}
} // namespace

InitializationOptions::InitializationOptions() :
    maxParallel(0),
    allowInsecureRepositories(false),
    checkValidUntil(true),
    forceEssential(false)
{
}

bool Initialize(const InitializationOptions &options, std::string *architecture) {
    /* Configuration is process-global. Remove any vector inherited from a
     * previous/rootful setup before reading the selected bootstrap's files. */
    ApplyBootstrapConfiguration(options, true);
    if (!pkgInitConfig(*_config))
        return false;

    /* The selected dpkg is the authority for native and foreign architecture
     * state. Clear a stale/partial apt.conf vector again so libapt asks the
     * initialized pkgSystem (and therefore this exact dpkg) when it constructs
     * the cache. */
    ApplyBootstrapConfiguration(options, true);
    if (!pkgInitSystem(*_config, _system))
        return false;

    gArchitecture = _config->Find("APT::Architecture");
    MaterializeArchitectures(gArchitecture);

    if (options.allowInsecureRepositories)
        _config->Set("Acquire::AllowInsecureRepositories", true);
    _config->Set("Acquire::Check-Valid-Until", options.checkValidUntil);
    _config->Set("Dir::Bin::Methods", options.methodsDirectory);
    if (options.forceEssential)
        _config->Set("pkgCacheGen::ForceEssential", "");
    if (!options.translation.empty())
        _config->Set("APT::Acquire::Translation", options.translation);
    _config->Set("Acquire::Languages", options.languages);
    if (options.maxParallel > 0)
        _config->Set("Acquire::http::MaxParallel", options.maxParallel);

    if (architecture != NULL)
        *architecture = gArchitecture;
    return true;
}

const std::string &Architecture() {
    return gArchitecture;
}

const std::vector<std::string> &Architectures() {
    return gArchitectures;
}

bool IsArchitectureSupported(const std::string &architecture) {
    if (architecture == "all")
        return true;
    return !architecture.empty() &&
        std::find(gArchitectures.begin(), gArchitectures.end(), architecture) !=
            gArchitectures.end();
}

std::string SourceArchitectureOption() {
    if (gArchitectures.empty())
        return std::string();

    std::string option("[arch=");
    for (std::size_t index(0); index != gArchitectures.size(); ++index) {
        if (index != 0)
            option.push_back(',');
        option.append(gArchitectures[index]);
    }
    option.push_back(']');
    return option;
}

} // namespace CydiaAPT
