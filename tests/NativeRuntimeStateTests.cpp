/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeState.hpp"
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
        Require(CommitExtendedState(f.environment, f.Payload(), &error) && Read(f.environment.extendedStates) == f.original,
            "incomplete package state never receives installed-package flag deltas");
        Require(unlink(f.environment.extendedStates.c_str()) == 0 &&
            symlink((f.environment.dpkgAdmin + "/status").c_str(), f.environment.extendedStates.c_str()) == 0, "create hostile state alias");
        Require(!CommitExtendedState(f.environment, f.Payload(), &error) && error.code == "extended_state_unavailable" &&
            Read(f.environment.dpkgAdmin + "/status").find("half-configured") != std::string::npos,
            "state symlink cannot overwrite the installed database");
    }
    std::cout << "[runtime-state] PASS: privileged persistence and concurrent-state conflicts\n";
}
