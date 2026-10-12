/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourcePreflight.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/KeyringImport.hpp"

#include <apt-pkg/acquire.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/gpgv.h>
#include <apt-pkg/indexfile.h>
#include <apt-pkg/metaindex.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/strutl.h>
#include <apt-pkg/tagfile.h>

#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cctype>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <set>
#include <sstream>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaAPT {
namespace {

const std::size_t MaximumDefinition = 128 * 1024;
const std::size_t MaximumMetadata = 10 * 1024 * 1024;

/* The directory is created by this operation and never exposed as a source
 * destination. Do not follow links during accounting or cleanup. */
bool Walk(const std::string &path, std::size_t *bytes, bool remove) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) return errno == ENOENT;
    if (!S_ISDIR(st.st_mode)) {
        if (S_ISREG(st.st_mode) && st.st_size > 0) *bytes += st.st_size;
        return !remove || unlink(path.c_str()) == 0;
    }
    DIR *directory(opendir(path.c_str()));
    if (directory == NULL) return errno == ENOENT;
    bool good(true);
    while (dirent *entry = readdir(directory)) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        good = Walk(path + '/' + entry->d_name, bytes, remove) && good;
    }
    closedir(directory);
    return (!remove || rmdir(path.c_str()) == 0) && good;
}

struct TemporaryDirectory {
    std::string path;
    explicit TemporaryDirectory(const std::string &parent) {
        if (parent.empty() || parent[0] != '/' || parent.find('\0') != std::string::npos) return;
        std::string pattern(parent + "/cydia-source-check.XXXXXX");
        std::vector<char> buffer(pattern.begin(), pattern.end()); buffer.push_back(0);
        if (mkdtemp(buffer.data()) != NULL) path = buffer.data();
    }
    ~TemporaryDirectory() { if (!path.empty()) { std::size_t ignored(0); Walk(path, &ignored, true); } }
};

void CopyConfiguration(const Configuration::Item *item, Configuration *target,
                       const std::string &parent = std::string()) {
    for (; item != NULL; item = item->Next) {
        const std::string name(parent.empty() ? item->Tag : parent + "::" + item->Tag);
        target->Set(name, item->Value);
        CopyConfiguration(item->Child, target, name);
    }
}

/* Swap the configuration pointer rather than trying to undo individual
 * mutations. Acquire methods also modify configuration as they run. */
struct ConfigurationScope {
    Configuration *original;
    Configuration isolated;
    explicit ConfigurationScope(const std::string &root) : original(_config) {
        CopyConfiguration(original->Tree(NULL), &isolated);
        /* Resolve inherited file paths before dropping RootDir, so private
         * temporary paths stay physical while trust, auth.conf and methods
         * retain their effective administrator-selected locations. */
        for (const char *name : {"Dir::Etc", "Dir::Etc::trusted", "Dir::Etc::trustedparts",
                "Dir::Etc::netrc", "Dir::Etc::netrcparts", "Dir::Bin::methods"})
            if (original->Exists(name)) isolated.Set(name, original->FindFile(name));
        isolated.Set("RootDir", "");
        isolated.Set("Dir::State", root);
        isolated.Set("Dir::State::lists", root + "/lists");
        isolated.Set("Dir::State::status", root + "/status");
        isolated.Set("Dir::State::extended_states", root + "/extended_states");
        isolated.Set("Dir::Cache", root + "/cache");
        isolated.Set("Dir::Cache::archives", root + "/cache/archives");
        isolated.Set("Dir::Cache::pkgcache", "");
        isolated.Set("Dir::Cache::srcpkgcache", "");
        isolated.Set("Dir::Log", root + "/log");
        isolated.Set("Dir::Etc::sourceparts", root + "/sources.d");
        isolated.Set("Acquire::Retries", 0);
        isolated.Set("Acquire::PDiffs", false);
        /* A preflight cannot establish the application's cache trust proof.
         * This flag is only consumed inside this fresh, private acquisition. */
        isolated.Set("Cydia::CachedRepositoryTrustValid", true);
        const auto security(GetRepositorySecurityMode());
        if (security == RepositorySecurityMode::Distribution)
            isolated.Clear("Cydia::RepositorySecurityMode");
        else isolated.Set("Cydia::RepositorySecurityMode", RepositorySecurityModeName(security));
        /* Authentication failures invoke their update hook directly from
         * acquire-item, even when ListUpdate is never called. */
        isolated.Clear("APT::Update");
        /* Mirror reporting is an external command, not part of validating
         * this private draft. An empty value would restore APT's default. */
        isolated.Set("Methods::Mirror::ProblemReporting", root + "/disabled-mirror-report");
        _error->PushToStack();
        _config = &isolated;
    }
    ~ConfigurationScope() { _config = original; _error->RevertToStack(); }
};

bool MakeDirectories(const std::string &root) {
    for (const char *part : {"lists", "lists/partial", "lists/auxfiles", "cache", "cache/archives",
             "cache/archives/partial", "sources.d", "log"})
        if (mkdir((root + '/' + part).c_str(), 0700) != 0) return false;
    return true;
}

bool Write(const std::string &path, const std::string &bytes) {
    int fd(open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (fd < 0) return false;
    std::size_t done(0);
    while (done != bytes.size()) {
        const ssize_t count(write(fd, bytes.data() + done, bytes.size() - done));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        done += count;
    }
    const bool closed(close(fd) == 0);
    return done == bytes.size() && closed;
}

bool Read(const std::string &path, std::size_t limit, std::string *bytes) {
    int fd(open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
    if (fd < 0) return false;
    struct stat st;
    bool good(fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0 &&
              static_cast<unsigned long long>(st.st_size) <= limit);
    std::string value;
    char buffer[8192];
    while (good) {
        const ssize_t count(read(fd, buffer, sizeof(buffer)));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { good = false; break; }
        if (count == 0) break;
        if (value.size() + count > limit) { good = false; break; }
        value.append(buffer, count);
    }
    close(fd);
    if (good) *bytes = value;
    return good;
}

void Drain(std::vector<ErrorData> *errors) {
    while (!_error->empty()) {
        ErrorData error;
        error.warning = !_error->PopMessage(error.message);
        errors->push_back(error);
    }
}

std::string Redacted(const std::string &value) {
    URI uri(value); uri.User.clear(); uri.Password.clear(); return std::string(uri);
}

class BoundedStatus : public pkgAcquireStatus {
    const std::function<bool()> cancelled_;
    const std::chrono::steady_clock::time_point deadline_;
    const std::string root_;
    const std::size_t maximumBytes_;
  public:
    SourceCheckStatus reason = SourceCheckStatus::Complete;
    BoundedStatus(const std::function<bool()> &cancelled, unsigned seconds,
                  const std::string &root, std::size_t maximum) : cancelled_(cancelled),
        deadline_(std::chrono::steady_clock::now() + std::chrono::seconds(seconds)),
        root_(root), maximumBytes_(maximum) { MorePulses = true; }
    bool MediaChange(std::string, std::string) override { return false; }
    bool Check() {
        if (cancelled_ && cancelled_()) reason = SourceCheckStatus::Cancelled;
        else if (std::chrono::steady_clock::now() >= deadline_) reason = SourceCheckStatus::TimedOut;
        else {
            std::size_t bytes(0);
            if (!Walk(root_, &bytes, false)) reason = SourceCheckStatus::InternalError;
            else if (bytes > maximumBytes_) reason = SourceCheckStatus::SizeLimit;
        }
        return reason == SourceCheckStatus::Complete;
    }
    bool Pulse(pkgAcquire *owner) override {
        pkgAcquireStatus::Pulse(owner);
        if (!Check()) return false;
        if (owner->ItemsEnd() - owner->ItemsBegin() > 256) { reason = SourceCheckStatus::SizeLimit; return false; }
        for (auto item = owner->ItemsBegin(); item != owner->ItemsEnd(); ++item)
            if ((*item)->FileSize > maximumBytes_) { reason = SourceCheckStatus::SizeLimit; return false; }
        return true;
    }
};

class BoundedFile : public pkgAcqFile {
    const std::size_t maximum_;
  public:
    BoundedFile(pkgAcquire *owner, const SourceResourceRequest &request, const std::string &path) :
        pkgAcqFile(owner, request.uri, HashStringList(), 0, "", "", "", path, false),
        maximum_(request.maximumBytes) {}
    std::string Custom600Headers() const override {
        return pkgAcqFile::Custom600Headers() + "\nMaximum-Size: " + std::to_string(maximum_);
    }
};

#if defined(APT_CYDIA_AUTHENTICATION_PROVENANCE)
FetchDiagnosticKind AuthenticationKind(pkgAcquire::Item::AuthenticationIssue issue) {
    typedef pkgAcquire::Item::AuthenticationIssue Issue;
    switch (issue) {
        case Issue::Unsigned: return FetchDiagnosticKind::UnsignedRepository;
        case Issue::MissingKey: return FetchDiagnosticKind::MissingSigningKey;
        case Issue::UnusableSignature: return FetchDiagnosticKind::UnusableSigningKey;
        case Issue::WeakSecurity: return FetchDiagnosticKind::WeakRepository;
        case Issue::MissingRelease: return FetchDiagnosticKind::MissingReleaseFile;
        case Issue::TrustDowngrade: return FetchDiagnosticKind::RepositoryTrustDowngrade;
        case Issue::BadSignature: return FetchDiagnosticKind::BadRepositorySignature;
        case Issue::InvalidSignature: return FetchDiagnosticKind::InvalidRepositorySignature;
        case Issue::None: return FetchDiagnosticKind::General;
    }
    return FetchDiagnosticKind::General;
}
#endif

std::vector<std::string> Words(const std::string &value) {
    std::vector<std::string> words; std::istringstream stream(value); std::string word;
    while (stream >> word) words.push_back(word);
    return words;
}

void MetadataFields(const std::string &path, SourceMetadata *metadata) {
    _error->PushToStack();
    FileFd file;
    if (OpenMaybeClearSignedFile(path, file)) {
        pkgTagFile tags(&file);
        pkgTagSection section;
        if (tags.Step(section)) {
            metadata->architectures = Words(section.FindS("Architectures"));
            metadata->components = Words(section.FindS("Components"));
            metadata->label = section.FindS("Label");
            metadata->origin = section.FindS("Origin");
        }
    }
    _error->RevertToStack();
}

/* Read only Architecture lines with bounded buffers. An empty repository is
 * Unknown; finding a single native/configured foreign/all package establishes
 * availability, never installation-layout compatibility. */
bool InspectArchitectures(const std::string &path, BoundedStatus *status,
                          std::size_t limit, bool *sawPackage, bool *supported) {
    FileFd file(path, FileFd::ReadOnly, FileFd::Extension);
    if (!file.IsOpen()) return false;
    char line[4096]; std::size_t readBytes(0), lines(0); bool continuation(false);
    bool package(false), version(false); std::string architecture;
    const auto finish = [&]() {
        if (package && version && !architecture.empty()) {
            *sawPackage = true;
            if (IsArchitectureSupported(architecture)) *supported = true;
        }
        package = false; version = false; architecture.clear();
    };
    while (file.ReadLine(line, sizeof(line)) != NULL) {
        const std::size_t length(strlen(line)); readBytes += length;
        if (readBytes > limit) { status->reason = SourceCheckStatus::SizeLimit; return false; }
        if ((++lines % 256) == 0 && !status->Check()) return false;
        if (!continuation) {
            if (line[0] == '\n' || (line[0] == '\r' && line[1] == '\n')) finish();
            else if (!strncasecmp(line, "Package:", 8)) package = Words(std::string(line + 8)).size() == 1;
            else if (!strncasecmp(line, "Version:", 8)) version = Words(std::string(line + 8)).size() == 1;
            else if (!strncasecmp(line, "Architecture:", 13)) {
                const std::vector<std::string> values(Words(std::string(line + 13)));
                if (values.size() == 1) architecture = values[0];
            }
        }
        if (*supported) return true;
        continuation = length && line[length - 1] != '\n';
    }
    finish();
    return !file.Failed();
}

} // namespace

SourceResourceResult FetchSourceResource(const SourceResourceRequest &request,
                                        const std::function<bool()> &cancelled) {
    SourceResourceResult result;
    const URI uri(request.uri);
    if ((uri.Access != "https" && uri.Access != "http") || uri.Host.empty() ||
        request.uri.find_first_of("\r\n\t") != std::string::npos || request.uri.find('\0') != std::string::npos ||
        request.maximumBytes == 0 || request.maximumBytes > MaximumMetadata ||
        request.timeoutSeconds == 0 || request.timeoutSeconds > 120) {
        result.status = SourceCheckStatus::InvalidDefinition; return result;
    }
    TemporaryDirectory temporary(request.temporaryParent);
    if (temporary.path.empty() || !MakeDirectories(temporary.path)) return result;
    ConfigurationScope configuration(temporary.path);
    for (const char *method : {"http", "https"}) {
        const std::string name(std::string("Acquire::") + method);
        _config->Set((name + "::AllowRedirect").c_str(), false);
        _config->Set((name + "::" + uri.Host + "::AllowRedirect").c_str(), false);
        _config->Set((name + "::Timeout").c_str(), static_cast<int>(request.timeoutSeconds));
        _config->Set((name + "::" + uri.Host + "::Timeout").c_str(), static_cast<int>(request.timeoutSeconds));
        _config->Set((std::string("Binary::") + method + "::" + name + "::AllowRedirect").c_str(), false);
        _config->Set((std::string("Binary::") + method + "::" + name + "::" + uri.Host + "::AllowRedirect").c_str(), false);
    }
    BoundedStatus status(cancelled, request.timeoutSeconds, temporary.path, request.maximumBytes);
    if (!status.Check()) { result.status = status.reason; return result; }
    pkgAcquire fetcher(&status);
    BoundedFile *item(new BoundedFile(&fetcher, request, temporary.path + "/resource"));
    const pkgAcquire::RunResult run(fetcher.Run(100000));
    status.Pulse(&fetcher);
    result.status = status.reason;
    if (result.status == SourceCheckStatus::Complete) {
        if (run != pkgAcquire::Continue || item->Status != pkgAcquire::Item::StatDone || !item->Complete)
            result.status = SourceCheckStatus::Unavailable;
        else if (!Read(temporary.path + "/resource", request.maximumBytes, &result.bytes))
            result.status = SourceCheckStatus::SizeLimit;
    }
    if (!item->ErrorText.empty()) result.errors.push_back({item->ErrorText, false});
    Drain(&result.errors);
    return result;
}

SourcePreflightResult RunSourcePreflight(const SourcePreflightRequest &request,
                                        const std::function<bool()> &cancelled) {
    SourcePreflightResult result;
    if (request.definition.empty() || request.definition.size() > MaximumDefinition ||
        request.definition.find('\0') != std::string::npos || request.timeoutSeconds == 0 ||
        request.timeoutSeconds > 300 || request.maximumBytes < MaximumMetadata ||
        request.maximumBytes > 512 * 1024 * 1024) {
        result.status = SourceCheckStatus::InvalidDefinition; return result;
    }
    TemporaryDirectory temporary(request.temporaryParent);
    if (temporary.path.empty() || !MakeDirectories(temporary.path)) return result;
    const std::string definitionPath(temporary.path + (request.format == CydiaSources::Format::Deb822 ?
                                                     "/draft.sources" : "/draft.list"));
    const auto document(CydiaSources::ParseDocument(definitionPath, request.format, request.definition));
    if (!document.valid() || document.definitions.empty() || document.definitions.size() > 16) {
        result.status = SourceCheckStatus::InvalidDefinition; return result;
    }
    std::size_t repositoryCount(0);
    for (const auto &definition : document.definitions) {
        if (definition.uris.size() > 8 || definition.suites.size() > 16 || definition.components.size() > 32) {
            result.status = SourceCheckStatus::SizeLimit; return result;
        }
        repositoryCount += definition.uris.size() * definition.suites.size();
        for (const auto &field : definition.fields) {
            std::string name(field.name);
            std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
            std::string values(field.value);
            std::replace(values.begin(), values.end(), ',', ' ');
            if ((name == "arch" || name == "arch+" || name == "arch-" || name == "architectures" ||
                 name == "architectures-add" || name == "architectures-remove") && Words(values).size() > 32) {
                result.status = SourceCheckStatus::SizeLimit; return result;
            }
        }
    }
    if (repositoryCount > 16) { result.status = SourceCheckStatus::SizeLimit; return result; }
    std::string checkDefinition(request.definition);
    if (!request.candidatePublicKey.empty()) {
        std::size_t primaryCount(0);
        CydiaRuntime::Privileged::Error error;
        if (!CydiaRuntime::Keyring::CheckPublicKeyPackets(request.candidatePublicKey, &primaryCount, &error)) {
            result.status = SourceCheckStatus::InvalidDefinition; return result;
        }
        const std::size_t first(request.candidatePublicKey.find_first_not_of(" \t\r\n"));
        const bool armored(first != std::string::npos && request.candidatePublicKey[first] == '-');
        const std::string keyPath(temporary.path + (armored ? "/candidate.asc" : "/candidate.gpg"));
        if (!Write(keyPath, request.candidatePublicKey)) return result;
        for (auto definition = document.definitions.rbegin(); definition != document.definitions.rend(); ++definition) {
            std::string replacement;
            if (!CydiaRuntime::Keyring::BindSignedBy(document, definition->ordinal, keyPath, &replacement, &error)) {
                result.status = SourceCheckStatus::InvalidDefinition; return result;
            }
            checkDefinition.replace(definition->span.begin, definition->span.end - definition->span.begin, replacement);
        }
    }
    if (!Write(definitionPath, checkDefinition)) return result;
    ConfigurationScope configuration(temporary.path);
    _config->Set("Dir::Etc::sourcelist", definitionPath);
    _config->Set("Acquire::MaxReleaseFileSize", static_cast<int>(MaximumMetadata));
    for (const char *method : {"http", "https", "ftp"})
        _config->Set((std::string("Acquire::") + method + "::Timeout").c_str(), static_cast<int>(request.timeoutSeconds));
    BoundedStatus status(cancelled, request.timeoutSeconds, temporary.path, request.maximumBytes);
    if (!status.Check()) { result.status = status.reason; return result; }
    pkgSourceList list;
    if (!list.Read(definitionPath) || list.empty()) {
        result.status = SourceCheckStatus::InvalidDefinition; Drain(&result.errors); return result;
    }
    pkgAcquire fetcher(&status);
    if (!fetcher.GetLock(_config->FindDir("Dir::State::lists")) || !list.GetIndexes(&fetcher)) {
        Drain(&result.errors); return result;
    }
    /* Deliberately not AcquireUpdate/ListUpdate: those execute update hooks
     * and may clean caches. Run only completes private item transactions. */
    const pkgAcquire::RunResult run(fetcher.Run(100000));
    status.Pulse(&fetcher);
    bool complete(run == pkgAcquire::Continue);
    bool authenticationIssue(false);
    std::set<std::pair<std::string, FetchDiagnosticKind>> reported;
    for (auto item = fetcher.ItemsBegin(); item != fetcher.ItemsEnd(); ++item) {
        const bool failed((*item)->Status != pkgAcquire::Item::StatDone);
        if (failed) complete = false;
        FetchFailureData diagnostic;
        diagnostic.uri = Redacted((*item)->DescURI());
        diagnostic.error = (*item)->ErrorText;
#if defined(APT_CYDIA_AUTHENTICATION_PROVENANCE)
        const auto issue((*item)->GetAuthenticationIssue());
        authenticationIssue = authenticationIssue || issue != pkgAcquire::Item::AuthenticationIssue::None;
        if (issue == pkgAcquire::Item::AuthenticationIssue::None && !failed) continue;
        diagnostic.kind = AuthenticationKind(issue);
#else
        if (!failed) continue;
        diagnostic.kind = FetchDiagnosticKind::General;
#endif
        if (!reported.insert({diagnostic.uri, diagnostic.kind}).second) continue;
        const RepositorySecurityMode policy(GetRepositorySecurityMode());
        const bool hard(failed || policy == RepositorySecurityMode::Error ||
            (policy != RepositorySecurityMode::Distribution &&
             (diagnostic.kind == FetchDiagnosticKind::BadRepositorySignature ||
              diagnostic.kind == FetchDiagnosticKind::InvalidRepositorySignature)));
        if (hard) result.failures.push_back(diagnostic);
        else result.warnings.push_back(diagnostic);
    }

    std::set<std::pair<std::string, std::string>> binaryRepositories;
    const auto binaryType(pkgSourceList::Type::GetType("deb"));
    for (const auto &definition : document.definitions) {
        if (!definition.enabled || std::find(definition.types.begin(), definition.types.end(), "deb") == definition.types.end())
            continue;
        for (auto uri : definition.uris) {
            if (binaryType == NULL || !binaryType->FixupURI(uri)) continue;
            for (const auto &suite : definition.suites)
                binaryRepositories.insert({uri, SubstVar(suite, "$(ARCH)", _config->Find("APT::Architecture"))});
        }
    }
    bool anySupported(false), anyUnsupported(false), distributionAllowsDowngrade(true);
    result.authenticated = !list.empty();
    for (auto source = list.begin(); source != list.end(); ++source) {
        bool sawPackage(false), supported(false), hasBinaryIndexes(false);
        bool wantsBinary(binaryRepositories.count({(*source)->GetURI(), (*source)->GetDist()}) != 0);
        SourceMetadata metadata;
        metadata.uri = Redacted((*source)->GetURI()); metadata.suitePath = (*source)->GetDist();
#if defined(APT_CYDIA_AUTHENTICATION_PROVENANCE)
        /* The embedded IsTrusted ignores Trusted:yes under the explicit
         * Cydia policy. Also require the actual acquisition to report no
         * authentication issue; a forced trust option is never crypto proof. */
        metadata.authenticated = complete && !authenticationIssue && (*source)->IsTrusted() &&
            (GetRepositorySecurityMode() != RepositorySecurityMode::Distribution ||
             (*source)->GetTrusted() != metaIndex::TRI_YES);
#endif
        result.authenticated = result.authenticated && metadata.authenticated;
        const auto targets((*source)->GetIndexTargets());
        if (!metadata.authenticated) {
            bool allowsDowngrade(_config->FindB("Acquire::AllowDowngradeToInsecureRepositories", false));
            for (const auto &target : targets)
                allowsDowngrade = allowsDowngrade || target.OptionBool(IndexTarget::ALLOW_DOWNGRADE_TO_INSECURE);
            distributionAllowsDowngrade = distributionAllowsDowngrade && allowsDowngrade;
        }
        std::string base;
        if (!targets.empty()) base = targets.front().Option(IndexTarget::BASE_URI);
        metadata.metadataBaseURI = base;
        if (!base.empty()) {
            for (const char *name : {"InRelease", "Release"}) {
                const std::string leaf(URItoFileName(base + name));
                for (const std::string &path : {temporary.path + "/lists/" + leaf,
                     temporary.path + "/lists/partial/" + leaf,
                     temporary.path + "/lists/partial/" + leaf + ".FAILED"}) {
                    if (!Read(path, MaximumMetadata, &metadata.metadata)) continue;
                    metadata.clearSigned = !strcmp(name, "InRelease");
                    MetadataFields(path, &metadata);
                    if (!strcmp(name, "Release")) {
                        const std::string sig(URItoFileName(base + "Release.gpg"));
                        for (const std::string &signature : {temporary.path + "/lists/" + sig,
                             temporary.path + "/lists/partial/" + sig,
                             temporary.path + "/lists/partial/" + sig + ".FAILED"})
                            if (Read(signature, MaximumMetadata, &metadata.detachedSignature)) break;
                    }
                    break;
                }
                if (!metadata.metadata.empty()) break;
            }
        }
        bool declaredSupported(false);
        for (const auto &arch : metadata.architectures)
            if (IsArchitectureSupported(arch)) declaredSupported = true;
        for (const auto &target : targets) {
            if (target.Option(IndexTarget::TARGET_OF) == "deb") wantsBinary = true;
            if (target.Option(IndexTarget::CREATED_BY) != "Packages") continue;
            const std::string path(target.Option(IndexTarget::EXISTING_FILENAME));
            if (path.empty()) continue;
            hasBinaryIndexes = true;
            if (!supported && status.reason == SourceCheckStatus::Complete &&
                !InspectArchitectures(path, &status, request.maximumBytes, &sawPackage, &supported)) complete = false;
        }
        /* Every URI/suite in a Deb822 definition must independently offer a
         * binary index. A usable first repository must not mask a later
         * metadata-only or entirely unsupported repository. Source-only
         * entries need no binary architecture evidence. */
        if (wantsBinary) {
            if (!hasBinaryIndexes) complete = false;
            if (supported) anySupported = true;
            else if (sawPackage || (!metadata.architectures.empty() && !declaredSupported)) anyUnsupported = true;
        }
        result.repositories.push_back(metadata);
    }
    if (anyUnsupported) result.architecture = SourceArchitectureAvailability::Unsupported;
    else if (anySupported) result.architecture = SourceArchitectureAvailability::Supported;
    result.status = status.reason != SourceCheckStatus::Complete ? status.reason :
        (complete ? SourceCheckStatus::Complete : SourceCheckStatus::Unavailable);
    if (request.previouslyAuthenticated && !result.authenticated && result.status == SourceCheckStatus::Complete) {
        FetchFailureData downgrade;
        downgrade.kind = FetchDiagnosticKind::RepositoryTrustDowngrade;
        downgrade.error = "Repository is no longer authenticated.";
        if (!result.repositories.empty()) downgrade.uri = result.repositories.front().uri;
        if (GetRepositorySecurityMode() == RepositorySecurityMode::Distribution && distributionAllowsDowngrade)
            result.warnings.push_back(downgrade);
        else result.failures.push_back(downgrade);
    }
    result.allowed = result.status == SourceCheckStatus::Complete && result.failures.empty() &&
        result.architecture != SourceArchitectureAvailability::Unsupported &&
        (request.candidatePublicKey.empty() || result.authenticated);
#if !defined(APT_CYDIA_AUTHENTICATION_PROVENANCE)
    /* API audit builds against unpatched upstream headers must not silently
     * claim the Cydia authentication policy was enforced. */
    result.allowed = false;
#endif
    Drain(&result.errors);
    return result;
}

} // namespace CydiaAPT
