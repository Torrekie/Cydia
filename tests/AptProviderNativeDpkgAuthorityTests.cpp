/* Protected native declaration and actual Mach-O byte fixtures. The sole
 * substitutions are declaration locations and a fixed host-test target/cache;
 * no executable is loaded and no package database is modified.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/AptRecoveryDependencyInspector.hpp"
#include "Cydia/AptRecoveryMachO.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
#ifndef CYDIA_NATIVE_DPKG_AUTHORITY_TESTING
#error This fixture requires the explicit declaration-location/platform test seam.
#endif
namespace {
namespace A = CydiaAPT::Provider;
namespace R = CydiaAPT::Recovery;
namespace P = CydiaRuntime::Privileged;
void Require(bool value, const char *message) {
    if (!value) { std::fprintf(stderr, "[native-dpkg-authority] %s\n", message); std::exit(1); }
}
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM); Require(hash.Add(bytes.data(), bytes.size()), "hash fixture bytes");
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc); stream.write(bytes.data(), bytes.size()); stream.close();
    Require(stream.good() && chmod(path.c_str(), mode) == 0, "write protected fixture");
}
void Word(std::string &bytes, std::size_t offset, uint32_t value) {
    Require(offset <= bytes.size() && bytes.size() - offset >= 4, "fixture word in range");
    for (unsigned index = 0; index != 4; ++index) bytes[offset + index] = value >> (8 * index);
}
std::string Command(uint32_t kind, std::size_t size) {
    std::string bytes(size, '\0'); Word(bytes, 0, kind); Word(bytes, 4, size); return bytes;
}
std::string StringCommand(uint32_t kind, const std::string &text, unsigned header = 12) {
    auto bytes = Command(kind, (header + text.size() + 8) & ~std::size_t(7));
    Word(bytes, 8, header); bytes.replace(header, text.size(), text); return bytes;
}
std::string Dylib(uint32_t kind, const std::string &name, uint32_t current = 0x20000) {
    auto bytes = StringCommand(kind, name, 24); Word(bytes, 16, current); Word(bytes, 20, 0x10000); return bytes;
}
std::string Image(bool executable, const std::vector<std::string> &dependencies = {},
    const std::vector<std::string> &rpaths = {}, uint32_t current = 0x20000, uint32_t cpu = 0x100000c) {
    auto segment = Command(0x19, 72); segment.replace(8, 6, "__TEXT"); Word(segment, 60, 5);
    auto platform = Command(0x32, 24); Word(platform, 8, 2); Word(platform, 12, 0xc0000);
    std::vector<std::string> commands{segment, platform};
    commands.push_back(executable ? StringCommand(0xe, "/usr/lib/dyld") : Dylib(0xd, "@rpath/libfixture.dylib", current));
    for (const auto &path : rpaths) commands.push_back(StringCommand(0x8000001c, path));
    for (const auto &path : dependencies) commands.push_back(Dylib(0xc, path));
    if (executable) commands.push_back(Command(0x80000028u, 24));
    std::string bytes(32, '\0'); Word(bytes, 0, 0xfeedfacf); Word(bytes, 4, cpu);
    Word(bytes, 12, executable ? 2 : 6); Word(bytes, 16, commands.size()); Word(bytes, 24, 0x80);
    for (const auto &command : commands) bytes += command;
    Word(bytes, 20, bytes.size() - 32);
    if (executable) Word(bytes, bytes.size() - 16, bytes.size());
    bytes += std::string(4, '\0'); Word(bytes, 32 + 48, bytes.size()); Word(bytes, 32 + 32, bytes.size()); return bytes;
}
struct Fixture {
    std::string root, primary, fallback, program, query, library, optional;
    std::map<std::string, std::string> bytes;
    A::BrokerEnvironment selected;
    A::ReviewedTransaction review;
    std::vector<std::string> fields, components, commands;
    Fixture() {
        std::string pattern = std::filesystem::current_path().string() + "/native-dpkg-authority.XXXXXX";
        std::vector<char> buffer(pattern.begin(), pattern.end()); buffer.push_back('\0');
        const char *created = mkdtemp(buffer.data()); Require(created, "fixture directory"); root = created;
        for (const char *name : {"bin", "lib", "conf", "conf.d"}) std::filesystem::create_directory(root + '/' + name);
        primary = root + "/native-dpkg.conf"; fallback = root + "/fallback.conf";
        program = root + "/bin/dpkg"; query = root + "/bin/dpkg-query"; library = root + "/lib/libfixture.dylib";
        optional = root + "/conf/optional";
        Put(program, Image(true, {"@rpath/libfixture.dylib"}, {"@executable_path/../lib"}));
        Put(query, Image(true)); Put(library, Image(false));
        components = {program, query, library};
        Write(root + "/conf/dpkg", "no-force\n"); Write(root + "/conf.d/a", "log configured\n");
        selected.environment.dpkg = program; selected.environment.dpkgQuery = query;
        selected.environment.dpkgRoot = "/"; selected.environment.dpkgAdmin = root + "/admin";
        selected.executableSearchPath = root + "/bin:/usr/bin:/bin";
        A::ArchiveManifest archive; archive.identifier = "dpkg-archive"; archive.package = {"dpkg", "2", "iphoneos-arm64"};
        review.execution.archives.push_back(archive);
        R::SetTransactionTargetForTesting({0x100000c, 0, 2, 0x100000});
        A::SetNativeDpkgAuthorityTestPaths(primary, fallback); Declaration();
    }
    ~Fixture() { std::filesystem::remove_all(root); }
    void Put(const std::string &path, const std::string &value) { bytes[path] = value; Write(path, value, 0755); }
    void Declaration() {
        std::vector<std::string> executors{program, Hash(bytes.at(program)), query, Hash(bytes.at(query))};
        for (const auto &command : commands) { executors.push_back(command); executors.push_back(Hash(bytes.at(command))); }
        fields = {"CYDIA-NATIVE-DPKG-1", P::SerializeFields(executors), P::SerializeFields({root + "/conf/dpkg"}),
            P::SerializeFields({root + "/conf.d"}), P::SerializeFields({optional}), "", P::SerializeFields(commands),
            P::SerializeFields(components), P::SerializeFields({"dpkg:iphoneos-arm64", P::SerializeFields({program})}), "complete-native-graph"};
        Save();
    }
    void Save() { Write(primary, P::SerializeFields(fields)); }
    bool Resolve(A::NativeDpkgAuthority *authority, std::string *error, const std::function<bool()> &cancelled = {}) {
        return A::ResolveNativeDpkgAuthority(selected, review, authority, error, cancelled);
    }
    std::vector<A::InstalledComponentEvidence> Capture() {
        std::vector<A::InstalledComponentEvidence> result; std::string error;
        for (const auto &path : components) {
            A::InstalledComponentEvidence file;
            Require(A::CaptureTransactionComponent(path, &file, &error), "capture real component identity"); result.push_back(file);
        }
        return result;
    }
};
void Declarations() {
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(f.Resolve(&authority, &error), error.c_str());
        Require(authority.configurationIdentity.size() == 64 && authority.platformIdentity.size() == 64 &&
            authority.successorPaths.at("dpkg-archive") == std::vector<std::string>{f.program}, "real declaration derives identities and exact archive successor association");
        Require(A::RevalidateNativeDpkgAuthority(authority, f.Capture(), &error), "unchanged declaration and graph revalidate");
        Require(authority.launchEnvironment.initialized() &&
            std::find(authority.launchEnvironment.entries().begin(), authority.launchEnvironment.entries().end(), "PATH=" + f.selected.executableSearchPath) != authority.launchEnvironment.entries().end() &&
            std::find(authority.launchEnvironment.entries().begin(), authority.launchEnvironment.entries().end(), "DPKG_FRONTEND_LOCKED=1") != authority.launchEnvironment.entries().end(),
            "authority captures exact selected path and parent-lock overlay");
        auto changedEnvironment = authority;
        Require(changedEnvironment.launchEnvironment.Overlay({"PATH=" + f.selected.executableSearchPath + ":/changed"}, {}, &changedEnvironment.launchEnvironment) &&
            !A::RevalidateNativeDpkgAuthority(changedEnvironment, f.Capture(), &error),
            "launch environment cannot change behind its retained binding");
        Write(f.optional, "new optional native policy\n");
        Require(!A::RevalidateNativeDpkgAuthority(authority, f.Capture(), &error), "previously absent native configuration cannot appear during a lease");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(f.Resolve(&authority, &error), "directory configuration captures"); Write(f.root + "/conf.d/a", "changed\n");
        Require(!A::RevalidateNativeDpkgAuthority(authority, f.Capture(), &error), "declared directory contents are read and rechecked");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        Require(rename(f.primary.c_str(), f.fallback.c_str()) == 0 && f.Resolve(&authority, &error), "absent primary allows protected distribution declaration");
        Write(f.primary, "bad declaration");
        Require(!f.Resolve(&authority, &error) && error == "provider_native_configuration_invalid" && authority.configurationIdentity.empty(),
            "present invalid primary never falls through or retains stale authority");
        Require(unlink(f.primary.c_str()) == 0 && unlink(f.fallback.c_str()) == 0 && !f.Resolve(&authority, &error) &&
            error == "provider_native_configuration_missing", "missing declaration remains explicitly unsupported");
    }
    for (unsigned variant = 0; variant != 9; ++variant) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        switch (variant) {
            case 0: f.fields[0] = "CYDIA-NATIVE-DPKG-2"; f.Save(); break;
            case 1: f.fields[1] = P::SerializeFields({f.program, std::string(64, 'z'), f.query, Hash(f.bytes[f.query])}); f.Save(); break;
            case 2: f.fields[7] = P::SerializeFields({f.program, f.query, f.library, f.library}); f.Save(); break;
            case 3: f.fields[2] = P::SerializeFields({f.root + "/conf/../conf/dpkg"}); f.Save(); break;
            case 4: f.fields[8] = P::SerializeFields({"dpkg:any", P::SerializeFields({f.program})}); f.Save(); break;
            case 5: f.fields[9] = "partial-graph"; f.Save(); break;
            case 6: Require(chmod(f.primary.c_str(), 0664) == 0, "make declaration writable"); break;
            case 7: Write(f.program, Image(true), 0755); break;
            case 8: Require(chmod((f.root + "/conf/dpkg").c_str(), 0664) == 0, "make native input writable"); break;
        }
        Require(!f.Resolve(&authority, &error) && authority.configurationIdentity.empty() && !error.empty(),
            "invalid, unprotected or binary-mismatched declaration never produces authority");
    }
    {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        const auto valid = P::SerializeFields(f.fields);
        for (std::size_t size : {std::size_t(0), std::size_t(1), valid.size()/2, valid.size()-1}) {
            Write(f.primary, valid.substr(0, size)); Require(!f.Resolve(&authority, &error), "truncated netstrings refuse");
        }
        f.Save(); Require(!f.Resolve(&authority, &error, [] { return true; }), "cancel before protected declaration admission");
    }
}
void ConfiguredAutomaticDeconfiguration() {
    const std::vector<std::string> configured{"auto-deconfigure\n", "auto-deconfigure  \n", "auto-deconfigure=# value\n",
        "\t--auto-deconfigure\n", "# harmless comment\nauto-deconfigure\n"};
    for (const auto &bytes : configured) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        A::ReviewedAction unpack; unpack.identifier = 1; unpack.action = A::ExecutionAction::Unpack;
        unpack.package = f.review.execution.archives.front().package; unpack.archive = "dpkg-archive";
        f.review.execution.actions = {unpack}; Write(f.root + "/conf.d/a", bytes);
        Require(!f.Resolve(&authority, &error) && error == "provider_native_auto_deconfigure_unsupported" &&
            authority.configurationIdentity.empty() && authority.configurationEvidence.empty(),
            "configured automatic deconfiguration cannot bypass absent argv switch or publish authority");
        f.review.execution.actions.front().action = A::ExecutionAction::Configure;
        Require(f.Resolve(&authority, &error), "known Unpack effect does not forbid an unrelated Configure review");
    }
    for (const char *bytes : {"# auto-deconfigure\n", "  # --auto-deconfigure\n", "pre-invoke echo auto-deconfigure\n",
        "log /auto-deconfigure\n", "auto-deconfigure-extra\n", "\n"}) {
        Fixture f; A::NativeDpkgAuthority authority; std::string error;
        A::ReviewedAction unpack; unpack.identifier = 1; unpack.action = A::ExecutionAction::Unpack;
        f.review.execution.actions = {unpack}; Write(f.root + "/conf/dpkg", bytes);
        Require(f.Resolve(&authority, &error), "comments and other option values do not become automatic deconfiguration");
    }
}
void Closures() {
    for (unsigned variant = 0; variant != 9; ++variant) {
        Fixture f; A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error), "resolve closure declaration"); auto components = f.Capture();
        Require(A::CaptureNativeDpkgClosure(authority, f.program, components, &proof, &error) && proof.nodes.size() == 2,
            "actual protected Mach-O graph resolves an rpath edge without loading code");
        switch (variant) {
            case 0: components[0].file.sha256.assign(64, '0'); break;
            case 1: Write(f.library, Image(false, {}, {}, 0), 0755); components = f.Capture(); break;
            case 2: components.pop_back(); break;
            case 3: Write(f.library, "changed after component capture", 0755); break;
            case 4: authority.configurationIdentity.assign(64, 'g'); break;
            case 5: R::SetTransactionTargetForTesting({0x100000c, 0, 2, 0xf0000}); break;
            case 6: f.Put(f.program, "#!/bin/sh\nexit 0\n"); f.Declaration(); Require(f.Resolve(&authority, &error), "script generation can be declared but not prove its dynamic command closure"); components = f.Capture(); break;
            case 7: f.Put(f.program, Image(true, {}, {}, 0x20000, 0x1000007)); f.Declaration(); Require(f.Resolve(&authority, &error), "generation capture is distinct from loadability"); components = f.Capture(); break;
            case 8: break;
        }
        Require(!A::CaptureNativeDpkgClosure(authority, f.program, components, &proof, &error,
            variant == 8 ? std::function<bool()>([] { return true; }) : std::function<bool()>()) && proof.nodes.empty(),
            "changed bytes/ABI/platform, incomplete inventory, unsupported executable or cancellation cannot publish closure proof");
    }
    {
        Fixture f; const auto earlier = f.root + "/earlier"; std::filesystem::create_directory(earlier);
        f.Put(f.program, Image(true, {"@rpath/libfixture.dylib"}, {earlier, "@executable_path/../lib"})); f.Declaration();
        A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error), "rpath declaration"); Write(earlier + "/libfixture.dylib", Image(false), 0755);
        Require(!A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error), "present undeclared earlier rpath candidate is not skipped");
        Require(unlink((earlier + "/libfixture.dylib").c_str()) == 0 &&
            A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error), "absent earlier rpath correctly resolves captured later candidate");
    }
    {
        Fixture f; const auto hook = f.root + "/bin/hook";
        f.Put(hook, Image(true, {f.root + "/lib/missing.dylib"})); f.components.push_back(hook); f.commands.push_back(hook); f.Declaration();
        A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error) && !A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error),
            "declared native command must independently resolve its dependency closure");
    }
    {
        Fixture f; std::vector<std::string> leaves, parents;
        for (unsigned index = 0; index != 64; ++index) {
            const auto path = f.root + "/lib/leaf" + std::to_string(index); f.Put(path, Image(false)); f.components.push_back(path); leaves.push_back(path);
        }
        for (unsigned index = 0; index != 65; ++index) {
            const auto path = f.root + "/lib/parent" + std::to_string(index); f.Put(path, Image(false, leaves)); f.components.push_back(path); parents.push_back(path);
        }
        f.Put(f.program, Image(true, parents)); f.Declaration();
        A::NativeDpkgAuthority authority; A::ComponentClosureEvidence proof; std::string error;
        Require(f.Resolve(&authority, &error) && !A::CaptureNativeDpkgClosure(authority, f.program, f.Capture(), &proof, &error) && proof.nodes.empty(),
            "actual shallow dependency graph is bounded to 4096 distinct edges");
    }
}
}
int main() {
    Declarations(); ConfiguredAutomaticDeconfiguration(); Closures();
    std::puts("Native dpkg protected declaration and Mach-O closure tests passed");
}
