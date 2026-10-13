/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBrokerPrivileged.hpp"
#include "Cydia/PackageArchiveReader.hpp"
#include "Cydia/RuntimeState.hpp"
#include <apt-pkg/fileutl.h>
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cstdlib>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
bool Fail(P::Error *error, const char *code) {
    if (error) { error->code = code; error->message = "The reviewed provider operation could not be verified."; }
    return false;
}
bool SameExpected(const P::ExpectedEnvironment &a, const P::ExpectedEnvironment &b) {
    std::string left, right;
    return Encode(a, &left) && Encode(b, &right) && left == right;
}
bool ParentOwns(const P::Environment &environment, pid_t parent) {
    P::Error ignored; pid_t owner = 0;
    return parent > 1 && getppid() == parent && P::FrontendLockOwner(environment.dpkgAdmin, &owner, &ignored) && owner == parent;
}
class Staging {
public:
    std::string directory;
    std::vector<std::string> files;
    ~Staging() { for (const auto &file : files) unlink(file.c_str()); if (!directory.empty()) rmdir(directory.c_str()); }
    bool Create(const CydiaRuntime::PackageDatabasePaths &paths, P::Error *error) {
        const std::string base = paths.CydiaStateDirectory();
        if (!P::ValidateRootOwnedPath(base, true, false, error)) return false;
        std::string pattern = base + "/.provider-transaction-XXXXXX";
        std::vector<char> bytes(pattern.begin(), pattern.end()); bytes.push_back('\0');
        char *created = mkdtemp(bytes.data());
        if (!created) return Fail(error, "provider_archive_staging_failed");
        directory = created;
        return chmod(directory.c_str(), 0700) == 0 && P::ValidateRootOwnedPath(directory, true, false, error);
    }
    bool Copy(const ArchiveManifest &archive, std::string *destination, P::Error *error) {
        const int input = open(archive.path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (input < 0) return Fail(error, "provider_archive_unavailable");
        FileFd source(input, true); struct stat identity;
        if (fstat(input, &identity) != 0 || !S_ISREG(identity.st_mode) || identity.st_size < 0 ||
            static_cast<std::uint64_t>(identity.st_size) != archive.size || archive.size == 0 ||
            archive.size > CydiaPackages::ArchiveLimits().maxStreamBytes)
            return Fail(error, "provider_archive_size_changed");
        *destination = directory + '/' + std::to_string(files.size()) + ".deb";
        const int output = open(destination->c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (output < 0) return Fail(error, "provider_archive_staging_failed");
        files.push_back(*destination); FileFd copy(output, true);
        std::uint64_t remaining = archive.size; char buffer[32768];
        while (remaining) {
            const std::size_t count = static_cast<std::size_t>(std::min<std::uint64_t>(remaining, sizeof(buffer)));
            if (!source.Read(buffer, count) || !copy.Write(buffer, count)) return Fail(error, "provider_archive_staging_failed");
            remaining -= count;
        }
        if (fsync(output) != 0 || !copy.Close()) return Fail(error, "provider_archive_staging_failed");
        HashStringList expected; bool strong = false;
        for (const auto &hash : archive.hashes) {
            const std::size_t size = hash.first == "SHA256" ? 64 : hash.first == "SHA512" ? 128 :
                hash.first == "SHA1" ? 40 : hash.first == "MD5Sum" ? 32 : 0;
            if (!size || hash.second.size() != size || hash.second.find_first_not_of("0123456789abcdef") != std::string::npos)
                return Fail(error, "provider_archive_hash_invalid");
            strong = strong || hash.first == "SHA256" || hash.first == "SHA512";
            expected.push_back(HashString(hash.first, hash.second));
        }
        if (!strong) return Fail(error, "provider_archive_hash_missing");
        FileFd checked(*destination, FileFd::ReadOnly); Hashes actual(expected);
        if (!actual.AddFD(checked) || checked.Failed() || actual.GetHashStringList() != expected)
            return Fail(error, "provider_archive_hash_changed");
        return P::ValidateRootOwnedPath(*destination, false, false, error);
    }
};
}
bool ResolveBrokerRequest(const CydiaRuntime::PackageDatabasePaths &paths, const P::Request &request,
                          RegisteredProviderEnvironment *selected, std::string *payload, P::Error *error) {
    std::vector<std::string> fields; RegistrationIdentity authority;
    if (!selected || !payload || !Decode(request.payload, &fields) || fields.size() != 3 ||
        fields[0] != "CYDIA-BROKER-1" || !ParseRegistrationIdentity(fields[1], &authority) ||
        !ResolveRegisteredProviderEnvironment(paths, authority.registrationPath, &authority, selected, error) ||
        !SameExpected(request.expected, selected->environment)) return Fail(error, "provider_authority_changed");
    *payload = fields[2]; return true;
}
bool ResolveBrokerRequest(const CydiaRuntime::PackageDatabasePaths &paths, const P::Request &request,
    uid_t uid, BrokerEnvironment *selected, std::string *payload, P::Error *error,
    const Recovery::DependencyInspector &inspect) {
    std::vector<std::string> fields;
    if (!selected || !payload || !Decode(request.payload, &fields) || fields.size() != 3)
        return Fail(error, "provider_authority_changed");
    BrokerEnvironment value;
    if (fields[0] == "CYDIA-BROKER-1") {
        RegisteredProviderEnvironment registered;
        if (!ResolveBrokerRequest(paths, request, &registered, payload, error)) return false;
        value = BrokerEnvironment(registered);
    } else if (fields[0] == "CYDIA-RECOVERY-BROKER-1") {
        Recovery::RequestAuthority authority; Recovery::Authority captured;
        if (!Recovery::ParseRequestAuthority(fields[1], &authority)) return Fail(error, "recovery_authority_invalid");
        if (!Recovery::ResolveInstalledAuthority(paths, uid, authority.preferences, &authority.identity, &captured, error, inspect)) return false;
        if (!SameExpected(request.expected, captured.environment)) return Fail(error, "recovery_authority_changed");
        value = BrokerEnvironment(captured); *payload = fields[2];
    } else return Fail(error, "provider_authority_changed");
    *selected = std::move(value); return true;
}
bool ExecuteBrokerDpkg(const CydiaRuntime::PackageDatabasePaths &paths,
    const BrokerEnvironment &selected, pid_t parent, const BrokerDpkgRequest &request,
    const std::function<int(const std::string &, const std::vector<std::string> &)> &execute,
    int *exitCode, P::Error *error) {
    const auto &environment = selected.environment; DpkgState state; std::string reason;
    if (!exitCode || !execute || !ParentOwns(environment, parent) ||
        !CaptureDpkgStateForParent(environment, parent, &state, &reason) || state.packageStateIdentity != request.stateIdentity ||
        !P::ValidateDpkgArguments(environment, request.arguments, error) ||
        request.action == ExecutionAction::Deconfigure)
        return Fail(error, "provider_execution_state_changed");
    const auto &prefix = selected.runtime.dpkgOptions;
    if (request.arguments.size() < prefix.size() || !std::equal(prefix.begin(), prefix.end(), request.arguments.begin()))
        return Fail(error, "provider_dpkg_options_changed");
    auto arguments = request.arguments; Staging staging; std::set<std::string> pathsSeen, identities;
    std::map<std::string, std::string> decoders;
    if (!request.archives.empty() && !CydiaPackages::ResolveTrustedArchiveDecoders(
        selected.archiveDecoderSearchPath, &decoders, &reason)) return Fail(error, "provider_archive_decoder_unavailable");
    if (!request.archives.empty() && (request.action != ExecutionAction::Unpack || !staging.Create(paths, error))) return false;
    for (const auto &archive : request.archives) {
        if (!pathsSeen.insert(archive.path).second || !identities.insert(archive.identifier).second ||
            archive.layout.prefix != selected.runtime.packageInstallPrefix)
            return Fail(error, "provider_archive_manifest_changed");
        std::string staged;
        if (!staging.Copy(archive, &staged, error)) return false;
        const auto inspection = CydiaPackages::InspectPackageArchiveWithDecoders(staged,
            {archive.package.package, archive.package.version, archive.package.architecture}, archive.layout, decoders);
        if (!inspection.identityVerified || !inspection.complete ||
            (inspection.status != CydiaPackages::ArchivePolicyStatus::Accepted &&
             !(inspection.status == CydiaPackages::ArchivePolicyStatus::Unverified &&
               request.acceptedArchiveWarnings.count(archive.identifier)))) return Fail(error, "provider_archive_layout_changed");
        unsigned replacements = 0;
        for (std::size_t i = prefix.size(); i < arguments.size(); ++i)
            if (arguments[i] == archive.path) { arguments[i] = staged; ++replacements; }
        if (replacements != 1) return Fail(error, "provider_archive_operand_changed");
    }
    if (request.action == ExecutionAction::Unpack && request.archives.empty()) return Fail(error, "provider_archive_manifest_missing");
    std::string current;
    if (!P::RecheckEvidence(environment.evidence, error) || !ParentOwns(environment, parent) ||
        !P::RuntimeSnapshot(environment, &current, error) || current != request.stateIdentity)
        return Fail(error, "provider_execution_state_changed");
    if (!P::BindDpkgArguments(environment, arguments, &arguments, error)) return false;
    *exitCode = execute(environment.dpkg, arguments);
    return true;
}
bool ExecuteBrokerDpkg(const CydiaRuntime::PackageDatabasePaths &paths,
    const RegisteredProviderEnvironment &selected, pid_t parent, const BrokerDpkgRequest &request,
    const std::function<int(const std::string &, const std::vector<std::string> &)> &execute,
    int *exitCode, P::Error *error) {
    const BrokerEnvironment value(selected);
    return ExecuteBrokerDpkg(paths, value, parent, request, execute, exitCode, error);
}
}} // namespace CydiaAPT::Provider
