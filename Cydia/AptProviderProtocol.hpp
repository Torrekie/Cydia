/* Cydia-owned external APT protocol. No libapt ABI objects cross this boundary.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderProtocol_HPP
#define Cydia_AptProviderProtocol_HPP

#include "Cydia/AptBackend.hpp"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/SourcePreflight.hpp"
#include "Cydia/PrivilegedRuntime.hpp"
#include "Cydia/PackageArchivePolicy.hpp"
#include "Cydia/RepositoryArchiveAuthorization.hpp"
#include <limits>
#include <type_traits>
#include <utility>

namespace CydiaAPT { namespace Provider {

constexpr std::uint32_t ProtocolVersion = 3;
constexpr std::size_t MaximumMessageBytes = 32 * 1024 * 1024;
constexpr std::size_t MaximumStringBytes = 16 * 1024 * 1024;
constexpr std::size_t MaximumCollectionItems = 100000;

enum class Availability { Ready, Missing, Unsupported, Broken };
enum class MessageKind { Request, Response, Event, ParentRequest, ParentResponse };

// Values are permanent wire identifiers. An incompatible schema requires a
// new protocol version; append-only changes also require negotiation.
enum class Operation {
    Hello, Reset, CreateCacheViews, DrainErrors, DiscardErrors, LoadSources,
    OpenCache, LockForTransaction, UnlockForTransaction, AutoInstalledDeltas,
    CacheState, ApplyStatus, FixBroken, MinimizeUpgrade, CleanArchives,
    PrepareArchives, SourceList, RunFetcher, RunPackageManager, UpdateLists,
    PackageHandles, LookupPackage, PackageHandle, DowngradeHandles, VersionHandles,
    PackageSnapshot, RecordData, PackageState, Relations, TransactionData,
    ResolveDependencies, ClearSelections, PrepareDistUpgrade, ClearPackage,
    InstallPackage, ReinstallPackage, RemovePackage, SourceHandles,
    SourceSnapshot, SourceField, SourceFileIDs, SourcePreflight, SourceResource,
    SetSecurityMode, RefreshArchitectures, Cancel,
    AcquireFrontendLock, ReleaseFrontendLock, ExecuteDpkg, CommitExtendedState,
    CaptureStateSnapshot, Progress, AuthorizeArchive,
};

enum Capability : std::uint64_t {
    CacheValues = 1ull << 0, SourceChecks = 1ull << 1, ArchitecturePolicy = 1ull << 2,
    DependencySolver = 1ull << 3, ExactQueueReview = 1ull << 4,
    VerifiedArchiveAcquisition = 1ull << 5, PackageLayoutValidation = 1ull << 6,
    DistributionPolicy = 1ull << 7, ParentFrontendLocks = 1ull << 8,
    ParentPackageExecutor = 1ull << 9, ParentExtendedStateWriter = 1ull << 10,
    RevalidateReviewedState = 1ull << 11, BoundedCancellation = 1ull << 12,
    StructuredProgress = 1ull << 13, SourceManagement = 1ull << 14,
    ExplicitSecurityOverrides = 1ull << 15, AuthorizedArchiveGrants = 1ull << 16,
    ReviewedExecutionManifest = 1ull << 17, FiniteTriggerEffects = 1ull << 18,
};
constexpr std::uint64_t RequiredCapabilities = CacheValues | SourceChecks |
    ArchitecturePolicy | DependencySolver | ExactQueueReview |
    VerifiedArchiveAcquisition | PackageLayoutValidation | DistributionPolicy |
    ParentFrontendLocks | ParentPackageExecutor | ParentExtendedStateWriter |
    RevalidateReviewedState | BoundedCancellation | StructuredProgress | SourceManagement | ReviewedExecutionManifest;

struct Environment {
    CydiaRuntime::Privileged::ExpectedEnvironment paths;
    std::string configurationIdentity, policyIdentity, methodsIdentity, packageStateIdentity;
    std::string nativeArchitecture;
    std::vector<std::string> registeredArchitectures, acquisitionArchitectures;
};

struct Info {
    std::uint32_t protocolVersion = ProtocolVersion;
    Availability availability = Availability::Unsupported;
    std::uint64_t capabilities = 0;
    // Support is a capability; this is the immutable mode accepted for one
    // session. Probes leave it false. It grants no parent execution authority.
    bool finiteTriggerEffects = false;
    std::string identifier, implementationVersion, libraryIdentity, frontendIdentity;
    Environment environment;
    // Stable code plus upstream diagnostic text, never an instruction or UI key.
    std::string errorCode, diagnostic;
};

struct Hello {
    std::uint32_t protocolVersion = ProtocolVersion;
    std::uint64_t requiredCapabilities = RequiredCapabilities;
    // Selected only after the app's native authority check succeeds. A worker
    // must echo this choice; merely advertising support never enables it.
    bool finiteTriggerEffects = false;
    std::string challenge; // Fresh caller-generated nonce, echoed in Binding.
    std::string registrationPath; // Protected provider declaration, empty only for explicit legacy/test clients.
    InitializationOptions options;
    Environment expected;
};

struct Binding {
    std::string providerIdentifier, session, configurationIdentity, policyIdentity;
    std::string packageStateIdentity, review;
    std::uint64_t cacheEpoch = 0, selectionRevision = 0;
};

struct Message {
    std::uint32_t version = ProtocolVersion;
    MessageKind kind = MessageKind::Request;
    std::uint64_t sequence = 0;
    Operation operation = Operation::Hello;
    Binding binding;
    bool succeeded = false;
    std::string errorCode;
    std::string payload;
};

struct LookupRequest { std::string name, preferredArchitecture; };
struct RemoveRequest { CydiaAPT::PackageHandle handle; bool purge = false; };
struct SourceFieldRequest { CydiaAPT::SourceHandle handle; std::string name; };
struct PackageManagerReply {
    PackageManagerResult result = PackageManagerResult::Failed;
    FetchResultData archives;
    bool started = false;
};
// Deconfigure is an unpack side effect, never a directly executable dpkg verb.
enum class ExecutionAction { Unpack, Configure, Remove, Purge, Triggers, Deconfigure };
struct ExecutionPackage { std::string package, version, architecture; };
struct ArchiveManifest {
    std::string identifier;
    ExecutionPackage package;
    std::string sourceURI, sourceIndexIdentity, path;
    // Exact parent-verifiable provenance. Index identity is SHA256:<hex> of
    // the stored index bytes; the record range addresses its decoded stream.
    std::string sourceDefinitionPath, sourceIndexPath, sourceIndexURI, filename;
    std::uint64_t sourceDefinitionOrdinal = 0, recordOffset = 0, recordSize = 0;
    std::map<std::string, std::string> hashes;
    std::uint64_t size = 0;
    CydiaPackages::ArchiveLayout layout;
};
struct ReviewedAction {
    std::uint64_t identifier = 0;
    ExecutionAction action = ExecutionAction::Unpack;
    ExecutionPackage package;
    std::string archive; // ArchiveManifest.identifier for unpack only.
};
struct ExecutionManifest {
    std::vector<ArchiveManifest> archives;
    // Order is significant for successive actions on the same exact package.
    // Additional pending/trigger actions must also be shown and approved.
    std::vector<ReviewedAction> actions;
};
struct ReviewedTransaction {
    CydiaAPT::TransactionData transaction;
    Binding binding;
    ExecutionManifest execution;
};
struct CacheReply { bool opened = false; Binding binding; };

// Reverse requests are advisory input to the parent, never path authority.
// The app owns fcntl locks and authenticates its direct cydo child. The worker
// may not execute cydo, acquire the parent's lock, or write extended state.
struct ParentExecutionRequest {
    Binding binding;
    std::uint64_t batch = 0;
    ExecutionAction action = ExecutionAction::Unpack;
    std::vector<std::uint64_t> actions; // Exact ReviewedAction identifiers.
    std::vector<std::string> arguments;
};
struct ParentExecutionReply {
    int exitCode = -1, signal = 0, launchError = 0;
    bool started = false;
};
// This capability transports only a short-lived grant for an already approved
// archive ID. The parent derives source and package identity from its evidence.
bool ValidIdentityToken(const std::string &value);
struct ArchiveAuthorizationRequest { Binding binding; std::string archive; };
using ArchiveAuthorizationReply = CydiaRuntime::RepositoryArchiveAuthorizationResult;
bool ValidArchiveAuthorizationReply(const ArchiveAuthorizationReply &reply);

struct ExtendedStateRequest {
    Binding binding;
    std::vector<AutoInstalledDelta> changes;
};
enum class SourceActivity : std::uint32_t { None, Started, Finished };
struct ProgressEvent {
    std::string type, package, message;
    std::uint64_t current = 0, total = 0;
    bool cancellable = false;
    SourceActivity sourceActivity = SourceActivity::None;
    // Transport identity only, never diagnostic text. It may contain private
    // credentials and is used solely to match an existing source's activity.
    std::string sourceURI;
};

/* Payload mapping follows AptBackend's value API: no-argument operations use
 * an empty payload; package/source methods encode their handle; lookup uses
 * LookupRequest; removal uses RemoveRequest; sourceField uses SourceFieldRequest.
 * Fetch/update encode the pulse interval as uint32_t. RunPackageManager has
 * no status-fd argument: progress is an event, execution is reverse RPC.
 * transactionData returns ReviewedTransaction; OpenCache/Reset return CacheReply
 * with the newly established binding. The reply envelope retains the request
 * binding until that payload is accepted. All other replies encode their
 * public AptBackend return type; void methods encode no payload. Preflight,
 * resources and initialization use their named DTOs. SetSecurityMode encodes
 * RepositorySecurityMode and must fail unsupported if its capability is absent.
 * Every request/reply/event carries the same binding. Only Reset/OpenCache can
 * establish a new cache epoch; changed selections invalidate the review token.
 * After a successful envelope for ApplyStatus, FixBroken, MinimizeUpgrade,
 * ResolveDependencies, ClearSelections, PrepareDistUpgrade, ClearPackage,
 * InstallPackage, ReinstallPackage or RemovePackage, both peers increment the
 * selection revision and clear the review, even if the encoded bool is false.
 * The reply envelope retains the old binding. A cache reply establishes a
 * strictly newer epoch with revision zero and no review. TransactionData may
 * supply a review token but must retain all other current binding fields.
 * RunPackageManager clears the review after its successful reply envelope.
 * Parent requests have a separate strictly increasing sequence starting at 1;
 * progress events use their active request sequence. Cancel encodes the active
 * request sequence and returns its own reply as well as settling that request.
 * AuthorizeArchive is negotiated by AuthorizedArchiveGrants and valid only
 * during RunFetcher under the current approved review and parent lock. Its
 * payload contains only ArchiveAuthorizationRequest; the parent derives the
 * account request from retained source/index proof. The typed reply carries
 * a short-lived HTTPS grant or a failure status, never account credentials.
 * CaptureStateSnapshot returns a parent-verified Environment. Only its package
 * state identity may change within the session; the next cache reply may adopt
 * that approved identity. Other environment changes require a fresh probe.
 * Successful SetSecurityMode/RefreshArchitectures therefore end the current
 * session after their boolean reply; a new verified environment is required.
 * PrepareArchives/RunFetcher/RunPackageManager require a current review, held
 * parent lock, unchanged state/policy and the exact reviewed package identities.
 * A provider disconnect after execution starts is indeterminate, never a retry
 * or permission to switch provider. Cancellation must settle on the same worker.
 */

template<class T, class Enable = void> struct Codec;
class Writer {
    std::string bytes_;
    bool valid_ = true;
public:
    bool bytes(const char *bytes, std::size_t count);
    bool integer(std::uint64_t value, unsigned bytes);
    bool operator()() { return valid_; }
    template<class T, class... Rest> bool operator()(const T &value, const Rest &...rest) {
        return Codec<T>::write(*this, value) && (*this)(rest...);
    }
    const std::string &result() const { return bytes_; }
};
class Reader {
    const std::string &bytes_;
    std::size_t offset_ = 0, items_ = 0;
    unsigned depth_ = 0;
public:
    explicit Reader(const std::string &bytes) : bytes_(bytes) {}
    bool bytes(std::size_t count, std::string *value);
    bool integer(std::uint64_t *value, unsigned bytes);
    bool collection(std::uint64_t count);
    void endCollection() { --depth_; }
    bool operator()() { return true; }
    template<class T, class... Rest> bool operator()(T &value, Rest &...rest) {
        return Codec<T>::read(*this, value) && (*this)(rest...);
    }
    bool complete() const { return offset_ == bytes_.size(); }
};

template<class T> struct Codec<T, typename std::enable_if<std::is_integral<T>::value &&
    !std::is_same<T, bool>::value>::type> {
    static bool write(Writer &w, T value) {
        // Fixed 64-bit wire width also keeps size_t portable between hosts.
        const std::uint64_t raw = std::is_signed<T>::value && value < 0 ?
            ~static_cast<std::uint64_t>(-(value + 1)) : static_cast<std::uint64_t>(value);
        return w.integer(raw, 8);
    }
    static bool read(Reader &r, T &value) {
        std::uint64_t raw;
        if (!r.integer(&raw, 8)) return false;
        if (std::is_signed<T>::value && (raw >> 63)) {
            const std::uint64_t magnitude(~raw);
            if (magnitude > static_cast<std::uint64_t>(std::numeric_limits<T>::max())) return false;
            value = static_cast<T>(-static_cast<T>(magnitude) - 1);
        } else {
            if (raw > static_cast<std::uint64_t>(std::numeric_limits<T>::max())) return false;
            value = static_cast<T>(raw);
        }
        return true;
    }
};
template<> struct Codec<bool> {
    static bool write(Writer &w, bool v) { return w.integer(v ? 1 : 0, 1); }
    static bool read(Reader &r, bool &v) {
        std::uint64_t value; if (!r.integer(&value, 1) || value > 1) return false;
        v = value != 0; return true;
    }
};
template<> struct Codec<std::string> {
    static bool write(Writer &w, const std::string &v) {
        return v.size() <= MaximumStringBytes && w.integer(v.size(), 4) && w.bytes(v.data(), v.size());
    }
    static bool read(Reader &r, std::string &v) {
        std::uint64_t size; return r.integer(&size, 4) && size <= MaximumStringBytes && r.bytes(size, &v);
    }
};
template<class T> struct Codec<std::vector<T>> {
    static bool write(Writer &w, const std::vector<T> &v) {
        if (v.size() > MaximumCollectionItems || !w.integer(v.size(), 4)) return false;
        for (const auto &item : v) if (!w(item)) return false;
        return true;
    }
    static bool read(Reader &r, std::vector<T> &v) {
        std::uint64_t size; if (!r.integer(&size, 4) || !r.collection(size)) return false;
        v.clear(); v.reserve(size);
        for (std::uint64_t i = 0; i < size; ++i) {
            T value; if (!r(value)) { r.endCollection(); return false; }
            v.push_back(std::move(value));
        }
        r.endCollection(); return true;
    }
};
template<class T> struct Codec<std::set<T>> {
    static bool write(Writer &w, const std::set<T> &v) {
        if (v.size() > MaximumCollectionItems || !w.integer(v.size(), 4)) return false;
        for (const auto &item : v) if (!w(item)) return false;
        return true;
    }
    static bool read(Reader &r, std::set<T> &v) {
        std::vector<T> values; if (!r(values)) return false;
        v = std::set<T>(values.begin(), values.end()); return v.size() == values.size();
    }
};
template<class K, class V> struct Codec<std::map<K, V>> {
    static bool write(Writer &w, const std::map<K, V> &v) {
        if (v.size() > MaximumCollectionItems || !w.integer(v.size(), 4)) return false;
        for (const auto &item : v) if (!w(item.first, item.second)) return false;
        return true;
    }
    static bool read(Reader &r, std::map<K, V> &v) {
        std::uint64_t size; if (!r.integer(&size, 4) || !r.collection(size)) return false;
        v.clear();
        for (std::uint64_t i = 0; i < size; ++i) {
            K key; V value;
            if (!r(key, value) || !v.emplace(std::move(key), std::move(value)).second) {
                r.endCollection(); return false;
            }
        }
        r.endCollection(); return true;
    }
};

#define CYDIA_PROVIDER_ENUM(Type, Last) \
template<> struct Codec<Type> { \
    static bool write(Writer &w, Type v) { \
        const auto n = static_cast<std::uint64_t>(v); \
        return n <= static_cast<std::uint64_t>(Last) && w.integer(n, 4); \
    } \
    static bool read(Reader &r, Type &v) { \
        std::uint64_t n; if (!r.integer(&n, 4) || n > static_cast<std::uint64_t>(Last)) return false; \
        v = static_cast<Type>(n); return true; \
    } \
};
CYDIA_PROVIDER_ENUM(Availability, Availability::Broken)
CYDIA_PROVIDER_ENUM(MessageKind, MessageKind::ParentResponse)
CYDIA_PROVIDER_ENUM(Operation, Operation::AuthorizeArchive)
CYDIA_PROVIDER_ENUM(CydiaRuntime::RepositoryArchiveAuthorizationStatus, CydiaRuntime::RepositoryArchiveAuthorizationStatus::Cancelled)
CYDIA_PROVIDER_ENUM(PackageManagerResult, PackageManagerResult::Completed)
CYDIA_PROVIDER_ENUM(PackageSelectorKind, PackageSelectorKind::Any)
CYDIA_PROVIDER_ENUM(PackageLookupStatus, PackageLookupStatus::Ambiguous)
CYDIA_PROVIDER_ENUM(MultiArchMode, MultiArchMode::Allowed)
CYDIA_PROVIDER_ENUM(FetchDiagnosticKind, FetchDiagnosticKind::ArchiveUnverified)
CYDIA_PROVIDER_ENUM(SourceCheckStatus, SourceCheckStatus::InternalError)
CYDIA_PROVIDER_ENUM(SourceArchitectureAvailability, SourceArchitectureAvailability::Unsupported)
CYDIA_PROVIDER_ENUM(RepositorySecurityMode, RepositorySecurityMode::Distribution)
CYDIA_PROVIDER_ENUM(CydiaSources::Format, CydiaSources::Format::Deb822)
CYDIA_PROVIDER_ENUM(ExecutionAction, ExecutionAction::Deconfigure)
CYDIA_PROVIDER_ENUM(SourceActivity, SourceActivity::Finished)
#undef CYDIA_PROVIDER_ENUM

// Field order below is the normative v3 schema. Reuse all Cydia value fields,
// including foreign architecture identities and typed authentication failures.
#define CYDIA_PROVIDER_VALUE(Type, ...) \
template<> struct Codec<Type> { \
    static bool write(Writer &a, const Type &v) { return a(__VA_ARGS__); } \
    static bool read(Reader &a, Type &v) { return a(__VA_ARGS__); } \
};
CYDIA_PROVIDER_VALUE(CydiaAPT::PackageHandle, v.value)
CYDIA_PROVIDER_VALUE(CydiaAPT::SourceHandle, v.value)
CYDIA_PROVIDER_VALUE(PackageSelector, v.kind, v.baseName, v.architecture)
CYDIA_PROVIDER_VALUE(PackageLookupResult, v.status, v.selector, v.handle, v.alternatives, v.availableArchitectures)
CYDIA_PROVIDER_VALUE(PackageIdentity, v.baseName, v.packageArchitecture, v.versionArchitecture,
    v.aptName, v.routingName, v.dpkgName, v.multiArch, v.architectureIndependent)
CYDIA_PROVIDER_VALUE(SourceSnapshot, v.handle, v.uri, v.distribution, v.type, v.base, v.defaultIcon,
    v.depiction, v.description, v.label, v.origin, v.support, v.version, v.files, v.trusted)
CYDIA_PROVIDER_VALUE(AcquireItemData, v.description, v.uri)
CYDIA_PROVIDER_VALUE(ErrorData, v.message, v.cydiaCode, v.warning)
CYDIA_PROVIDER_VALUE(CacheStateSummary, v.deletes, v.installs, v.broken)
CYDIA_PROVIDER_VALUE(FetchFailureData, v.uri, v.error, v.package, v.path, v.reason, v.kind)
CYDIA_PROVIDER_VALUE(FetchResultData, v.failures, v.warnings, v.completed)
CYDIA_PROVIDER_VALUE(SourceListData, v.uris, v.success)
CYDIA_PROVIDER_VALUE(UpdateResultData, v.warnings, v.failures, v.prepared, v.success, v.metadataComplete)
CYDIA_PROVIDER_VALUE(PackageRecordData, v.fields, v.tags, v.displayName, v.maintainer,
    v.shortDescription, v.longDescription, v.raw)
CYDIA_PROVIDER_VALUE(PackageStateData, v.state, v.selection, v.mode, v.essential, v.protectedPackage,
    v.ignored, v.broken, v.hasMode, v.half, v.halfConfigured, v.halfInstalled, v.hasCurrent,
    v.upgradable, v.candidateMatchesVersion, v.newInstall, v.deletePackage, v.reinstall,
    v.upgrade, v.downgrade, v.versionAvailable, v.installedVersionAvailable, v.policyCandidate,
    v.installedVersion, v.architectureSupported, v.versionPriority, v.versionComparison)
CYDIA_PROVIDER_VALUE(PackageSnapshot, v.handle, v.registeredArchitectures, v.identity, v.installedIdentity,
    v.record, v.state, v.identifier, v.version, v.installedVersion, v.section, v.architecture,
    v.installedSize, v.sourceFileID, v.hasSourceFile, v.defaultPriority)
CYDIA_PROVIDER_VALUE(RelationClauseData, v.package, v.comparison, v.version, v.providers)
CYDIA_PROVIDER_VALUE(RelationData, v.relationship, v.clauses)
CYDIA_PROVIDER_VALUE(TransactionClauseData, v.package, v.comparison, v.version, v.reason, v.installed, v.providers)
CYDIA_PROVIDER_VALUE(TransactionReasonData, v.relationship, v.clauses)
CYDIA_PROVIDER_VALUE(TransactionIssueData, v.package, v.kind, v.reasons)
CYDIA_PROVIDER_VALUE(TransactionPackageData, v.identity, v.version, v.displayName)
CYDIA_PROVIDER_VALUE(TransactionData, v.registeredArchitectures, v.installs, v.reinstalls, v.upgrades,
    v.downgrades, v.removes, v.purges, v.issues, v.packages, v.downloading, v.resuming, v.removesEssential, v.substrate)
CYDIA_PROVIDER_VALUE(AutoInstalledDelta, v.package, v.architecture, v.automatic)
CYDIA_PROVIDER_VALUE(SourcePreflightRequest, v.definition, v.format, v.candidatePublicKey,
    v.previouslyAuthenticated, v.temporaryParent, v.timeoutSeconds, v.maximumBytes)
CYDIA_PROVIDER_VALUE(SourceMetadata, v.uri, v.suitePath, v.label, v.origin, v.metadataBaseURI,
    v.architectures, v.components, v.metadata, v.detachedSignature, v.clearSigned, v.authenticated)
CYDIA_PROVIDER_VALUE(SourcePreflightResult, v.status, v.allowed, v.authenticated, v.architecture,
    v.warnings, v.failures, v.repositories, v.errors)
CYDIA_PROVIDER_VALUE(SourceResourceRequest, v.uri, v.temporaryParent, v.timeoutSeconds, v.maximumBytes)
CYDIA_PROVIDER_VALUE(SourceResourceResult, v.status, v.bytes, v.errors)
CYDIA_PROVIDER_VALUE(InitializationOptions, v.architecture, v.aptConfigDirectory, v.methodsDirectory,
    v.cacheDirectory, v.stateDirectory, v.listsDirectory, v.logDirectory, v.dpkgStatusPath,
    v.bootstrapExtendedStatesPath, v.dpkgPath, v.nativeDpkgPath, v.packageInstallPrefix,
    v.privateRuntimeConfigurationPath, v.helperPath, v.dpkgDataDirectory, v.dpkgExecutableSearchPath,
    v.translation, v.languages, v.maxParallel, v.repositorySecurityMode, v.forceEssential)
CYDIA_PROVIDER_VALUE(CydiaRuntime::Privileged::ExpectedEnvironment, v.aptConfigOverride, v.dpkgRoot,
    v.dpkgAdmin, v.dpkg, v.dpkgQuery, v.dpkgDeb, v.sourceList, v.sourceParts)
CYDIA_PROVIDER_VALUE(Environment, v.paths, v.configurationIdentity, v.policyIdentity, v.methodsIdentity,
    v.packageStateIdentity, v.nativeArchitecture, v.registeredArchitectures, v.acquisitionArchitectures)
CYDIA_PROVIDER_VALUE(Info, v.protocolVersion, v.availability, v.capabilities, v.finiteTriggerEffects, v.identifier,
    v.implementationVersion, v.libraryIdentity, v.frontendIdentity, v.environment, v.errorCode, v.diagnostic)
CYDIA_PROVIDER_VALUE(Hello, v.protocolVersion, v.requiredCapabilities, v.finiteTriggerEffects, v.challenge, v.registrationPath, v.options, v.expected)
CYDIA_PROVIDER_VALUE(Binding, v.providerIdentifier, v.session, v.configurationIdentity,
    v.policyIdentity, v.packageStateIdentity, v.review, v.cacheEpoch, v.selectionRevision)
CYDIA_PROVIDER_VALUE(Message, v.version, v.kind, v.sequence, v.operation, v.binding,
    v.succeeded, v.errorCode, v.payload)
CYDIA_PROVIDER_VALUE(LookupRequest, v.name, v.preferredArchitecture)
CYDIA_PROVIDER_VALUE(RemoveRequest, v.handle, v.purge)
CYDIA_PROVIDER_VALUE(SourceFieldRequest, v.handle, v.name)
CYDIA_PROVIDER_VALUE(PackageManagerReply, v.result, v.archives, v.started)
CYDIA_PROVIDER_VALUE(ExecutionPackage, v.package, v.version, v.architecture)
CYDIA_PROVIDER_VALUE(CydiaPackages::ArchiveLayout, v.prefix, v.foreignPrefixes)
CYDIA_PROVIDER_VALUE(ArchiveManifest, v.identifier, v.package, v.sourceURI, v.sourceIndexIdentity,
    v.path, v.sourceDefinitionPath, v.sourceIndexPath, v.sourceIndexURI, v.filename,
    v.sourceDefinitionOrdinal, v.recordOffset, v.recordSize, v.hashes, v.size, v.layout)
CYDIA_PROVIDER_VALUE(ReviewedAction, v.identifier, v.action, v.package, v.archive)
CYDIA_PROVIDER_VALUE(ExecutionManifest, v.archives, v.actions)
CYDIA_PROVIDER_VALUE(ReviewedTransaction, v.transaction, v.binding, v.execution)
CYDIA_PROVIDER_VALUE(CacheReply, v.opened, v.binding)
CYDIA_PROVIDER_VALUE(ParentExecutionRequest, v.binding, v.batch, v.action, v.actions, v.arguments)
CYDIA_PROVIDER_VALUE(ParentExecutionReply, v.exitCode, v.signal, v.launchError, v.started)
CYDIA_PROVIDER_VALUE(ExtendedStateRequest, v.binding, v.changes)
CYDIA_PROVIDER_VALUE(ProgressEvent, v.type, v.package, v.message, v.current, v.total, v.cancellable, v.sourceActivity, v.sourceURI)
#undef CYDIA_PROVIDER_VALUE

// Grant payloads have much tighter limits than general cache records. Check
// lengths before allocating; a URL is sensitive transport, never diagnostics.
template<> struct Codec<ArchiveAuthorizationRequest> {
    static bool write(Writer &w, const ArchiveAuthorizationRequest &v) {
        return ValidIdentityToken(v.archive) && w(v.binding, v.archive);
    }
    static bool read(Reader &r, ArchiveAuthorizationRequest &v) {
        std::uint64_t n;
        return r(v.binding) && r.integer(&n, 4) && n <= 512 && r.bytes(n, &v.archive) && ValidIdentityToken(v.archive);
    }
};
template<> struct Codec<ArchiveAuthorizationReply> {
    static bool write(Writer &w, const ArchiveAuthorizationReply &v) {
        return ValidArchiveAuthorizationReply(v) && w(v.status, v.transportURL, v.message);
    }
    static bool read(Reader &r, ArchiveAuthorizationReply &v) {
        std::uint64_t n;
        return r(v.status) && r.integer(&n, 4) && n <= 32768 && r.bytes(n, &v.transportURL) &&
            r.integer(&n, 4) && n <= 4096 && r.bytes(n, &v.message) && ValidArchiveAuthorizationReply(v);
    }
};

template<class T> bool Encode(const T &value, std::string *bytes) {
    if (bytes == NULL) return false;
    Writer writer;
    if (!writer(value)) return false;
    *bytes = writer.result(); return true;
}
template<class T> bool Decode(const std::string &bytes, T *value) {
    if (value == NULL || bytes.size() > MaximumMessageBytes) return false;
    T candidate(*value); Reader reader(bytes);
    if (!reader(candidate) || !reader.complete()) return false;
    *value = std::move(candidate); return true;
}

// Frames have magic CYAP, a big-endian 32-bit length, then one encoded Message.
// DecodeFrame accepts exactly one complete frame and rejects trailing bytes.
bool EncodeFrame(const Message &message, std::string *bytes);
bool DecodeFrame(const std::string &bytes, Message *message);
/* Identity tokens are protocol identifiers, never arbitrary diagnostic or
 * repository text. Session challenges are fresh cryptographically random
 * values supplied by the caller, encoded as 32–128 hexadecimal characters.
 * Syntax validation cannot prove randomness or reject reuse across sessions. */
bool ValidIdentityToken(const std::string &value);
bool ValidChallenge(const std::string &value);
bool ValidEnvironment(const Environment &environment);
bool ValidProgressEvent(const ProgressEvent &event);
bool ValidHello(const Hello &hello);
bool SameEnvironment(const Environment &left, const Environment &right);
bool Compatible(const Info &info, const Environment &expected, std::string *reason);
bool SameBinding(const Binding &left, const Binding &right);
bool ValidRequestBinding(const Message &request);
bool ValidateReply(const Message &request, const Message &reply);
bool ValidateHelloReply(const Hello &hello, const Message &reply, Info *info);

}} // namespace CydiaAPT::Provider
#endif
