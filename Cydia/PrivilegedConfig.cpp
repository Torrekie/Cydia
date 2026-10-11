/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PrivilegedRuntime.hpp"
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <sys/stat.h>

namespace CydiaRuntime {
namespace Privileged {
namespace {
bool Fail(Error *error, const char *code, const std::string &message) {
    if (error != NULL) { error->code = code; error->message = message; }
    return false;
}

std::string TrimSlash(std::string path) {
    while (path.size() > 1 && path.back() == '/') path.pop_back();
    return path;
}

bool SamePath(const std::string &left, const std::string &right) {
    if (left == right) return true;
    char *a = realpath(left.c_str(), NULL), *b = realpath(right.c_str(), NULL);
    const bool equal = a != NULL && b != NULL && std::strcmp(a, b) == 0;
    std::free(a); std::free(b);
    return equal;
}

bool Absolute(const std::string &path) {
    return !path.empty() && path[0] == '/' && path.find('\0') == std::string::npos &&
        path.find('\n') == std::string::npos && path.find('\r') == std::string::npos;
}

bool Disabled(const std::string &path) {
    return path.empty() || path == "-" || TrimSlash(path) == "/dev/null";
}

struct Inputs {
    Environment *environment;
    Error *error;
    bool denied;
};

bool ValidateInput(const std::string &path, bool directory, void *context) {
    Inputs &inputs = *static_cast<Inputs *>(context);
    Evidence evidence;
    if (!CaptureEvidence(TrimSlash(path), directory, false, &evidence, inputs.error)) {
        inputs.denied = true;
        return false;
    }
    inputs.environment->evidence.push_back(evidence);
    return true;
}

class Guard {
  public:
    explicit Guard(Inputs *inputs) {
        _error->PushToStack(); SetConfigurationReadValidator(ValidateInput, inputs);
    }
    ~Guard() {
        SetConfigurationReadValidator(NULL, NULL); _error->RevertToStack();
    }
};

bool ReadOptional(Configuration &configuration, const std::string &rawPath,
                  bool directory, Inputs &inputs) {
    if (Disabled(rawPath)) return true;
    const std::string path = TrimSlash(rawPath);
    Evidence evidence;
    if (!CaptureEvidence(path, directory, true, &evidence, inputs.error)) return false;
    if (evidence.absent) {
        inputs.environment->evidence.push_back(evidence);
        return true;
    }
    return directory ? ReadConfigDir(configuration, path) : ReadConfigFile(configuration, path);
}

bool SelectExecutable(const Configuration &configuration, const PackageDatabasePaths &paths,
                      Environment *environment, const char *purpose, const std::string &fallback,
                      std::string *selected, Error *error) {
    const std::string key = std::string("Dir::Bin::") + purpose;
    *selected = configuration.Find(key, fallback);
    if (std::string(purpose) == "dpkg" && SamePath(*selected, paths.CydoPath()))
        *selected = fallback;
    const auto replacement = environment->executableOverrides.find(purpose);
    if (replacement != environment->executableOverrides.end()) *selected = replacement->second;
    Evidence identity;
    if (!CapturePathIdentity(*selected, false, true, &identity, error)) return false;
    environment->evidence.push_back(identity);
    return true;
}

bool ResolveOptions(const Configuration &configuration, Environment *environment, Error *error) {
    const std::string status = TrimSlash(configuration.FindFile("Dir::State::status"));
    const std::size_t slash = status.rfind('/');
    if (!Absolute(status) || slash == std::string::npos || status.substr(slash + 1) != "status")
        return Fail(error, "invalid_dpkg_status", "APT does not select a dpkg status database.");
    environment->dpkgAdmin = slash == 0 ? "/" : status.substr(0, slash);
    environment->dpkgRoot = "/";
    if (TrimSlash(configuration.FindDir("DPkg::Chroot-Directory", "/")) != "/")
        return Fail(error, "unsupported_dpkg_chroot", "This dpkg chroot requires a supported privileged wrapper.");
    const std::vector<std::string> options = configuration.FindVector("DPkg::Options");
    environment->trustedDpkgHooks.clear();
    for (std::size_t index = 0; index != options.size(); ++index) {
        for (const char *name : {"--pre-invoke", "--post-invoke"}) {
            const std::string key(name);
            if (options[index] == key) {
                if (++index == options.size() || options[index].empty() || options[index].find('\0') != std::string::npos)
                    return Fail(error, "invalid_dpkg_options", "Missing protected dpkg hook command.");
                environment->trustedDpkgHooks.push_back(key + '=' + options[index]);
            } else if (options[index].compare(0, key.size() + 1, key + '=') == 0)
                environment->trustedDpkgHooks.push_back(options[index]);
            else continue;
            break;
        }
    }
    std::string declaredAdmin;
    for (std::size_t index = 0; index != options.size(); ++index) {
        if (options[index] == "--pre-invoke" || options[index] == "--post-invoke") { ++index; continue; }
        for (const char *name : {"--root", "--instdir", "--admindir"}) {
            const std::string key(name);
            std::string value;
            if (options[index] == key) {
                if (++index == options.size()) return Fail(error, "invalid_dpkg_options", "Missing dpkg path.");
                value = options[index];
            } else if (options[index].compare(0, key.size() + 1, key + '=') == 0)
                value = options[index].substr(key.size() + 1);
            else continue;
            if (!Absolute(value)) return Fail(error, "invalid_dpkg_options", "dpkg paths must be absolute.");
            value = TrimSlash(value);
            if (key == "--admindir") declaredAdmin = value;
            else {
                environment->dpkgRoot = value;
                if (key == "--root") declaredAdmin = value + (value == "/" ? "var/lib/dpkg" : "/var/lib/dpkg");
            }
            break;
        }
    }
    if (!declaredAdmin.empty() && !SamePath(declaredAdmin, environment->dpkgAdmin))
        return Fail(error, "contradictory_dpkg_admin", "APT and dpkg select different package databases.");
    for (const std::string &path : {environment->dpkgRoot, environment->dpkgAdmin}) {
        Evidence identity;
        if (!CapturePathIdentity(path, true, false, &identity, error)) return false;
        environment->evidence.push_back(identity);
    }
    return ValidateDpkgArguments(*environment, options, error);
}
} // namespace

bool ResolveCurrentEnvironment(const PackageDatabasePaths &paths,
                              const std::string &aptConfigOverride,
                              Environment *environment, Error *error) {
    if (environment == NULL) return false;
    *environment = Environment();
    environment->aptConfigOverride = aptConfigOverride;
    Configuration configuration;
    /* Match the app's bootstrap seeds and pkgInitConfig's read order. Only
     * the existing APT parser interprets apt.conf syntax and nested includes. */
    configuration.Set("Dir", "/");
    configuration.Set("Dir::Etc", paths.AptConfigDirectory());
    configuration.Set("Dir::Etc::parts", "apt.conf.d");
    configuration.Set("Dir::Etc::main", "apt.conf");
    configuration.Set("Dir::Etc::sourcelist", "sources.list");
    configuration.Set("Dir::Etc::sourceparts", "sources.list.d");
    configuration.Set("Dir::Etc::preferences", "preferences");
    configuration.Set("Dir::Etc::preferencesparts", "preferences.d");
    configuration.Set("Dir::Etc::trusted", "trusted.gpg");
    configuration.Set("Dir::Etc::trustedparts", "trusted.gpg.d");
    configuration.Set("Dir::State::status", paths.DpkgStatusPath());
    configuration.Set("Dir::State::extended_states", paths.AptExtendedStatesPath());
    configuration.Set("Dir::Bin::dpkg", paths.CydoPath());
    Inputs inputs = {environment, error, false};
    Guard guard(&inputs);
    if (!aptConfigOverride.empty() && !ReadConfigFile(configuration, aptConfigOverride))
        return inputs.denied ? false : Fail(error, "invalid_apt_configuration", "Unable to parse the declared APT configuration.");
    if (!ReadOptional(configuration, configuration.FindDir("Dir::Etc::parts"), true, inputs) ||
        !ReadOptional(configuration, configuration.FindFile("Dir::Etc::main"), false, inputs))
        return inputs.denied ? false : Fail(error, "invalid_apt_configuration", "Unable to parse bootstrap APT configuration.");
    Evidence overrides;
    if (!ReadExecutableOverrides(paths, &environment->executableOverrides, &overrides, error)) return false;
    environment->evidence.push_back(overrides);
    if (!ResolveOptions(configuration, environment, error)) return false;
    environment->extendedStates = configuration.FindFile("Dir::State::extended_states");
    const std::string prefix = paths.layout() == PackageDatabaseLayout::Rootless ? "/var/jb" : "";
    if (!SelectExecutable(configuration, paths, environment, "dpkg", paths.DpkgBinaryPath(), &environment->dpkg, error) ||
        !SelectExecutable(configuration, paths, environment, "dpkg-query", prefix + "/usr/bin/dpkg-query", &environment->dpkgQuery, error) ||
        !SelectExecutable(configuration, paths, environment, "dpkg-deb", prefix + "/usr/bin/dpkg-deb", &environment->dpkgDeb, error)) return false;
    environment->gpg = configuration.Find("Dir::Bin::gpg", prefix + "/usr/bin/gpg");
    const auto gpgOverride = environment->executableOverrides.find("gpg");
    if (gpgOverride != environment->executableOverrides.end()) environment->gpg = gpgOverride->second;
    const std::string main = configuration.Find("Dir::Etc::sourcelist", "sources.list");
    const std::string parts = configuration.Find("Dir::Etc::sourceparts", "sources.list.d");
    environment->sourceList = Disabled(main) ? "" : configuration.FindFile("Dir::Etc::sourcelist");
    environment->sourceParts = Disabled(parts) ? "" : TrimSlash(configuration.FindDir("Dir::Etc::sourceparts"));
    if (Disabled(environment->sourceList)) environment->sourceList.clear();
    if (Disabled(environment->sourceParts)) environment->sourceParts.clear();
    for (const auto &setting : {std::make_pair("Dir::Etc::preferences", &environment->preferences),
                               std::make_pair("Dir::Etc::trusted", &environment->trusted)}) {
        *setting.second = Disabled(configuration.Find(setting.first)) ? "" : configuration.FindFile(setting.first);
        if (Disabled(*setting.second)) setting.second->clear();
    }
    for (const auto &setting : {std::make_pair("Dir::Etc::preferencesparts", &environment->preferencesParts),
                               std::make_pair("Dir::Etc::trustedparts", &environment->trustedParts)}) {
        *setting.second = Disabled(configuration.Find(setting.first)) ? "" : TrimSlash(configuration.FindDir(setting.first));
        if (Disabled(*setting.second)) setting.second->clear();
    }
    return RecheckEvidence(environment->evidence, error);
}

bool ResolveEnvironment(const PackageDatabasePaths &paths,
                        const ExpectedEnvironment &expected,
                        Environment *environment, Error *error) {
    if (!ResolveCurrentEnvironment(paths, expected.aptConfigOverride, environment, error)) return false;
    const std::string *claimed[] = {&expected.dpkgRoot, &expected.dpkgAdmin, &expected.dpkg,
        &expected.dpkgQuery, &expected.dpkgDeb, &expected.sourceList, &expected.sourceParts};
    const std::string *actual[] = {&environment->dpkgRoot, &environment->dpkgAdmin, &environment->dpkg,
        &environment->dpkgQuery, &environment->dpkgDeb, &environment->sourceList, &environment->sourceParts};
    for (std::size_t index = 0; index != 7; ++index)
        if (!SamePath(*claimed[index], *actual[index]))
            return Fail(error, "environment_mismatch", "The reviewed environment does not match protected APT configuration.");
    return true;
}
} // namespace Privileged
} // namespace CydiaRuntime
