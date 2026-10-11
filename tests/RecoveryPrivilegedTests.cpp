/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RecoveryPrivileged.hpp"
#include <cstdlib>
#include <dirent.h>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>
using namespace CydiaRuntime;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[recovery-privileged][FAIL] " << message << '\n'; std::exit(1); }
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream output(path.c_str(), std::ios::binary | std::ios::trunc); output << bytes; output.close();
    Require(output.good() && chmod(path.c_str(), mode) == 0, "write generic fixture");
}
std::string Read(const std::string &path) {
    std::ifstream input(path.c_str(), std::ios::binary); return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
void Clean(const std::string &path) {
    struct stat st; if (lstat(path.c_str(), &st) != 0) return;
    if (!S_ISDIR(st.st_mode)) { unlink(path.c_str()); return; }
    DIR *directory(opendir(path.c_str()));
    if (directory == NULL) return;
    while (const auto entry = readdir(directory)) {
        const std::string leaf(entry->d_name);
        if (leaf != "." && leaf != "..") Clean(path + '/' + leaf);
    }
    closedir(directory); rmdir(path.c_str());
}
struct Fixture {
    std::string path, state, script, status, unrelated;
    Privileged::Environment environment;
    Fixture() {
        char pattern[] = "/tmp/recovery-fixture-XXXXXX"; const char *created(mkdtemp(pattern));
        Require(created != NULL, "create isolated fixture"); path = created; state = path + "/state";
        environment.dpkgRoot = path; environment.dpkgAdmin = path + "/admin"; environment.dpkg = path + "/dpkg";
        for (const auto &directory : {state, environment.dpkgAdmin, environment.dpkgAdmin + "/info", environment.dpkgAdmin + "/updates"})
            Require(mkdir(directory.c_str(), 0755) == 0, "create isolated trusted directories");
        status = environment.dpkgAdmin + "/status";
        script = environment.dpkgAdmin + "/info/damaged.postinst";
        unrelated = environment.dpkgAdmin + "/info/another.prerm";
        Write(status, "Package: damaged\nArchitecture: arm64\nVersion: 1.0\nStatus: install ok half-configured\n\n"
            "Package: another\nArchitecture: arm64\nVersion: 1.0\nStatus: install ok installed\n\n");
        Write(script, "#!/bin/sh\nexit 1\n", 0755); Write(unrelated, "unrelated package bytes\n", 0755);
    }
    ~Fixture() { Clean(path); }
    Recovery::Snapshot Preview() {
        Recovery::Snapshot snapshot; Privileged::Error error;
        Require(Recovery::Prepare(environment, "damaged", "arm64", &snapshot, &error, getuid()), "prepare actual trusted package snapshot");
        return snapshot;
    }
};
int main() {
    {
        Fixture fixture; const auto snapshot(fixture.Preview());
        Require(snapshot.review.scripts == std::vector<std::string>{"postinst"} && access(fixture.script.c_str(), F_OK) == 0,
            "preview changes no scripts and reports only selected existing maintscripts");
        Recovery::RemovalResult result; Privileged::Error error; bool invoked(false);
        Require(!Recovery::Remove(fixture.path + "/missing-state", fixture.environment, "damaged", "arm64", snapshot.review.token,
            [&](const std::string &) { invoked = true; return 0; }, &result, &error, getuid()) && !invoked &&
            Read(fixture.script) == snapshot.scripts[3].file.bytes, "unavailable backup fails before any deletion or dpkg execution");
    }
    {
        Fixture fixture; const auto snapshot(fixture.Preview());
        Write(fixture.script, "#!/bin/sh\nchanged since review\n", 0755);
        Recovery::RemovalResult result; Privileged::Error error; bool invoked(false);
        Require(!Recovery::Remove(fixture.state, fixture.environment, "damaged", "arm64", snapshot.review.token,
            [&](const std::string &) { invoked = true; return 0; }, &result, &error, getuid()) && !invoked &&
            result.backupDirectory.empty() && Read(fixture.script).find("changed") != std::string::npos,
            "changed script token refuses clearing before backup and execution");
    }
    {
        Fixture fixture; const auto snapshot(fixture.Preview());
        Recovery::RemovalResult result; Privileged::Error error; unsigned invoked(0);
        Require(Recovery::Remove(fixture.state, fixture.environment, "damaged", "arm64", snapshot.review.token,
            [&](const std::string &package) {
                ++invoked; Require(package == "damaged" && access(fixture.script.c_str(), F_OK) != 0, "only selected script is cleared for reviewed removal");
                Require(Read(result.backupDirectory + "/postinst") == "#!/bin/sh\nexit 1\n" &&
                    Read(result.backupDirectory + "/manifest").find("half-configured") != std::string::npos,
                    "original script and chosen status stanza are backed up before dpkg starts");
                struct stat st; Require(stat(result.backupDirectory.c_str(), &st) == 0 && (st.st_mode & 077) == 0,
                    "package backup is private");
                return 0;
            }, &result, &error, getuid()) && invoked == 1 && Read(fixture.unrelated) == "unrelated package bytes\n",
            "successful emergency transaction leaves unrelated package scripts unchanged");
    }
    {
        Fixture fixture; const auto snapshot(fixture.Preview()); Recovery::RemovalResult result; Privileged::Error error;
        Require(!Recovery::Remove(fixture.state, fixture.environment, "damaged", "arm64", snapshot.review.token,
            [&](const std::string &) { return 1; }, &result, &error, getuid()) && result.scriptsRestored &&
            Read(fixture.script) == "#!/bin/sh\nexit 1\n" && access((result.backupDirectory + "/manifest").c_str(), F_OK) == 0,
            "dpkg failure restores absent original scripts and retains durable backup");
        struct stat st; Require(stat(fixture.script.c_str(), &st) == 0 && (st.st_mode & 0777) == 0755, "restoration preserves executable mode");
    }
    {
        Fixture fixture; const auto snapshot(fixture.Preview()); Recovery::RemovalResult result; Privileged::Error error;
        Require(!Recovery::Remove(fixture.state, fixture.environment, "damaged", "arm64", snapshot.review.token,
            [&](const std::string &) { Write(fixture.script, "other manager's replacement\n", 0755); return 1; },
            &result, &error, getuid()) && !result.scriptsRestored && Read(fixture.script) == "other manager's replacement\n",
            "failed removal restoration never overwrites a replacement script");
    }
    {
        Fixture fixture; Require(unlink(fixture.script.c_str()) == 0 && symlink(fixture.unrelated.c_str(), fixture.script.c_str()) == 0, "create symlink fixture");
        Recovery::Snapshot snapshot; Privileged::Error error;
        Require(!Recovery::Prepare(fixture.environment, "damaged", "arm64", &snapshot, &error, getuid()) &&
            Read(fixture.unrelated) == "unrelated package bytes\n", "symlink script refuses backup and never touches its target");
    }
    {
        Fixture fixture; Write(fixture.environment.dpkgAdmin + "/updates/0001", "pending dpkg status update\n");
        Recovery::Snapshot snapshot; Privileged::Error error;
        Require(!Recovery::Prepare(fixture.environment, "damaged", "arm64", &snapshot, &error, getuid()), "pending dpkg journals require ordinary recovery before emergency classification");
    }
    std::cout << "[recovery-privileged] PASS\n";
}
