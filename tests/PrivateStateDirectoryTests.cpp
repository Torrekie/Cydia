// Copyright (C) 2026 Torrekie
// SPDX-License-Identifier: GPL-3.0-or-later
#include "Cydia/PrivateStateDirectory.hpp"
#include "Cydia/PrivateMetadataMigration.hpp"
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>

namespace {
void Require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "[private-state-directory] FAIL: " << message << '\n';
        std::exit(1);
    }
}
mode_t Mode(const std::string &path) {
    struct stat info;
    Require(lstat(path.c_str(), &info) == 0, "inspect fixture mode");
    return info.st_mode & 07777;
}
} // namespace

int main() {
    char pattern[] = "/tmp/cydia-private-state.XXXXXX";
    char *created(mkdtemp(pattern));
    Require(created != NULL, "create temporary parent");
    const std::string parent(created);
    const int directory(open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW));
    Require(directory >= 0, "open verified fixture parent");
    Require(CydiaRuntime::EnsurePrivateStateDirectoryAt(directory, "policy", geteuid(), getegid()),
            "create private leaf");
    const std::string policy(parent + "/policy"), child(policy + "/existing.conf");
    std::ofstream file(child.c_str()); file << "untrusted existing configuration\n"; file.close();
    Require(chmod(child.c_str(), 0666) == 0 && chmod(policy.c_str(), 0777) == 0, "prepare old leaf permissions");
    Require(CydiaRuntime::EnsurePrivateStateDirectoryAt(directory, "policy", geteuid(), getegid()),
            "repair private leaf");
    Require(Mode(policy) == 0755 && Mode(parent) == 0700 && Mode(child) == 0666,
            "repair touches only leaf directory, never parents or config children");
    const std::string old(parent + "/old-private");
    Require(mkdir(old.c_str(), 0700) == 0, "create historical private metadata directory");
    const int oldDirectory(open(old.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW));
    const int policyDirectory(open(policy.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW));
    Require(oldDirectory >= 0 && policyDirectory >= 0, "open metadata directory capabilities");
    const std::string oldMetadata(old + "/metadata.cb0"), metadata(policy + "/metadata.cb0");
    { std::ofstream body(oldMetadata.c_str()); body << "preserved metadata bytes\n"; }
    Require(CydiaRuntime::MigratePrivateMetadataAt(oldDirectory, "metadata.cb0", policyDirectory,
            "metadata.cb0", geteuid(), getegid()), "migrate historical private metadata");
    { std::ifstream body(metadata.c_str()); std::string bytes; std::getline(body, bytes);
      Require(bytes == "preserved metadata bytes", "metadata bytes preserved"); }
    Require(access(oldMetadata.c_str(), F_OK) != 0 && Mode(metadata) == 0644,
            "remove only migrated unchanged source and publish readable mobile metadata");
    { std::ofstream body(oldMetadata.c_str()); body << "older metadata retained\n"; }
    Require(CydiaRuntime::MigratePrivateMetadataAt(oldDirectory, "metadata.cb0", policyDirectory,
            "metadata.cb0", geteuid(), getegid()) && access(oldMetadata.c_str(), F_OK) == 0,
            "existing destination remains authoritative and old source stays intact");
    Require(unlink(metadata.c_str()) == 0 && symlink("existing.conf", metadata.c_str()) == 0,
            "prepare malicious destination alias");
    Require(!CydiaRuntime::MigratePrivateMetadataAt(oldDirectory, "metadata.cb0", policyDirectory,
            "metadata.cb0", geteuid(), getegid()) && Mode(child) == 0666,
            "reject symbolic destination without touching its target");
    Require(unlink(metadata.c_str()) == 0 && unlink(oldMetadata.c_str()) == 0 &&
            symlink("../policy/existing.conf", oldMetadata.c_str()) == 0, "prepare source alias");
    Require(!CydiaRuntime::MigratePrivateMetadataAt(oldDirectory, "metadata.cb0", policyDirectory,
            "metadata.cb0", geteuid(), getegid()) && access(metadata.c_str(), F_OK) != 0,
            "reject symbolic source without publishing copied target bytes");
    Require(unlink(oldMetadata.c_str()) == 0, "remove source alias");
    close(oldDirectory); close(policyDirectory);
    Require(rmdir(old.c_str()) == 0, "remove old private directory");
    const std::string outside(parent + "/outside");
    Require(mkdir(outside.c_str(), 0777) == 0 && chmod(outside.c_str(), 0777) == 0, "create unrelated target");
    const std::string alias(parent + "/alias");
    Require(symlink("outside", alias.c_str()) == 0, "create malicious leaf alias");
    Require(!CydiaRuntime::EnsurePrivateStateDirectoryAt(directory, "alias", geteuid(), getegid()),
            "reject symbolic-link leaf");
    Require(Mode(outside) == 0777, "leave symlink target unchanged");
    Require(!CydiaRuntime::EnsurePrivateStateDirectoryAt(directory, "policy/existing.conf", geteuid(), getegid()) &&
            !CydiaRuntime::EnsurePrivateStateDirectoryAt(directory, "..", geteuid(), getegid()),
            "reject traversal and multi-component leaf");
    Require(chmod(parent.c_str(), 0777) == 0, "prepare writable parent");
    Require(!CydiaRuntime::EnsurePrivateStateDirectoryAt(directory, "new-policy", geteuid(), getegid()) &&
            access((parent + "/new-policy").c_str(), F_OK) != 0,
            "reject writable parent before creating anything");
    Require(chmod(parent.c_str(), 0700) == 0, "restore temporary parent mode");
    close(directory);
    Require(unlink(child.c_str()) == 0 && unlink(alias.c_str()) == 0 &&
            rmdir(outside.c_str()) == 0 && rmdir(policy.c_str()) == 0 && rmdir(parent.c_str()) == 0,
            "clean fixture tree");
    std::cout << "[private-state-directory] PASS\n";
    return 0;
}
