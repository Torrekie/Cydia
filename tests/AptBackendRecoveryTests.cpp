/* Real GetArchives provenance through the native backend; no downloads/dpkg.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptNativeBackend.hpp"
#include "Cydia/AptRuntime.hpp"
#include <apt-pkg/acquire.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgsystem.h>
#include <apt-pkg/strutl.h>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <unistd.h>

// The fixture supplies only Cydia's selected runtime policy. Actual cache,
// ordering, archive construction, records and source matching use libapt.
namespace CydiaAPT {
RepositorySecurityMode GetRepositorySecurityMode() { return RepositorySecurityMode::Warning; }
bool CachedRepositoryTrustValid() { return true; }
const std::string &PackageInstallPrefix() { static const std::string prefix = "/"; return prefix; }
const std::vector<std::string> &RegisteredArchitectures() {
    static const std::vector<std::string> architectures{"amd64", "i386"}; return architectures;
}
const std::vector<std::string> &Architectures() { return RegisteredArchitectures(); }
bool IsArchitectureSupported(const std::string &architecture) {
    return architecture == "all" || architecture == "amd64" || architecture == "i386";
}
}
namespace {
using namespace CydiaAPT;
namespace P = CydiaAPT::Provider;
void Require(bool good, const char *message) {
    if (good) return;
    std::cerr << "[apt-recovery-backend] " << message << '\n'; _error->DumpErrors(); std::exit(1);
}
void Write(const std::string &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc); file << bytes; Require(file.good(), "write fixture");
}
std::string Read(const std::string &path) {
    std::ifstream file(path, std::ios::binary); return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
std::string Hash(const std::string &bytes, Hashes::SupportedHashes kind = Hashes::SHA256SUM) {
    Hashes hash(kind); Require(hash.Add(bytes.data(), bytes.size()), "hash fixture");
    return hash.GetHashString(kind).HashValue();
}
std::string Record(const std::string &name, const std::string &version, const std::string &architecture,
        const std::string &extra = "") {
    const auto bytes = name + ':' + version + ':' + architecture;
    return "Package: " + name + "\nVersion: " + version + "\nArchitecture: " + architecture +
        "\nMaintainer: Fixture <fixture@example.invalid>\nDescription: fixture\nFilename: pool/" + name + '_' + architecture +
        ".deb\nSize: " + std::to_string(bytes.size()) + "\nSHA256: " + Hash(bytes) + '\n' + extra + '\n';
}
std::string ConfigurationText() { std::ostringstream stream; _config->Dump(stream); return stream.str(); }
template<class T> std::string Encoded(const T &value) {
    std::string bytes; Require(P::Encode(value, &bytes), "encode fixture value"); return bytes;
}
class Status final : public pkgAcquireStatus {
public:
    bool MediaChange(std::string, std::string) override { Require(false, "preview requested media"); return false; }
    void Start() override { Require(false, "preview started acquisition"); }
};
struct Fixture {
    std::string root, records, sourceBytes;
    RuntimeDescriptor runtime;
    P::Binding binding;
    CydiaPackages::ArchiveLayout layout = {"/", {"/var/jb"}};
    Status status;
    std::unique_ptr<Internal::NativeBackend> backend;
    explicit Fixture(bool duplicateRecord = false, bool mixedHashOrigins = false) {
        char pattern[] = "/tmp/cydia-recovery-backend-XXXXXX";
        const char *made = mkdtemp(pattern); Require(made, "create fixture"); root = made;
        for (const char *path : {"etc", "etc/parts", "lists", "lists/partial", "archives", "archives/partial", "log"})
            std::filesystem::create_directories(root + '/' + path);
        runtime.architecture = "amd64"; runtime.registeredArchitectures = RegisteredArchitectures();
        runtime.acquisitionArchitectures = runtime.registeredArchitectures; runtime.packageInstallPrefix = "/";
        runtime.sourceListPath = root + "/etc/sources.list"; runtime.sourcePartsDirectory = root + "/etc/parts";
        runtime.listsDirectory = root + "/lists";
        binding.providerIdentifier = "recovery-fixture"; binding.session = std::string(64, 'a');
        binding.configurationIdentity = "config-1"; binding.policyIdentity = "policy-1";
        binding.packageStateIdentity = "state-1"; binding.cacheEpoch = 1; binding.selectionRevision = 1; binding.review = "review-1";
        runtime.binding.providerIdentifier = binding.providerIdentifier; runtime.binding.session = binding.session;
        runtime.binding.configurationIdentity = binding.configurationIdentity; runtime.binding.policyIdentity = binding.policyIdentity;
        runtime.binding.packageStateIdentity = binding.packageStateIdentity;
        sourceBytes = "deb [trusted=no] https://first.invalid/ ./\ndeb [trusted=yes] https://selected.invalid/ ./\n";
        if (mixedHashOrigins) sourceBytes.replace(sourceBytes.find("trusted=no"), 10, "trusted=yes");
        Write(runtime.sourceListPath, sourceBytes);
        records = Record("base", "1", "amd64") + Record("top", "2", "amd64", "Pre-Depends: base (= 1)\n") +
            Record("portable", "1:3.0~rc1-2", "all") + Record("portable", "2", "amd64") +
            Record("twin", "1", "amd64", "Multi-Arch: same\n") + Record("twin", "1", "i386", "Multi-Arch: same\n");
        for (const char *host : {"first.invalid", "selected.invalid"}) {
            auto bytes = records + (duplicateRecord ? Record("portable", "1:3.0~rc1-2", "all") : "");
            if (mixedHashOrigins && std::string(host) == "selected.invalid") {
                const auto original = Record("portable", "1:3.0~rc1-2", "all");
                const auto extra = Record("portable", "1:3.0~rc1-2", "all", "SHA512: " + Hash("portable:1:3.0~rc1-2:all", Hashes::SHA512SUM) + '\n');
                bytes.replace(bytes.find(original), original.size(), extra);
            }
            Write(runtime.listsDirectory + '/' + URItoFileName(std::string("https://") + host + "/./Packages"), bytes);
        }
        Write(root + "/status", ""); Write(root + "/extended_states", "");
        unsetenv("APT_CONFIG"); _config->Clear(); _error->Discard();
        _config->Set("Dir", "/"); _config->Set("Dir::Etc", root + "/etc");
        _config->Set("Dir::Etc::main", "/dev/null"); _config->Set("Dir::Etc::parts", "/dev/null");
        _config->Set("Dir::Etc::sourcelist", runtime.sourceListPath); _config->Set("Dir::Etc::sourceparts", runtime.sourcePartsDirectory);
        _config->Set("Dir::State", root); _config->Set("Dir::State::status", root + "/status");
        _config->Set("Dir::State::lists", runtime.listsDirectory); _config->Set("Dir::State::extended_states", root + "/extended_states");
        _config->Set("Dir::Cache", root); _config->Set("Dir::Cache::archives", root + "/archives");
        _config->Set("Dir::Cache::archives::Retain::", "one"); _config->Set("Dir::Cache::archives::Retain::", "two");
        _config->Set("Dir::Cache::pkgcache", ""); _config->Set("Dir::Cache::srcpkgcache", "");
        _config->Set("Dir::Log", root + "/log"); _config->Set("Dir::Bin::dpkg", root + "/forbidden-dpkg");
        _config->Set("APT::Architecture", "amd64"); _config->Set("APT::Architectures::", "amd64"); _config->Set("APT::Architectures::", "i386");
        _config->Set("APT::Sandbox::User", ""); _config->Set("Debug::NoLocking", true); _config->Set("Acquire::Languages", "none");
        Require(pkgInitConfig(*_config) && pkgInitSystem(*_config, _system), "initialize isolated APT");
        backend = Internal::CreateNativeBackend(status);
        Require(backend->openCache(), "open real backend cache"); backend->createCacheViews();
        Require(backend->loadSources(), "load real sources");
    }
    ~Fixture() { backend.reset(); std::filesystem::remove_all(root); }
    void Select(const char *route) {
        const auto handle = backend->packageHandle(route, "amd64");
        Require(handle.valid() && backend->installPackage(handle) && backend->resolveDependencies(), "select exact package");
    }
    RecoveryCaptureResult Capture(const std::function<bool()> &cancelled = {}) {
        auto *original = _config; const auto config = ConfigurationText();
        const auto result = backend->captureRecoveryReview(runtime, binding, layout, cancelled);
        Require(_config == original && ConfigurationText() == config, "preview did not restore exact configuration");
        Require(Read(runtime.sourceListPath) == sourceBytes && Read(root + "/status").empty() && Read(root + "/extended_states").empty(),
            "preview altered package/source state");
        Require(std::filesystem::is_empty(root + "/log") && !std::filesystem::exists(root + "/forbidden"), "preview invoked external effects");
        Require(!std::filesystem::exists(root + "/archives/lock"), "preview created an archive lock");
        return result;
    }
};
void SelectedOriginsAndExactArchitectures() {
    Fixture f; f.Select("top"); f.Select("portable:all"); f.Select("twin:amd64"); f.Select("twin:i386");
    const auto before = f.backend->transactionData();
    const auto result = f.Capture(); Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
    Require(result.review.execution.archives.size() == 5, "GetArchives selection omitted a dependency or architecture");
    bool native = false, foreign = false, all = false;
    for (const auto &archive : result.review.execution.archives) {
        Require(archive.sourceURI == "https://selected.invalid/" && archive.sourceDefinitionOrdinal == 1 &&
            archive.sourceIndexURI == "https://selected.invalid/./Packages" &&
            archive.sourceIndexPath == f.runtime.listsDirectory + '/' + URItoFileName(archive.sourceIndexURI),
            "review did not bind the trusted origin selected by GetArchives");
        const auto leaf = QuoteString(archive.package.package, "_:") + '_' + QuoteString(archive.package.version, "_:") + '_' +
            QuoteString(archive.package.architecture, "_:.") + ".deb";
        Require(archive.path == f.root + "/archives/" + leaf, "review path used partial directory or unescaped version");
        const auto record = Read(archive.sourceIndexPath).substr(archive.recordOffset, archive.recordSize);
        Require(record.find("Package: " + archive.package.package + '\n') == 0 && archive.sourceIndexIdentity == "SHA256:" + Hash(f.records),
            "archive did not retain exact native record evidence");
        native = native || (archive.package.package == "twin" && archive.package.architecture == "amd64");
        foreign = foreign || (archive.package.package == "twin" && archive.package.architecture == "i386");
        all = all || (archive.package.package == "portable" && archive.package.architecture == "all" && archive.package.version == "1:3.0~rc1-2");
    }
    Require(native && foreign && all, "native, foreign, or all identity was lost");
    const auto repeated = f.Capture(); Require(repeated.status == RecoveryCaptureStatus::Recorded, repeated.errorCode.c_str());
    Require(Encoded(before) == Encoded(f.backend->transactionData()) && Encoded(result.review) == Encoded(repeated.review),
        "review mutated selection or retained an earlier package-manager ordering");
}
void ExistingArchivesRemainUntouched() {
    for (unsigned variant = 0; variant != 3; ++variant) {
        Fixture f; f.Select("portable:all");
        const auto leaf = QuoteString("portable", "_:") + '_' + QuoteString("1:3.0~rc1-2", "_:") + "_all.deb";
        const auto final = f.root + "/archives/" + leaf, partial = f.root + "/archives/partial/" + leaf;
        // Includes a size-correct cached archive, wrong-size final, and missing
        // final with oversized partial: all must preview the same final path.
        const std::string bytes = variant == 0 ? "portable:1:3.0~rc1-2:all" : "wrong size";
        if (variant != 2) Write(final, bytes);
        Write(partial, std::string(4096, 'p'));
        const auto result = f.Capture(); Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
        Require(result.review.execution.archives.size() == 1 && result.review.execution.archives.front().path == final,
            "cache availability changed planned final archive path");
        Require((variant == 2 ? !std::filesystem::exists(final) : Read(final) == bytes) && Read(partial) == std::string(4096, 'p'),
            "GetArchives preview touched a cached or partial archive");
    }
}
void MixedHashOrigins() {
    // Both origins are eligible. APT chooses the first record but aggregates
    // the additional SHA512 from its alternative; the review keeps the exact
    // chosen record's SHA256 proof instead of borrowing the alternative record.
    Fixture f(false, true); f.Select("portable:all");
    const auto result = f.Capture(); Require(result.status == RecoveryCaptureStatus::Recorded, result.errorCode.c_str());
    Require(result.review.execution.archives.size() == 1, "mixed-hash origins changed selected archive count");
    const auto &archive = result.review.execution.archives.front();
    Require(archive.sourceURI == "https://first.invalid/" && archive.sourceDefinitionOrdinal == 0 &&
        archive.hashes.count("SHA256") == 1 && archive.hashes.count("SHA512") == 0,
        "mixed-hash origins borrowed an alternative record or were rejected");
}
void RefusalsAndCancellation() {
    {
        Fixture f; f.Select("portable:all"); _config->Set("RootDir", f.root);
        const auto result = f.Capture(); Require(result.errorCode == "recovery_rootdir_ordering_unsupported", "RootDir was not refused before acquisition");
    }
    {
        Fixture f; f.Select("portable:all");
        Write(f.runtime.sourcePartsDirectory + "/duplicate.list", "deb [trusted=yes] https://selected.invalid/ ./\n");
        const auto result = f.Capture(); Require(result.status != RecoveryCaptureStatus::Recorded &&
            result.errorCode == "recovery_source_association_ambiguous", "ambiguous source definitions were guessed");
    }
    {
        Fixture f(true); f.Select("portable:all");
        const auto result = f.Capture(); Require(result.status != RecoveryCaptureStatus::Recorded &&
            result.errorCode == "recovery_archive_origin_ambiguous", "duplicate equal source records were guessed");
    }
    {
        Fixture f; f.Select("portable:all"); unsigned calls = 0;
        const auto result = f.Capture([&] { return ++calls > 1; });
        Require(result.status == RecoveryCaptureStatus::Cancelled, "in-preview cancellation was ignored");
        auto *original = _config; const auto config = ConfigurationText(); calls = 0;
        bool threw = false;
        try { f.backend->captureRecoveryReview(f.runtime, f.binding, f.layout, [&]() -> bool {
            if (++calls > 1) throw std::runtime_error("fixture cancellation");
            return false;
        }); } catch (const std::runtime_error &) { threw = true; }
        Require(threw && _config == original && ConfigurationText() == config, "exception leaked preview configuration");
        const auto retry = f.Capture(); Require(retry.status == RecoveryCaptureStatus::Recorded, retry.errorCode.c_str());
    }
    {
        Fixture f; f.Select("portable:all"); _config->Set("DPkg::Pre-Invoke::", "touch " + f.root + "/forbidden");
        Require(f.Capture().errorCode == "recovery_hooks_unsupported", "preview accepted an unrecorded hook");
    }
}
}
int main() {
    SelectedOriginsAndExactArchitectures(); ExistingArchivesRemainUntouched(); MixedHashOrigins(); RefusalsAndCancellation();
    std::cout << "[apt-recovery-backend] GetArchives origin/path/isolation fixtures passed\n";
}
