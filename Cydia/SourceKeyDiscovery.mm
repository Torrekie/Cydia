/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceKeyDiscovery.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/Database.h"
#include "Cydia/Package.h"
#include "Cydia/Source.h"
#include "Cydia/DpkgRunner.h"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/KeyringVerifier.hpp"
#include "Cydia/PrivilegedClient.h"
#include "Cydia/SourceDocumentStore.hpp"
#include <apt-pkg/dirstream.h>
#include <apt-pkg/error.h>
#include <apt-pkg/extracttar.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <dirent.h>
#include <fcntl.h>
#include <map>
#include <set>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT {
namespace {
namespace Keys = CydiaRuntime::Keyring;
namespace Privileged = CydiaRuntime::Privileged;
namespace Client = CydiaRuntime::PrivilegedClient;
std::string Bytes(NSString *value) { return value.UTF8String ?: ""; }
NSString *String(const std::string &value) { return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding]; }
std::string Lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
bool Hex(const std::string &value, std::size_t length) {
    if (value.size() != length) return false;
    for (char c : value) if (!(c >= '0' && c <= '9') && !(c >= 'A' && c <= 'F') && !(c >= 'a' && c <= 'f')) return false;
    return true;
}
bool Suffix(const std::string &value, const char *suffix) {
    const std::string ending(suffix);
    return value.size() >= ending.size() && value.compare(value.size() - ending.size(), ending.size(), ending) == 0;
}
bool KeyFile(const std::string &path) {
    const std::string lower(Lower(path));
    for (const char *suffix : {".gpg", ".asc", ".pgp", ".pub", ".key"}) if (Suffix(lower, suffix)) return true;
    return false;
}
NSURLComponents *Resource(const std::string &value, bool httpsOnly = false) {
    if (value.empty() || value.size() > 8192 || value.find_first_of("\r\n\0", 0, 3) != std::string::npos) return nil;
    NSURLComponents *url([NSURLComponents componentsWithString:String(value)]);
    NSString *scheme(url.scheme.lowercaseString);
    if (!url.host.length || url.user.length || url.password.length || url.fragment.length ||
        (![scheme isEqualToString:@"https"] && (httpsOnly || ![scheme isEqualToString:@"http"]))) return nil;
    return url.URL ? url : nil;
}
bool SameOrigin(const std::string &a, const std::string &b) {
    NSURLComponents *left(Resource(a)), *right(Resource(b));
    if (!left || !right || ![left.scheme.lowercaseString isEqualToString:right.scheme.lowercaseString] ||
        ![left.host.lowercaseString isEqualToString:right.host.lowercaseString]) return false;
    const NSInteger lp(left.port ? left.port.integerValue : ([left.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80));
    const NSInteger rp(right.port ? right.port.integerValue : ([right.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80));
    return lp == rp;
}
std::string RelativeURI(const std::string &base, const std::string &relative) {
    if (!Resource(base) || relative.empty() || relative.find_first_of("\r\n\0", 0, 3) != std::string::npos) return "";
    NSURL *url([NSURL URLWithString:String(relative) relativeToURL:[NSURL URLWithString:String(base)]]);
    const std::string result(Bytes(url.absoluteURL.absoluteString));
    return Resource(result) && SameOrigin(base, result) ? result : "";
}
void Warn(SourceKeyDiscoveryResult *result, const std::string &code) {
    if (std::find(result->warnings.begin(), result->warnings.end(), code) == result->warnings.end()) result->warnings.push_back(code);
}
class Budget {
    const std::function<bool()> &cancelled_;
    std::chrono::steady_clock::time_point deadline_;
    SourceKeyDiscoveryResult &result_;
  public:
    Budget(unsigned seconds, const std::function<bool()> &cancelled, SourceKeyDiscoveryResult &result) :
        cancelled_(cancelled), deadline_(std::chrono::steady_clock::now() + std::chrono::seconds(std::max(1U, std::min(seconds, 120U)))), result_(result) {}
    bool stopped() {
        if (cancelled_ && cancelled_()) { result_.status = SourceKeyDiscoveryStatus::Cancelled; return true; }
        if (std::chrono::steady_clock::now() >= deadline_) { result_.status = SourceKeyDiscoveryStatus::TimedOut; return true; }
        return false;
    }
    unsigned remaining() {
        if (stopped()) return 0;
        return static_cast<unsigned>(std::max<std::int64_t>(1, std::chrono::duration_cast<std::chrono::seconds>(deadline_ - std::chrono::steady_clock::now()).count()));
    }
};
bool PublicFile(const std::string &path, std::string *bytes) {
    Privileged::Error error;
    if (!Privileged::ValidateRootOwnedPath(path, false, false, &error)) return false;
    const int fd(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (fd < 0) return false;
    struct stat st;
    bool valid(fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 && static_cast<std::uint64_t>(st.st_size) <= Keys::MaximumKeyBytes);
    bytes->clear();
    if (valid) {
        bytes->resize(static_cast<std::size_t>(st.st_size)); std::size_t offset(0);
        while (offset < bytes->size()) {
            const ssize_t count(read(fd, &(*bytes)[offset], bytes->size() - offset));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { valid = false; break; } offset += static_cast<std::size_t>(count);
        }
        struct stat after;
        valid = valid && fstat(fd, &after) == 0 && st.st_size == after.st_size && st.st_mtime == after.st_mtime && st.st_ctime == after.st_ctime;
    }
    close(fd); return valid;
}
void LocalFiles(std::vector<std::string> *paths, const std::string &directory) {
    Privileged::Error error;
    if (directory.empty() || !Privileged::ValidateRootOwnedPath(directory, true, false, &error)) return;
    DIR *dir(opendir(directory.c_str())); if (!dir) return;
    std::vector<std::string> found;
    while (const auto entry = readdir(dir)) {
        const std::string leaf(entry->d_name);
        if (!leaf.empty() && leaf[0] != '.' && KeyFile(leaf)) found.push_back(directory + '/' + leaf);
        if (found.size() >= 128) break;
    }
    closedir(dir); std::sort(found.begin(), found.end()); paths->insert(paths->end(), found.begin(), found.end());
}
bool ManifestFields(const std::string &payload, std::vector<std::string> *fields) {
    Privileged::Error error;
    for (std::size_t count(0); count <= 256; ++count)
        if (Privileged::ParseFields(payload, count, fields, &error)) return true;
    return false;
}
struct PackageChoice {
    std::string package, version, installedVersion, architecture, uri, hash, size;
    bool installed = false;
    unsigned rank = 0;
};
bool MatchesPackageIdentity(const std::string &fields, const PackageChoice &package) {
    if (fields.empty() || fields.size() > 8192 || fields.find('\0') != std::string::npos) return false;
    std::map<std::string, std::string> values;
    std::istringstream lines(fields); std::string line;
    while (std::getline(lines, line)) {
        const auto colon(line.find(':'));
        if (colon == std::string::npos || line.find('\r') != std::string::npos) return false;
        const std::string name(Lower(line.substr(0, colon)));
        if (name != "package" && name != "version" && name != "architecture") return false;
        const auto first(line.find_first_not_of(" \t", colon + 1)), last(line.find_last_not_of(" \t"));
        if (first == std::string::npos || last < first || !values.emplace(name, line.substr(first, last - first + 1)).second) return false;
    }
    std::string name(package.package); const auto colon(name.find(':')); if (colon != std::string::npos) name.erase(colon);
    return values.size() == 3 && values["package"] == name && values["version"] == package.version &&
        values["architecture"] == package.architecture;
}
class ArchiveFile {
    std::string path_;
  public:
    ~ArchiveFile() { if (!path_.empty()) unlink(path_.c_str()); }
    const std::string &path() const { return path_; }
    bool Write(const std::string &parent, const std::string &bytes) {
        std::string pattern(parent + "/.keyring-package.XXXXXX"); std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
        const int fd(mkstemp(name.data())); if (fd < 0) return false; path_ = name.data();
        std::size_t offset(0); bool okay(fchmod(fd, 0600) == 0);
        while (okay && offset < bytes.size()) {
            const ssize_t count(write(fd, bytes.data() + offset, bytes.size() - offset));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { okay = false; break; } offset += static_cast<std::size_t>(count);
        }
        close(fd); return okay;
    }
};
struct ExtractedKey { std::string path, bytes; };
class KeyPayload : public pkgDirStream {
    Budget &budget_;
    std::vector<ExtractedKey> keys_;
    bool current_ = false;
    std::size_t entries_ = 0, total_ = 0;
  public:
    explicit KeyPayload(Budget &budget) : budget_(budget) {}
    const std::vector<ExtractedKey> &keys() const { return keys_; }
    bool DoItem(Item &item, int &fd) override {
        fd = -2; current_ = false;
        if (budget_.stopped() || ++entries_ > 512 || item.Size > 16 * 1024 * 1024 || total_ > 16 * 1024 * 1024 - item.Size) return false;
        total_ += static_cast<std::size_t>(item.Size);
        if (item.Type == Item::File && item.Name && KeyFile(item.Name) && item.Size > 0 && item.Size <= Keys::MaximumKeyBytes) {
            if (keys_.size() == 16) return false;
            keys_.push_back({item.Name, ""}); current_ = true;
        }
        return true;
    }
    bool Process(Item &, const unsigned char *data, unsigned long long size, unsigned long long) override {
        if (budget_.stopped()) return false;
        if (current_) keys_.back().bytes.append(reinterpret_cast<const char *>(data), static_cast<std::size_t>(size));
        return true;
    }
    bool FinishedFile(Item &, int) override { current_ = false; return !budget_.stopped(); }
    bool Fail(Item &, int) override { return false; }
};
struct ErrorScope { ErrorScope() { _error->PushToStack(); } ~ErrorScope() { _error->RevertToStack(); } };
} // namespace

SourceKeyDiscoveryResult DiscoverSourceSigningKeys(Database *database, const SourcePreflightResult &preflight,
    const SourceKeyDiscoveryRequest &request, const std::function<bool()> &cancelled) {
    SourceKeyDiscoveryResult result; Budget budget(request.timeoutSeconds, cancelled, result);
    Keys::VerificationLimits verification; verification.cancelled = [&]() { return budget.stopped(); };
    if (budget.stopped()) return result;
    Privileged::Error error; const std::string verifier(GpgExecutablePath());
    if (!Privileged::ValidateRootOwnedPath(verifier, false, true, &error)) {
        result.status = SourceKeyDiscoveryStatus::VerifierUnavailable; return result;
    }
    const auto fetch = [&](const std::string &uri, std::size_t maximum) {
        SourceResourceResult fetched;
        if (budget.stopped() || result.requestsPerformed >= 24 || !Resource(uri)) return fetched;
        SourceResourceRequest resource; resource.uri = uri; resource.temporaryParent = request.temporaryParent;
        resource.timeoutSeconds = std::min(12U, budget.remaining()); resource.maximumBytes = maximum;
        ++result.requestsPerformed;
        return FetchSourceResource(resource, [&]() { return budget.stopped(); });
    };
    // Account for the complete draft before attempting a key match. APT can
    // stop after the first failed URI/suite, so its captured metadata alone
    // must not define the scope of a successful discovery result.
    const auto identity = [](std::string uri, const std::string &suite) {
        while (!uri.empty() && uri.back() == '/') uri.pop_back();
        return std::make_pair(uri, suite);
    };
    std::map<std::pair<std::string, std::string>, SourceMetadata> scopes;
    if (!request.definition.empty()) {
        const auto document(CydiaSources::ParseDocument("draft", request.format, request.definition));
        if (!document.valid()) { result.status = SourceKeyDiscoveryStatus::MetadataUnavailable; return result; }
        for (const auto &definition : document.definitions) for (const auto &uri : definition.uris) for (const auto &suite : definition.suites) {
            const auto key(identity(uri, suite));
            if (scopes.count(key)) continue; // A matching deb/deb-src pair shares metadata.
            if (scopes.size() == 4 || !Resource(uri)) {
                Warn(&result, "key_discovery_scope_unavailable");
                result.status = SourceKeyDiscoveryStatus::MetadataUnavailable; return result;
            }
            SourceMetadata source; source.uri = uri; source.suitePath = suite;
            const std::string base(uri + (Suffix(uri, "/") ? "" : "/"));
            source.metadataBaseURI = RelativeURI(base, Suffix(suite, "/") ? suite : "dists/" + suite + "/");
            for (const auto &captured : preflight.repositories)
                if (identity(captured.uri, captured.suitePath) == key) {
                    const std::string fallback(source.metadataBaseURI);
                    source = captured;
                    if (source.metadataBaseURI.empty()) source.metadataBaseURI = fallback;
                    break;
                }
            scopes.emplace(key, source);
        }
    } else {
        for (const auto &source : preflight.repositories) scopes.emplace(identity(source.uri, source.suitePath), source);
        if (scopes.size() > 4) {
            Warn(&result, "key_discovery_scope_unavailable");
            result.status = SourceKeyDiscoveryStatus::MetadataUnavailable; return result;
        }
    }
    std::vector<SourceMetadata> metadata;
    for (const auto &scope : scopes) metadata.push_back(scope.second);
    std::vector<SourceMetadata> signedMetadata;
    std::set<std::string> missingIdentifiers;
    for (auto &source : metadata) {
        if (budget.stopped()) return result;
        if ((!source.clearSigned && source.detachedSignature.empty()) || source.metadata.empty()) {
            if (!source.metadataBaseURI.empty() && SameOrigin(request.repositoryURI, source.metadataBaseURI)) {
                const auto inRelease(fetch(source.metadataBaseURI + "InRelease", 4 * 1024 * 1024));
                if (inRelease.status == SourceCheckStatus::Complete && inRelease.bytes.compare(0, 34, "-----BEGIN PGP SIGNED MESSAGE-----") == 0) {
                    source.metadata = inRelease.bytes; source.clearSigned = true; source.detachedSignature.clear();
                } else {
                    const auto release(fetch(source.metadataBaseURI + "Release", 4 * 1024 * 1024));
                    const auto signature(fetch(source.metadataBaseURI + "Release.gpg", Keys::MaximumKeyBytes));
                    if (release.status == SourceCheckStatus::Complete) {
                        source.metadata = release.bytes; source.clearSigned = false;
                        source.detachedSignature = signature.status == SourceCheckStatus::Complete ? signature.bytes : "";
                    }
                }
            }
        }
        if (source.metadata.empty() || (!source.clearSigned && source.detachedSignature.empty())) continue;
        signedMetadata.push_back(source);
        Keys::RepositorySignatureReview review;
        Keys::VerifyRepositorySignature(verifier, request.temporaryParent, "", source.metadata, source.detachedSignature, &review, &error, verification);
        for (const auto &identifier : review.missingKeyIdentifiers)
            if (Hex(identifier, 40) || Hex(identifier, 64)) missingIdentifiers.insert(identifier);
    }
    if (budget.stopped()) return result;
    if (signedMetadata.empty() || signedMetadata.size() != metadata.size()) {
        // A transport failure is not evidence of an unsigned repository. Only
        // APT's explicit unsigned diagnostic for a single, fetched metadata
        // scope supports that explanation; mixed or absent scopes stay unknown.
        const auto unsignedIssue = [](const FetchFailureData &failure) { return failure.kind == FetchDiagnosticKind::UnsignedRepository; };
        const bool unsignedRepository(metadata.size() == 1 && !metadata.front().metadata.empty() &&
            !metadata.front().clearSigned && metadata.front().detachedSignature.empty() &&
            (std::any_of(preflight.warnings.begin(), preflight.warnings.end(), unsignedIssue) ||
             std::any_of(preflight.failures.begin(), preflight.failures.end(), unsignedIssue)));
        result.status = unsignedRepository ? SourceKeyDiscoveryStatus::NoSignedMetadata : SourceKeyDiscoveryStatus::MetadataUnavailable;
        if (!unsignedRepository) Warn(&result, "key_discovery_incomplete_metadata");
        return result;
    }

    std::set<std::string> inspectedBytes;
    std::map<std::string, std::size_t> acceptedInputs;
    const auto accept = [&](const std::string &bytes, SourceSigningKeyCandidate candidate) {
        if (budget.stopped() || result.candidatesExamined >= 96 || result.candidates.size() == 16 || bytes.empty() || bytes.size() > Keys::MaximumKeyBytes) return;
        Hashes hash(Hashes::SHA256SUM);
        if (!hash.Add(bytes.data(), bytes.size())) return;
        const std::string digest(hash.GetHashString(Hashes::SHA256SUM).HashValue());
        if (!inspectedBytes.insert(digest).second) {
            // Promote an identical copied candidate to a package-managed
            // reference when installed-package ownership becomes available.
            const auto accepted(acceptedInputs.find(digest));
            if (!candidate.referencePath.empty() && accepted != acceptedInputs.end()) {
                    auto &existing(result.candidates[accepted->second]);
                    existing.referencePackage = candidate.referencePackage; existing.referencePath = candidate.referencePath;
                    existing.referenceBytes = bytes;
                    existing.package = candidate.package; existing.packagePath = candidate.packagePath; existing.packageVersion = candidate.packageVersion;
                    existing.provenance = SourceKeyProvenance::InstalledPackage; existing.provenanceURI = candidate.provenanceURI;
            }
            return;
        }
        ++result.candidatesExamined;
        if (!Keys::VerifyPublicKey(verifier, request.temporaryParent, bytes, &candidate.publicBytes, &candidate.fingerprints, &error, verification)) return;
        for (const auto &source : signedMetadata) {
            if (budget.stopped()) return;
            Keys::RepositorySignatureReview review;
            if (!Keys::VerifyRepositorySignature(verifier, request.temporaryParent, candidate.publicBytes,
                    source.metadata, source.detachedSignature, &review, &error, verification)) return;
            for (const auto &fingerprint : review.signerFingerprints)
                if (std::find(candidate.signerFingerprints.begin(), candidate.signerFingerprints.end(), fingerprint) == candidate.signerFingerprints.end())
                    candidate.signerFingerprints.push_back(fingerprint);
        }
        if (!candidate.referencePath.empty()) candidate.referenceBytes = bytes;
        for (std::size_t index(0); index != result.candidates.size(); ++index) if (result.candidates[index].publicBytes == candidate.publicBytes) {
            if (!candidate.referencePath.empty()) result.candidates[index] = candidate;
            acceptedInputs[digest] = index;
            return;
        }
        acceptedInputs[digest] = result.candidates.size();
        result.candidates.push_back(candidate);
    };

    std::vector<std::string> localPaths(request.sourceKeyringPaths);
    localPaths.push_back(TrustedKeyringDirectory()); LocalFiles(&localPaths, TrustedKeyringPartsDirectory());
    const auto sources(CydiaSources::ReadEffectiveDocuments({SourceListPath(), SourcePartsDirectory()}));
    if (sources.ready()) for (const auto &stored : sources.documents) for (const auto &definition : stored.document.definitions)
        for (const auto &field : definition.fields) if (Lower(field.name) == "signed-by") {
            std::string values(field.value); std::replace(values.begin(), values.end(), ',', ' ');
            std::istringstream paths(values); std::string path;
            while (paths >> path) if (!path.empty() && path[0] == '/' && localPaths.size() < 256) localPaths.push_back(path);
        }
    std::set<std::string> pathsSeen; unsigned localCount(0);
    for (const auto &path : localPaths) {
        if (budget.stopped()) return result;
        if (path.empty() || !pathsSeen.insert(path).second) continue;
        if (++localCount > 64) break;
        std::string bytes;
        if (!PublicFile(path, &bytes)) continue;
        SourceSigningKeyCandidate candidate; candidate.provenanceURI = path;
        accept(bytes, candidate);
    }

    std::vector<PackageChoice> packages;
    const std::string host(Lower(Bytes(Resource(request.repositoryURI).host)));
    unsigned examinedPackages(0);
    for (Package *package in [database packages]) {
        if (budget.stopped()) return result;
        if (++examinedPackages > 100000) break;
        const std::string name(Bytes([package baseId])), section(Lower(Bytes([package section])));
        if (Lower(name).find("keyring") == std::string::npos && section != "keyrings") continue;
        const auto snapshot([database packageSnapshot:[package handle]]);
        PackageChoice choice; choice.package = Bytes([package dpkgId]); choice.version = snapshot.version; choice.architecture = snapshot.architecture;
        choice.installedVersion = snapshot.installedVersion;
        choice.installed = !choice.installedVersion.empty(); choice.rank = choice.installed ? 2 : 0;
        const std::string homepage(snapshot.record.Field("Homepage"));
        if (!host.empty() && (Lower(name).find(host.substr(0, host.find('.'))) != std::string::npos || Lower(Bytes(Resource(homepage).host)) == host)) choice.rank += 4;
        if (snapshot.state.versionAvailable && IsArchitectureSupported(choice.architecture)) {
            const std::string root(Bytes([[package source] rooturi]));
            choice.uri = RelativeURI(root, snapshot.record.Field("Filename"));
            choice.hash = snapshot.record.Field("SHA256"); choice.size = snapshot.record.Field("Size");
        }
        packages.push_back(choice);
        if (packages.size() == 128) break;
    }
    std::stable_sort(packages.begin(), packages.end(), [](const PackageChoice &a, const PackageChoice &b) { return a.rank > b.rank; });
    unsigned manifests(0);
    for (const auto &package : packages) {
        if (budget.stopped()) return result;
        if (!package.installed || ++manifests > 24) continue;
        const auto listed(Client::RunNativeCommand("--cydia-key-package-files", Privileged::SerializeFields({package.package}),
            128 * 1024, std::max(1U, std::min(4000U, budget.remaining() * 1000))));
        std::vector<std::string> files;
        if (!listed.succeeded() || !ManifestFields(listed.output, &files)) continue;
        for (const auto &path : files) {
            if (budget.stopped()) return result;
            std::string bytes;
            if (!PublicFile(path, &bytes)) continue;
            SourceSigningKeyCandidate candidate; candidate.provenance = SourceKeyProvenance::InstalledPackage;
            candidate.provenanceURI = path; candidate.package = package.package; candidate.packageVersion = package.installedVersion; candidate.packagePath = path;
            const bool armored(bytes.find("-----BEGIN PGP PUBLIC KEY BLOCK-----") != std::string::npos);
            if ((Suffix(path, ".gpg") && !armored) || (Suffix(path, ".asc") && armored)) {
                candidate.referencePackage = package.package; candidate.referencePath = path;
            }
            accept(bytes, candidate);
        }
    }
    if (budget.stopped() || !result.candidates.empty()) return result;
    unsigned publisherCount(0);
    for (const auto &link : request.publisherKeys) {
        if (budget.stopped()) return result;
        if (++publisherCount > 8) break;
        if (!Resource(link.uri, true) || !SameOrigin(request.repositoryURI, link.uri)) continue;
        const auto downloaded(fetch(link.uri, Keys::MaximumKeyBytes));
        if (downloaded.status != SourceCheckStatus::Complete) continue;
        SourceSigningKeyCandidate candidate; candidate.provenance = SourceKeyProvenance::PublisherLink; candidate.provenanceURI = link.uri;
        accept(downloaded.bytes, candidate);
    }
    if (budget.stopped() || !result.candidates.empty()) return result;
    unsigned lookups(0);
    for (const auto &fingerprint : missingIdentifiers) {
        if (budget.stopped()) return result;
        if (++lookups > 4) break;
        const std::string uri("https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x" + fingerprint);
        const auto downloaded(fetch(uri, Keys::MaximumKeyBytes));
        if (downloaded.status != SourceCheckStatus::Complete) continue;
        SourceSigningKeyCandidate candidate; candidate.provenance = SourceKeyProvenance::Keyserver; candidate.provenanceURI = uri;
        accept(downloaded.bytes, candidate);
    }
    if (budget.stopped() || !result.candidates.empty()) return result;
    const std::string archiveTool(DpkgDebExecutablePath());
    if (!Privileged::ValidateRootOwnedPath(archiveTool, false, true, &error)) {
        Warn(&result, "key_package_inspection_unavailable"); return result;
    }
    CydiaRuntime::Dpkg::Runner archiveReader(archiveTool);
    unsigned downloads(0);
    for (const auto &package : packages) {
        if (budget.stopped()) return result;
        if (package.uri.empty() || !Hex(package.hash, 64) || package.size.empty()) continue;
        std::uint64_t size(0); bool validSize(true);
        for (char c : package.size) { if (c < '0' || c > '9' || size > 4 * 1024 * 1024 / 10) { validSize = false; break; } size = size * 10 + c - '0'; }
        if (!validSize || size == 0 || size > 4 * 1024 * 1024) continue;
        if (++downloads > 4) break;
        const auto downloaded(fetch(package.uri, static_cast<std::size_t>(size)));
        if (downloaded.status != SourceCheckStatus::Complete || downloaded.bytes.size() != size) continue;
        Hashes hash(Hashes::SHA256SUM);
        if (!hash.Add(downloaded.bytes.data(), downloaded.bytes.size()) || Lower(hash.GetHashString(Hashes::SHA256SUM).HashValue()) != Lower(package.hash)) {
            Warn(&result, "key_package_hash_mismatch"); continue;
        }
        ArchiveFile archive;
        if (!archive.Write(request.temporaryParent, downloaded.bytes)) continue;
        // Let the configured dpkg-deb read the package format. Its decoder
        // descendants share the bounded runner's private process group, so a
        // stalled decoder cannot outlive cancellation or the discovery budget.
        std::string fields;
        const auto stopped([&]() { return budget.stopped(); });
        if (!archiveReader.RunAndCaptureBounded({"--field", archive.path(), "Package", "Version", "Architecture"},
                &fields, 8192, std::max(1U, std::min(15000U, budget.remaining() * 1000)), stopped).succeeded() ||
            !MatchesPackageIdentity(fields, package)) {
            Warn(&result, "key_package_inspection_failed"); continue;
        }
        std::string tarBytes;
        if (!archiveReader.RunAndCaptureBounded({"--fsys-tarfile", archive.path()}, &tarBytes, 16 * 1024 * 1024,
                std::max(1U, std::min(15000U, budget.remaining() * 1000)), stopped).succeeded() || tarBytes.empty()) {
            Warn(&result, "key_package_inspection_failed"); continue;
        }
        if (budget.stopped()) return result;
        ArchiveFile tar;
        if (!tar.Write(request.temporaryParent, tarBytes)) continue;
        const int fd(open(tar.path().c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)); if (fd < 0) continue;
        ErrorScope errors;
        FileFd file(fd, true); KeyPayload payload(budget);
        // An empty decompressor selects FileFd::None. Only this already
        // bounded tar is parsed; the callback retains public-key bytes in
        // memory and never writes package paths or executes package scripts.
        ExtractTar extract(file, tarBytes.size(), "");
        if (_error->PendingError() || !extract.Go(payload)) continue;
        for (const auto &key : payload.keys()) {
            SourceSigningKeyCandidate candidate; candidate.provenance = SourceKeyProvenance::AvailablePackage;
            candidate.provenanceURI = package.uri; candidate.package = package.package; candidate.packageVersion = package.version; candidate.packagePath = key.path;
            accept(key.bytes, candidate);
        }
    }
    budget.stopped(); return result;
}
} // namespace CydiaAPT
