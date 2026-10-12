/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/AptRuntime.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/PrivilegedRuntime.hpp"

#include <apt-pkg/aptconfiguration.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace CydiaAPT {

namespace {
std::string gArchitecture;
std::vector<std::string> gArchitectures;
std::vector<std::string> gRegisteredArchitectures;
bool gExplicitAcquisitionArchitectures(false);
bool gArchitectureQueryFailed(false);
const std::string gArchitectureQueryErrorCode("architecture_query_failed");
const std::string gArchitectureQueryError("Unable to query the selected dpkg's native and foreign architectures.");
std::string gSourceListPath;
std::string gSourcePartsDirectory;
std::string gManagedSourceListPath;
std::string gDpkgExecutablePath;
std::string gDpkgQueryExecutablePath;
std::string gDpkgDebExecutablePath;
std::string gAptConfigOverride;
std::string gPrivilegedHelperPath;
std::string gDpkgAdminDirectory;
std::string gDpkgRootDirectory;
std::string gPackageInstallPrefix;
std::string gDpkgChrootDirectory;
std::vector<std::string> gDpkgOptions;
bool gMutationEnvironmentValid(false);
std::string gRuntimeError;
std::string gRuntimeErrorCode;
std::string gExtendedStatesPath;
std::string gMethodsDirectory;
std::string gListsDirectory;
std::string gTrustedKeyringDirectory;
std::string gTrustedKeyringPartsDirectory;
RepositorySecurityMode gRepositorySecurityMode(DefaultRepositorySecurityMode());
bool gCachedRepositoryTrustValid(false);
struct PolicySetting {
    const char *name;
    bool present;
    std::string value;
};
PolicySetting gDistributionSecurity[] = {
    {"Acquire::AllowInsecureRepositories", false, {}},
    {"Acquire::AllowWeakRepositories", false, {}},
    {"Acquire::AllowDowngradeToInsecureRepositories", false, {}},
};

void CaptureDistributionSecurity() {
    for (auto &setting : gDistributionSecurity) {
        setting.present = _config->Exists(setting.name);
        setting.value = _config->Find(setting.name);
    }
}

void RestoreDistributionSecurity() {
    for (const auto &setting : gDistributionSecurity) {
        if (setting.present) _config->Set(setting.name, setting.value);
        else _config->Clear(setting.name);
    }
}

std::string JoinPath(const std::string &directory, const char *leaf) {
    std::string path(directory);
    path += '/';
    path += leaf;
    return path;
}

void ApplyBootstrapConfiguration(const InitializationOptions &options) {
    /* Seed fallbacks once, before apt.conf is read. Loaded bootstrap paths,
     * methods and architecture policy are authoritative after that read. */
    _config->Set("APT::Architecture", options.architecture);
    _config->Set("Dir::Etc", options.aptConfigDirectory);
    _config->Set("Dir::Bin::Methods", options.methodsDirectory);
    _config->Set("Dir::Cache", options.cacheDirectory);
    _config->Set("Dir::State", options.stateDirectory);
    _config->Set("Dir::State::Lists", options.listsDirectory);
    _config->Set("Dir::State::status", options.dpkgStatusPath);
    if (!options.bootstrapExtendedStatesPath.empty())
        _config->Set("Dir::State::extended_states", options.bootstrapExtendedStatesPath);
    _config->Set("Dir::Log", options.logDirectory);
    _config->Set("Dir::Bin::dpkg", options.dpkgPath);
    _config->Set("Cydia::Package-Install-Prefix", options.packageInstallPrefix.empty() ? "/" : options.packageInstallPrefix);
    /* Embedded APT's compile-time /usr/bin default belongs to a rooted
     * build. Seed sibling tools from the selected native dpkg location;
     * apt.conf and protected executable overrides still take precedence. */
    const auto binSlash(options.nativeDpkgPath.rfind('/'));
    if (binSlash != std::string::npos) {
        const std::string bin(options.nativeDpkgPath.substr(0, binSlash + 1));
        for (const char *tool : {"apt-key", "gpgv", "gpg"})
            _config->Set((std::string("Dir::Bin::") + tool).c_str(), bin + tool);
    }
    _config->Set("Dir::dpkg::cputable", JoinPath(options.dpkgDataDirectory, "cputable"));
    _config->Set("Dir::dpkg::tupletable", JoinPath(options.dpkgDataDirectory, "tupletable"));
    _config->Set("Dir::dpkg::triplettable", JoinPath(options.dpkgDataDirectory, "triplettable"));
    _config->Set("DPkg::Path", options.dpkgExecutableSearchPath);
}

void ResolveCompressionTools(const InitializationOptions &options) {
    // Unlike source/data paths, APT probes these keys with raw Find() and
    // executes Compressor::Binary through PATH. RootDir does not relocate
    // that execution namespace; DPkg::Path contains physical tool paths.
    const std::string searchPath(_config->Find("DPkg::Path", options.dpkgExecutableSearchPath.c_str()));
    for (const char *tool : {"gzip", "bzip2", "xz", "lzma", "lz4", "zstd"}) {
        const std::string key("Dir::Bin::" + std::string(tool));
        // A configured missing path can intentionally disable a format.
        // Discovery supplies only an absent default, never a replacement.
        if (_config->Exists(key.c_str())) continue;
        std::istringstream directories(searchPath);
        std::string directory;
        while (std::getline(directories, directory, ':')) {
            if (directory.empty() || directory.front() != '/') continue;
            const std::string path(directory + (directory.back() == '/' ? "" : "/") + tool);
            struct stat identity;
            if (stat(path.c_str(), &identity) == 0 && S_ISREG(identity.st_mode) && access(path.c_str(), X_OK) == 0) {
                _config->Set(key.c_str(), path);
                break;
            }
        }
    }
    // APT's compressor and extension lists are process caches. Refresh them
    // after this distribution's paths/configuration have been selected.
    APT::Configuration::getCompressors(false);
    APT::Configuration::getCompressionTypes(false);
}

void ResetRuntimeState() {
    gArchitecture.clear();
    gArchitectures.clear();
    gRegisteredArchitectures.clear();
    gExplicitAcquisitionArchitectures = false;
    gArchitectureQueryFailed = false;
    gSourceListPath.clear();
    gSourcePartsDirectory.clear();
    gManagedSourceListPath.clear();
    gDpkgExecutablePath.clear();
    gDpkgQueryExecutablePath.clear();
    gDpkgDebExecutablePath.clear();
    gAptConfigOverride.clear();
    gPrivilegedHelperPath.clear();
    gDpkgAdminDirectory.clear();
    gDpkgRootDirectory.clear();
    gPackageInstallPrefix.clear();
    gDpkgChrootDirectory.clear();
    gDpkgOptions.clear();
    gMutationEnvironmentValid = false;
    gRuntimeError.clear();
    gRuntimeErrorCode.clear();
    gExtendedStatesPath.clear();
    gMethodsDirectory.clear();
    gListsDirectory.clear();
    gTrustedKeyringDirectory.clear();
    gTrustedKeyringPartsDirectory.clear();
    gRepositorySecurityMode = DefaultRepositorySecurityMode();
    gCachedRepositoryTrustValid = false;
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

bool HasIncompatibleRootedOptions(const std::string &rootDirectory) {
    if (rootDirectory.empty() || rootDirectory == "/")
        return false;

    /* APT applies RootDir to FILE/DIR options itself. Loaded values use
     * that same (root-relative) coordinate system; accepting a physical
     * path which already contains RootDir would silently produce e.g.
     * /var/jb/var/jb/etc/apt. Reject the mixed coordinate system rather than
     * letting source discovery or dpkg status access land in an unintended
     * tree. DPkg::Path is a search path and is intentionally excluded: APT
     * does not RootDir-prefix its colon-separated entries. */
    const char *paths[] = {
        "Dir::Etc", "Dir::Bin::Methods", "Dir::Cache", "Dir::State",
        "Dir::State::Lists", "Dir::Log", "Dir::State::status",
        "Dir::dpkg::cputable", "Dir::dpkg::tupletable", "Dir::dpkg::triplettable",
    };
    for (std::size_t index(0); index != sizeof(paths) / sizeof(paths[0]); ++index)
        if (IsPathUnderRootDirectory(_config->Find(paths[index]), rootDirectory))
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

void InvalidateMutations(const char *code, const char *message) {
    gMutationEnvironmentValid = false;
    if (gRuntimeError.empty()) {
        gRuntimeErrorCode = code;
        gRuntimeError = message;
    }
}

std::string NormalizeAbsolutePath(const std::string &value) {
    if (value.empty() || value[0] != '/')
        return std::string();
    std::vector<std::string> parts;
    std::istringstream input(value);
    std::string part;
    while (std::getline(input, part, '/')) {
        if (part.empty() || part == ".")
            continue;
        if (part == "..") {
            if (!parts.empty())
                parts.pop_back();
        } else
            parts.push_back(part);
    }
    std::string result;
    for (const std::string &component : parts)
        result += '/' + component;
    return result.empty() ? "/" : result;
}

bool PathsReferToSameDirectory(const std::string &left, const std::string &right) {
    if (left == right)
        return true;
    /* Bootstrap paths can use equivalent aliases such as /var and
     * /private/var. A differing spelling is not a different database. */
    char *resolvedLeft(realpath(left.c_str(), NULL));
    char *resolvedRight(realpath(right.c_str(), NULL));
    const bool same(resolvedLeft != NULL && resolvedRight != NULL &&
                    std::string(resolvedLeft) == resolvedRight);
    std::free(resolvedLeft);
    std::free(resolvedRight);
    return same;
}

void ResolveDpkgEnvironment(const InitializationOptions &options) {
    gMutationEnvironmentValid = true;
    const std::string configured(_config->Find("Dir::Bin::dpkg", options.dpkgPath.c_str()));
    gDpkgExecutablePath = configured != options.dpkgPath &&
        !PathsReferToSameDirectory(configured, options.dpkgPath) ? configured : options.nativeDpkgPath;
    const std::string::size_type binSlash(options.nativeDpkgPath.rfind('/'));
    const std::string bin(binSlash == std::string::npos ? std::string() :
                          options.nativeDpkgPath.substr(0, binSlash + 1));
    gDpkgQueryExecutablePath = _config->Find("Dir::Bin::dpkg-query", (bin + "dpkg-query").c_str());
    gDpkgDebExecutablePath = _config->Find("Dir::Bin::dpkg-deb", (bin + "dpkg-deb").c_str());
    const std::string status(NormalizeAbsolutePath(_config->FindFile("Dir::State::status")));
    const std::string::size_type slash(status.rfind('/'));
    if (slash == std::string::npos || status.substr(slash + 1) != "status")
        InvalidateMutations("invalid_dpkg_status", "APT's status path is not a dpkg status database.");
    else
        gDpkgAdminDirectory = slash == 0 ? "/" : status.substr(0, slash);

    gDpkgRootDirectory = "/";
    gDpkgChrootDirectory = NormalizeAbsolutePath(
        _config->FindDir("DPkg::Chroot-Directory", "/"));
    if (gDpkgChrootDirectory != "/")
        InvalidateMutations("unsupported_dpkg_chroot", "This dpkg chroot requires a supported privileged wrapper before packages can be changed.");

    gDpkgOptions = _config->FindVector("DPkg::Options");
    /* Match APT's command construction: empty list entries are not argv. */
    gDpkgOptions.erase(std::remove(gDpkgOptions.begin(), gDpkgOptions.end(), std::string()), gDpkgOptions.end());
    std::string declaredAdmin;
    for (std::size_t index(0); index != gDpkgOptions.size(); ++index) {
        const std::string &argument(gDpkgOptions[index]);
        const char *names[] = { "--root", "--instdir", "--admindir" };
        for (const char *name : names) {
            const std::string key(name);
            std::string value;
            if (argument == key) {
                if (index + 1 != gDpkgOptions.size())
                    value = gDpkgOptions[++index];
            } else if (argument.compare(0, key.size() + 1, key + '=') == 0)
                value = argument.substr(key.size() + 1);
            else
                continue;

            const std::string normalized(NormalizeAbsolutePath(value));
            if (normalized.empty()) {
                InvalidateMutations("invalid_dpkg_options", "The configured dpkg root or admin directory must be an absolute path.");
                continue;
            }
            if (key == "--admindir")
                declaredAdmin = normalized;
            else {
                gDpkgRootDirectory = normalized;
                if (key == "--root")
                    declaredAdmin = NormalizeAbsolutePath(JoinPath(normalized, "var/lib/dpkg"));
            }
            break;
        }
    }
    if (!declaredAdmin.empty() && !PathsReferToSameDirectory(declaredAdmin, gDpkgAdminDirectory))
        InvalidateMutations("contradictory_dpkg_admin", "APT and the configured dpkg options select different package databases.");

    gPackageInstallPrefix = NormalizeAbsolutePath(_config->Find("Cydia::Package-Install-Prefix"));
    if (gPackageInstallPrefix.empty())
        InvalidateMutations("invalid_package_prefix", "The selected package layout prefix must be an absolute path.");
    /* An explicitly relocated dpkg root can already include the selected
     * prefix. Compare lexical namespace boundaries, never architecture names
     * or unrelated custom admin/tool paths. A different installation root
     * hosts the same layout within that root. */
    if (gDpkgRootDirectory != "/" && IsPathUnderRootDirectory(gPackageInstallPrefix, gDpkgRootDirectory)) {
        gPackageInstallPrefix.erase(0, gDpkgRootDirectory.size());
        if (gPackageInstallPrefix.empty()) gPackageInstallPrefix = "/";
    }
}

void ApplyTrustedExecutableOverrides(const InitializationOptions &options) {
    if (options.privateRuntimeConfigurationPath.empty()) return;
    std::map<std::string, std::string> overrides;
    CydiaRuntime::Privileged::Evidence evidence;
    CydiaRuntime::Privileged::Error error;
    if (!CydiaRuntime::Privileged::ReadExecutableOverridesFromPath(
            options.privateRuntimeConfigurationPath, &overrides, &evidence, &error)) {
        InvalidateMutations("invalid_executable_overrides", error.message.empty() ?
            "The protected executable configuration could not be validated." : error.message.c_str());
        return;
    }
    for (const auto &entry : overrides) {
        if (entry.first == "dpkg") gDpkgExecutablePath = entry.second;
        else if (entry.first == "dpkg-query") gDpkgQueryExecutablePath = entry.second;
        else if (entry.first == "dpkg-deb") gDpkgDebExecutablePath = entry.second;
        else if (entry.first == "apt-key" || entry.first == "gpgv" || entry.first == "gpg") {
            _config->Set(("Dir::Bin::" + entry.first).c_str(), entry.second);
            // apt-key consumes these names, rather than Dir::Bin::gpgv/gpg.
            if (entry.first != "apt-key")
                _config->Set(("Apt::Key::" + entry.first + "command").c_str(), entry.second);
        }
    }
}

bool IsArchitectureName(const std::string &value) {
    if (value.empty() || value == "any" || value == "all")
        return false;
    for (unsigned char character : value)
        if (!(character >= 'a' && character <= 'z') &&
            !(character >= '0' && character <= '9') && character != '-')
            return false;
    return true;
}

bool QueryDpkgArchitectures(std::vector<std::string> &discovered) {
    CydiaRuntime::Dpkg::Runner runner(gDpkgExecutablePath);
    std::vector<std::string> arguments;
    arguments.push_back("--root=" + gDpkgRootDirectory);
    arguments.push_back("--admindir=" + gDpkgAdminDirectory);
    arguments.push_back("--print-architecture");
    std::string native;
    if (!runner.RunAndCapture(arguments, &native, 65536).succeeded())
        return false;
    std::istringstream nativeInput(native);
    std::string architecture;
    std::string excess;
    if (!(nativeInput >> architecture) || (nativeInput >> excess) || !IsArchitectureName(architecture))
        return false;
    std::vector<std::string> queried(1, architecture);

    arguments.back() = "--print-foreign-architectures";
    std::string foreign;
    if (!runner.RunAndCapture(arguments, &foreign, 65536).succeeded())
        return false;
    std::istringstream foreignInput(foreign);
    while (foreignInput >> architecture) {
        if (!IsArchitectureName(architecture))
            return false;
        if (std::find(queried.begin(), queried.end(), architecture) == queried.end())
            queried.push_back(architecture);
    }
    discovered.swap(queried);
    return true;
}

bool RefreshRegisteredArchitectures() {
    std::vector<std::string> discovered;
    if (!QueryDpkgArchitectures(discovered)) {
        // Query failures are recoverable without clearing errors from the
        // selected paths, dpkg options, or protected executable settings.
        gArchitectureQueryFailed = true;
        return false;
    }

    // Neither dpkg output nor the APT defaults are published until both
    // probes have succeeded. An explicit acquisition list is independent of
    // the architectures dpkg currently permits installing.
    gRegisteredArchitectures.swap(discovered);
    gArchitecture = gRegisteredArchitectures.front();
    _config->Set("APT::Architecture", gArchitecture);
    if (!gExplicitAcquisitionArchitectures) {
        _config->Clear("APT::Architectures");
        for (std::size_t index(0); index != gRegisteredArchitectures.size(); ++index) {
            const std::string key("APT::Architectures::" + std::to_string(index));
            _config->Set(key.c_str(), gRegisteredArchitectures[index]);
        }
    }
    gArchitectureQueryFailed = false;
    return true;
}

void MaterializeArchitectures(const std::string &nativeArchitecture) {
    const std::vector<std::string> discovered(APT::Configuration::getArchitectures(false));
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

    /* Do not rewrite the maintainer's explicit foreign-architecture policy.
     * getArchitectures adds the native architecture and normalizes the view. */
    gArchitectures.swap(normalized);
}
} // namespace

bool Initialize(const InitializationOptions &options, std::string *architecture) {
    ResetRuntimeState();
    const char *aptConfig(std::getenv("APT_CONFIG"));
    gAptConfigOverride = aptConfig == NULL ? std::string() : aptConfig;
    gPrivilegedHelperPath = options.helperPath.empty() ? options.dpkgPath : options.helperPath;

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
    _config->Clear("APT::Architectures");
    _config->Clear("DPkg::Options");
    _config->Clear("DPkg::Chroot-Directory");
    _config->Clear("APT::Compressor");
    _config->Clear("Acquire::CompressionTypes");
    _config->Clear("Apt::Key::gpgvcommand");
    _config->Clear("Apt::Key::gpgcommand");
    // Never let a prior Cydia override become the next distribution baseline.
    _config->Clear("Cydia::RepositorySecurityMode");
    for (const auto &setting : gDistributionSecurity) _config->Clear(setting.name);
    _config->Clear("Acquire::Check-Valid-Until");
    ApplyBootstrapConfiguration(options);
    if (!pkgInitConfig(*_config)) {
        ResetRuntimeState();
        return false;
    }
    for (const char *tool : {"gpgv", "gpg"}) {
        const std::string command("Apt::Key::" + std::string(tool) + "command");
        const std::string path(_config->Find((std::string("Dir::Bin::") + tool).c_str()));
        if (!path.empty()) _config->CndSet(command.c_str(), path.c_str());
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
    if (HasIncompatibleRootedOptions(rootDirectory) ||
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

    ResolveDpkgEnvironment(options);
    ApplyTrustedExecutableOverrides(options);
    if (gDpkgExecutablePath.empty())
        InvalidateMutations("missing_dpkg_executable", "The configured dpkg executable is missing.");
    /* Query the real dpkg without invoking the privileged wrapper. An
     * explicit APT::Architectures list remains the bootstrap's acquisition
     * policy; only an absent list is populated from dpkg's foreign state. */
    gExplicitAcquisitionArchitectures = !_config->FindVector("APT::Architectures").empty();
    RefreshRegisteredArchitectures();
    /* Only the privileged execution endpoint is Cydia-owned. The real
     * configured executable and all options remain in the descriptor. */
    _config->Set("Dir::Bin::dpkg", options.dpkgPath);
    _config->Set("Dir::Etc::sourcelist", sourceListSetting);
    _config->Set("Dir::Etc::sourceparts", sourcePartsSetting);
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
    gExtendedStatesPath = _config->FindFile("Dir::State::extended_states", "extended_states");
    gMethodsDirectory = NormalizeRootDirectory(_config->FindDir("Dir::Bin::Methods"));
    gListsDirectory = NormalizeRootDirectory(_config->FindDir("Dir::State::Lists"));
    gTrustedKeyringDirectory = _config->FindFile("Dir::Etc::trusted", "trusted.gpg");
    gTrustedKeyringPartsDirectory = NormalizeRootDirectory(
        _config->FindDir("Dir::Etc::trustedparts", "trusted.gpg.d"));

    ResolveCompressionTools(options);

    SetCachedRepositoryTrustValid(false);
    CaptureDistributionSecurity();
    SetRepositorySecurityMode(options.repositorySecurityMode);
    if (options.forceEssential)
        _config->Set("pkgCacheGen::ForceEssential", "");
    if (!options.translation.empty() && !_config->Exists("APT::Acquire::Translation"))
        _config->Set("APT::Acquire::Translation", options.translation);
    if (!_config->Exists("Acquire::Languages"))
        _config->Set("Acquire::Languages", options.languages);
    if (options.maxParallel > 0 && !_config->Exists("Acquire::http::MaxParallel"))
        _config->Set("Acquire::http::MaxParallel", options.maxParallel);

    /* Acquisition helpers inherit the app's environment. Launch services
     * does not load the distribution's shell profile, while apt-key calls
     * apt-config and its utilities by name. Use the same loaded tool search
     * policy as dpkg rather than the host/iOS launch environment. */
    const std::string executablePath(_config->Find("DPkg::Path", options.dpkgExecutableSearchPath.c_str()));
    if (setenv("PATH", executablePath.c_str(), 1) != 0) {
        ResetRuntimeState();
        return false;
    }

    if (architecture != NULL)
        *architecture = gArchitecture;
    return true;
}

void SetRepositorySecurityMode(RepositorySecurityMode mode) {
    gRepositorySecurityMode = RepositorySecurityModeFromString(
        RepositorySecurityModeName(mode));
    RestoreDistributionSecurity();
    if (gRepositorySecurityMode == RepositorySecurityMode::Distribution) {
        // Absence disables Cydia's acquisition-policy patch. Keep each APT
        // setting independent, including its absence/compiled default.
        _config->Clear("Cydia::RepositorySecurityMode");
        return;
    }
    const bool allow(AllowsInsecureRepositories(gRepositorySecurityMode));
    /* This process-local override is consumed by the bundled acquisition
     * policy. It takes precedence over per-source Trusted/allow shortcuts,
     * while leaving the administrator's source documents unchanged. */
    _config->Set("Cydia::RepositorySecurityMode", RepositorySecurityModeName(gRepositorySecurityMode));
    _config->Set("Acquire::AllowInsecureRepositories", allow);
    _config->Set("Acquire::AllowWeakRepositories", allow);
    _config->Set("Acquire::AllowDowngradeToInsecureRepositories", allow);
}

RepositorySecurityMode GetRepositorySecurityMode() {
    return gRepositorySecurityMode;
}

void SetCachedRepositoryTrustValid(bool valid) {
    gCachedRepositoryTrustValid = valid;
    _config->Set("Cydia::CachedRepositoryTrustValid", valid);
}

bool CachedRepositoryTrustValid() { return gCachedRepositoryTrustValid; }

const std::string &Architecture() {
    return gArchitecture;
}

const std::vector<std::string> &Architectures() {
    return gArchitectures;
}

const std::vector<std::string> &RegisteredArchitectures() {
    return gRegisteredArchitectures;
}

bool RefreshArchitectures() {
    if (_config == NULL || _system == NULL) {
        gArchitectureQueryFailed = true;
        return false;
    }
    if (!RefreshRegisteredArchitectures())
        return false;
    MaterializeArchitectures(gArchitecture);
    return true;
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

const std::string &DpkgExecutablePath() { return gDpkgExecutablePath; }
const std::string &DpkgQueryExecutablePath() { return gDpkgQueryExecutablePath; }
const std::string &DpkgDebExecutablePath() { return gDpkgDebExecutablePath; }
std::string GpgExecutablePath() {
    return _config->Find("Apt::Key::gpgcommand", _config->Find("Dir::Bin::gpg").c_str());
}
const std::string &AptConfigOverride() { return gAptConfigOverride; }
const std::string &PrivilegedHelperPath() { return gPrivilegedHelperPath; }
const std::string &DpkgAdminDirectory() { return gDpkgAdminDirectory; }
const std::string &DpkgRootDirectory() { return gDpkgRootDirectory; }
const std::string &PackageInstallPrefix() { return gPackageInstallPrefix; }
const std::string &DpkgChrootDirectory() { return gDpkgChrootDirectory; }
const std::vector<std::string> &DpkgOptions() { return gDpkgOptions; }
bool MutationEnvironmentValid() { return gMutationEnvironmentValid && !gArchitectureQueryFailed; }
const std::string &RuntimeError() {
    return gRuntimeError.empty() && gArchitectureQueryFailed ? gArchitectureQueryError : gRuntimeError;
}
const std::string &RuntimeErrorCode() {
    return gRuntimeErrorCode.empty() && gArchitectureQueryFailed ? gArchitectureQueryErrorCode : gRuntimeErrorCode;
}
const std::string &ExtendedStatesPath() { return gExtendedStatesPath; }
const std::string &MethodsDirectory() { return gMethodsDirectory; }
const std::string &ListsDirectory() { return gListsDirectory; }
const std::string &TrustedKeyringDirectory() { return gTrustedKeyringDirectory; }
const std::string &TrustedKeyringPartsDirectory() { return gTrustedKeyringPartsDirectory; }

bool IsArchitectureSupported(const std::string &architecture) {
    if (architecture == "all")
        return true;
    return !architecture.empty() &&
        std::find(gRegisteredArchitectures.begin(), gRegisteredArchitectures.end(), architecture) !=
            gRegisteredArchitectures.end();
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
