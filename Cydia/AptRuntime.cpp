/* Cydia - iPhone UIKit Front-End for Debian APT */

#include "Cydia/AptRuntime.hpp"

#include <apt-pkg/configuration.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>

namespace CydiaAPT {

namespace {
std::string gArchitecture;
}

InitializationOptions::InitializationOptions() :
    maxParallel(0),
    allowInsecureRepositories(false),
    checkValidUntil(true),
    forceEssential(false)
{
}

bool Initialize(const InitializationOptions &options, std::string *architecture) {
    if (!pkgInitConfig(*_config))
        return false;

    _config->Set("Dir::Etc", options.aptConfigDirectory);
    if (!pkgInitSystem(*_config, _system))
        return false;

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
    _config->Set("Dir::Cache", options.cacheDirectory);
    _config->Set("Dir::State", options.stateDirectory);
    _config->Set("Dir::State::Lists", options.listsDirectory);
    _config->Set("Dir::Log", options.logDirectory);
    _config->Set("Dir::Bin::dpkg", options.dpkgPath);

    gArchitecture = _config->Find("APT::Architecture");
    if (architecture != NULL)
        *architecture = gArchitecture;
    return true;
}

const std::string &Architecture() {
    return gArchitecture;
}

} // namespace CydiaAPT
