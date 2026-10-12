/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/DpkgRunner.h"
#include "Cydia/FirmwareMarkerPermissions.hpp"
#include "Cydia/InstalledRuntimePolicy.hpp"
#include "Cydia/LegacySourceHandoff.hpp"
#include "Cydia/LegacyCydiaSourceAlias.hpp"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/PrivateStateDirectory.hpp"
#include "Cydia/PrivateMetadataMigration.hpp"
#include "Cydia/SharedConfigHandoff.hpp"
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <pwd.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#ifndef CYDIA_POSTINST_ROOTLESS
#define CYDIA_POSTINST_ROOTLESS 0
#endif

static void RequestUICache() {
    const char *value(getenv("CYDIA"));
    if (value == NULL)
        return;
    char *end(NULL);
    const long descriptor(strtol(value, &end, 10));
    if (end == value || (*end != '\0' && *end != ' ') || descriptor < 0 || descriptor > 65535)
        return;
    const int copy(dup(static_cast<int>(descriptor)));
    if (copy == -1)
        return;
    FILE *output(fdopen(copy, "w"));
    if (output == NULL) { close(copy); return; }
    fprintf(output, "uicache:yes\n");
    fclose(output);
}

static bool FinishSharedConfigHandoff(const char *scriptPath,
                                     const CydiaRuntime::PackageDatabasePaths &paths) {
    // Use the same bootstrap interpreter as this package's shell maintscripts.
    const std::string interpreter(paths.layout() == CydiaRuntime::PackageDatabaseLayout::Rootless ?
        "/var/jb/bin/bash" : "/bin/bash");
    const auto result(CydiaRuntime::RunSharedConfigHandoff(scriptPath, interpreter));
    if (result.succeeded()) return true;
    if (result.kind == CydiaRuntime::Dpkg::ResultKind::LaunchFailed)
        fprintf(stderr, "cydia shared configuration: cannot launch lifecycle helper: %s\n", strerror(result.error));
    else if (result.kind == CydiaRuntime::Dpkg::ResultKind::Signaled)
        fprintf(stderr, "cydia shared configuration: lifecycle helper terminated by signal %d\n", result.code);
    else
        fprintf(stderr, "cydia shared configuration: lifecycle helper exited with status %d\n", result.code);
    return false;
}

static int OpenVerifiedPrivateDirectory(const std::string &path, uid_t owner, bool permitFinalAlias = false) {
    if (path.empty() || path[0] != '/' || path.find("/../") != std::string::npos ||
            path.find("/./") != std::string::npos || path.find("//") != std::string::npos) {
        errno = EINVAL; return -1;
    }
    for (std::size_t index = 1; index <= path.size(); ++index) {
        if (index != path.size() && path[index] != '/') continue;
        struct stat info;
        if (lstat(path.substr(0, index).c_str(), &info) != 0) return -1;
        if (S_ISLNK(info.st_mode)) {
            if (info.st_uid != 0 || (index == path.size() && !permitFinalAlias)) { errno = EPERM; return -1; }
        } else if (!S_ISDIR(info.st_mode) || (info.st_uid != 0 && info.st_uid != owner) || (info.st_mode & 0022) != 0) {
            errno = EPERM; return -1;
        }
    }
    char *resolved(realpath(path.c_str(), NULL));
    if (resolved == NULL) return -1;
    const std::string canonical(resolved); free(resolved);
    for (std::size_t index = 1; index <= canonical.size(); ++index) {
        if (index != canonical.size() && canonical[index] != '/') continue;
        struct stat info;
        if (lstat(canonical.substr(0, index).c_str(), &info) != 0) return -1;
        if (!S_ISDIR(info.st_mode) || (info.st_uid != 0 && info.st_uid != owner) || (info.st_mode & 0022) != 0) {
            errno = EPERM; return -1;
        }
    }
    return open(canonical.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static bool EnsureOwnedPrivateDirectory(const std::string &path, uid_t owner, gid_t group) {
    const std::string::size_type slash(path.rfind('/'));
    if (slash == std::string::npos) { errno = EINVAL; return false; }
    const std::string parent(path.substr(0, slash == 0 ? 1 : slash));
    const std::string leaf(path.substr(slash + 1));
    const int directory(OpenVerifiedPrivateDirectory(parent, owner, true));
    if (directory == -1) return false;
    const bool success(CydiaRuntime::EnsurePrivateStateDirectoryAt(directory, leaf.c_str(), owner, group));
    const int error(errno); close(directory); errno = error;
    return success;
}

static bool MigrateMetadata(const std::string &sourceDirectory,
                            const std::string &destinationDirectory,
                            uid_t owner, gid_t group) {
    const int source(OpenVerifiedPrivateDirectory(sourceDirectory, owner));
    if (source == -1)
        return errno == ENOENT;
    const int destination(OpenVerifiedPrivateDirectory(destinationDirectory, owner));
    if (destination == -1) { close(source); return false; }
    const bool success(CydiaRuntime::MigratePrivateMetadataAt(source, "metadata.cb0",
        destination, "metadata.cb0", owner, group));
    const int error(errno);
    close(source); close(destination);
    errno = error;
    return success;
}

static void InitializeInstalledRuntimePolicies(const char *controlPath,
                                              const CydiaRuntime::PackageDatabasePaths &paths) {
    const int state(OpenVerifiedPrivateDirectory(paths.CydiaStateDirectory(), 0));
    if (state < 0) {
        perror("Cydia installed runtime policy directory");
        return;
    }
    namespace Policy = CydiaRuntime::InstalledPolicy;
    const std::string admin(Policy::InstallerAdminDirectory(getenv("DPKG_ADMINDIR"), controlPath));
    if (Policy::InitializeAdminAccessAt(state, admin) == Policy::Result::Refused)
        fprintf(stderr, "cydia: automatic package database access could not be established safely; review Package Database Access in Advanced Settings\n");
    if (Policy::InitializeSourceProtectionAt(state) == Policy::Result::Refused)
        perror("Cydia initial distribution source policy");
    close(state);
}

int main(int argc, const char *argv[]) {
    if (argc < 2)
        return 0;
    if (strcmp(argv[1], "triggered") == 0) { RequestUICache(); return 0; }
    if (strcmp(argv[1], "configure") != 0)
        return 0;

    // An incoming dpkg control script has no installed executable identity.
    // Its package build variant, rather than database presence or environment
    // preferences, selects the private payload locations it owns.
    const auto paths(CydiaRuntime::PackageDatabasePaths::ForLayout(
#if CYDIA_POSTINST_ROOTLESS
        CydiaRuntime::PackageDatabaseLayout::Rootless
#else
        CydiaRuntime::PackageDatabaseLayout::Rootful
#endif
    ));
    if (!EnsureOwnedPrivateDirectory(paths.CydiaStateDirectory(), 0, 0)) {
        perror("Cydia private state directory");
        return 1;
    }
    InitializeInstalledRuntimePolicies(argv[0], paths);
    if (!CydiaRuntime::RestoreLegacySourceHandoff(paths)) {
        perror("Cydia legacy source handoff");
        return 1;
    }
    if (!FinishSharedConfigHandoff(argv[0], paths))
        return 1;
    if (!CydiaRuntime::RepairFirmwareMarkerPermissions(paths.CydiaFirmwareVersionPath().c_str())) {
        perror("Cydia existing firmware marker permissions");
        return 1;
    }

    const struct passwd *mobile(getpwnam("mobile"));
    if (mobile == NULL || mobile->pw_dir == NULL || mobile->pw_dir[0] != '/') {
        fprintf(stderr, "cydia: mobile account home is unavailable; private metadata migration was not performed\n");
        return 1;
    }
    const uid_t owner(mobile->pw_uid);
    const gid_t group(mobile->pw_gid);
    const std::string home(mobile->pw_dir);
    const std::string cache(home + "/Library/Caches/com.saurik.Cydia");
    const std::string library(home + "/Library/Cydia");
    if (!EnsureOwnedPrivateDirectory(cache, owner, group) ||
            !EnsureOwnedPrivateDirectory(library, owner, group)) {
        perror("Cydia private mobile directories");
        return 1;
    }
    const std::string admin(CydiaRuntime::InstalledPolicy::InstallerAdminDirectory(getenv("DPKG_ADMINDIR"), argv[0]));
    // This compatibility alias belongs to the running device's home and APT
    // layout. An alternate installation root cannot authorize host changes.
    const char *installationRoot(getenv("DPKG_ROOT"));
    const bool hostInstallation(installationRoot == NULL || installationRoot[0] == '\0' || strcmp(installationRoot, "/") == 0);
    if (hostInstallation && CydiaRuntime::MaterializeLegacyCydiaSourceAlias(paths, home, owner, group, admin) ==
            CydiaRuntime::LegacyCydiaSourceAliasResult::Refused) {
        fprintf(stderr, "cydia: optional legacy source cache alias migration could not be completed: %s; no repositories were removed\n",
            strerror(errno));
    }
    if (!MigrateMetadata(cache, library, owner, group) ||
            !MigrateMetadata(paths.CydiaStateDirectory(), library, owner, group)) {
        perror("Cydia private metadata migration");
        return 1;
    }
    // The old root cache is an explicit historical Cydia location. Preserve
    // every other entry; only the metadata file can move into the mobile leaf.
    const struct passwd *root(getpwnam("root"));
    if (root != NULL && root->pw_dir != NULL && root->pw_dir[0] == '/') {
        const std::string oldCache(std::string(root->pw_dir) + "/Library/Caches/com.saurik.Cydia");
        if (!MigrateMetadata(oldCache, library, owner, group)) {
            perror("Cydia legacy private metadata migration");
            return 1;
        }
    }
    RequestUICache();
    return 0;
}
