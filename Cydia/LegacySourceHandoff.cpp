/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacySourceHandoff.hpp"
#include "Cydia/PackageDatabasePaths.hpp"

#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fstream>
#include <map>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#if defined(__APPLE__) && (defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__) || \
                           defined(__IPHONE_OS_VERSION_MIN_REQUIRED))
#include <sys/stdio.h>
#endif
#include <unistd.h>
#include <vector>

namespace CydiaRuntime {

struct LegacySourceMarker {
    std::string source;
    std::string backup;
    std::string parts;
    std::string main;
    std::string sourceType;
    bool sole;
    bool legacy;
};

enum LegacyMarkerReadResult {
    LegacyMarkerAbsent,
    LegacyMarkerInvalid,
    LegacyMarkerValid,
};

static bool IsSafeAbsolutePath(const std::string &path) {
    if (path.empty() || path[0] != '/' || path.find('\n') != std::string::npos ||
        path.find('\r') != std::string::npos || path.find("//") != std::string::npos ||
        path.find("/./") != std::string::npos || path.find("/../") != std::string::npos ||
        (path.size() >= 3 && (path.compare(path.size() - 2, 2, "/.") == 0 ||
                              path.compare(path.size() - 3, 3, "/..") == 0)))
        return false;
    for (std::size_t index(0); index != path.size(); ++index) {
        if (std::iscntrl(static_cast<unsigned char>(path[index])) != 0)
            return false;
    }
    return true;
}

static std::string PathParent(const std::string &path) {
    const std::string::size_type slash(path.rfind('/'));
    return slash == std::string::npos ? std::string() :
        (slash == 0 ? std::string("/") : path.substr(0, slash));
}

static std::string PathLeaf(const std::string &path) {
    const std::string::size_type slash(path.rfind('/'));
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

static bool IsLegacyBackupLeaf(const std::string &leaf) {
    const std::string first("cydia.list.cydia.disabled");
    if (leaf == first)
        return true;
    const std::string prefix("cydia.list.cydia.");
    const std::string suffix(".disabled");
    if (leaf.size() <= prefix.size() + suffix.size() ||
        leaf.compare(0, prefix.size(), prefix) != 0 ||
        leaf.compare(leaf.size() - suffix.size(), suffix.size(), suffix) != 0)
        return false;
    const std::string number(leaf.substr(prefix.size(),
                                         leaf.size() - prefix.size() - suffix.size()));
    if (number.empty())
        return false;
    for (std::size_t index(0); index != number.size(); ++index)
        if (number[index] < '0' || number[index] > '9')
            return false;
    return true;
}

static LegacyMarkerReadResult ReadLegacySourceMarker(const std::string &path,
                                                      LegacySourceMarker *marker) {
    marker->sole = false;
    marker->legacy = false;
    struct stat markerStat;
    if (lstat(path.c_str(), &markerStat) == -1)
        return errno == ENOENT ? LegacyMarkerAbsent : LegacyMarkerInvalid;
    if (!S_ISREG(markerStat.st_mode))
        return LegacyMarkerInvalid;

    std::ifstream stream(path.c_str());
    if (!stream.good())
        return LegacyMarkerInvalid;

    std::map<std::string, std::string> values;
    std::string line;
    while (std::getline(stream, line)) {
        if (line.empty() || line.size() > 4096 || line[line.size() - 1] == '\r')
            return LegacyMarkerInvalid;
        const std::string::size_type equals(line.find('='));
        if (equals == std::string::npos || equals == 0 || equals + 1 >= line.size())
            return LegacyMarkerInvalid;
        const std::string key(line.substr(0, equals));
        const std::string value(line.substr(equals + 1));
        if (key != "version" && key != "package" && key != "mode" && key != "sole" &&
            key != "source" && key != "backup" && key != "parts" && key != "main" &&
            key != "source_type")
            return LegacyMarkerInvalid;
        if (!values.insert(std::make_pair(key, value)).second)
            return LegacyMarkerInvalid;
    }
    if (!stream.eof())
        return LegacyMarkerInvalid;

    /* Version 1 was the marker format emitted by the previous migration:
     * it carried only the source and uniquely selected backup path.  Keep
     * accepting that receipt, but retain the same absolute-path and backup
     * naming checks used by version 2; RestoreLegacySourceHandoff derives and
     * verifies the standard APT layout from the marker's durable state or
     * legacy dpkg-info location.
     * No unmarked .disabled file is ever considered for recovery. */
    if (values["version"] == "1") {
        if (values.size() != 3 || values.find("source") == values.end() ||
            values.find("backup") == values.end() ||
            !IsSafeAbsolutePath(values["source"]) ||
            !IsSafeAbsolutePath(values["backup"]) ||
            PathLeaf(values["source"]) != "cydia.list" ||
            PathParent(values["source"]) != PathParent(values["backup"]) ||
            !IsLegacyBackupLeaf(PathLeaf(values["backup"])))
            return LegacyMarkerInvalid;
        marker->source = values["source"];
        marker->backup = values["backup"];
        marker->parts.clear();
        marker->main.clear();
        marker->sourceType.clear();
        marker->sole = true;
        marker->legacy = true;
        return LegacyMarkerValid;
    }

    const char *common[] = { "version", "package", "mode", "sole" };
    for (std::size_t index(0); index != sizeof(common) / sizeof(common[0]); ++index)
        if (values.find(common[index]) == values.end())
            return LegacyMarkerInvalid;

    if (values["version"] != "2" || values["package"] != "cydia")
        return LegacyMarkerInvalid;
    if (values["mode"] == "disabled" && values["sole"] == "0") {
        marker->sole = false;
        return LegacyMarkerValid; /* Explicit non-sole receipts are inert. */
    }
    const char *soleFields[] = {
        "source", "backup", "parts", "main", "source_type",
    };
    for (std::size_t index(0); index != sizeof(soleFields) / sizeof(soleFields[0]); ++index)
        if (values.find(soleFields[index]) == values.end())
            return LegacyMarkerInvalid;
    if (values["mode"] != "sole" || values["sole"] != "1" ||
        (values["source_type"] != "regular" && values["source_type"] != "symlink"))
        return LegacyMarkerInvalid;

    marker->source = values["source"];
    marker->backup = values["backup"];
    marker->parts = values["parts"];
    marker->main = values["main"];
    marker->sourceType = values["source_type"];
    marker->sole = true;
    marker->legacy = false;
    if (!IsSafeAbsolutePath(marker->source) || !IsSafeAbsolutePath(marker->backup) ||
        !IsSafeAbsolutePath(marker->parts) || !IsSafeAbsolutePath(marker->main) ||
        PathParent(marker->source) != marker->parts ||
        PathLeaf(marker->source) != "cydia.list" ||
        PathParent(marker->backup) != marker->parts ||
        !IsLegacyBackupLeaf(PathLeaf(marker->backup)))
        return LegacyMarkerInvalid;
    return LegacyMarkerValid;
}

static bool IsActiveSourcePath(const std::string &path, bool *exists) {
    struct stat sourceStat;
    if (lstat(path.c_str(), &sourceStat) == -1) {
        if (errno == ENOENT) {
            if (exists != NULL)
                *exists = false;
            return false;
        }
        if (exists != NULL)
            *exists = true;
        return true; /* An unreadable path is active for fail-closed policy. */
    }
    if (exists != NULL)
        *exists = true;
    if (S_ISLNK(sourceStat.st_mode) || !S_ISREG(sourceStat.st_mode))
        return true;

    FILE *file(fopen(path.c_str(), "r"));
    if (file == NULL)
        return true;
    bool active(false);
    char buffer[4096];
    while (fgets(buffer, sizeof(buffer), file) != NULL) {
        char *cursor(buffer);
        while (*cursor != '\0' && std::isspace(static_cast<unsigned char>(*cursor)) != 0)
            ++cursor;
        if (*cursor != '\0' && *cursor != '#') {
            active = true;
            break;
        }
    }
    if (ferror(file) != 0)
        active = true;
    fclose(file);
    return active;
}

static bool IsSourcePartName(const char *name) {
    if (name == NULL)
        return false;
    const std::size_t length(strlen(name));
    return (length > 5 && strcmp(name + length - 5, ".list") == 0) ||
        (length > 8 && strcmp(name + length - 8, ".sources") == 0);
}

static bool HasOtherActiveSourcePart(const std::string &parts, const std::string &source) {
    DIR *directory(opendir(parts.c_str()));
    if (directory == NULL)
        return true;

    bool active(false);
    errno = 0;
    while (dirent *entry = readdir(directory)) {
        const char *name(entry->d_name);
        if (!IsSourcePartName(name) || strcmp(name, "cydia.list") == 0)
            continue;
        std::string candidate(parts);
        candidate += '/';
        candidate += name;
        if (candidate == source)
            continue;
        if (IsActiveSourcePath(candidate, NULL)) {
            active = true;
            break;
        }
    }
    if (errno != 0)
        active = true;
    closedir(directory);
    return active;
}

static std::string TrimTrailingSlash(std::string value) {
    while (value.size() > 1 && value[value.size() - 1] == '/')
        value.erase(value.size() - 1);
    return value;
}

static bool LegacyLayoutForPrefix(const std::string &prefix,
                                  std::string *parts,
                                  std::string *main) {
    if (!prefix.empty() && !IsSafeAbsolutePath(prefix))
        return false;
    if (parts != NULL) {
        *parts = prefix;
        *parts += "/etc/apt/sources.list.d";
    }
    if (main != NULL) {
        *main = prefix;
        *main += "/etc/apt/sources.list";
    }
    return true;
}

static bool LegacyLayoutForInfoDirectory(const std::string &info,
                                         std::string *prefix,
                                         std::string *parts,
                                         std::string *main) {
    const std::string normalized(TrimTrailingSlash(info));
    std::string suffix;
    const std::string varSuffix("/var/lib/dpkg/info");
    const std::string librarySuffix("/Library/dpkg/info");
    if (normalized.size() >= varSuffix.size() &&
        normalized.compare(normalized.size() - varSuffix.size(), varSuffix.size(), varSuffix) == 0)
        suffix = varSuffix;
    else if (normalized.size() >= librarySuffix.size() &&
             normalized.compare(normalized.size() - librarySuffix.size(), librarySuffix.size(), librarySuffix) == 0)
        suffix = librarySuffix;
    else
        return false;

    std::string root(normalized.substr(0, normalized.size() - suffix.size()));
    if (root == "/")
        root.clear();
    if (prefix != NULL)
        *prefix = root;
    return LegacyLayoutForPrefix(root, parts, main);
}

static bool LegacyLayoutForMarkerPath(const std::string &marker,
                                      std::string *prefix,
                                      std::string *parts,
                                      std::string *main) {
    if (PathLeaf(marker) != "cydia.legacy-source-marker")
        return false;

    const std::string parent(TrimTrailingSlash(PathParent(marker)));
    const char *suffixes[] = {
        "/var/lib/cydia",
        "/var/lib/dpkg/info",
        "/Library/dpkg/info",
    };
    for (std::size_t index(0); index != sizeof(suffixes) / sizeof(suffixes[0]); ++index) {
        const std::string suffix(suffixes[index]);
        if (parent.size() < suffix.size() ||
            parent.compare(parent.size() - suffix.size(), suffix.size(), suffix) != 0)
            continue;
        std::string root(parent.substr(0, parent.size() - suffix.size()));
        if (root == "/")
            root.clear();
        if (!LegacyLayoutForPrefix(root, parts, main))
            return false;
        if (prefix != NULL)
            *prefix = root;
        return true;
    }
    return false;
}

static bool IsTrustedMarkerLocation(const std::string &marker,
                                    const std::string &prefix) {
    const std::string state(prefix + "/var/lib/cydia");
    const std::string parent(PathParent(marker));
    if (parent != state &&
        parent != prefix + "/var/lib/dpkg/info" &&
        parent != prefix + "/Library/dpkg/info")
        return false;

    struct stat parentStat;
    if (lstat(parent.c_str(), &parentStat) == -1 || !S_ISDIR(parentStat.st_mode) ||
        (parentStat.st_mode & 0022) != 0)
        return false;

    struct stat markerStat;
    if (lstat(marker.c_str(), &markerStat) == -1 || !S_ISREG(markerStat.st_mode) ||
        markerStat.st_uid != parentStat.st_uid)
        return false;
    return true;
}

static void AddMarkerCandidate(std::vector<std::string> *candidates,
                               const std::string &marker) {
    for (std::size_t index(0); index != candidates->size(); ++index)
        if ((*candidates)[index] == marker)
            return;
    candidates->push_back(marker);
}

static void AddLegacyMarkerCandidate(std::vector<std::string> *candidates,
                                     const std::string &info) {
    std::string prefix, parts, main;
    if (!LegacyLayoutForInfoDirectory(info, &prefix, &parts, &main))
        return;
    const std::string normalized(TrimTrailingSlash(info));
    /* The durable state marker survives dpkg's package-info cleanup.  Keep
     * the historical info marker as a read-only compatibility candidate for
     * upgrades that were interrupted before this relocation landed. */
    const std::string markers[] = {
        prefix + "/var/lib/cydia/cydia.legacy-source-marker",
        normalized + "/cydia.legacy-source-marker",
    };
    for (std::size_t markerIndex(0);
         markerIndex != sizeof(markers) / sizeof(markers[0]); ++markerIndex)
        AddMarkerCandidate(candidates, markers[markerIndex]);
}

/* Restore without replacing a source file created by another maintainer.
 * Darwin's renamex_np provides an atomic RENAME_EXCL operation.  On hosts
 * without that extension, a same-directory hard-link publication still
 * gives us an atomic no-replace check; unlinking the old name completes the
 * move while preserving the exact regular-file/symlink object. */
static int RenameLegacySourceNoReplace(const char *source, const char *target) {
#if defined(__APPLE__)
    return renamex_np(source, target, RENAME_EXCL);
#else
    if (link(source, target) == -1)
        return -1;
    /* Keep both names if the source unlink fails.  Removing target here could
     * destroy a concurrently-created object after the link publication. */
    if (unlink(source) == -1)
        return -1;
    return 0;
#endif
}

bool RestoreLegacySourceHandoff() {
    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    std::vector<std::string> candidates;
    /* Use the layout abstraction for the normal state marker.  The explicit
     * admin/root candidates below retain compatibility with maintainer
     * scripts invoked under an alternate dpkg root. */
    AddMarkerCandidate(&candidates, paths.CydiaLegacySourceMarkerPath());
    AddLegacyMarkerCandidate(&candidates, paths.DpkgInfoDirectory());
    if (paths.layout() == CydiaRuntime::PackageDatabaseLayout::Rootful)
        AddLegacyMarkerCandidate(&candidates, "/Library/dpkg/info");
    else
        AddLegacyMarkerCandidate(&candidates, "/var/jb/Library/dpkg/info");

    const char *rootValue(getenv("DPKG_ROOT"));
    if (rootValue != NULL && rootValue[0] == '/') {
        const std::string root(TrimTrailingSlash(rootValue));
        AddLegacyMarkerCandidate(&candidates, root + "/var/lib/dpkg/info");
        AddLegacyMarkerCandidate(&candidates, root + "/Library/dpkg/info");
    }
    const char *adminValue(getenv("DPKG_ADMINDIR"));
    if (adminValue != NULL && adminValue[0] == '/') {
        std::string admin(TrimTrailingSlash(adminValue));
        if (admin == "/var/lib/dpkg" || admin == "/Library/dpkg") {
            if (rootValue != NULL && rootValue[0] == '/' && rootValue[1] != '\0')
                admin = TrimTrailingSlash(rootValue) + admin;
        }
        AddLegacyMarkerCandidate(&candidates, admin + "/info");
    }

    std::vector<std::string> existing;
    std::vector<struct stat> existingStats;
    for (std::size_t index(0); index != candidates.size(); ++index) {
        struct stat markerStat;
        if (lstat(candidates[index].c_str(), &markerStat) == 0) {
            std::string markerPrefix, markerParts, markerMain;
            if (!LegacyLayoutForMarkerPath(candidates[index], &markerPrefix,
                                           &markerParts, &markerMain) ||
                !IsTrustedMarkerLocation(candidates[index], markerPrefix))
                continue;
            bool duplicate(false);
            for (std::size_t prior(0); prior != existingStats.size(); ++prior) {
                if (existingStats[prior].st_dev == markerStat.st_dev &&
                    existingStats[prior].st_ino == markerStat.st_ino) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                existing.push_back(candidates[index]);
                existingStats.push_back(markerStat);
            }
        } else if (errno != ENOENT)
            fprintf(stderr, "cydia: cannot inspect legacy source marker %s\n",
                    candidates[index].c_str());
    }
    if (existing.size() > 1) {
        fprintf(stderr, "cydia: multiple legacy source markers found; leaving them untouched\n");
        return true;
    }
    if (existing.empty())
        return true;

    const std::string markerPath(existing[0]);
    LegacySourceMarker marker;
    const LegacyMarkerReadResult result(ReadLegacySourceMarker(markerPath, &marker));
    if (result == LegacyMarkerAbsent || result == LegacyMarkerInvalid) {
        fprintf(stderr, "cydia: ignoring invalid legacy source marker %s\n", markerPath.c_str());
        return true;
    }
    if (!marker.sole)
        return true;

    std::string prefix, expectedParts, expectedMain;
    if (!LegacyLayoutForMarkerPath(markerPath, &prefix, &expectedParts, &expectedMain) ||
        marker.source != expectedParts + "/cydia.list" ||
        marker.backup.empty() || PathParent(marker.backup) != expectedParts ||
        (!marker.legacy && (marker.parts != expectedParts || marker.main != expectedMain)))
        return true;

    /* Version-1 receipts predate the explicit layout fields.  Fill the
     * derived standard paths before the common active-source checks below;
     * otherwise the later main/sourceparts probes would inspect empty paths
     * and conservatively strand an otherwise valid sole-source handoff. */
    if (marker.legacy) {
        marker.parts = expectedParts;
        marker.main = expectedMain;
    }

    if (marker.legacy) {
        /* v1 had no object-type field. Infer it from the preserved inode only
         * after the path/layout gates above; the later type check remains
         * fail-closed for all other object kinds. */
        struct stat legacyBackupStat;
        if (lstat(marker.backup.c_str(), &legacyBackupStat) == 0) {
            if (S_ISLNK(legacyBackupStat.st_mode))
                marker.sourceType = "symlink";
            else if (S_ISREG(legacyBackupStat.st_mode))
                marker.sourceType = "regular";
            else
                return true;
        }
    }

    /* The marker is accepted only for the same standard APT layout selected
     * by the runtime path policy.  A dpkg --root invocation may intentionally
     * supply a test/in-root prefix, in which case DPKG_ROOT is the explicit
     * authority; without it, a marker from an unrelated admin tree is inert. */
    const bool policyLayout(expectedParts == paths.AptSourcesDirectory() &&
                            expectedMain == paths.AptSourcesListPath());
    const char *explicitRoot(getenv("DPKG_ROOT"));
    const bool rootedOverride(explicitRoot != NULL && explicitRoot[0] == '/' &&
                              TrimTrailingSlash(explicitRoot) == prefix);
    if (!policyLayout && !rootedOverride)
        return true;

    bool sourceExists(false);
    if (IsActiveSourcePath(marker.source, &sourceExists) && sourceExists) {
        fprintf(stderr, "cydia: legacy source target already exists; preserving backup %s\n",
                marker.backup.c_str());
        return true;
    }
    if (sourceExists)
        return true;

    struct stat backupStat;
    if (lstat(marker.backup.c_str(), &backupStat) == -1) {
        if (errno == ENOENT)
            return true;
        fprintf(stderr, "cydia: cannot inspect legacy source backup %s\n", marker.backup.c_str());
        return false;
    }
    if ((marker.sourceType == "symlink" && !S_ISLNK(backupStat.st_mode)) ||
        (marker.sourceType == "regular" && !S_ISREG(backupStat.st_mode)))
        return true;

    struct stat partsStat;
    if (lstat(marker.parts.c_str(), &partsStat) == -1 || !S_ISDIR(partsStat.st_mode))
        return true;
    if (IsActiveSourcePath(marker.main, NULL) ||
        HasOtherActiveSourcePart(marker.parts, marker.source))
        return true;

    /* Recheck immediately before rename.  POSIX rename is atomic, and the
     * lstat guard prevents an already-created maintainer target from being
     * replaced during the normal (non-racing) upgrade path. */
    if (lstat(marker.source.c_str(), &partsStat) == 0) {
        fprintf(stderr, "cydia: legacy source target appeared during handoff; preserving backup\n");
        return true;
    }
    if (errno != ENOENT)
        return false;
    const int renameStatus(RenameLegacySourceNoReplace(marker.backup.c_str(),
                                                       marker.source.c_str()));
    if (renameStatus == -1) {
        if (errno == EEXIST || errno == ENOTEMPTY)
            return true;
        fprintf(stderr, "cydia: could not restore legacy source %s\n", marker.source.c_str());
        return false;
    }
    if (unlink(markerPath.c_str()) == -1 && errno != ENOENT) {
        fprintf(stderr, "cydia: restored legacy source but could not consume marker %s\n",
                markerPath.c_str());
        return false;
    }
    return true;
}

} // namespace CydiaRuntime
