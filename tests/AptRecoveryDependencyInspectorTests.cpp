/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryDependencyInspector.hpp"
#include "Cydia/AptRecoveryMachO.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#ifndef CYDIA_RECOVERY_DEPENDENCY_TESTING
#error This fixture requires the isolated dependency-graph test seam.
#endif
namespace {
namespace R = CydiaAPT::Recovery;
void Require(bool value, const char *description) {
    if (value) return;
    std::fprintf(stderr, "[recovery-dependencies] %s\n", description); std::exit(1);
}
R::MachO::Image Image(std::vector<std::string> dependencies, std::vector<std::string> paths = {}) {
    R::MachO::Image value; value.type = 6; value.currentVersion = 0x20000; value.rpaths = paths;
    for (const auto &name : dependencies) value.dependencies.push_back({name, 0x10000, false});
    return value;
}
bool Missing(const R::DependencyProof &proof, const std::string &field) {
    return std::find(proof.unresolvedFields.begin(), proof.unresolvedFields.end(), field) != proof.unresolvedFields.end();
}
}
int main() {
    Require(!Missing(R::InspectConfiguredCommandsForTesting("Acquire::cdrom::mount \"/media/cdrom/\";\n"),
        "configuredCommandInterfaceUnsupported"), "default passive cdrom mount point is not a command");
    for (const char *command : {"Mount", "UMount"})
        Require(Missing(R::InspectConfiguredCommandsForTesting(std::string("Acquire::cdrom::media::") +
            command + " \"untrusted command\";\n"), "configuredCommandInterfaceUnsupported"),
            "per-mount shell overrides remain unresolved");
    const auto pathCommand(R::InspectConfiguredCommandsForTesting("Acquire::cdrom::/media/cdrom/::Mount \"command\";\n"));
    Require(Missing(pathCommand, "configuredCommandPolicyInvalid"),
        "unsupported path-bearing configuration tag cannot bypass command admission");
    const std::string root = "/cydia-fixture/bin/worker", a = "/cydia-fixture/lib/a.dylib", b = "/cydia-fixture/lib/b.dylib";
    std::map<std::string, R::MachO::Image> images{
        {root, Image({"@rpath/a.dylib"}, {"@executable_path/../lib"})},
        {a, Image({"@loader_path/b.dylib"}, {"@loader_path"})},
        {b, Image({"@rpath/a.dylib"}, {"@loader_path"})}};
    images[root].type = 2;
    auto proof = R::InspectDependencyGraphForTesting(images, {root});
    Require(proof.unresolvedFields.empty() && proof.nonPlatformDependencies == std::vector<std::string>{a, b}, "cyclic closure terminates with exact declared dependencies");
    Require(proof.discoveredComponents.empty(), "private graph cannot fabricate external discoveries");
    auto changed = images; changed.erase(b);
    Require(Missing(R::InspectDependencyGraphForTesting(changed, {root}), "dependencyUnavailable"), "missing transitive dependency is not Ready");
    changed = images; changed[b].currentVersion = 0;
    Require(Missing(R::InspectDependencyGraphForTesting(changed, {root}), "dependencyABIUnsupported"), "dylib compatibility version enforced");
    changed = images; changed[root].rpaths = {"relative/path"};
    Require(Missing(R::InspectDependencyGraphForTesting(changed, {root}), "dynamicLoaderSearchUnsupported"), "ambient working-directory lookup refused");
    changed = images; changed[root].rpaths.assign(257, "/cydia-fixture/lib");
    Require(Missing(R::InspectDependencyGraphForTesting(changed, {root}), "dependencyGraphTooLarge"), "rpath work bounded");
    Require(Missing(R::InspectDependencyGraphForTesting(images, {root}, [] { return true; }), "dependencyInspectionCancelled"), "cancel before graph traversal");
    changed.clear();
    for (unsigned n = 0; n < 70; ++n) {
        const auto path = "/cydia-fixture/deep/" + std::to_string(n);
        changed[path] = Image(n == 69 ? std::vector<std::string>() : std::vector<std::string>{"/cydia-fixture/deep/" + std::to_string(n+1)});
    }
    Require(Missing(R::InspectDependencyGraphForTesting(changed, {"/cydia-fixture/deep/0"}), "dependencyGraphTooLarge"), "recursive work bounded");
    changed = images;
    changed[root].rpaths = {"/cydia-fixture/older", "/cydia-fixture/lib"};
    changed["/cydia-fixture/older/a.dylib"] = Image({}); changed["/cydia-fixture/older/a.dylib"].currentVersion = 0;
    Require(Missing(R::InspectDependencyGraphForTesting(changed, {root}), "dependencyABIUnsupported"), "earlier present rpath candidate cannot be skipped");
    std::puts("Recovery dependency graph tests passed");
}
