/* Production protected I/O in an isolated native fixture; no dpkg child.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderInstalledOwnership.hpp"
#include "Cydia/RuntimeState.hpp"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <fcntl.h>
#include <unistd.h>

namespace {
namespace P = CydiaAPT::Provider;
namespace R = CydiaRuntime::Privileged;
using Code = P::InstalledOwnershipErrorCode;
void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[apt-provider-installed-ownership] " << message << '\n'; std::exit(1);
}
void Write(const std::string &path, const std::string &bytes, mode_t mode = 0644) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc); out << bytes; out.close();
    Require(out.good() && chmod(path.c_str(), mode) == 0, "write disposable fixture");
}
void Parsers() {
    std::vector<std::string> paths; P::InstalledOwnershipError error;
    Require(P::ParseInstalledOwnershipList("/.\n/usr/share/\n/a space\n/usr/share\n", &paths, &error) &&
        paths == std::vector<std::string>({"/.", "/usr/share", "/a space", "/usr/share"}),
        "native sentinel, one trailing slash and duplicate ownership records retained without type inference");
    const std::string bytePath("/\xffname\n", 7);
    Require(P::ParseInstalledOwnershipList(bytePath, &paths, &error) && paths.at(0) == bytePath.substr(0, 6),
        "native byte paths are not incorrectly restricted to UTF-8");
    Require(P::ParseInstalledOwnershipList("", &paths, &error) && paths.empty(), "present empty list parses explicitly");
    for (const auto &bad : {std::string("/missing-newline"), std::string("/\n"), std::string("\n"),
            std::string("relative\n"), std::string("//\n"), std::string("/a//b\n"), std::string("/a/../b\n"),
            std::string("/a/./b\n"), std::string("/a\r\n"), std::string("/a\0b\n", 5)}) {
        paths = {"discard"};
        Require(!P::ParseInstalledOwnershipList(bad, &paths, &error) && paths.empty() && error.code != Code::None,
            "unsupported list syntax clears provisional paths");
    }
    Require(!P::ParseInstalledOwnershipList(std::string(P::MaximumOwnershipFileBytes + 1, 'x'), &paths, &error) &&
        error.code == Code::LimitExceeded, "file byte ceiling");
    Require(!P::ParseInstalledOwnershipList('/' + std::string(P::MaximumOwnershipPathBytes, 'x') + '\n', &paths, &error),
        "individual path ceiling");
    std::string many;
    for (std::size_t i = 0; i <= P::MaximumOwnershipPaths; ++i) many += "/a\n";
    Require(!P::ParseInstalledOwnershipList(many, &paths, &error) && error.code == Code::LimitExceeded,
        "path count ceiling independently of byte ceiling");
    std::vector<P::InstalledDiversion> diversions;
    Require(P::ParseInstalledOwnershipDiversions("/bin/tool\n/bin/tool.real\n:\n/old\n/new\nalpha\n", &diversions, &error) &&
        diversions.size() == 2 && diversions[0].local && diversions[0].package.empty() &&
        !diversions[1].local && diversions[1].package == "alpha", "native local/package-set diversion records");
    for (const auto &bad : {"/old\n/new\n", "/old\n/new\nalpha", "/old\n/new\nalpha:amd64\n",
            "/old\n/new\n\n", "/old\n/old\n:\n", "/old\n/new\n:\n/new\n/third\nalpha\n",
            "/old/\n/new\n:\n", "/old\nrelative\n:\n"})
        Require(!P::ParseInstalledOwnershipDiversions(bad, &diversions, &error) && diversions.empty(),
            "incomplete, conflicting, qualified-owner and unsupported diversion syntax refuses atomically");
    Require(!P::ParseInstalledOwnershipDiversions('/' + std::string(1022, 'x') + "\n/new\n:\n", &diversions, &error) &&
        error.code == Code::LimitExceeded, "native fgets 1024 buffer requires newline and NUL");
}
struct Fixture {
    std::string root, info, rows;
    R::Environment environment; P::TriggerCaptureLock lock;
    Fixture() {
        const auto pattern = std::filesystem::current_path().string() + "/cydia-installed-ownership.XXXXXX";
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
        const auto made = mkdtemp(name.data()); Require(made != nullptr, "create fixture"); root = made;
        environment.dpkgAdmin = root + "/admin"; info = environment.dpkgAdmin + "/info";
        Require(std::filesystem::create_directories(info), "create info directory");
        Write(environment.dpkgAdmin + "/lock-frontend", "", 0600);
        lock.descriptor = open((environment.dpkgAdmin + "/lock-frontend").c_str(), O_RDWR);
        struct flock request{}; request.l_type = F_WRLCK; request.l_whence = SEEK_SET;
        Require(lock.descriptor >= 3 && fcntl(lock.descriptor, F_SETLK, &request) == 0, "retain actual frontend lock");
        Write(environment.dpkgAdmin + "/status", "");
    }
    ~Fixture() { close(lock.descriptor); std::filesystem::remove_all(root); }
    void Packages() {
        Write(info + "/format", "1\n");
        std::string status;
        const auto add = [&](const std::string &name, const std::string &version, const std::string &arch,
            const std::string &phase, const std::string &multi, const std::string &config = "") {
            status += "Package: " + name + "\nVersion: " + version + "\nArchitecture: " + arch +
                "\nStatus: install ok " + phase + '\n';
            if (!multi.empty()) status += "Multi-Arch: " + multi + '\n';
            if (!config.empty()) status += "Config-Version: " + config + '\n';
            status += '\n';
            rows += name + '\t' + version + '\t' + arch + "\tinstall ok " + phase + '\t' + multi + "\t\t\n";
        };
        add("alpha", "2", "amd64", "unpacked", "same", "1");
        add("alpha", "2", "i386", "installed", "same");
        add("portable", "4", "all", "installed", "");
        add("residual", "1", "all", "config-files", "", "1");
        Write(environment.dpkgAdmin + "/status", status);
        Write(info + "/alpha:amd64.list", "/.\n/usr/share/\n/usr/lib/native\n");
        Write(info + "/alpha:i386.list", "/.\n/usr/share\n/usr/lib/foreign\n");
        Write(info + "/residual.list", "/etc/residual.conf\n");
    }
    P::DpkgState State() {
        std::string identity, text; R::Error ignored; P::DpkgState state;
        Require(R::RuntimeSnapshot(environment, &identity, &ignored), "capture real package token");
        Require(P::ParseDpkgState(rows, "amd64\n", "i386\n", identity, &state, &text), "parse structured state");
        return state;
    }
    bool Capture(P::InstalledOwnershipMetadata *out, P::InstalledOwnershipError *error) {
        return P::CaptureInstalledOwnership(environment, State(), lock, out, error);
    }
};
void NativeCapture() {
    Fixture f; f.Packages(); P::InstalledOwnershipMetadata result; P::InstalledOwnershipError error;
    Require(f.Capture(&result, &error) && result.complete && result.packages.size() == 4 && result.infoFormat == 1,
        "capture all actual native and foreign owners");
    const auto &native = result.packages.at("alpha:amd64");
    Require(native.list.path == f.info + "/alpha:amd64.list" && native.configVersion == "1" &&
        native.status == P::DpkgPackageStatus::Unpacked && native.disappearanceEligible &&
        native.paths == std::vector<std::string>({"/.", "/usr/share", "/usr/lib/native"}), "native info path and last configured evidence");
    Require(result.packages.at("alpha:i386").list.path == f.info + "/alpha:i386.list" &&
        !result.packages.at("residual:all").disappearanceEligible &&
        result.packages.at("residual:all").paths.at(0) == "/etc/residual.conf", "ConfigFiles remains a noneligible third-party owner");
    Require(result.packages.at("portable:all").list.absent && result.packages.at("portable:all").paths.empty() &&
        result.diversions.absent, "absence is explicit, not proof of an empty installed package");
    std::size_t count = 0;
    for (const auto &file : result.files) if (file.path == f.info + "/alpha.list") ++count;
    Require(count == 1, "shared absent multiarch alternate evidence canonicalized once");
    const auto missing = result.evidenceIdentity;
    Write(f.info + "/portable.list", "");
    Require(f.Capture(&result, &error) && !result.packages.at("portable:all").list.absent &&
        result.evidenceIdentity != missing, "missing and empty lists have different identities");
    Write(f.environment.dpkgAdmin + "/diversions", "/usr/bin/tool\n/usr/bin/tool.original\n:\n");
    Require(f.Capture(&result, &error) && !result.diversions.absent && result.diversionRecords.size() == 1 &&
        result.diversions.bytes == "/usr/bin/tool\n/usr/bin/tool.original\n:\n", "raw diversion bytes retained alongside parsed evidence");
    Write(f.info + "/alpha.list", "/unexpected\n");
    Require(!f.Capture(&result, &error) && !result.complete && result.files.empty(), "ambiguous info filenames never publish partial ownership");
    Require(unlink((f.info + "/alpha.list").c_str()) == 0, "remove alternate");
    Write(f.info + "/format-new", "2\n");
    Require(!f.Capture(&result, &error) && error.code == Code::UnsupportedFormat, "native info migration refuses");
}
void EmptyAndLegacy() {
    Fixture empty; P::InstalledOwnershipMetadata result; P::InstalledOwnershipError error;
    Require(empty.Capture(&result, &error) && result.complete && result.packages.empty() && result.diversions.absent &&
        !result.evidenceIdentity.empty(), "empty protected database is a complete explicit empty capture");
    Write(empty.info + "/format", "2\n");
    Require(!empty.Capture(&result, &error) && error.code == Code::UnsupportedFormat && !result.complete,
        "unknown native format is not guessed even for empty database");
    Fixture legacy;
    legacy.rows = "alpha\t1\tamd64\tinstall ok installed\tsame\t\t\n";
    Write(legacy.environment.dpkgAdmin + "/status", "Package: alpha\nVersion: 1\nArchitecture: amd64\nStatus: install ok installed\nMulti-Arch: same\n\n");
    Write(legacy.info + "/alpha.list", "/native\n");
    Require(legacy.Capture(&result, &error) && result.infoFormat == 0 && result.packages.at("alpha:amd64").list.path == legacy.info + "/alpha.list",
        "legacy format selects bare filename even with Multi-Arch same");
}
void SafetyAndRechecks() {
    Fixture f; f.Packages(); P::InstalledOwnershipMetadata result; P::InstalledOwnershipError error;
    auto state = f.State(); P::TriggerCaptureLock missing;
    Require(!P::CaptureInstalledOwnership(f.environment, state, missing, &result, &error) && error.code == Code::FrontendLockMissing,
        "retained actual frontend lock is mandatory");
    Require(!P::CaptureInstalledOwnership(f.environment, state, f.lock, &result, &error, [] { return true; }) &&
        error.code == Code::Cancelled && !result.complete && result.files.empty(), "cancellation publishes nothing");
    for (unsigned boundary : {2u, 3u}) {
        unsigned captures = 0;
        Require(!P::CaptureInstalledOwnership(f.environment, state, f.lock, &result, &error,
            [&] { return captures >= boundary; },
            [&](std::string *identity, std::string *) { *identity = state.packageStateIdentity; ++captures; return true; }) &&
            error.code == Code::Cancelled && !result.complete && result.files.empty() && result.packages.empty(),
            "cancellation before independent rechecks or final serialization publishes nothing");
    }
    unsigned snapshots = 0;
    Require(!P::CaptureInstalledOwnership(f.environment, state, f.lock, &result, &error, {},
        [&](std::string *identity, std::string *) {
            *identity = state.packageStateIdentity;
            if (++snapshots == 2) Write(f.info + "/alpha:amd64.list", "/changed\n");
            return true;
        }) && !result.complete && error.code == Code::StateChanged, "list mutation detected independently of unchanged package token");
    snapshots = 0;
    Require(!P::CaptureInstalledOwnership(f.environment, state, f.lock, &result, &error, {},
        [&](std::string *identity, std::string *) {
            *identity = state.packageStateIdentity;
            if (++snapshots == 2) Write(f.environment.dpkgAdmin + "/diversions", "/old\n/new\n:\n");
            return true;
        }) && !result.complete && error.code == Code::StateChanged, "new diversion after initial absence is detected");
    const auto path = f.info + "/alpha:amd64.list";
    Require(chmod(path.c_str(), 0666) == 0 && !f.Capture(&result, &error) && error.code == Code::UnsafeInput,
        "writable list refuses");
    Require(chmod(path.c_str(), 0644) == 0 && link(path.c_str(), (f.info + "/alias").c_str()) == 0 &&
        !f.Capture(&result, &error), "multiply linked list refuses");
    Require(unlink(path.c_str()) == 0 && symlink("alias", path.c_str()) == 0 && !f.Capture(&result, &error),
        "leaf alias cannot substitute for exact native file evidence");
    Require(unlink(path.c_str()) == 0, "remove alias");
    Write(path, std::string(P::MaximumOwnershipFileBytes + 1, 'x'));
    Require(!f.Capture(&result, &error) && error.code == Code::LimitExceeded && result.packages.empty(),
        "oversized file refuses before read and without partial result");
}
void AggregateLimits() {
    Fixture f; P::InstalledOwnershipMetadata result; P::InstalledOwnershipError error;
    auto excess = f.State();
    for (std::size_t i = 0; i <= P::MaximumOwnershipPackages; ++i)
        excess.packages["package" + std::to_string(i) + ":amd64"] = P::DpkgPackageState();
    Require(!P::CaptureInstalledOwnership(f.environment, excess, f.lock, &result, &error) && error.code == Code::LimitExceeded,
        "package count bound rejects before capture");
    // Nine individually bounded lists, each with relatively long names: their
    // combined bytes exceed the aggregate bound before the path-count bound.
    const std::string line = '/' + std::string(253, 'x') + '\n';
    std::string list;
    while (list.size() + line.size() <= P::MaximumOwnershipFileBytes) list += line;
    std::string status;
    for (unsigned i = 0; i < 9; ++i) {
        const auto name = "package" + std::to_string(i);
        status += "Package: " + name + "\nVersion: 1\nArchitecture: all\nStatus: install ok installed\n\n";
        f.rows += name + "\t1\tall\tinstall ok installed\t\t\t\n";
        Write(f.info + '/' + name + ".list", list);
    }
    Write(f.environment.dpkgAdmin + "/status", status);
    Require(!f.Capture(&result, &error) && error.code == Code::LimitExceeded && !result.complete && result.files.empty(),
        "aggregate ownership bytes reject atomically despite individually valid bounded inputs");
}
}
int main() {
    Require(geteuid() == 0, "run disposable protected fixtures under fakeroot");
    alarm(60); Parsers(); NativeCapture(); EmptyAndLegacy(); SafetyAndRechecks(); AggregateLimits(); alarm(0);
    std::cout << "apt-provider-installed-ownership tests passed\n";
}
