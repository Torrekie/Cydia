/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderNativeDpkgAuthority.hpp"
#include "Cydia/AptRecoveryDependencyInspector.hpp"
#include "Cydia/AptProviderComponentCapture.hpp"
#include "Cydia/ExtendedState.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <sys/stat.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
const std::size_t DeclarationLimit = 1024 * 1024;
#if defined(CYDIA_NATIVE_DPKG_AUTHORITY_TESTING)
std::vector<std::string> testPaths;
#endif
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Path(const std::string &path) {
    if (path.size() < 2 || path.size() > 4096 || path.front() != '/' || path.back() == '/') return false;
    for (unsigned char c : path) if (c < 32 || c == 127) return false;
    std::size_t start = 1;
    while (start < path.size()) {
        const auto end = path.find('/', start); const auto part = path.substr(start, end == std::string::npos ? end : end-start);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break; start = end+1;
    }
    return true;
}
bool Digest(const std::string &value) { return value.size() == 64 && value.find_first_not_of("0123456789abcdef") == std::string::npos; }
bool Fields(const std::string &bytes, std::vector<std::string> *fields, std::size_t maximum = 4096) {
    if (!fields || bytes.size() > DeclarationLimit) return false;
    fields->clear(); std::size_t at = 0;
    while (at < bytes.size()) {
        const auto begin = at; std::size_t length = 0;
        while (at < bytes.size() && bytes[at] >= '0' && bytes[at] <= '9') {
            const unsigned digit = bytes[at++] - '0';
            if (at-begin > 8 || length > (DeclarationLimit-digit)/10) return false;
            length = length*10 + digit;
        }
        if (at == begin || (at-begin > 1 && bytes[begin] == '0') || at == bytes.size() || bytes[at++] != ':' ||
            length >= bytes.size()-at) return false;
        fields->push_back(bytes.substr(at, length)); at += length;
        if (bytes[at++] != ',' || fields->size() > maximum) return false;
    }
    return true;
}
struct Declaration {
    std::vector<std::string> files, directories, optionalFiles, optionalDirectories, components, commands;
    std::map<std::string, std::set<std::string>> executors;
    std::map<std::string, std::vector<std::string>> successors;
};
bool Paths(const std::string &bytes, std::vector<std::string> *paths) {
    if (!Fields(bytes, paths, MaximumTransactionComponents)) return false;
    std::set<std::string> unique;
    for (const auto &path : *paths) if (!Path(path) || !unique.insert(path).second) return false;
    return true;
}
bool Parse(const std::string &bytes, Declaration *result) {
    std::vector<std::string> fields, pairs;
    if (!result || !Fields(bytes, &fields, 10) || fields.size() != 10 || fields[0] != "CYDIA-NATIVE-DPKG-1" ||
        !Fields(fields[1], &pairs, 1024) || pairs.empty() || pairs.size()%2) return false;
    Declaration value;
    for (std::size_t i=0; i<pairs.size(); i+=2)
        if (!Path(pairs[i]) || !Digest(pairs[i+1]) || !value.executors[pairs[i]].insert(pairs[i+1]).second) return false;
    if (!Paths(fields[2], &value.files) || !Paths(fields[3], &value.directories) ||
        !Paths(fields[4], &value.optionalFiles) || !Paths(fields[5], &value.optionalDirectories) ||
        !Paths(fields[6], &value.commands) || !Paths(fields[7], &value.components) || value.components.empty() ||
        !Fields(fields[8], &pairs, 1024) || pairs.size()%2 || fields[9] != "complete-native-graph") return false;
    for (std::size_t i=0; i<pairs.size(); i+=2) {
        const auto colon = pairs[i].find(':');
        if (colon == std::string::npos || !CydiaRuntime::ValidPackageName(pairs[i].substr(0,colon)) ||
            !CydiaRuntime::ValidArchitectureName(pairs[i].substr(colon+1)) || pairs[i].substr(colon+1) == "any" ||
            pairs[i].substr(colon+1) == "native") return false;
        std::vector<std::string> paths;
        if (!Paths(pairs[i+1], &paths) || paths.empty() || !value.successors.emplace(pairs[i], paths).second) return false;
    }
    for (const auto &executor : value.executors)
        if (std::find(value.components.begin(), value.components.end(), executor.first) == value.components.end()) return false;
    for (const auto &command : value.commands) if (!value.executors.count(command) ||
        std::find(value.components.begin(), value.components.end(), command) == value.components.end()) return false;
    *result = std::move(value); return true;
}
// A narrow refusal for an already unsupported effect, not an effective native
// policy parser. dpkg reads configuration before argv, so omitting its command
// line switch does not disable a configured automatic deconfiguration.
bool ConfiguredAutoDeconfigure(const std::string &bytes) {
    std::size_t at = 0;
    while (at < bytes.size()) {
        const auto newline = bytes.find('\n', at);
        const auto end = newline == std::string::npos ? bytes.size() : newline;
        std::size_t begin = at;
        while (begin < end && (bytes[begin] == ' ' || bytes[begin] == '\t' || bytes[begin] == '\r' ||
            bytes[begin] == '\v' || bytes[begin] == '\f')) ++begin;
        std::size_t token = begin;
        while (token < end && ((bytes[token] >= 'a' && bytes[token] <= 'z') ||
            (bytes[token] >= 'A' && bytes[token] <= 'Z') || (bytes[token] >= '0' && bytes[token] <= '9') || bytes[token] == '-')) ++token;
        if (token - begin >= 2 && bytes.compare(begin, 2, "--") == 0) begin += 2;
        if (token - begin == 16 && bytes.compare(begin, 16, "auto-deconfigure") == 0) return true;
        at = newline == std::string::npos ? bytes.size() : newline + 1;
    }
    return false;
}
struct Graph {
    std::vector<P::Evidence> inputs; std::set<std::string> expanded;
    std::size_t bytes = 0; std::function<bool()> cancelled;
    bool Add(const std::string &path, bool directory, bool optional, std::string *error, unsigned depth = 0) {
        if ((cancelled && cancelled()) || depth > 16 || inputs.size() >= 4096) return Fail(error, "provider_native_configuration_limit");
        P::Error ignored; P::Evidence input;
        if (!P::CaptureEvidence(path, directory, optional, &input, &ignored)) return Fail(error, "provider_native_configuration_unprotected");
        bytes += input.bytes.size(); if (bytes > 32 * 1024 * 1024) return Fail(error, "provider_native_configuration_limit");
        inputs.push_back(input);
        if (directory && !input.absent && expanded.insert(path).second) for (const auto &leaf : input.entries) {
            const auto child = path+'/'+leaf; struct stat state{};
            if (stat(child.c_str(), &state) || (!S_ISREG(state.st_mode) && !S_ISDIR(state.st_mode)) ||
                !Add(child, S_ISDIR(state.st_mode), false, error, depth+1)) return false;
        }
        return true;
    }
};
}
bool ResolveNativeDpkgAuthority(const BrokerEnvironment &selected, const ReviewedTransaction &review,
    NativeDpkgAuthority *result, std::string *error, const std::function<bool()> &cancelled) {
    return ResolveNativeDpkgAuthority(CydiaRuntime::PackageDatabasePaths::Current(), selected, review, result, error, cancelled);
}
bool ResolveNativeDpkgAuthority(const CydiaRuntime::PackageDatabasePaths &paths, const BrokerEnvironment &selected,
    const ReviewedTransaction &review, NativeDpkgAuthority *result, std::string *error, const std::function<bool()> &cancelled) {
    if (!result) return Fail(error, "provider_native_configuration_invalid");
    *result = NativeDpkgAuthority();
    const auto &data = paths.DpkgDataDirectory(); const auto slash = data.rfind('/');
    if (slash == std::string::npos) return Fail(error, "provider_native_configuration_missing");
    P::Evidence declaration; P::Error ignored; bool found = false;
    std::vector<std::string> locations{paths.CydiaStateDirectory()+"/native-dpkg.conf", data.substr(0,slash)+"/cydia/native-dpkg.conf"};
#if defined(CYDIA_NATIVE_DPKG_AUTHORITY_TESTING)
    if (!testPaths.empty()) locations = testPaths;
#endif
    for (const auto &path : locations) {
        if (cancelled && cancelled()) return Fail(error, "provider_cancelled");
        struct stat state{};
        if (lstat(path.c_str(), &state)) { if (errno == ENOENT) continue; return Fail(error, "provider_native_configuration_unreadable"); }
        if (!P::CaptureEvidence(path, false, false, &declaration, &ignored) || declaration.bytes.size() > DeclarationLimit)
            return Fail(error, "provider_native_configuration_unprotected");
        found = true; break;
    }
    if (!found) return Fail(error, "provider_native_configuration_missing");
    Declaration parsed;
    if (!Parse(declaration.bytes, &parsed)) return Fail(error, "provider_native_configuration_invalid");
    NativeDpkgAuthority value; value.executorGenerations = parsed.executors;
    value.commands = parsed.commands; value.componentPaths = parsed.components;
    for (const auto &tool : {selected.environment.dpkg, selected.environment.dpkgQuery})
        if (!parsed.executors.count(tool) || std::find(parsed.components.begin(), parsed.components.end(), tool) == parsed.components.end())
            return Fail(error, "provider_native_executor_undeclared");
    Graph graph; graph.cancelled = cancelled; graph.inputs.push_back(declaration);
    for (const auto &path : parsed.files) if (!graph.Add(path, false, false, error)) return false;
    for (const auto &path : parsed.directories) if (!graph.Add(path, true, false, error)) return false;
    for (const auto &path : parsed.optionalFiles) if (!graph.Add(path, false, true, error)) return false;
    for (const auto &path : parsed.optionalDirectories) if (!graph.Add(path, true, true, error)) return false;
    if (std::any_of(review.execution.actions.begin(), review.execution.actions.end(),
        [](const ReviewedAction &action) { return action.action == ExecutionAction::Unpack; }))
        for (std::size_t i = 1; i < graph.inputs.size(); ++i)
            if (!graph.inputs[i].absent && !graph.inputs[i].directory && ConfiguredAutoDeconfigure(graph.inputs[i].bytes))
                return Fail(error, "provider_native_auto_deconfigure_unsupported");
    for (const auto &archive : review.execution.archives) {
        const auto match = parsed.successors.find(archive.package.package+':'+archive.package.architecture);
        if (match != parsed.successors.end()) value.successorPaths.emplace(archive.identifier, match->second);
    }
    std::vector<std::string> fields{"CYDIA-NATIVE-DPKG-CONFIGURATION-1", selected.executableSearchPath,
        selected.environment.dpkgRoot, selected.environment.dpkgAdmin};
    for (const auto &input : graph.inputs) fields.push_back(P::SerializeSnapshotEvidence(input));
    const auto bytes = P::SerializeFields(fields); Hashes hash(Hashes::SHA256SUM);
    if (!hash.Add(bytes.data(), bytes.size()) || !P::RecheckEvidence(graph.inputs, &ignored))
        return Fail(error, "provider_native_configuration_changed");
    value.configurationIdentity = hash.GetHashString(Hashes::SHA256SUM).HashValue();
    value.configurationEvidence = std::move(graph.inputs);
    if (!Recovery::CaptureTransactionPlatformIdentity(&value.platformIdentity, error)) return false;
    std::vector<InstalledComponentEvidence> components;
    for (const auto &path : value.componentPaths) {
        InstalledComponentEvidence observed;
        if (!CaptureTransactionComponent(path, &observed, error, cancelled)) return false;
        components.push_back(std::move(observed));
    }
    if (!RevalidateNativeDpkgAuthority(value, components, error)) return false;
    *result = std::move(value); if (error) error->clear(); return true;
}
bool RevalidateNativeDpkgAuthority(const NativeDpkgAuthority &authority,
    const std::vector<InstalledComponentEvidence> &components, std::string *error) {
    P::Error ignored;
    if (!Digest(authority.configurationIdentity) || !Digest(authority.platformIdentity) ||
        authority.configurationEvidence.empty() || !P::RecheckEvidence(authority.configurationEvidence, &ignored))
        return Fail(error, "provider_native_configuration_changed");
    std::map<std::string, const InstalledComponentEvidence *> observed;
    for (const auto &component : components)
        if (!observed.emplace(component.file.metadata.path, &component).second) return Fail(error, "provider_component_origin_invalid");
    for (const auto &executor : authority.executorGenerations) {
        const auto file = observed.find(executor.first);
        if (file == observed.end() || !executor.second.count(file->second->file.sha256) || !(file->second->file.metadata.mode & 0111))
            return Fail(error, "provider_native_executor_generation_unsupported");
    }
    if (error) error->clear(); return true;
}
bool CaptureNativeDpkgClosure(const NativeDpkgAuthority &authority, const std::string &executable,
    const std::vector<InstalledComponentEvidence> &components, ComponentClosureEvidence *proof,
    std::string *error, const std::function<bool()> &cancelled) {
    if (!proof) return Fail(error, "provider_component_closure_unverified");
    *proof = ComponentClosureEvidence();
    if (!authority.executorGenerations.count(executable)) return Fail(error, "provider_native_executor_undeclared");
    if (!RevalidateNativeDpkgAuthority(authority, components, error)) return false;
    // Native configured commands must retain complete admitted closures too.
    for (const auto &command : authority.commands) {
        ComponentClosureEvidence checked;
        if (!Recovery::InspectTransactionComponentClosure(command, components, authority.configurationIdentity,
            authority.platformIdentity, &checked, error, cancelled)) return false;
    }
    return Recovery::InspectTransactionComponentClosure(executable, components, authority.configurationIdentity,
        authority.platformIdentity, proof, error, cancelled);
}
#if defined(CYDIA_NATIVE_DPKG_AUTHORITY_TESTING)
void SetNativeDpkgAuthorityTestPaths(const std::string &primary, const std::string &fallback) {
    testPaths = {primary, fallback};
}
#endif
}}
