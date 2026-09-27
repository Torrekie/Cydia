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
#include <cctype>
#include <cstdio>
#include <vector>

namespace CydiaAPT {

namespace {
std::string gArchitecture;
std::vector<std::string> gArchitectures;
std::string gSourceListPath;
std::string gSourcePartsDirectory;
std::string gManagedSourceListPath;

std::string JoinPath(const std::string &directory, const char *leaf) {
    std::string path(directory);
    path += '/';
    path += leaf;
    return path;
}

void ApplyBootstrapConfiguration(const InitializationOptions &options,
                                 bool resetArchitectureVector,
                                 const std::string *etcSetting = NULL,
                                 const std::string *sourceListSetting = NULL,
                                 const std::string *sourcePartsSetting = NULL) {
    /* pkgInitConfig supplies compile-time defaults and then reads apt.conf.
     * Seed the selected non-source bootstrap paths before that read.  The
     * second call, before pkgInitSystem, reapplies those selected paths while
     * carrying the maintainer's raw Dir::Etc/source settings explicitly. */
    _config->Set("APT::Architecture", options.architecture);
    if (resetArchitectureVector)
        _config->Clear("APT::Architectures");
    if (etcSetting == NULL)
        _config->Set("Dir::Etc", options.aptConfigDirectory);
    else
        _config->Set("Dir::Etc", *etcSetting);
    /* Keep the maintainer's spelling (including relative values and an
     * explicit /dev/null) for the second pass. Passing FindFile/FindDir's
     * already-rooted result back here would apply RootDir twice. */
    if (sourceListSetting != NULL)
        _config->Set("Dir::Etc::sourcelist", *sourceListSetting);
    if (sourcePartsSetting != NULL)
        _config->Set("Dir::Etc::sourceparts", *sourcePartsSetting);
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

void ResetRuntimeState() {
    gArchitecture.clear();
    gArchitectures.clear();
    gSourceListPath.clear();
    gSourcePartsDirectory.clear();
    gManagedSourceListPath.clear();
    _system = NULL;
}

std::string NormalizeRootDirectory(const std::string &rootDirectory) {
    std::string normalized(rootDirectory);
    while (normalized.size() > 1 && normalized[normalized.size() - 1] == '/')
        normalized.erase(normalized.size() - 1);
    return normalized;
}

bool IsPathUnderRootDirectory(const std::string &path,
                              const std::string &rootDirectory) {
    if (path.empty() || rootDirectory.empty() || rootDirectory == "/")
        return false;

    const std::string root(NormalizeRootDirectory(rootDirectory));
    if (root.empty() || root == "/")
        return false;
    return path == root ||
        (path.size() > root.size() &&
         path.compare(0, root.size(), root) == 0 &&
         path[root.size()] == '/');
}

bool HasIncompatibleRootedOptions(const InitializationOptions &options,
                                  const std::string &rootDirectory) {
    if (rootDirectory.empty() || rootDirectory == "/")
        return false;

    /* APT applies RootDir to FILE/DIR options itself. InitializationOptions
     * use that same (root-relative) coordinate system; accepting a physical
     * path which already contains RootDir would silently produce e.g.
     * /var/jb/var/jb/etc/apt. Reject the mixed coordinate system rather than
     * letting source discovery or dpkg status access land in an unintended
     * tree. DPkg::Path is a search path and is intentionally excluded: APT
     * does not RootDir-prefix its colon-separated entries. */
    const std::string *paths[] = {
        &options.aptConfigDirectory,
        &options.methodsDirectory,
        &options.cacheDirectory,
        &options.stateDirectory,
        &options.listsDirectory,
        &options.logDirectory,
        &options.dpkgStatusPath,
        &options.dpkgDataDirectory,
    };
    for (std::size_t index(0); index != sizeof(paths) / sizeof(paths[0]); ++index)
        if (IsPathUnderRootDirectory(*paths[index], rootDirectory))
            return true;

    return false;
}

bool IsDisabledSourceValue(const std::string &value) {
    /* libapt treats /dev/null specially even after RootDir is prepended.  A
     * rooted result therefore ends in /dev/null rather than comparing equal
     * to the sentinel; keep Cydia's ownership view identical to ReadMainList. */
    return value.empty() || value == "/dev/null" ||
        (value.size() >= 9 &&
         value.compare(value.size() - 9, 9, "/dev/null") == 0);
}

bool IsDisabledSourceSetting(const std::string &value) {
    /* FindFile also collapses any value beginning with /dev/null to that
     * sentinel.  Check the raw spelling before asking APT to resolve it. */
    return value.empty() || value.compare(0, 9, "/dev/null") == 0;
}

std::string ResolveSourceListPath() {
    /* Check the raw value first. APT's FindFile intentionally prefixes even
     * an absolute value when RootDir is set, so /dev/null must be recognized
     * before resolution rather than as a filesystem path. */
    const std::string raw(_config->Find("Dir::Etc::sourcelist", "sources.list"));
    if (IsDisabledSourceSetting(raw))
        return std::string();
    const std::string configured(_config->FindFile("Dir::Etc::sourcelist", "sources.list"));
    if (IsDisabledSourceValue(configured))
        return std::string();
    return configured;
}

std::string ResolveSourcePartsDirectory() {
    const std::string raw(_config->Find("Dir::Etc::sourceparts", "sources.list.d"));
    if (IsDisabledSourceSetting(raw))
        return std::string();
    const std::string configured(_config->FindDir("Dir::Etc::sourceparts", "sources.list.d"));
    if (IsDisabledSourceValue(configured))
        return std::string();
    std::string result(configured);
    while (result.size() > 1 && result[result.size() - 1] == '/')
        result.erase(result.size() - 1);
    return IsDisabledSourceValue(result) ? std::string() : result;
}

bool IsDirectListLeaf(const std::string &value) {
    if (value.empty() || value == "." || value == ".." ||
        value.find('/') != std::string::npos || value.find('\\') != std::string::npos)
        return false;
    for (std::size_t index(0); index != value.size(); ++index) {
        const unsigned char character(static_cast<unsigned char>(value[index]));
        if (std::isspace(character) != 0 || std::iscntrl(character) != 0)
            return false;
    }
    const std::string suffix(".list");
    return value.size() > suffix.size() &&
        value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string PrefixRootDirectory(const std::string &path) {
    if (path.empty())
        return path;

    const std::string root(NormalizeRootDirectory(_config->Find("RootDir", "")));
    if (root.empty() || root == "/")
        return path;

    std::string result(root);
    if (path[0] == '/')
        result += path;
    else {
        result.push_back('/');
        result += path;
    }
    return result;
}

std::string ResolveManagedSourceList(const std::string &sourcePartsDirectory) {
    if (sourcePartsDirectory.empty())
        return std::string();

    /* This key belongs to the bootstrap maintainer.  It is deliberately not
     * read from Cydia preferences: an app preference must not redirect APT's
     * source ownership.  Relative values are a single filename below the
     * already-resolved sourceparts directory. */
    const std::string configured(_config->Find("Cydia::APT::ManagedSourceList", ""));
    if (configured.empty())
        return std::string();

    std::string candidate;
    if (configured[0] == '/') {
        /* A maintainer may spell an absolute key either in APT's
         * RootDir-relative coordinate system (/etc/apt/parts/foo.list) or as
         * the already-effective path (/root/etc/apt/parts/foo.list). Accept
         * only the spelling whose parent is exactly the effective sourceparts
         * directory; traversal and sibling paths remain rejected. */
        const std::string rooted(PrefixRootDirectory(configured));
        const std::string candidates[] = { rooted, configured };
        for (std::size_t index(0); index != sizeof(candidates) / sizeof(candidates[0]); ++index) {
            const std::string &value(candidates[index]);
            const std::string::size_type slash(value.rfind('/'));
            if (slash == std::string::npos ||
                value.substr(0, slash) != sourcePartsDirectory ||
                !IsDirectListLeaf(value.substr(slash + 1)))
                continue;
            candidate = value;
            break;
        }
    } else if (IsDirectListLeaf(configured)) {
        candidate = sourcePartsDirectory + "/" + configured;
    }

    if (candidate.empty()) {
        std::fprintf(stderr,
                     "Cydia APT: ignoring invalid Cydia::APT::ManagedSourceList\n");
        return std::string();
    }
    return candidate;
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
    ResetRuntimeState();

    /* Configuration is process-global. Remove any vector inherited from a
     * previous bootstrap before reading the selected maintainer config. The
     * complete Dir tree and RootDir are reset here; apt.conf/defaults
     * loaded by pkgInitConfig repopulate the maintainer-owned values. This is
     * important when one process probes rootless and rootful databases in
     * sequence: Cnf.CndSet() otherwise preserves old source/config paths. */
    _config->Clear("RootDir");
    _config->Clear("Dir");
    _config->Clear("Dir::Etc");
    _config->Clear("Dir::Etc::sourcelist");
    _config->Clear("Dir::Etc::sourceparts");
    _config->Clear("Cydia::APT::ManagedSourceList");
    ApplyBootstrapConfiguration(options, true);
    if (!pkgInitConfig(*_config)) {
        ResetRuntimeState();
        return false;
    }

    /* Preserve the maintainer's raw Dir::Etc value through the second pass.
     * Relative source settings are interpreted against this directory by
     * libapt; replacing it with the selected layout here would make an
     * APT_CONFIG/apt.conf redirect appear to work during pkgInitConfig and
     * then silently read a different source tree after pkgInitSystem. */
    const std::string etcSetting(
        _config->Find("Dir::Etc", options.aptConfigDirectory.c_str()));
    const std::string rootDirectory(_config->Find("RootDir", ""));
    const std::string sourceListSetting(
        _config->Find("Dir::Etc::sourcelist", "sources.list"));
    const std::string sourcePartsSetting(
        _config->Find("Dir::Etc::sourceparts", "sources.list.d"));
    if (HasIncompatibleRootedOptions(options, rootDirectory) ||
        IsPathUnderRootDirectory(etcSetting, rootDirectory) ||
        IsPathUnderRootDirectory(sourceListSetting, rootDirectory) ||
        IsPathUnderRootDirectory(sourcePartsSetting, rootDirectory)) {
        std::fprintf(stderr,
                     "Cydia APT: rejecting RootDir with already-rooted APT paths\n");
        ResetRuntimeState();
        return false;
    }

    /* Resolve the maintainer's source locations before the second bootstrap
     * pass.  They may be relative to Dir::Etc or come from a custom apt.conf;
     * FindFile/FindDir are the APT APIs that perform that resolution. */
    gSourceListPath = ResolveSourceListPath();
    gSourcePartsDirectory = ResolveSourcePartsDirectory();

    /* The selected dpkg is the authority for native and foreign architecture
     * state. Clear a stale/partial apt.conf vector again so libapt asks the
     * initialized pkgSystem (and therefore this exact dpkg) when it constructs
     * the cache. */
    ApplyBootstrapConfiguration(options, true,
                                &etcSetting,
                                &sourceListSetting, &sourcePartsSetting);
    if (!pkgInitSystem(*_config, _system)) {
        ResetRuntimeState();
        return false;
    }

    /* pkgInitSystem is not allowed to redirect source discovery. Reassert the
     * original maintainer settings, rather than the resolved paths, so an
     * optional RootDir is not applied twice on the next ReadMainList call. */
    _config->Set("Dir::Etc", etcSetting);
    _config->Set("Dir::Etc::sourcelist", sourceListSetting);
    _config->Set("Dir::Etc::sourceparts", sourcePartsSetting);

    gManagedSourceListPath = ResolveManagedSourceList(gSourcePartsDirectory);

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

const std::string &SourceListPath() {
    return gSourceListPath;
}

const std::string &SourcePartsDirectory() {
    return gSourcePartsDirectory;
}

const std::string &ManagedSourceListPath() {
    return gManagedSourceListPath;
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
