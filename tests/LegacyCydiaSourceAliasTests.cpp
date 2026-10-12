/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/LegacyCydiaSourceAlias.hpp"
#include "Cydia/PackageDatabasePaths.hpp"
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {
typedef CydiaRuntime::LegacyCydiaSourceAliasResult Result;
void Expect(bool condition, const char *detail) {
    if (!condition) { fprintf(stderr, "[legacy-cydia-source-alias] FAIL: %s (errno %d)\n", detail, errno); exit(1); }
}
void Write(const std::string &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::binary); file << bytes; file.close(); Expect(file.good(), "write fixture");
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary); Expect(file.good(), "read fixture");
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}
void Remove(const std::string &path) {
    struct stat st; if (lstat(path.c_str(), &st) != 0) return;
    if (!S_ISDIR(st.st_mode)) { Expect(unlink(path.c_str()) == 0, "remove fixture leaf"); return; }
    DIR *directory(opendir(path.c_str())); Expect(directory != NULL, "open cleanup directory");
    while (struct dirent *entry = readdir(directory)) {
        const std::string name(entry->d_name); if (name != "." && name != "..") Remove(path + '/' + name);
    }
    closedir(directory); Expect(rmdir(path.c_str()) == 0, "remove fixture directory");
}
struct Fixture {
    std::string root, source, home, cache, admin;
    const std::string bytes = "# preserve comments and options\n"
        "deb [arch=iphoneos-arm] https://packages.example.invalid/ ./\n"
        "# deb https://disabled.example.invalid/ stable main\n";
    Fixture() {
        char temporary[] = "/tmp/cydia-source-alias.XXXXXX";
        char *created(mkdtemp(temporary)); Expect(created != NULL, "create fixture");
        char *canonical(realpath(created, NULL)); Expect(canonical != NULL, "canonical fixture"); root = canonical; free(canonical);
        const char *directories[] = {"etc", "etc/apt", "etc/apt/sources.list.d", "mobile", "mobile/Library",
            "mobile/Library/Caches", "mobile/Library/Caches/com.saurik.Cydia", "database", "database/info"};
        for (auto directory : directories) Expect(mkdir((root + '/' + directory).c_str(), 0755) == 0, "create fixture directory");
        source = root + "/etc/apt/sources.list.d/cydia.list"; home = root + "/mobile";
        cache = home + "/Library/Caches/com.saurik.Cydia/sources.list"; admin = root + "/database";
        Write(cache, bytes); Write(admin + "/info/cydia.list", "/Applications/Cydia.app/Cydia\n");
        Write(root + "/etc/apt/sources.list.d/bootstrap.sources", "Types: deb\nURIs: https://distribution.example.invalid/\nSuites: ./\n");
    }
    ~Fixture() { Remove(root); }
    Result migrate(uid_t cacheOwner = getuid()) {
        return CydiaRuntime::MaterializeLegacyCydiaSourceAliasAt(source, home, cacheOwner, getgid(), admin, getuid());
    }
    void alias(const std::string &target) { Expect(symlink(target.c_str(), source.c_str()) == 0, "create source alias"); }
    bool linked() { struct stat st; return lstat(source.c_str(), &st) == 0 && S_ISLNK(st.st_mode); }
    void preserved() {
        Expect(Read(cache) == bytes, "legacy cache retained exactly");
        Expect(Read(root + "/etc/apt/sources.list.d/bootstrap.sources") ==
            "Types: deb\nURIs: https://distribution.example.invalid/\nSuites: ./\n", "other source preserved");
        DIR *directory(opendir((root + "/etc/apt/sources.list.d").c_str())); Expect(directory != NULL, "inspect source directory");
        while (struct dirent *entry = readdir(directory))
            Expect(std::string(entry->d_name).compare(0, 20, ".cydia-source-alias.") != 0, "no abandoned temporary files");
        closedir(directory);
    }
};
void Exact(bool relative) {
    Fixture f; struct stat before; Expect(stat(f.cache.c_str(), &before) == 0, "cache identity");
    f.alias(relative ? "../../../mobile/Library/Caches/com.saurik.Cydia/sources.list" : f.cache);
    Expect(f.migrate() == Result::Materialized, "materialize recognized legacy alias");
    struct stat source, after; Expect(lstat(f.source.c_str(), &source) == 0 && S_ISREG(source.st_mode) &&
        source.st_uid == getuid() && (source.st_mode & 07777) == 0644, "administrator-owned regular source");
    Expect(stat(f.cache.c_str(), &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_mode == after.st_mode && before.st_uid == after.st_uid && before.st_gid == after.st_gid, "cache object and metadata unchanged");
    Expect(Read(f.source) == f.bytes, "source syntax and bytes unchanged"); f.preserved();
    Expect(f.migrate() == Result::Unchanged, "idempotent regular source");
}
void Noop() {
    Fixture f; Expect(f.migrate() == Result::Unchanged, "absent source is not seeded");
    Write(f.source, "administrator config\n"); Expect(f.migrate() == Result::Unchanged && Read(f.source) == "administrator config\n", "regular config untouched");
    f.preserved();
}
void Foreign() {
    Fixture f; const std::string zebra(f.home + "/Library/Caches/Zebra.list"); Write(zebra, f.bytes); f.alias(zebra);
    Expect(f.migrate() == Result::Unchanged && f.linked(), "another frontend alias untouched");
    Expect(CydiaRuntime::MaterializeLegacyCydiaSourceAliasAt(f.source, f.home, getuid(), getgid(), f.admin,
        getuid() + 1) == Result::Unchanged && f.linked(), "foreign alias owner cannot block installation"); f.preserved();
}
void Owned(bool target) {
    Fixture f; f.alias(f.cache); Write(f.admin + "/info/cydia-sources.list", (target ? f.cache : f.source) + '\n');
    Expect(f.migrate() == Result::Unchanged && f.linked(), "foreign package ownership retained"); f.preserved();
}
void Diverted(bool target) {
    Fixture f; f.alias(f.cache); const std::string path(target ? f.cache : f.source);
    Write(f.admin + "/diversions", path + '\n' + path + ".distribution\nbootstrap-fixture\n");
    Expect(f.migrate() == Result::Unchanged && f.linked(), "foreign diversion retained"); f.preserved();
}
void DiversionDestination(bool target) {
    Fixture f; f.alias(f.cache); const std::string path(target ? f.cache : f.source);
    Write(f.admin + "/diversions", f.root + "/distribution-original.list\n" + path + "\nbootstrap-fixture\n");
    Expect(f.migrate() == Result::Unchanged && f.linked(), "foreign diversion destination retained"); f.preserved();
}
void Unsafe() {
    Fixture f; f.alias(f.cache); Expect(chmod(f.cache.c_str(), 0666) == 0, "unsafe fixture permissions");
    Expect(f.migrate() == Result::Refused && f.linked(), "writable cache fails closed"); f.preserved();
    Expect(chmod(f.cache.c_str(), 0644) == 0, "restore fixture permissions");
    Expect(f.migrate(getuid() + 1) == Result::Refused && f.linked(), "unexpected cache owner fails closed"); f.preserved();
}
void AliasedCache() {
    Fixture f; f.alias(f.cache); const auto real(f.cache + ".real"); Expect(rename(f.cache.c_str(), real.c_str()) == 0, "move cache");
    Expect(symlink(real.c_str(), f.cache.c_str()) == 0, "alias cache file");
    Expect(f.migrate() == Result::Refused && f.linked(), "cache leaf aliases rejected"); f.preserved();
}
void AliasedCacheParent() {
    Fixture f; f.alias(f.cache); const auto parent(f.home + "/Library/Caches/com.saurik.Cydia"); const auto real(parent + ".real");
    Expect(rename(parent.c_str(), real.c_str()) == 0 && symlink(real.c_str(), parent.c_str()) == 0, "alias cache parent");
    Expect(f.migrate() == Result::Refused && f.linked(), "cache parent aliases rejected"); f.preserved();
}
void AliasedHome() {
    Fixture f; f.alias(f.cache); const auto real(f.home + ".real");
    Expect(rename(f.home.c_str(), real.c_str()) == 0 && symlink(real.c_str(), f.home.c_str()) == 0, "protected home alias");
    Expect(f.migrate() == Result::Materialized && Read(f.source) == f.bytes, "administrator-owned home alias supported"); f.preserved();
}
void UnsafeAptParent() {
    Fixture f; f.alias(f.cache); Expect(chmod((f.root + "/etc/apt").c_str(), 0777) == 0, "writable APT parent");
    Expect(f.migrate() == Result::Refused && f.linked(), "untrusted APT namespace rejected"); f.preserved();
}
void UnsafeMetadata() {
    Fixture f; f.alias(f.cache); Write(f.admin + "/info/frontend.list", f.source + '\n');
    Expect(chmod((f.admin + "/info/frontend.list").c_str(), 0666) == 0, "unsafe ownership metadata");
    Expect(f.migrate() == Result::Refused && f.linked(), "untrusted ownership metadata rejected"); f.preserved();
}
}
int main() {
    Exact(false); Exact(true); Noop(); Foreign(); Owned(false); Owned(true); Diverted(false); Diverted(true);
    DiversionDestination(false); DiversionDestination(true);
    Unsafe(); AliasedCache(); AliasedCacheParent(); AliasedHome(); UnsafeAptParent(); UnsafeMetadata();
    Expect(CydiaRuntime::MaterializeLegacyCydiaSourceAlias(CydiaRuntime::PackageDatabasePaths::ForLayout(
        CydiaRuntime::PackageDatabaseLayout::Rootless), "/home/fixture", getuid(), getgid(), "/unused") ==
        Result::Unchanged, "rootless layout remains untouched");
    puts("[legacy-cydia-source-alias] PASS (17 scoped migrations and safety cases)");
}
