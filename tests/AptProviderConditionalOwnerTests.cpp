/* Connected disposable TransactionOwner conditional lifecycle.
 * Real package archives, native dpkg/query children, private Store copies,
 * kernel frontend lock, policy/channel acknowledgments and extended-state CAS.
 * The existing TransactionFiles declaration/loader/effective-policy producer
 * seam is deliberately a labelled test double: this is NOT proof of a real
 * distributor's policy producer or its Darwin loader declaration.
 * No conditional bypass, Owner clone or product helper belongs to this test.
 * Run only in the existing Linux/fakeroot native fixture environment.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef CYDIA_TRANSACTION_OWNER_TESTING
#error Link the existing labelled protected producer fixture, never a product.
#endif
#define CYDIA_TRANSACTION_FILES_FIXTURE_ONLY 1
#include "tests/AptProviderTransactionFilesTests.cpp"
#include "Cydia/AptProviderNativeEffectPolicy.hpp"
#include "Cydia/AptProviderEffectReviewBundle.hpp"
#include "Cydia/AptProviderTriggerCapture.hpp"
#include "Cydia/DpkgRunner.h"
#include <cerrno>
#include <dirent.h>
#include <spawn.h>
#include <sstream>
#include <sys/utsname.h>

namespace {
namespace ConditionalV = CydiaRuntime::Privileged;
namespace ConditionalN = P::NativeEffectPolicy;
enum class ConditionalCase { Complete, FailedChild, LateArchiveTamper, CancelAfterSpawn, CommitCAS };

// Test prerequisite, not a product policy producer: --root/--admindir and a
// private HOME do not prevent dpkg from loading its compiled system config.
// Refuse every host setting except those explicitly reset by our HOME config.
// In particular, no host invocation hook is safe merely because package files
// and the database are disposable. No executable is invoked by this guard.
bool ConditionalHostRefusal(std::string *reason, const char *message) {
    if (reason) *reason = message;
    return false;
}
bool ConditionalReadOrdinary(const std::string &path, std::size_t limit,
    bool optional, std::string *bytes, std::string *reason) {
    struct stat before{}, after{};
    if (lstat(path.c_str(), &before) != 0) {
        if (optional && errno == ENOENT) { bytes->clear(); return true; }
        return ConditionalHostRefusal(reason, "native fixture host file unavailable");
    }
    if (!S_ISREG(before.st_mode) || !(before.st_mode & 0444) || before.st_size < 0 ||
        static_cast<unsigned long long>(before.st_size) > limit)
        return ConditionalHostRefusal(reason, "native fixture host file is symlink, unreadable, nonregular or unbounded");
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return ConditionalHostRefusal(reason, "native fixture host file cannot be safely opened");
    bool accepted = fstat(fd, &after) == 0 && S_ISREG(after.st_mode) && before.st_dev == after.st_dev &&
        before.st_ino == after.st_ino && before.st_size == after.st_size;
    std::string value; char buffer[4096];
    while (accepted) {
        const ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || (count > 0 && value.size() + static_cast<std::size_t>(count) > limit)) { accepted = false; break; }
        if (!count) break;
        value.append(buffer, static_cast<std::size_t>(count));
    }
    accepted = accepted && fstat(fd, &after) == 0 && before.st_dev == after.st_dev &&
        before.st_ino == after.st_ino && before.st_size == after.st_size &&
        value.size() == static_cast<std::size_t>(before.st_size);
    close(fd);
    if (!accepted) return ConditionalHostRefusal(reason, "native fixture host file changed or exceeded bounds");
    *bytes = std::move(value); return true;
}
bool ConditionalResetHostConfiguration(const std::string &bytes, std::string *reason) {
    if (bytes.find('\0') != std::string::npos)
        return ConditionalHostRefusal(reason, "native fixture host configuration contains NUL");
    for (std::size_t offset = 0; offset < bytes.size();) {
        const auto end = bytes.find('\n', offset);
        std::string line = bytes.substr(offset, end == std::string::npos ? bytes.size() - offset : end - offset);
        offset = end == std::string::npos ? bytes.size() : end + 1;
        if (line.size() > 4096) return ConditionalHostRefusal(reason, "native fixture host configuration line is unbounded");
        const auto first = line.find_first_not_of(" \t");
        if (first == std::string::npos || line[first] == '#') continue;
        const auto last = line.find_last_not_of(" \t"); line = line.substr(first, last - first + 1);
        if (line == "log /var/log/dpkg.log" || line == "log=/var/log/dpkg.log" || line == "no-debsig" ||
            line == "force-unsafe-io" || line == "force-confdef" || line == "force-confold" ||
            line == "force-confnew" || line == "force-overwrite" || line == "force-downgrade") continue;
        // Report only the option name, never a hook body or value. Refusal
        // remains mandatory; diagnostics do not relax the host prerequisite.
        const auto optionEnd = line.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-");
        std::cerr << "[conditional-host-config] unsupported option " << line.substr(0, std::min<std::size_t>(optionEnd, 64)) << '\n';
        return ConditionalHostRefusal(reason, "native fixture host configuration has an unmodeled directive or hook");
    }
    return true;
}
void ConditionalObserveHostPart(const std::string &path, const std::string &bytes, std::string *observation) {
    *observation += std::to_string(path.size()) + ':' + path + std::to_string(bytes.size()) + ':' + bytes;
}
bool ConditionalHostConfigurationTree(const std::string &directory,
    std::string *observation, std::string *reason) {
    observation->clear(); struct stat metadata{};
    if (lstat(directory.c_str(), &metadata) != 0 || !S_ISDIR(metadata.st_mode) || !(metadata.st_mode & 0444))
        return ConditionalHostRefusal(reason, "native fixture system configuration root is not an ordinary readable directory");
    std::string bytes;
    const std::string main = directory + "/dpkg.cfg";
    if (!ConditionalReadOrdinary(main, 65536, true, &bytes, reason) || !ConditionalResetHostConfiguration(bytes, reason)) return false;
    ConditionalObserveHostPart(main, bytes, observation);
    const std::string fragments = directory + "/dpkg.cfg.d";
    if (lstat(fragments.c_str(), &metadata) != 0) {
        if (errno == ENOENT) { ConditionalObserveHostPart(fragments, "absent", observation); return true; }
        return ConditionalHostRefusal(reason, "native fixture system configuration fragments unavailable");
    }
    if (!S_ISDIR(metadata.st_mode) || !(metadata.st_mode & 0444))
        return ConditionalHostRefusal(reason, "native fixture system fragments are symlink, unreadable or non-directory");
    const int fd = open(fragments.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY);
    if (fd < 0) return ConditionalHostRefusal(reason, "native fixture system fragments cannot be safely opened");
    DIR *entries = fdopendir(fd);
    if (!entries) { close(fd); return ConditionalHostRefusal(reason, "native fixture system fragments cannot be listed"); }
    std::vector<std::string> names; bool accepted = true; errno = 0;
    while (const auto *entry = readdir(entries)) {
        const std::string name = entry->d_name;
        if (name == "." || name == "..") continue;
        if (names.size() >= 64 || name.empty() || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos) {
            accepted = false; break;
        }
        names.push_back(name);
    }
    if (errno != 0) accepted = false;
    closedir(entries);
    if (!accepted) return ConditionalHostRefusal(reason, "native fixture system fragments contain unsupported names or exceed bounds");
    std::sort(names.begin(), names.end()); ConditionalObserveHostPart(fragments, "present", observation);
    for (const auto &name : names) {
        const std::string path = fragments + '/' + name;
        if (!ConditionalReadOrdinary(path, 65536, false, &bytes, reason) ||
            !ConditionalResetHostConfiguration(bytes, reason)) return false;
        ConditionalObserveHostPart(path, bytes, observation);
        if (observation->size() > 262144) return ConditionalHostRefusal(reason, "native fixture total system configuration exceeds bounds");
    }
    return true;
}
bool ConditionalNativeHost(std::string *observation, std::string *reason) {
#if !defined(__linux__)
    return ConditionalHostRefusal(reason, "native fixture requires the supported Debian/Ubuntu Linux configuration root");
#else
    struct utsname platform{}; struct stat metadata{};
    if (uname(&platform) != 0 || std::string(platform.sysname) != "Linux" || std::string(platform.machine) != "x86_64" ||
        lstat("/etc", &metadata) != 0 || !S_ISDIR(metadata.st_mode))
        return ConditionalHostRefusal(reason, "native fixture host platform or system configuration parent is unsupported");
    // Use the distro's ordinary file directly; /etc/os-release is commonly a
    // symlink. Arbitrary derivatives and custom dpkg configuration roots are
    // not accepted as a disposable-native-test claim.
    std::string release, binary;
    if (!ConditionalReadOrdinary("/usr/lib/os-release", 16384, false, &release, reason) ||
        !ConditionalReadOrdinary("/usr/bin/dpkg", 16777216, false, &binary, reason)) return false;
    bool supported = false;
    std::istringstream lines(release); std::string line; unsigned identifiers = 0;
    while (std::getline(lines, line)) if (line.rfind("ID=", 0) == 0) {
        ++identifiers;
        supported = line == "ID=debian" || line == "ID=\"debian\"" || line == "ID=ubuntu" || line == "ID=\"ubuntu\"";
    }
    const std::string expectedMain("/etc/dpkg/dpkg.cfg\0", 19);
    const std::string expectedFragments("/etc/dpkg/dpkg.cfg.d\0", 21);
    const std::string expectedRoot("/etc/dpkg\0", 10);
    if (!supported || identifiers != 1 || binary.size() < 4 || binary.substr(0, 4) != std::string("\177ELF", 4) ||
        (binary.find(expectedRoot) == std::string::npos &&
         (binary.find(expectedMain) == std::string::npos || binary.find(expectedFragments) == std::string::npos)))
        return ConditionalHostRefusal(reason, "native fixture distribution or compiled dpkg configuration root is unsupported");
    if (!ConditionalHostConfigurationTree("/etc/dpkg", observation, reason)) return false;
    ConditionalObserveHostPart("/usr/lib/os-release", release, observation);
    ConditionalObserveHostPart("/usr/bin/dpkg", Hash(binary), observation);
    return true;
#endif
}
void ConditionalHostGuardFixtures() {
    Fixture fixture; std::string observation, reason;
    const auto directory = fixture.root + "/host-dpkg";
    std::filesystem::create_directory(directory); std::filesystem::create_directory(directory + "/dpkg.cfg.d");
    Write(directory + "/dpkg.cfg", "# ordinary system configuration\nno-debsig\nlog /var/log/dpkg.log\n");
    Write(directory + "/dpkg.cfg.d/01-native-test", "force-unsafe-io\n");
    Require(ConditionalHostConfigurationTree(directory, &observation, &reason), "nonexecuting guard accepts only host values reset by HOME");
    for (const auto &setting : {"pre-invoke=touch /outside\n", "post-invoke echo unsafe\n", "include /elsewhere\n", "root=/\n", "force-all\n", "log=/tmp/other\n", "status-logger=touch /outside\n"}) {
        Write(directory + "/dpkg.cfg.d/01-native-test", setting);
        Require(!ConditionalHostConfigurationTree(directory, &observation, &reason), "nonexecuting guard refuses unmodeled hooks/includes/options");
    }
    Write(directory + "/dpkg.cfg.d/01-native-test", "force-unsafe-io\n");
    const auto link = directory + "/dpkg.cfg.d/02-link";
    Require(symlink((directory + "/dpkg.cfg").c_str(), link.c_str()) == 0 &&
        !ConditionalHostConfigurationTree(directory, &observation, &reason), "nonexecuting guard refuses system configuration symlinks");
    Require(unlink(link.c_str()) == 0, "remove disposable guard symlink");
    Write(directory + "/dpkg.cfg.d/01-native-test", "", 0000);
    Require(!ConditionalHostConfigurationTree(directory, &observation, &reason), "nonexecuting guard refuses unreadable configuration even under fakeroot");
    Write(directory + "/dpkg.cfg.d/01-native-test", std::string(65537, '#'));
    Require(!ConditionalHostConfigurationTree(directory, &observation, &reason), "nonexecuting guard bounds native configuration before reading");
    Write(directory + "/dpkg.cfg.d/01-native-test", "force-unsafe-io\n");
    Require(ConditionalHostConfigurationTree(directory, &observation, &reason), "nonexecuting guard returns to known disposable configuration");
}

std::string ConditionalRead(const std::string &path) {
    std::ifstream file(path, std::ios::binary);
    Require(file.good(), "read disposable conditional fixture");
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
std::string ConditionalControl(const std::string &name, const std::string &version,
    const std::string &architecture, const std::string &fields = "") {
    return "Package: " + name + "\nVersion: " + version + "\nArchitecture: " + architecture +
        "\nMaintainer: Cydia fixture <fixture@example.invalid>\nDescription: isolated owner fixture\n" + fields;
}
P::ReviewedAction ConditionalAction(std::uint64_t id, P::ExecutionAction kind,
    const P::ExecutionPackage &package, const std::string &archive = "") {
    P::ReviewedAction result; result.identifier = id; result.action = kind;
    result.package = package; result.archive = archive; return result;
}
struct ConditionalFixture : Fixture {
    P::TransactionOwnerOptions options;
    std::vector<P::InstalledComponentEvidence> components;
    std::string configuration, hostConfiguration;
    int frontend = -1;
    explicit ConditionalFixture(ConditionalCase scenario) : Fixture() {
        std::string hostReason;
        const bool supportedHost = ConditionalNativeHost(&hostConfiguration, &hostReason);
        Require(supportedHost, hostReason.c_str());
        auto &environment = options.selected.environment;
        options.selected.runtime = runtime;
        environment.dpkg = "/usr/bin/dpkg"; environment.dpkgQuery = "/usr/bin/dpkg-query";
        environment.dpkgDeb = "/usr/bin/dpkg-deb";
        environment.dpkgRoot = root + "/payload"; environment.dpkgAdmin = root + "/admin";
        environment.sourceList = runtime.sourceListPath; environment.extendedStates = root + "/extended_states";
        std::filesystem::create_directories(environment.dpkgRoot + "/usr/lib");
        std::filesystem::create_directories(environment.dpkgAdmin + "/info");
        std::filesystem::create_directory(environment.dpkgAdmin + "/updates");
        std::filesystem::create_directory(environment.dpkgAdmin + "/triggers");
        Write(environment.extendedStates, "");
        Write(environment.dpkgAdmin + "/info/format", "1\n");
        Write(environment.dpkgAdmin + "/triggers/Lock", "", 0600);
        Write(environment.dpkgAdmin + "/triggers/Unincorp", "");
        Write(environment.dpkgAdmin + "/triggers/cache-refresh", "cache\n");
        Write(environment.dpkgAdmin + "/info/cache.triggers", "interest-await cache-refresh\n");
        Write(environment.dpkgAdmin + "/status", ConditionalControl("victim", "1", "amd64") +
            "Status: install ok installed\n\n" + ConditionalControl("cache", "1", "amd64") +
            "Status: install ok installed\n\n");
        Write(environment.dpkgAdmin + "/info/victim.list", "/usr/lib/victim-fixture\n");
        Write(environment.dpkgAdmin + "/info/cache.list", "/usr/lib/cache-fixture\n");
        Write(environment.dpkgRoot + "/usr/lib/victim-fixture", "old victim payload");
        Write(environment.dpkgRoot + "/usr/lib/cache-fixture", "unchanged cache payload");
        if (scenario == ConditionalCase::FailedChild) {
            // A real native unpack error after admission. Its unowned nonempty
            // directory exists only beneath this fixture's explicit --root.
            std::filesystem::create_directory(environment.dpkgRoot + "/usr/lib/fixture");
            Write(environment.dpkgRoot + "/usr/lib/fixture/keep", "native directory replacement must fail");
        }
        options.selected.executableSearchPath = "/usr/bin:/bin:/sbin:/usr/sbin";
        options.selected.archiveDecoderSearchPath = "/usr/bin:/bin";
        options.selected.runtime.dpkgOptions = {"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin};
        options.selected.runtime.packageInstallPrefix = "/";
        options.selected.runtime.dpkgExecutablePath = environment.dpkg;
        options.selected.runtime.dpkgQueryExecutablePath = environment.dpkgQuery;
        options.selected.runtime.dpkgDebExecutablePath = environment.dpkgDeb;
        options.selected.runtime.dpkgAdminDirectory = environment.dpkgAdmin;
        options.selected.runtime.extendedStatesPath = environment.extendedStates;
        policy.environment.paths = environment;
        policy.protectedDpkgOptions = options.selected.runtime.dpkgOptions;

        // Replace the inherited archive/index together. Controls carry real
        // Breaks plus an activation; victim 2 is the reviewed restoration.
        auto first = review.execution.archives.front();
        const auto sampleControl = ConditionalControl("sample", "1", "all", "Breaks: victim (<< 2)\n");
        std::string tar = Tar("control", sampleControl);
        tar.resize(tar.size() - 1024); tar += Tar("triggers", "activate-await cache-refresh\n");
        // The known trigger file still carries the ordinary maintainer warning.
        // Record its fixture review approval; retained archive checks remain required.
        policy.unverifiedArchiveWarningsAccepted.insert(first.identifier);
        deb = "!<arch>\n" + Ar("debian-binary", "2.0\n") + Ar("control.tar", tar) +
            Ar("data.tar", Tar("usr/lib/fixture", "approved library bytes"));
        first.size = deb.size(); first.hashes = {{"SHA512", Hash(deb, Hashes::SHA512SUM)}};
        const auto sampleRecord = sampleControl + "Filename: pool/sample.deb\nSize: " + std::to_string(first.size) +
            "\nSHA512: " + first.hashes.at("SHA512") + "\n\n";
        first.recordOffset = 0; first.recordSize = sampleRecord.size();
        P::ArchiveManifest successor = first; successor.identifier = "victim-successor";
        successor.package = {"victim", "2", "amd64"}; successor.path = root + "/victim-successor.deb";
        successor.filename = "pool/victim-successor.deb";
        const auto successorControl = ConditionalControl("victim", "2", "amd64");
        const auto successorBytes = "!<arch>\n" + Ar("debian-binary", "2.0\n") +
            Ar("control.tar", Tar("control", successorControl)) +
            Ar("data.tar", Tar("usr/lib/victim-fixture", "approved victim successor bytes"));
        successor.size = successorBytes.size(); successor.hashes = {{"SHA512", Hash(successorBytes, Hashes::SHA512SUM)}};
        const auto successorRecord = successorControl + "Filename: " + successor.filename + "\nSize: " +
            std::to_string(successor.size) + "\nSHA512: " + successor.hashes.at("SHA512") + "\n\n";
        successor.recordOffset = sampleRecord.size(); successor.recordSize = successorRecord.size();
        const auto index = sampleRecord + successorRecord;
        first.sourceIndexIdentity = successor.sourceIndexIdentity = "SHA256:" + Hash(index);
        Write(first.path, deb); Write(successor.path, successorBytes); Write(first.sourceIndexPath, index);
        review.execution.archives = {first, successor};
        review.execution.actions = {ConditionalAction(1, P::ExecutionAction::Unpack, first.package, first.identifier),
            ConditionalAction(3, P::ExecutionAction::Unpack, successor.package, successor.identifier),
            ConditionalAction(4, P::ExecutionAction::Configure, successor.package),
            ConditionalAction(2, P::ExecutionAction::Configure, first.package)};
        const auto identity = CydiaAPT::BuildPackageIdentity("victim", "amd64", "amd64", "amd64", CydiaAPT::MultiArchMode::None);
        review.transaction.installs.push_back(identity.routingName);
        review.transaction.packages[identity.routingName] = {identity, "2", "victim"};

        // dpkg loads HOME/.dpkg.cfg after its system configuration. Keep its
        // logfile in this disposable tree and explicitly fix the force subset.
        // The nonexecuting host guard above excludes all unreset directives,
        // including hooks. This remains a labelled producer test double.
        // This does not alter the host HOME or install any product helper.
        std::filesystem::create_directory(root + "/home");
        configuration = root + "/home/.dpkg.cfg";
        Write(configuration, "log=" + root + "/dpkg.log\nno-debsig\nno-force-all\nforce=overwrite,downgrade\n");
        fixtureAuthority = P::NativeDpkgAuthority(); fixtureAuthorityAvailable = true;
        fixtureAuthority.dpkgRoot = environment.dpkgRoot; fixtureAuthority.dpkgAdmin = environment.dpkgAdmin;
        fixtureAuthority.executableSearchPath = options.selected.executableSearchPath;
        fixtureAuthority.configurationIdentity = Hash(ConditionalRead(configuration));
        fixtureAuthority.platformIdentity = Hash("labelled-linux-conditional-owner-fixture");
        fixtureAuthority.componentPaths = {environment.dpkg, environment.dpkgQuery};
        fixtureAuthority.effectRecordState = P::NativeEffectRecordState::Parsed;
        std::vector<std::string> launchEntries{"PATH=" + options.selected.executableSearchPath, "LANG=C", "LC_ALL=C",
            "HOME=" + root + "/home", "DPKG_FRONTEND_LOCKED=1"};
        // Preserve only the already-active test harness interposition, once,
        // inside the retained snapshot. Native children never merge ambient
        // environ after policy matching or turn a fixture into real host root.
        if (std::getenv("FAKEROOTKEY"))
            for (const char *name : {"LD_PRELOAD", "LD_LIBRARY_PATH", "FAKEROOTKEY", "FAKED_MODE", "FAKEROOTDONTTRYCHOWN"})
                if (const char *value = std::getenv(name)) launchEntries.push_back(std::string(name) + '=' + value);
        Require(CydiaRuntime::NativeLaunchEnvironment::FromEntries(launchEntries, &fixtureAuthority.launchEnvironment),
            "actual children use a retained explicit isolated HOME and locale");
        fixtureAuthority.launchEnvironmentBytes = ConditionalV::SerializeFields(fixtureAuthority.launchEnvironment.entries());
        ConditionalV::Error ignored; ConditionalV::Evidence config;
        Require(ConditionalV::CaptureEvidence(configuration, false, false, &config, &ignored), "capture actual fixture native configuration");
        fixtureAuthority.configurationEvidence = {config};
        for (const auto &path : fixtureAuthority.componentPaths) {
            P::InstalledComponentEvidence file; std::string error;
            const bool captured = P::CaptureTransactionComponent(path, &file, &error);
            Require(captured, ("conditional component capture: " + error).c_str());
            fixtureAuthority.executorGenerations[path] = {file.file.sha256}; components.push_back(std::move(file));
        }
        fixturePolicyProducer = [](const P::NativeDpkgAuthority &authority, const std::string &executable,
            const std::vector<P::InstalledComponentEvidence> &files, const std::string &profile, ConditionalN::Role role,
            const std::vector<std::string> &prefix, ConditionalN::Inputs *output, std::string *, const std::function<bool()> &cancel) {
            if (!output || (cancel && cancel())) return false;
            ConditionalN::Inputs value; value.semanticProfile = profile; value.executorPath = executable;
            value.dpkgRoot = authority.dpkgRoot; value.dpkgAdmin = authority.dpkgAdmin;
            value.platformIdentity = authority.platformIdentity; value.environment = authority.launchEnvironment;
            value.executableSearchPath = authority.executableSearchPath; value.role = role; value.optionPrefix = prefix;
            for (const auto &file : authority.configurationEvidence) {
                ConditionalN::ContentInput input; input.path = file.path; input.present = !file.absent;
                input.size = file.bytes.size(); input.sha256 = Hash(file.bytes); value.configuration.push_back(std::move(input));
            }
            for (const auto &file : files) {
                value.components.push_back({file.file.metadata.path, file.file.sha256});
                if (file.file.metadata.path == executable) value.executorSHA256 = file.file.sha256;
            }
            std::string canonical; if (!ConditionalN::EncodeInputs(value, &canonical)) return false;
            *output = std::move(value); return true;
        };
        Require(ConditionalV::RuntimeSnapshot(environment, &review.binding.packageStateIdentity, &ignored), "actual initial package-state binding");
        policy.environment.packageStateIdentity = options.selected.runtime.binding.packageStateIdentity = review.binding.packageStateIdentity;
        options.application = {std::to_string(getpid()), "10.1", "20.2", std::string(40, 'a')}; options.applicationUID = getuid();
        options.privateStateDirectory = root + "/private"; options.nonce = std::string(64, '1'); options.reviewDigest = std::string(64, '2');
        options.policy = policy; options.review = review; options.changes = {{"sample", "amd64", true}, {"victim", "amd64", false}};
        options.requireConffilePolicy = true;
        frontend = open((environment.dpkgAdmin + "/lock-frontend").c_str(), O_CREAT | O_RDWR, 0600);
        struct stat identityStat{}; struct flock held{}; held.l_type = F_WRLCK; held.l_whence = SEEK_SET;
        Require(frontend >= 3 && fstat(frontend, &identityStat) == 0 && fcntl(frontend, F_SETLK, &held) == 0,
            "application parent owns the real frontend lock before helper capture");
        options.lock.device = identityStat.st_dev; options.lock.inode = identityStat.st_ino;
    }
    ~ConditionalFixture() { if (frontend >= 0) close(frontend); fixturePolicyProducer = FixturePolicyProducer(); }
};

void ConditionalOwnerChild(ConditionalFixture &fixture, ConditionalCase scenario, unsigned lateBoundary) {
    close(fixture.frontend); fixture.frontend = -1;
    auto options = fixture.options;
    std::string error;
    // This first capture produces only DTO transport. Owner Begin performs a
    // second, independent locked capture before any retained archive staging.
    std::shared_ptr<const P::ProtectedDeconfigurationReview> reviewed;
    const bool capturedReview = P::CaptureReviewedDeconfiguration(CydiaRuntime::PackageDatabasePaths::Current(), options.selected,
        options.review, &reviewed, &error);
    Require(capturedReview, ("conditional review capture: " + error).c_str());
    auto bundle = std::make_shared<P::EffectReviewBundle>(); bundle->methodsIdentity = options.selected.runtime.binding.methodsIdentity;
    bundle->deconfiguration = reviewed->allowances;
    Require(bundle->deconfiguration.allowances.size() == 1 && bundle->deconfiguration.allowances.count("victim:amd64@1") &&
        bundle->deconfiguration.allowances.at("victim:amd64@1").endpoint.action == 4,
        "actual reconstructed nonempty Breaks approval has only the reviewed successor configure endpoint");
    const bool builtEffects = P::BuildTriggerEffectEnvelope(options.review, reviewed->checkpoint, &bundle->triggers, &error,
        reviewed->allowances.nativeAuthorityIdentity);
    Require(builtEffects, ("conditional trigger envelope: " + error).c_str());
    options.reviewedDeconfiguration = bundle;
    options.reviewedEffects = std::shared_ptr<const P::TriggerEffectEnvelope>(bundle, &bundle->triggers);
    options.authenticate = [options](ConditionalV::ApplicationProcessIdentity *application, uid_t *uid, std::string *) {
        *application = options.application; *uid = options.applicationUID; return true;
    };
    P::TransactionOwner *owner = nullptr;
    unsigned channelScopes = 0, policies = 0, starts = 0, settlements = 0, executions = 0, firstUnpackInputs = 0;
    unsigned nativeInputs = 0, primaryOrdinal = 0, drains = 0;
    bool policyAccepted = false, tampered = false;
    std::string privateArchive;
    const auto baseProducer = fixturePolicyProducer;
    // Owner retains its NativeDpkgAuthority by value at Begin. Every permitted
    // exact child prefix therefore has a record in that initial snapshot;
    // child/channel callbacks never append new assertions after Begin.
    fixtureAuthority.effectRecords.clear();
    for (unsigned kind = 0; kind != 4; ++kind) {
        const auto role = kind < 2 ? ConditionalN::Role::Unpack : kind == 2 ?
            ConditionalN::Role::Configure : ConditionalN::Role::TriggerDrain;
        auto prefix = options.policy.protectedDpkgOptions;
        prefix.insert(prefix.end(), {"--status-fd=3", "--no-triggers"});
        if (kind == 0) prefix.push_back("--auto-deconfigure");
        prefix.push_back(kind < 2 ? "--unpack" : kind == 2 ? "--configure" : "--triggers-only");
        ConditionalN::Inputs input;
        Require(baseProducer(fixtureAuthority, options.selected.environment.dpkg, fixture.components,
            "dpkg-1.23.7-effects-1", role, prefix, &input, &error, {}), "complete initial labelled native-policy input capture");
        ConditionalN::Record record; record.semanticProfile = input.semanticProfile; record.executorPath = input.executorPath;
        record.executorSHA256 = input.executorSHA256; record.optionPrefix = input.optionPrefix; record.role = role;
        Require(ConditionalN::InputIdentity(input, [](const std::string &bytes) { return Hash(bytes); }, &record.inputIdentity),
            "initial policy record binds exact actual inputs and final ordered prefix");
        record.settings.triggers = ConditionalN::TriggerMode::Disabled; record.settings.statusDescriptors = {3};
        record.settings.noDebsig = true; // Explicit isolated HOME setting above.
        record.settings.forces = {ConditionalN::Force::Downgrade, ConditionalN::Force::Overwrite};
        record.settings.autoDeconfigure = kind == 0;
        record.settings.logFilePresent = true; record.settings.logFile = fixture.root + "/dpkg.log";
        fixtureAuthority.effectRecords.push_back(std::move(record));
    }
    fixturePolicyProducer = [&](const P::NativeDpkgAuthority &authority, const std::string &executable,
        const std::vector<P::InstalledComponentEvidence> &files, const std::string &profile, ConditionalN::Role role,
        const std::vector<std::string> &prefix, ConditionalN::Inputs *output, std::string *reason, const std::function<bool()> &cancel) {
        if (role == ConditionalN::Role::Unpack && primaryOrdinal == 1) {
            ++nativeInputs;
            if (scenario == ConditionalCase::LateArchiveTamper && nativeInputs == lateBoundary) {
                Require(!privateArchive.empty(), "late producer callback sees only actual parent-retained copy");
                Write(privateArchive, "late native policy callback modified private archive\n", 0600); tampered = true;
            }
        }
        return baseProducer(authority, executable, files, profile, role, prefix, output, reason, cancel);
    };
    const auto scope = [&](ConditionalN::Role role, const std::vector<std::string> &source,
        P::TransactionEffectChildChannels *channels, std::string *reason) {
        auto descriptors = std::make_shared<std::vector<int>>(4);
        Require(socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors->data()) == 0 &&
            pipe(descriptors->data() + 2) == 0, "fresh production-shaped stdin/status channels for each child");
        for (int descriptor : *descriptors)
            Require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                "native children inherit only the prepared stdin and fd3 mappings");
        channels->inputDescriptor = (*descriptors)[0]; channels->statusDescriptor = (*descriptors)[3]; ++channelScopes;
        const auto statusIndex = std::find_if(source.begin(), source.end(), [](const std::string &arg) {
            return arg.compare(0, 12, "--status-fd=") == 0;
        });
        Require(statusIndex != source.end(), "one explicit received status descriptor before final preparation");
        auto boundSource = source; const auto position = static_cast<std::size_t>(statusIndex - source.begin());
        boundSource[position] = "--status-fd=" + std::to_string(channels->statusDescriptor);
        std::size_t prefixSize = 0;
        for (const auto &arg : boundSource) { if (arg.compare(0, 2, "--") != 0) break; ++prefixSize; }
        std::vector<std::string> bound, finalized; ConditionalV::Error ignored;
        Require(ConditionalV::BindDpkgArguments(options.selected.environment, boundSource, &bound, &ignored) &&
            P::FinalizeNativeChildArguments(bound, prefixSize, position, channels->statusDescriptor, &finalized),
            "fixture builds policy for the same native bound fd3 prefix used by Owner");
        ConditionalN::Inputs input;
        // Policy generation uses the base producer; the late callback test is
        // reserved for Owner's own final native-input capture, not this setup.
        Require(baseProducer(fixtureAuthority, options.selected.environment.dpkg, fixture.components,
            "dpkg-1.23.7-effects-1", role, {finalized.begin(), finalized.begin() + prefixSize}, &input, reason, {}), "complete labelled producer inputs");
        Require(ConditionalN::MatchRecord(fixtureAuthority.effectRecords, input,
            [](const std::string &bytes) { return Hash(bytes); }).status == ConditionalN::Status::Matched,
            "every child prefix already matches the initial immutable native authority snapshot");
        policyAccepted = false;
        channels->policy = [&](const P::ConffilePolicyDecision &decision, std::string *) {
            Require(P::ValidConffilePolicyDecision(decision) && decision.match == ConditionalN::Status::Matched &&
                decision.input == CydiaRuntime::Dpkg::ConffileInputPolicy::Interactive &&
                !decision.recordIdentity.empty() && !decision.launchIdentity.empty(),
                "channel acknowledges immutable matched policy and exact final launch before native spawn");
            ++policies; policyAccepted = true; return true;
        };
        channels->started = [&] { Require(policyAccepted && owner && owner->mutationStarted(), "start follows policy acknowledgment and actual lease child record"); ++starts; };
        channels->settled = [&, descriptors](const P::ParentExecutionReply &) {
            for (int descriptor : *descriptors) close(descriptor);
            ++settlements;
        };
        return true;
    };
    options.primaryChildChannels = [&](const P::ParentExecutionRequest &request, P::TransactionEffectChildChannels *channels, std::string *reason) {
        ++primaryOrdinal; Require(request.actions.size() == 1, "one exact reviewed primary per conditional boundary");
        if (primaryOrdinal == 1) for (const auto &directory : std::filesystem::directory_iterator(fixture.root + "/private"))
            if (directory.is_directory()) privateArchive = directory.path().string() + "/0.deb";
        const auto role = request.action == P::ExecutionAction::Unpack ? ConditionalN::Role::Unpack : ConditionalN::Role::Configure;
        return scope(role, request.arguments, channels, reason);
    };
    options.effectChildChannels = [&](const P::TriggerDrainPlan &plan, P::TransactionEffectChildChannels *channels, std::string *reason) {
        Require(plan.targets.size() == 1 && plan.targets.front().package == "cache" && plan.targets.front().architecture == "amd64",
            "only the complete freshly selected native pending cache recipient is drained");
        ++drains;
        auto source = options.policy.protectedDpkgOptions;
        source.insert(source.end(), {"--status-fd=99", "--no-triggers", "--triggers-only", "cache:amd64"});
        return scope(ConditionalN::Role::TriggerDrain, source, channels, reason);
    };
    // Owner requires both callbacks, as cydo supplies them. Every permitted
    // fixture child must still take the matched, prepared native executor.
    options.execute = [](const std::string &, const std::vector<std::string> &, int, int,
        const std::function<void()> &, const CydiaRuntime::NativeLaunchEnvironment &) {
        Require(false, "conditional owner cannot fall back to an unprepared executor");
        return P::ParentExecutionReply();
    };
    options.executePrepared = [&](const std::string &executable, const std::vector<std::string> &arguments,
        int input, int status, const std::function<void()> &notify, const CydiaRuntime::NativeLaunchEnvironment &environment,
        std::size_t statusIndex) {
        Require(executable == "/usr/bin/dpkg" && P::ValidFinalNativeChildArguments(arguments, statusIndex) &&
            policyAccepted && environment.entries() == fixtureAuthority.launchEnvironment.entries(),
            "actual executor receives unchanged fd3 argv and exact retained environment");
        Require(arguments.size() >= 3 && arguments[0] == "--root=" + options.selected.environment.dpkgRoot &&
            arguments[1] == "--admindir=" + options.selected.environment.dpkgAdmin,
            "native mutation remains confined to disposable root/admin");
        std::string hostConfiguration, hostReason;
        Require(ConditionalNativeHost(&hostConfiguration, &hostReason) && hostConfiguration == fixture.hostConfiguration,
            "nonexecuting host prerequisite remains unchanged immediately before native fixture spawn");
        ++executions;
        if (primaryOrdinal == 1 && drains == 0) { firstUnpackInputs = nativeInputs; Write(fixture.root + "/native-input-count", std::to_string(nativeInputs)); }
        std::vector<char *> argv, envp;
        argv.push_back(const_cast<char *>(executable.c_str()));
        for (const auto &arg : arguments) argv.push_back(const_cast<char *>(arg.c_str()));
        argv.push_back(nullptr);
        for (const auto &entry : environment.entries()) envp.push_back(const_cast<char *>(entry.c_str()));
        envp.push_back(nullptr);
        // Resolve all descriptor aliases before installing fd3, just as cydo's
        // prepared executor does. Stdout/stderr stay visible in fixture logs.
        const int copiedInput = fcntl(input, F_DUPFD_CLOEXEC, 10), copiedStatus = fcntl(status, F_DUPFD_CLOEXEC, 10);
        Require(copiedInput >= 10 && copiedStatus >= 10, "prepare alias-safe actual child descriptors");
        posix_spawn_file_actions_t actions; Require(posix_spawn_file_actions_init(&actions) == 0, "initialize actual native child actions");
        Require(posix_spawn_file_actions_adddup2(&actions, copiedInput, 0) == 0 &&
            posix_spawn_file_actions_adddup2(&actions, copiedStatus, 3) == 0 &&
            posix_spawn_file_actions_addclose(&actions, copiedInput) == 0 &&
            posix_spawn_file_actions_addclose(&actions, copiedStatus) == 0, "actual spawn installs exact stdin and fd3 status mapping");
        pid_t child = -1; const int launched = posix_spawn(&child, executable.c_str(), &actions, nullptr, argv.data(), envp.data());
        posix_spawn_file_actions_destroy(&actions); close(copiedInput); close(copiedStatus);
        P::ParentExecutionReply reply;
        if (launched) { reply.launchError = launched; return reply; }
        reply.started = true; notify();
        if (scenario == ConditionalCase::CancelAfterSpawn) owner->Cancel();
        int waitStatus = 0; pid_t reaped;
        do { reaped = waitpid(child, &waitStatus, 0); } while (reaped < 0 && errno == EINTR);
        Require(reaped == child, "started native child is always reaped even after cancellation");
        reply.exitCode = WIFEXITED(waitStatus) ? WEXITSTATUS(waitStatus) : -1;
        reply.signal = WIFSIGNALED(waitStatus) ? WTERMSIG(waitStatus) : 0;
        return reply;
    };
    P::TransactionOwner actual(options); owner = &actual;
    const bool begun = actual.Begin(&error);
    Require(begun, ("conditional owner Begin: " + error).c_str());
    const auto execute = [&](std::uint64_t sequence, std::uint64_t identifier, bool autoDeconfigure, P::DpkgState *after) {
        const auto found = std::find_if(options.review.execution.actions.begin(), options.review.execution.actions.end(),
            [&](const P::ReviewedAction &action) { return action.identifier == identifier; });
        Require(found != options.review.execution.actions.end(), "fixture request uses only reviewed primary IDs");
        P::ParentExecutionRequest request; request.binding = options.review.binding; request.batch = sequence;
        request.action = found->action; request.actions = {identifier}; request.arguments = options.policy.protectedDpkgOptions;
        request.arguments.insert(request.arguments.end(), {"--status-fd=99", "--no-triggers"});
        if (autoDeconfigure) request.arguments.push_back("--auto-deconfigure");
        request.arguments.push_back(found->action == P::ExecutionAction::Unpack ? "--unpack" : "--configure");
        if (found->action == P::ExecutionAction::Unpack) {
            const auto archive = std::find_if(options.review.execution.archives.begin(), options.review.execution.archives.end(),
                [&](const P::ArchiveManifest &value) { return value.identifier == found->archive; });
            request.arguments.push_back(archive->path);
        } else request.arguments.push_back(found->package.package + ':' + found->package.architecture);
        P::ParentExecutionReply reply;
        const bool accepted = actual.Execute(Envelope(sequence), request, -1, -1, &reply, after, &error);
        if (scenario == ConditionalCase::LateArchiveTamper) {
            Require(tampered && !accepted && !reply.started && executions == 0 && policies == 1 &&
                starts == 0 && settlements == 1 && !actual.mutationStarted() && !actual.complete(),
                "late final native-policy mutation is caught before any child by final Store reseal");
        } else if (scenario == ConditionalCase::FailedChild || scenario == ConditionalCase::CancelAfterSpawn) {
            Require(!accepted && reply.started && executions == 1 && actual.mutationStarted() && !actual.complete() &&
                (scenario != ConditionalCase::FailedChild || reply.exitCode != 0),
                "real failed/cancelled native child settles without publishing success or permitting continuation");
            Require(!actual.Execute(Envelope(sequence), request, -1, -1, &reply, after, &error) && executions == 1,
                "failed conditional primary cannot replay a started child");
        }
        if (scenario == ConditionalCase::Complete || scenario == ConditionalCase::CommitCAS)
            Require(accepted, ("conditional native execution " + std::to_string(sequence) + ": " + error).c_str());
        return accepted;
    };
    P::DpkgState after;
    const bool first = execute(1, 1, true, &after);
    if (scenario == ConditionalCase::LateArchiveTamper || scenario == ConditionalCase::FailedChild ||
        scenario == ConditionalCase::CancelAfterSpawn) {
        Require(!first && actual.Close(&error), "refused/settled conditional owner closes with no live child"); return;
    }
    Require(first && after.packages.at("victim:amd64").status == P::DpkgPackageStatus::HalfConfigured &&
        after.packages.at("sample:all").status == P::DpkgPackageStatus::Unpacked && drains == 0,
        "native Breaks produces observed old HalfConfigured debt and defers pending effects");
    Require(execute(2, 3, false, &after) && after.packages.at("victim:amd64").package.version == "2" &&
        after.packages.at("victim:amd64").status == P::DpkgPackageStatus::Unpacked && drains == 0,
        "actual retained successor replaces only approved old generation and remains Unpacked before configure");
    Require(execute(3, 4, false, &after) && after.packages.at("victim:amd64").status == P::DpkgPackageStatus::Installed &&
        after.packages.at("cache:amd64").status == P::DpkgPackageStatus::Installed && drains == 1 && !actual.complete(),
        "exact reviewed restore endpoint then native trigger drain settle debt before remaining primary");
    Require(execute(4, 2, false, &after) && after.packages.at("sample:all").status == P::DpkgPackageStatus::Installed &&
        after.packages.at("victim:amd64").package.version == "2" && drains == 1 && !actual.complete(),
        "every remaining reviewed primary must complete before extended-state commit");
    unsigned commits = 0;
    const bool committed = actual.Commit(Envelope(5), options.changes, options.expectedExtendedState, &error, [&] {
        ++commits;
        if (scenario == ConditionalCase::CommitCAS) Write(options.selected.environment.extendedStates, "external concurrent bytes\n");
    });
    if (scenario == ConditionalCase::CommitCAS)
        Require(!committed && !actual.complete() && commits == 1 &&
            ConditionalRead(options.selected.environment.extendedStates) == "external concurrent bytes\n",
            "actual compare-and-replace preserves concurrent bytes even after commit start notification");
    else Require(committed && actual.complete() && commits == 1 &&
        ConditionalRead(options.selected.environment.extendedStates).find("Package: sample") != std::string::npos,
        "only full actual primary completion, zero debt and quiescence admit real CAS");
    Require(policies == executions && starts == executions && settlements == channelScopes && executions == 5 && firstUnpackInputs > 0,
        "four primaries plus one drain have exactly one policy acknowledgment/start/settlement each");
    Require(actual.Close(&error), "complete conditional owner closes after all real children were reaped");
}
}

int main() {
    ConditionalHostGuardFixtures();
    unsigned lateBoundary = 0;
    for (const auto scenario : {ConditionalCase::Complete, ConditionalCase::FailedChild, ConditionalCase::LateArchiveTamper,
        ConditionalCase::CancelAfterSpawn, ConditionalCase::CommitCAS}) {
        ConditionalFixture fixture(scenario);
        const pid_t child = fork(); Require(child >= 0, "spawn direct authenticated helper owner below real lock parent");
        if (child == 0) { ConditionalOwnerChild(fixture, scenario, lateBoundary); _exit(0); }
        int status = 0; Require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "connected disposable conditional Owner scenario");
        if (scenario == ConditionalCase::Complete) {
            lateBoundary = static_cast<unsigned>(std::stoul(ConditionalRead(fixture.root + "/native-input-count")));
            Require(lateBoundary > 0, "successful real call chain locates actual final first-Unpack producer boundary");
        }
    }
    std::cout << "connected conditional Owner fixtures passed (labelled distributor producer seam)\n";
}
