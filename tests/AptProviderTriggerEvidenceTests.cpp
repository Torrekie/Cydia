/* Native dpkg formats, independent of a device or installed package database.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEvidence.hpp"
#include <cstdlib>
#include <iostream>

namespace {
namespace T = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[trigger-evidence] " << message << '\n'; std::exit(1);
}
T::TriggerRegistryInput Example() {
    T::TriggerRegistryInput input; input.directoryPresent = true;
    input.files["Lock"] = "";
    input.files["File"] = "/usr/share/icons icon-cache:all/noawait\n/usr/lib libcache:iphoneos-arm64/await\n";
    input.files["update-cache"] = "cache:iphoneos-arm64\ncache:iphoneos-arm/noawait\n";
    input.files["Unincorp"] = "# native deferred activations\nupdate-cache requester:iphoneos-arm64 -\n"
        "update-cache requester:iphoneos-arm64\n/usr/share/icons/icon.png requester:all\n";
    return input;
}
void FormatsAndIdentity() {
    auto input = Example(); T::TriggerRegistryState state; std::string error;
    Require(T::ParseTriggerRegistry(input, &state, &error) && error.empty() && state.canonicalIdentity.size() == 64,
        "native File, named registry and deferred queue admitted");
    Require(state.directoryPresent && state.lockPresent && state.fileRegistryPresent && state.deferredPresent &&
        state.interests.size() == 4 && state.deferred.size() == 2, "finite normalized registry shape");
    Require(state.interests[0].trigger == "/usr/lib" && state.interests[0].await &&
        state.interests[1].package == "icon-cache:all" && !state.interests[1].await &&
        state.interests[2].package == "cache:iphoneos-arm" && !state.interests[2].await,
        "literal all/foreign architecture and await choices retained");
    Require(state.deferred[1].trigger == "update-cache" && state.deferred[1].noAwait &&
        state.deferred[1].awaiters == std::vector<std::string>{"requester:iphoneos-arm64"},
        "duplicate queued activations merge without treating noawait as a package");
    const std::string original = state.canonicalIdentity;
    input.files["Unincorp"] = "/usr/share/icons/icon.png requester:all\nupdate-cache - requester:iphoneos-arm64\n";
    input.files["update-cache"] = "cache:iphoneos-arm/noawait\ncache:iphoneos-arm64/await\ncache:iphoneos-arm64\n";
    Require(T::ParseTriggerRegistry(input, &state, &error) && state.canonicalIdentity == original,
        "record ordering, explicit await, comments and duplicate queue entries are semantically canonical");
    input.files["update-cache"] = "cache:iphoneos-arm/noawait\ncache\n";
    Require(T::ParseTriggerRegistry(input, &state, &error) && state.canonicalIdentity != original &&
        state.interests[2].package == "cache", "bare selectors are not silently native-qualified");
    T::TriggerRegistryInput absent;
    Require(T::ParseTriggerRegistry(absent, &state, &error), "missing trigger directory represented");
    const std::string missing = state.canonicalIdentity;
    absent.directoryPresent = true;
    Require(T::ParseTriggerRegistry(absent, &state, &error) && state.canonicalIdentity != missing,
        "missing and present empty trigger directories differ");
    const std::string empty = state.canonicalIdentity; absent.files["Unincorp"] = "";
    Require(T::ParseTriggerRegistry(absent, &state, &error) && state.canonicalIdentity != empty,
        "missing and present empty deferred files differ");
}
void Rejections() {
    auto base = Example(); std::string error; T::TriggerRegistryState state;
    for (const auto &change : std::vector<std::pair<std::string, std::string>>{
        {"File", "relative/path cache\n"}, {"File", "/usr/lib cache\n/usr/lib cache\n"},
        {"File", "/usr/lib cache/mystery\n"}, {"File", "/usr/lib cache:*\n"},
        {"File", "/usr/lib cache:-invalid\n"}, {"File", "/usr/lib cache:iphoneos-arm64:all\n"},
        {"File", "/usr/lib cache\n\n"}, {"File", "/usr//lib cache\n"},
        {"update-cache", "cache\ncache/noawait\n"}, {"update-cache", "cache/*\n"},
        {"Unincorp", "update-cache\n"}, {"Unincorp", "update-cache requester/all\n"},
        {"Unincorp", "update-cache --\n"}, {"Unincorp", "update-cache Requester\n"},
        {"Unincorp", "update-cache legacy_name\n"}, {"has_underscore", "cache\n"},
        {"Unincorp", "update-cache requester"}, {"Lock", "unrecognized"},
        {"Unincorp.new", ""}, {"../escape", "cache\n"}}) {
        auto input = base; input.files[change.first] = change.second;
        Require(!T::ParseTriggerRegistry(input, &state, &error) && !error.empty() &&
            state.canonicalIdentity.empty() && state.interests.empty(), "malformed/unsupported input fails without partial state");
    }
    auto input = base; input.directoryPresent = false;
    Require(!T::ParseTriggerRegistry(input, &state, &error), "absent directory cannot contain claimed records");
    input = base; input.files["Unincorp"] = std::string("update-cache requester\0hidden\n", 30);
    Require(!T::ParseTriggerRegistry(input, &state, &error), "NUL cannot hide a deferred directive");
    input = base; input.files["Unincorp"] = std::string(T::MaximumDeferredTriggerBytes + 1, '#');
    Require(!T::ParseTriggerRegistry(input, &state, &error) && error == "provider_trigger_evidence_limit", "deferred byte ceiling");
    input = base; input.files["File"] = "/" + std::string(1020, 'x') + " cache\n";
    Require(!T::ParseTriggerRegistry(input, &state, &error), "native line reader bound");
    input = T::TriggerRegistryInput(); input.directoryPresent = true;
    for (std::size_t i = 0; i <= T::MaximumTriggerRegistryFiles; ++i) input.files["trigger-" + std::to_string(i)] = "";
    Require(!T::ParseTriggerRegistry(input, &state, &error), "registry membership ceiling");
    input = T::TriggerRegistryInput(); input.directoryPresent = true;
    std::string entries;
    for (std::size_t i = 0; i <= T::MaximumTriggerRelations; ++i) entries += "cache\n";
    input.files["named"] = entries;
    Require(!T::ParseTriggerRegistry(input, &state, &error), "duplicate relations still count toward processing ceiling");
}
void NativeLegacyNames() {
    T::TriggerRegistryInput input; input.directoryPresent = true;
    input.files["X-Cache"] = "Legacy_Name:ARM64\nqualified:any\nqualified:native\n";
    input.files["x"] = "a\n";
    input.files["File"] = "/usr/share/图标 cache\n";
    input.files["Unincorp"] = "X-Cache requester:any -\n";
    T::TriggerRegistryState state; std::string error;
    Require(T::ParseTriggerRegistry(input, &state, &error) && state.interests.size() == 5 &&
        state.interests[0].trigger == "/usr/share/图标" && state.interests[1].trigger == "X-Cache" &&
        state.interests[1].package == "Legacy_Name:ARM64" && state.interests[2].package == "qualified:any" &&
        state.interests[3].package == "qualified:native" && state.interests[4].trigger == "x" && state.interests[4].package == "a",
        "native uppercase, legacy package underscore and single-letter names are preserved without resolving qualifiers");
}
}
int main() { FormatsAndIdentity(); Rejections(); NativeLegacyNames(); std::cout << "trigger-evidence tests passed\n"; }
