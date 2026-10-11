/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeState.hpp"
#include "Cydia/ApplicationIdentity.hpp"
#include "Cydia/SourceDocumentCommit.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include <algorithm>
#include <cerrno>
#include <dirent.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

using namespace CydiaRuntime::Privileged;
namespace {
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[runtime-state] FAIL: " << message << '\n'; std::exit(1);
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << bytes; file.close(); Require(file.good() && chmod(path.c_str(), mode) == 0, "write fixture");
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    Require(file.good(), "read fixture");
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
bool FixtureCapture(const std::string &path, bool directory, bool absent, Evidence *input, Error *) {
    *input = Evidence(); input->path = path; input->directory = directory;
    if (lstat(path.c_str(), &input->identity) != 0) { input->absent = errno == ENOENT; return input->absent && absent; }
    if (!directory) { input->bytes = Read(path); return S_ISREG(input->identity.st_mode); }
    DIR *stream(opendir(path.c_str())); if (stream == NULL) return false;
    while (struct dirent *entry = readdir(stream))
        if (std::string(entry->d_name) != "." && std::string(entry->d_name) != "..") input->entries.push_back(entry->d_name);
    closedir(stream); std::sort(input->entries.begin(), input->entries.end()); return true;
}
bool FixtureSourceCapture(const std::string &path, bool directory, bool absent, Evidence *input, Error *error) {
    struct stat leaf;
    if (lstat(path.c_str(), &leaf) == 0 && S_ISLNK(leaf.st_mode)) return CaptureSourceEvidence(path, directory, absent, input, error);
    return FixtureCapture(path, directory, absent, input, error);
}
struct Fixture {
    std::string root, status, original;
    Environment environment;
    Fixture() {
        char pattern[] = "/tmp/cydia-native-state.XXXXXX";
        const char *created(mkdtemp(pattern)); Require(created != NULL, "create disposable root"); root = created;
        environment.dpkgRoot = root; environment.dpkgAdmin = root + "/admin";
        environment.dpkg = root + "/dpkg"; environment.extendedStates = root + "/extended_states";
        Require(std::filesystem::create_directory(environment.dpkgAdmin), "create disposable dpkg database");
        status = "Package: target\nArchitecture: amd64\nVersion: 1\nStatus: install ok installed\n\n";
        Write(environment.dpkgAdmin + "/status", status);
        original = "Package: target\nArchitecture: amd64\nAuto-Installed: 1\nX-Local: keep\n\n"
            "# external manager record\nPackage: neighbor\nArchitecture: i386\nAuto-Installed: 1\nX-Extra: unchanged\n\n";
        Write(environment.extendedStates, original, 0640);
        Write(environment.dpkg, "#!/bin/sh\n"
            "case \"$*\" in\n"
            " *--print-architecture)\n"
            "  if test -f \"$0.change-status\"; then cat \"${0%/*}/changed-status\" > \"${0%/*}/admin/status\"; fi\n"
            "  if test -f \"$0.change-state\"; then printf 'external replacement\\n' > \"${0%/*}/extended_states\"; fi\n"
            "  printf 'amd64\\n';;\n"
            " *--print-foreign-architectures) printf 'i386\\n';;\n"
            " *) exit 31;;\n"
            "esac\n", 0755);
    }
    ~Fixture() { std::filesystem::remove_all(root); }
    std::string Payload(const std::string &flag = "0") const {
        return SerializeFields({environment.extendedStates, original, "target", "amd64", flag});
    }
};
}
int main() {
    // fakeroot supplies root ownership semantics without modifying host state.
    Require(geteuid() == 0, "run this isolated privileged-boundary fixture through fakeroot");
    {
        Fixture f;
        const std::string shared(f.root + "/Applications"), bundle(shared + "/Cydia.app"), app(bundle + "/Cydia");
        Require(std::filesystem::create_directory(shared) && std::filesystem::create_directory(bundle), "create shared app fixture");
        Require(chmod(shared.c_str(), 0775) == 0 && chmod(bundle.c_str(), 0755) == 0, "bootstrap application permissions");
        Write(app, "signed application fixture", 0755);
        struct stat identity; Error error;
        Require(InspectApplicationExecutable(app, &identity), "protected app leaf permits shared administrator-writable Applications");
        Require(!ValidateRootOwnedPath(app, false, true, &error), "generic privileged tool checks retain strict parent permissions");
        Require(chmod(bundle.c_str(), 0775) == 0 && !InspectApplicationExecutable(app, &identity), "writable app bundle is rejected");
        Require(chmod(bundle.c_str(), 0755) == 0 && chmod(app.c_str(), 0775) == 0 &&
            !InspectApplicationExecutable(app, &identity), "writable app executable is rejected");
        Require(chmod(app.c_str(), 0755) == 0 && chown(app.c_str(), 501, 501) == 0 &&
            !InspectApplicationExecutable(app, &identity), "non-root app executable is rejected");
    }
    {
        Fixture f; Error error;
        const std::string sources(f.root + "/sources"), cache(f.root + "/cache"), alias(sources + "/bootstrap.list"),
            target(cache + "/provider.sources"), local(sources + "/user.list"), policy(f.root + "/source-policy");
        Require(std::filesystem::create_directory(sources) && std::filesystem::create_directory(cache), "create delegated-source fixture");
        Require(chown(cache.c_str(), 501, 501) == 0 && chmod(cache.c_str(), 0700) == 0, "private external frontend cache");
        const std::string delegated("deb https://bootstrap.invalid/ stable main\n");
        Write(target, delegated); Require(chown(target.c_str(), 501, 501) == 0 && symlink(target.c_str(), alias.c_str()) == 0,
            "root-owned source alias delegates user-owned data");
        Write(local, "deb https://user.invalid/ stable main\n");
        CydiaSources::ProtectedFileSnapshot protectedSource;
        const std::string untrustedParent(f.root + "/untrusted-sourceparts");
        Require(CydiaSources::ReadProtectedFile(local, &protectedSource) &&
            symlink(sources.c_str(), untrustedParent.c_str()) == 0 && lchown(untrustedParent.c_str(), 501, 501) == 0,
            "create untrusted lexical source-parent alias");
        Require(CydiaSources::ReplaceProtectedFile(untrustedParent + "/user.list", protectedSource, "changed\n").status ==
            CydiaSources::CommitStatus::UnsafePath && Read(local) == protectedSource.bytes,
            "root source writer refuses untrusted lexical aliases before replacement");
        const CydiaSources::EffectiveLocations locations{alias, sources};
        const auto snapshot(CydiaSources::ReadEffectiveDocuments(locations));
        Require(snapshot.ready() && snapshot.documents.size() == 2 && snapshot.documents[0].readOnly &&
            snapshot.documents[0].document.format == CydiaSources::Format::OneLine && snapshot.documents[0].document.bytes == delegated,
            "delegated source uses lexical APT format and remains visible read-only");
        CydiaSources::Mutation remove(CydiaSources::EditKind::RemoveDefinition); remove.ordinal = 0;
        Require(!CydiaSources::PlanStoredMutation(locations, snapshot.documents[0], remove).ready() &&
            !CydiaSources::PlanStoredMutation(locations, snapshot.documents[0], remove, {}, CydiaSources::Access::AdvancedSettings).ready(),
            "ordinary and advanced planners refuse edit-through aliases");
        Require(CydiaSources::PlanStoredMutation(locations, snapshot.documents[1], remove).ready(), "alias does not block unrelated source edits");
        const std::string emptyPolicy(CydiaSources::SerializeProtectionPolicy({})); Write(policy, emptyPolicy);
        CydiaSources::CommitRequest request; request.expected = snapshot.documents[1]; request.mutation = remove; request.expectedPolicy = emptyPolicy;
        Require(CydiaSources::CommitSourceRequest(locations, policy, request).succeeded() && Read(target) == delegated,
            "unrelated source commit preserves delegation and target bytes");
        Evidence evidence;
        Require(CaptureSourceEvidence(alias, false, false, &evidence, &error) && evidence.sourceInput &&
            !evidence.sourceDelegation.empty() && RecheckEvidence({evidence}, &error), "snapshot binds protected delegation and target");
        CydiaSources::ReaderGroups invalidGroups; invalidGroups.valid = false; Evidence denied;
        Require(!CaptureSourceEvidenceForReader(alias, false, false, &denied, &error, getuid(), getgid(), invalidGroups),
            "uncaptured supplementary credentials deny delegated source reads");
        f.environment.sourceList = alias; f.environment.sourceParts = sources; f.environment.preferencesParts = sources;
        std::vector<Evidence> inputs;
        Require(CaptureSnapshotInputs(f.environment, SnapshotScope::PackageState, &inputs, &error,
            FixtureCapture, CaptureSharedStateEvidence, FixtureSourceCapture), "source/pin overlap preserves per-entry source policy");
        Require(unlink(alias.c_str()) == 0 && symlink(target.c_str(), alias.c_str()) == 0 &&
            !RecheckEvidence({evidence}, &error), "same-target alias replacement invalidates earlier review");
        Require(chmod(target.c_str(), 0600) == 0 && !CaptureSourceEvidence(alias, false, false, &evidence, &error),
            "non-public delegated target is refused");
        Require(chmod(target.c_str(), 0644) == 0 && lchown(alias.c_str(), 501, 501) == 0 &&
            !CaptureSourceEvidence(alias, false, false, &evidence, &error), "user-owned source delegation is refused");
    }
    {
        Fixture f; Error error; std::string bytes;
        Require(chown(f.environment.extendedStates.c_str(), 501, 20) == 0 &&
            chmod(f.environment.extendedStates.c_str(), 0664) == 0 &&
            chown((f.environment.dpkgAdmin + "/status").c_str(), 502, 20) == 0, "external frontend state ownership");
        Require(ReadExtendedState(f.environment, &bytes, &error) && bytes == f.original,
            "read user-owned data without changing bootstrap metadata");
        const std::string alias(f.root + "/bootstrap");
        Require(symlink(f.root.c_str(), alias.c_str()) == 0, "create bootstrap parent alias");
        const std::string actual(f.environment.extendedStates);
        f.environment.extendedStates = alias + "/extended_states";
        Require(ReadExtendedState(f.environment, &bytes, &error), "root-owned bootstrap parent alias remains usable");
        Require(lchown(alias.c_str(), 501, 20) == 0 && !ReadExtendedState(f.environment, &bytes, &error),
            "user-owned parent alias cannot select protected state");
        f.environment.extendedStates = actual;
        Evidence state;
        Require(CaptureSharedStateEvidence(f.environment.extendedStates, false, false, &state, &error) &&
            state.sharedState && RecheckEvidence({state}, &error), "state evidence reuses data-only policy");
        CydiaSources::ProtectedFileSnapshot strict;
        Require(!CydiaSources::ReadProtectedFile(f.environment.extendedStates, &strict),
            "user-owned data never satisfies protected configuration policy");
        const std::string preference(f.root + "/external.pref");
        Write(preference, "Package: target\nPin: version 1\nPin-Priority: 700\n");
        Require(chown(preference.c_str(), 503, 20) == 0 &&
            CaptureSharedStateEvidence(preference, false, false, &state, &error) && RecheckEvidence({state}, &error),
            "user-owned package preferences retain snapshot evidence");
        Require(CommitExtendedState(f.environment, f.Payload(), &error), "commit external frontend manual flag");
        struct stat st;
        Require(stat(f.environment.extendedStates.c_str(), &st) == 0 && st.st_uid == 501 && st.st_gid == 20 &&
            (st.st_mode & 0777) == 0664 && Read(f.environment.extendedStates).find("X-Extra: unchanged") != std::string::npos,
            "preserve external owner, group, mode and unrelated state");
        Write(preference, "Package: replacement\n");
        Require(!RecheckEvidence({state}, &error) && error.code == "stale_environment", "changed data invalidates review");
        Require(chmod(f.root.c_str(), 0775) == 0 && !ReadExtendedState(f.environment, &bytes, &error),
            "group-writable state parent is refused");
        Require(chmod(f.root.c_str(), 01777) == 0 && !ReadExtendedState(f.environment, &bytes, &error),
            "sticky state parent is refused");
        Require(chmod(f.root.c_str(), 0700) == 0 && chown(f.root.c_str(), 501, 20) == 0 &&
            !ReadExtendedState(f.environment, &bytes, &error), "user-owned parent is refused");
        Require(chown(f.root.c_str(), 0, 0) == 0, "restore disposable parent");
    }
    {
        Fixture f; Error error; std::string bytes;
        Require(link(f.environment.extendedStates.c_str(), (f.root + "/alias").c_str()) == 0 &&
            !ReadExtendedState(f.environment, &bytes, &error), "hard-linked state is refused");
        Require(unlink((f.root + "/alias").c_str()) == 0 && chmod(f.environment.extendedStates.c_str(), 0666) == 0 &&
            !ReadExtendedState(f.environment, &bytes, &error), "world-writable state is refused");
        Require(chmod(f.environment.extendedStates.c_str(), 04644) == 0 &&
            !ReadExtendedState(f.environment, &bytes, &error), "set-id state is refused");
    }
    {
        Fixture f; Error error; std::string bytes;
        Require(ReadExtendedState(f.environment, &bytes, &error) && bytes == f.original, "protected state read");
        Require(CommitExtendedState(f.environment, f.Payload(), &error), "commit manual flag after successful package state");
        const std::string updated(Read(f.environment.extendedStates));
        Require(updated.find("Auto-Installed: 0\nX-Local: keep\n") != std::string::npos &&
            updated.substr(updated.find("# external manager record")) == f.original.substr(f.original.find("# external manager record")),
            "preserve unknown fields and unrelated manager records");
        struct stat st; Require(stat(f.environment.extendedStates.c_str(), &st) == 0 && (st.st_mode & 0777) == 0640,
            "preserve shared state permissions");
        Require(!CommitExtendedState(f.environment, f.Payload(), &error) && error.code == "stale_extended_state" &&
            Read(f.environment.extendedStates) == updated, "stale review never overwrites a later commit");
    }
    {
        Fixture f; Error error; const std::string external(f.original + "# external addition\n");
        Write(f.environment.extendedStates, external);
        Require(!CommitExtendedState(f.environment, f.Payload(), &error) && error.code == "stale_extended_state" &&
            Read(f.environment.extendedStates) == external, "external preimage conflict preserves its bytes");
    }
    {
        Fixture f; Error error;
        Write(f.root + "/changed-status", "Package: target\nArchitecture: amd64\nStatus: install ok half-configured\n\n");
        Write(f.environment.dpkg + ".change-status", "");
        Require(!CommitExtendedState(f.environment, f.Payload(), &error) && error.code == "stale_package_state" &&
            Read(f.environment.extendedStates) == f.original, "dpkg changes during architecture query prevent flag persistence");
    }
    {
        Fixture f; Error error; Write(f.environment.dpkg + ".change-state", "");
        Require(!CommitExtendedState(f.environment, f.Payload(), &error) && error.code == "extended_state_write_failed" &&
            Read(f.environment.extendedStates) == "external replacement\n", "atomic commit preserves concurrent state replacement");
    }
    {
        Fixture f; Error error;
        Require(!CommitExtendedState(f.environment, f.Payload("2"), &error) && error.code == "invalid_extended_state" &&
            Read(f.environment.extendedStates) == f.original, "invalid flags change no shared state");
        const auto wrong(SerializeFields({f.root + "/unreviewed", f.original}));
        Require(!CommitExtendedState(f.environment, wrong, &error) && error.code == "invalid_extended_state",
            "wire payload cannot select another destination");
        Write(f.environment.dpkgAdmin + "/status", "Package: target\nArchitecture: amd64\nStatus: install ok half-configured\n\n");
        Require(!CommitExtendedState(f.environment, f.Payload("1"), &error) && error.code == "invalid_extended_state" &&
            Read(f.environment.extendedStates) == f.original,
            "incomplete packages cannot be persisted as automatically installed");
        Require(unlink(f.environment.extendedStates.c_str()) == 0 &&
            symlink((f.environment.dpkgAdmin + "/status").c_str(), f.environment.extendedStates.c_str()) == 0, "create hostile state alias");
        Require(!CommitExtendedState(f.environment, f.Payload(), &error) && error.code == "extended_state_unavailable" &&
            Read(f.environment.dpkgAdmin + "/status").find("half-configured") != std::string::npos,
            "state symlink cannot overwrite the installed database");
    }
    std::cout << "[runtime-state] PASS: privileged persistence and concurrent-state conflicts\n";
}
