/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoverySnapshot.hpp"
#include "Cydia/AptProviderSelection.hpp"
#include <cstdlib>
#include <iostream>

namespace {
namespace R = CydiaAPT::Recovery;
void Require(bool value, const char *message) { if (!value) { std::cerr << message << '\n'; std::abort(); } }
R::Authority Fixture() {
    R::Authority a;
    a.identity.configuration = std::string(64, 'a'); a.identity.policy = std::string(64, 'b');
    a.identity.methods = std::string(64, 'c'); a.identity.libraries = std::string(64, 'd');
    a.identity.frontend = std::string(64, 'e'); a.identity.dependencies = std::string(64, 'f');
    auto &d = a.runtime; d.origin = CydiaAPT::RuntimeDescriptorOrigin::Embedded;
    d.architecture = "iphoneos-arm64"; d.registeredArchitectures = {d.architecture, "iphoneos-arm64e"};
    d.acquisitionArchitectures = {d.architecture, "iphoneos-arm64e", "all"};
    d.sourceListPath = "/fixture/apt/sources.list"; d.sourcePartsDirectory = "/fixture/apt/sources.list.d";
    d.managedSourceListPath = d.sourcePartsDirectory + "/cydia.list";
    d.dpkgExecutablePath = "/fixture/bin/dpkg"; d.dpkgQueryExecutablePath = "/fixture/bin/dpkg-query";
    d.dpkgDebExecutablePath = "/fixture/bin/dpkg-deb"; d.gpgExecutablePath = "/fixture/bin/gpg";
    d.privilegedHelperPath = "/fixture/libexec/cydo"; d.dpkgAdminDirectory = "/fixture/dpkg";
    d.dpkgRootDirectory = "/"; d.packageInstallPrefix = "/var/jb"; d.dpkgChrootDirectory = "/";
    d.extendedStatesPath = "/fixture/apt/extended_states"; d.methodsDirectory = "/fixture/libexec/recovery-methods";
    d.listsDirectory = "/fixture/cache/lists"; d.trustedKeyringPath = "/fixture/apt/trusted.gpg";
    d.trustedKeyringPartsDirectory = "/fixture/apt/trusted.gpg.d";
    d.repositorySecurityMode = CydiaAPT::RepositorySecurityMode::Warning; d.mutationEnvironmentValid = true;
    auto &s = a.startup; s.architecture = d.architecture; s.aptConfigDirectory = "/fixture/apt";
    s.methodsDirectory = d.methodsDirectory; s.cacheDirectory = s.stateDirectory = "/fixture/cache";
    s.listsDirectory = d.listsDirectory; s.logDirectory = "/fixture/log"; s.dpkgStatusPath = "/fixture/dpkg/status";
    s.bootstrapExtendedStatesPath = d.extendedStatesPath; s.dpkgPath = s.helperPath = d.privilegedHelperPath;
    s.nativeDpkgPath = d.dpkgExecutablePath; s.packageInstallPrefix = d.packageInstallPrefix;
    s.privateRuntimeConfigurationPath = "/fixture/runtime.conf"; s.dpkgDataDirectory = "/fixture/share/dpkg";
    s.dpkgExecutableSearchPath = a.executableSearchPath = "/fixture/bin:/usr/bin:/bin";
    s.translation = "zh_CN"; s.languages = "zh_CN,en"; s.maxParallel = 3;
    s.repositorySecurityMode = d.repositorySecurityMode;
    a.executable = "/fixture/libexec/cydia-recovery"; a.cacheDirectory = s.cacheDirectory;
    a.acquisitionSearchPath = "/fixture/libexec/recovery-bin:" + a.executableSearchPath;
    a.archivesDirectory = "/fixture/cache/archives"; a.logDirectory = s.logDirectory;
    a.configuration = "APT::Architecture \"iphoneos-arm64\";\n";
    a.configuredSecurity["Acquire::Check-Valid-Until"] = "false";
    for (const auto *path : {&a.executable, &d.privilegedHelperPath, &d.dpkgExecutablePath, &d.dpkgQueryExecutablePath, &d.dpkgDebExecutablePath}) {
        R::Component c; c.path = *path; c.sha256 = std::string(64, '1'); c.executable = true; a.components.push_back(c);
    }
    return a;
}
void RoundtripAndAdmission() {
    auto authority = Fixture(); R::Snapshot value, decoded;
    Require(R::MakeSnapshot(authority, std::string(64, '2'), &value), "complete authority creates bounded snapshot");
    const auto bytes = R::SerializeSnapshot(value);
    Require(!bytes.empty() && R::ParseSnapshot(bytes, &decoded) && R::SerializeSnapshot(decoded) == bytes, "snapshot roundtrip preserves all values");
    Require(decoded.runtime.origin == CydiaAPT::RuntimeDescriptorOrigin::Embedded && decoded.runtime.binding.session.empty() &&
        decoded.configuredSecurity == authority.configuredSecurity && decoded.configuration == authority.configuration &&
        decoded.archivesDirectory == authority.archivesDirectory &&
        decoded.executableSearchPath == authority.executableSearchPath &&
        decoded.acquisitionSearchPath == authority.acquisitionSearchPath,
        "snapshot preserves clean policy and separate execution paths without a fabricated session");
    const auto environment = R::SnapshotEnvironment(decoded);
    Require(environment.nativeArchitecture == "iphoneos-arm64" && environment.registeredArchitectures.size() == 2 &&
        environment.paths.dpkg == authority.runtime.dpkgExecutablePath && environment.configurationIdentity == authority.identity.configuration,
        "worker environment comes from exact parent snapshot");
    R::RequestAuthority request = R::AuthorityRequest(decoded), parsed;
    const auto requestBytes = R::SerializeRequestAuthority(request);
    Require(!requestBytes.empty() && R::ParseRequestAuthority(requestBytes, &parsed) &&
        R::SerializeRequestAuthority(parsed) == requestBytes && parsed.preferences.securityPreference.empty(), "absent security choice stays absent");
    CydiaAPT::Provider::RegistrationIdentity registration;
    Require(!CydiaAPT::Provider::ParseRegistrationIdentity(requestBytes, &registration) &&
        !R::ParseRequestAuthority(CydiaAPT::Provider::SerializeRegistrationIdentity(registration), &parsed), "authority tags cannot be confused");
    authority.securityPreferenceExplicit = true; authority.runtime.repositorySecurityMode = authority.startup.repositorySecurityMode = CydiaAPT::RepositorySecurityMode::Distribution;
    Require(R::MakeSnapshot(authority, value.packageStateIdentity, &decoded) &&
        R::AuthorityRequest(decoded).preferences.securityPreference == "distribution", "explicit active-APT policy remains explicit");
    authority.unresolvedFields = {"dependencyClosure"};
    Require(!R::MakeSnapshot(authority, value.packageStateIdentity, &decoded), "unresolved closure cannot become a launch capsule");
    authority = Fixture(); authority.runtime.mutationEnvironmentValid = false;
    Require(!R::MakeSnapshot(authority, value.packageStateIdentity, &decoded), "invalid mutation environment cannot launch");
    authority = Fixture(); authority.identity.dependencies.clear();
    Require(!R::MakeSnapshot(authority, value.packageStateIdentity, &decoded), "missing dependency proof cannot launch");
    for (unsigned variant = 0; variant != 14; ++variant) {
        auto invalid = value;
        if (variant == 0) invalid.components.push_back(invalid.components.front());
        if (variant == 1) invalid.components.front().executable = false;
        if (variant == 2) invalid.components.front().sha256[0] = 'x';
        if (variant == 3) invalid.runtime.binding.session = std::string(64, '0');
        if (variant == 4) invalid.runtime.origin = CydiaAPT::RuntimeDescriptorOrigin::External;
        if (variant == 5) invalid.archivesDirectory = "/fixture/../archives";
        if (variant == 6) invalid.configuredSecurity["Dir::Bin::dpkg"] = "/untrusted";
        if (variant == 7) invalid.configuration.assign(R::MaximumConfigurationBytes + 1, 'x');
        if (variant == 8) invalid.packageStateIdentity = "version text";
        if (variant == 9) invalid.executableSearchPath = "/fixture/bin:";
        if (variant == 10) invalid.acquisitionSearchPath = invalid.executableSearchPath;
        if (variant == 11) invalid.acquisitionSearchPath = "/other/recovery-bin:" + invalid.executableSearchPath;
        if (variant == 12) invalid.acquisitionSearchPath += ":/extra/tools";
        if (variant == 13) invalid.acquisitionSearchPath.clear();
        Require(R::SerializeSnapshot(invalid).empty(), "invalid capsule rejected before serialization");
    }
    for (std::size_t length = 0; length < bytes.size(); ++length)
        Require(!R::ParseSnapshot(bytes.substr(0, length), &decoded), "truncated capsule rejected");
    Require(!R::ParseSnapshot(bytes + 'x', &decoded) && !R::ParseSnapshot(std::string(R::MaximumSnapshotBytes + 1, 'x'), &decoded),
        "trailing/oversized capsule rejected");
    auto corrupt = bytes; const auto digest = corrupt.find(std::string(64, 'a'));
    Require(digest != std::string::npos, "fixture identity exists in wire bytes"); corrupt[digest] = 'g';
    Require(!R::ParseSnapshot(corrupt, &decoded), "invalid digest rejected on decode");
}
}
int main() { RoundtripAndAdmission(); std::cout << "[apt-recovery-snapshot] PASS\n"; }
