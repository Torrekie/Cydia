/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/LegacySourceHandoff.hpp"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {

void Fail(const char *message) {
    fprintf(stderr, "[legacy-source-handoff][FAIL] %s\n", message);
    exit(1);
}

void Require(bool condition, const char *message) {
    if (!condition)
        Fail(message);
}

std::string Join(const std::string &left, const char *right) {
    return left + "/" + right;
}

void MakeDirectory(const std::string &path) {
    if (mkdir(path.c_str(), 0755) == -1 && errno != EEXIST)
        Fail("could not create fixture directory");
}

void MakeLayout(const std::string &root) {
    MakeDirectory(Join(root, "etc"));
    MakeDirectory(Join(root, "etc/apt"));
    MakeDirectory(Join(root, "etc/apt/sources.list.d"));
    MakeDirectory(Join(root, "var"));
    MakeDirectory(Join(root, "var/lib"));
    MakeDirectory(Join(root, "var/lib/dpkg"));
    MakeDirectory(Join(root, "var/lib/dpkg/info"));
    MakeDirectory(Join(root, "var/lib/cydia"));
}

void WriteFile(const std::string &path, const char *contents) {
    FILE *file(fopen(path.c_str(), "w"));
    Require(file != NULL, "could not write fixture file");
    Require(fputs(contents, file) >= 0, "could not write fixture bytes");
    Require(fclose(file) == 0, "could not close fixture file");
}

std::string ReadFile(const std::string &path) {
    FILE *file(fopen(path.c_str(), "r"));
    Require(file != NULL, "could not read restored source");
    std::string result;
    char buffer[256];
    size_t count(0);
    while ((count = fread(buffer, 1, sizeof(buffer), file)) != 0)
        result.append(buffer, count);
    Require(ferror(file) == 0, "could not read restored source bytes");
    Require(fclose(file) == 0, "could not close restored source");
    return result;
}

void RemoveTree(const std::string &path) {
    struct stat statbuf;
    if (lstat(path.c_str(), &statbuf) == -1) {
        Require(errno == ENOENT, "could not inspect cleanup path");
        return;
    }
    if (!S_ISDIR(statbuf.st_mode)) {
        Require(unlink(path.c_str()) == 0, "could not remove fixture file");
        return;
    }
    DIR *directory(opendir(path.c_str()));
    Require(directory != NULL, "could not open fixture directory");
    while (dirent *entry = readdir(directory)) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        RemoveTree(Join(path, entry->d_name));
    }
    Require(closedir(directory) == 0, "could not close fixture directory");
    Require(rmdir(path.c_str()) == 0, "could not remove fixture directory");
}

struct Fixture {
    std::string root;
    std::string parts;
    std::string source;
    std::string backup;
    std::string marker;
    std::string infoMarker;
    std::string main;

    Fixture() {
        char pattern[] = "/tmp/cydia-legacy-handoff.XXXXXX";
        char *created(mkdtemp(pattern));
        Require(created != NULL, "could not create fixture root");
        root = created;
        MakeLayout(root);
        parts = Join(root, "etc/apt/sources.list.d");
        source = Join(parts, "cydia.list");
        backup = Join(parts, "cydia.list.cydia.disabled");
        marker = Join(root, "var/lib/cydia/cydia.legacy-source-marker");
        infoMarker = Join(root, "var/lib/dpkg/info/cydia.legacy-source-marker");
        main = Join(root, "etc/apt/sources.list");
    }

    ~Fixture() {
        unsetenv("DPKG_ROOT");
        unsetenv("DPKG_ADMINDIR");
        RemoveTree(root);
    }

    void Configure() {
        setenv("CYDIA_PACKAGE_LAYOUT", "rootful", 1);
        setenv("DPKG_ROOT", root.c_str(), 1);
        setenv("DPKG_ADMINDIR", "/var/lib/dpkg", 1);
    }

    void WriteMarker(const char *version, const char *sourceType = "regular") {
        WriteMarkerAt(marker, version, sourceType);
    }

    void WriteMarkerAt(const std::string &path, const char *version,
                       const char *sourceType = "regular") {
        std::string text;
        if (strcmp(version, "1") == 0) {
            text = "version=1\nsource=" + source + "\nbackup=" + backup + "\n";
        } else {
            text = "version=2\npackage=cydia\nmode=sole\nsole=1\nsource=" + source +
                "\nbackup=" + backup + "\nparts=" + parts + "\nmain=" + main +
                "\nsource_type=" + sourceType + "\n";
        }
        WriteFile(path, text.c_str());
    }
};

void TestRegularV2() {
    Fixture fixture;
    fixture.Configure();
    WriteFile(fixture.backup, "deb https://example.invalid/ stable main\n");
    fixture.WriteMarker("2");
    Require(CydiaRuntime::RestoreLegacySourceHandoff(), "v2 regular restore failed");
    Require(ReadFile(fixture.source) == "deb https://example.invalid/ stable main\n",
            "v2 regular bytes changed");
    Require(access(fixture.backup.c_str(), F_OK) == -1 && errno == ENOENT,
            "v2 regular backup remains");
    Require(access(fixture.marker.c_str(), F_OK) == -1 && errno == ENOENT,
            "v2 regular marker remains");
}

void TestLegacyV1() {
    Fixture fixture;
    fixture.Configure();
    WriteFile(fixture.backup, "deb https://legacy.invalid/ stable main\n");
    fixture.WriteMarker("1");
    Require(CydiaRuntime::RestoreLegacySourceHandoff(), "v1 restore failed");
    Require(ReadFile(fixture.source) == "deb https://legacy.invalid/ stable main\n",
            "v1 bytes changed");
    Require(access(fixture.backup.c_str(), F_OK) == -1 && errno == ENOENT,
            "v1 backup remains");
    Require(access(fixture.marker.c_str(), F_OK) == -1 && errno == ENOENT,
            "v1 marker remains");
}

void TestLegacyInfoMarkerCompatibility() {
    Fixture fixture;
    fixture.Configure();
    WriteFile(fixture.backup, "deb https://legacy-info.invalid/ stable main\n");
    fixture.WriteMarkerAt(fixture.infoMarker, "1");
    Require(CydiaRuntime::RestoreLegacySourceHandoff(),
            "legacy info marker restore failed");
    Require(ReadFile(fixture.source) ==
                "deb https://legacy-info.invalid/ stable main\n",
            "legacy info marker bytes changed");
    Require(access(fixture.backup.c_str(), F_OK) == -1 && errno == ENOENT,
            "legacy info backup remains");
    Require(access(fixture.infoMarker.c_str(), F_OK) == -1 && errno == ENOENT,
            "legacy info marker remains");
}

void TestSymlink() {
    Fixture fixture;
    fixture.Configure();
    const std::string target(Join(fixture.root, "preserved-target"));
    WriteFile(target, "deb https://symlink.invalid/ stable main\n");
    Require(symlink("../../preserved-target", fixture.backup.c_str()) == 0,
            "could not create symlink backup");
    fixture.WriteMarker("2", "symlink");
    Require(CydiaRuntime::RestoreLegacySourceHandoff(), "symlink restore failed");
    char linkTarget[256];
    const ssize_t length(readlink(fixture.source.c_str(), linkTarget, sizeof(linkTarget) - 1));
    Require(length > 0, "restored source is not a symlink");
    linkTarget[length] = '\0';
    Require(strcmp(linkTarget, "../../preserved-target") == 0,
            "symlink target changed");
    Require(access(fixture.marker.c_str(), F_OK) == -1 && errno == ENOENT,
            "symlink marker remains");
}

void TestCollisionAndActiveSibling() {
    Fixture collision;
    collision.Configure();
    WriteFile(collision.backup, "deb https://collision.invalid/ stable main\n");
    collision.WriteMarker("2");
    WriteFile(collision.source, "maintainer target\n");
    Require(CydiaRuntime::RestoreLegacySourceHandoff(), "collision handling failed");
    Require(ReadFile(collision.source) == "maintainer target\n",
            "collision replaced maintainer target");
    Require(access(collision.backup.c_str(), F_OK) == 0 && access(collision.marker.c_str(), F_OK) == 0,
            "collision did not preserve handoff receipt");

    Fixture sibling;
    sibling.Configure();
    WriteFile(sibling.backup, "deb https://sibling.invalid/ stable main\n");
    WriteFile(Join(sibling.parts, "default.sources"), "Types: deb\nURIs: https://owner.invalid\n");
    sibling.WriteMarker("2");
    Require(CydiaRuntime::RestoreLegacySourceHandoff(), "active sibling handling failed");
    Require(access(sibling.source.c_str(), F_OK) == -1 && errno == ENOENT,
            "active sibling unexpectedly restored source");
    Require(access(sibling.backup.c_str(), F_OK) == 0 && access(sibling.marker.c_str(), F_OK) == 0,
            "active sibling did not preserve handoff receipt");

    Fixture empty;
    empty.Configure();
    WriteFile(empty.backup, "deb https://empty-sibling.invalid/ stable main\n");
    WriteFile(Join(empty.parts, "comment-only.list"),
              "# an intentionally inert sourcepart\n\n");
    WriteFile(Join(empty.parts, "empty.sources"), "");
    empty.WriteMarker("2");
    Require(CydiaRuntime::RestoreLegacySourceHandoff(),
            "empty sibling handling failed");
    Require(ReadFile(empty.source) ==
                "deb https://empty-sibling.invalid/ stable main\n",
            "empty sibling restore bytes changed");
    Require(access(empty.backup.c_str(), F_OK) == -1 && errno == ENOENT,
            "empty sibling backup remains");
    Require(access(empty.marker.c_str(), F_OK) == -1 && errno == ENOENT,
            "empty sibling marker remains");
}

} // namespace

int main() {
    TestRegularV2();
    TestLegacyV1();
    TestLegacyInfoMarkerCompatibility();
    TestSymlink();
    TestCollisionAndActiveSibling();
    puts("[legacy-source-handoff][ ok ] marker-authorized restore is executable and fail-closed");
    return 0;
}
