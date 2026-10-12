/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDocumentCommit.hpp"
#include "Cydia/SharedStateFile.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <limits>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <copyfile.h>
#endif

namespace CydiaSources {
namespace {
const std::size_t Limit = 8 * 1024 * 1024;
const char PolicyHeader[] = "CYDIA-SOURCE-PROTECTION-1\n";
const char RequestHeader[] = "CYDIA-SOURCE-COMMIT-1\n";
class FD {
    int fd_;
public:
    explicit FD(int fd = -1) : fd_(fd) {}
    ~FD() { if (fd_ >= 0) close(fd_); }
    int get() const { return fd_; }
    FD(const FD &) = delete;
    FD &operator=(const FD &) = delete;
};

void Put(std::string &output, const std::string &value) {
    output += std::to_string(value.size()) + ':' + value + ',';
}
bool Number(const std::string &text, std::size_t *value) {
    if (text.empty() || text.size() > 20) return false;
    std::size_t result(0);
    for (char c : text) {
        if (c < '0' || c > '9' || result > (std::numeric_limits<std::size_t>::max() - (c - '0')) / 10) return false;
        result = result * 10 + (c - '0');
    }
    *value = result; return true;
}
class Reader {
    const std::string &bytes_;
    std::size_t cursor_;
public:
    Reader(const std::string &bytes, const char *header) : bytes_(bytes), cursor_(std::string(header).size()) {}
    bool get(std::string *value) {
        const std::size_t colon(bytes_.find(':', cursor_));
        if (colon == std::string::npos) return false;
        std::size_t size;
        if (!Number(bytes_.substr(cursor_, colon - cursor_), &size) || size > Limit ||
            colon + 1 > bytes_.size() || size >= bytes_.size() - colon - 1) return false;
        const std::size_t end(colon + 1 + size);
        if (bytes_[end] != ',') return false;
        *value = bytes_.substr(colon + 1, size); cursor_ = end + 1; return true;
    }
    bool number(std::size_t *value) { std::string text; return get(&text) && Number(text, value); }
    bool done() const { return cursor_ == bytes_.size(); }
};
bool Header(const std::string &bytes, const char *header) {
    return bytes.size() <= Limit && bytes.compare(0, std::string(header).size(), header) == 0;
}
bool Text(const std::string &text, std::size_t maximum = 4096) {
    return !text.empty() && text.size() <= maximum && text.find('\0') == std::string::npos;
}
std::string Parent(const std::string &path) {
    const std::size_t slash(path.find_last_of('/')); return slash == 0 ? "/" : path.substr(0, slash);
}
std::string Leaf(const std::string &path) { return path.substr(path.find_last_of('/') + 1); }
bool Owner(const struct stat &st, uid_t owner) { return st.st_uid == owner; }
bool SafeFile(const struct stat &st, uid_t owner) {
    return S_ISREG(st.st_mode) && Owner(st, owner) && st.st_nlink == 1 &&
        (st.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID)) == 0;
}
bool SafeDirectory(const struct stat &st, uid_t owner) {
    if (!S_ISDIR(st.st_mode) || (st.st_uid != 0 && !Owner(st, owner))) return false;
    return (st.st_mode & (S_IWGRP | S_IWOTH)) == 0 ||
        (st.st_uid == 0 && (st.st_mode & S_ISVTX) != 0);
}
int TrustedParent(const std::string &path, uid_t owner) {
    if (!Text(path) || path[0] != '/' || Leaf(path).empty() || Leaf(path) == "." || Leaf(path) == "..") return -1;
    if (owner == 0) return CydiaRuntime::SharedState::OpenParent(path);
    char *resolved(realpath(Parent(path).c_str(), NULL));
    if (resolved == NULL) return -1;
    const std::string canonical(resolved); free(resolved);
    std::string component;
    struct stat st;
    if (lstat("/", &st) != 0 || !SafeDirectory(st, owner)) return -1;
    std::size_t start(1);
    while (start < canonical.size()) {
        const std::size_t end(canonical.find('/', start));
        component = canonical.substr(0, end);
        if (lstat(component.c_str(), &st) != 0 || !SafeDirectory(st, owner)) return -1;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    const int fd(open(canonical.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    if (fd < 0) return -1;
    if (fstat(fd, &st) != 0 || !SafeDirectory(st, owner)) { close(fd); return -1; }
    return fd;
}
std::string IdentityText(const FileIdentity &id) {
    std::ostringstream out;
    out << id.exists << ' ' << id.device << ' ' << id.inode << ' ' << id.size << ' '
        << id.links << ' ' << id.mode << ' ' << id.owner << ' ' << id.group << ' '
        << id.modifiedSeconds << ' ' << id.modifiedNanoseconds << ' '
        << id.changedSeconds << ' ' << id.changedNanoseconds;
    return out.str();
}
bool ParseIdentity(const std::string &text, FileIdentity *id) {
    std::istringstream tokens(text);
    std::string token;
    for (unsigned index = 0; index != 12; ++index) {
        if (!(tokens >> token) || token.empty()) return false;
        const std::size_t start((index == 8 || index == 10) && token[0] == '-' ? 1 : 0);
        if (start == token.size()) return false;
        for (std::size_t position = start; position != token.size(); ++position)
            if (token[position] < '0' || token[position] > '9') return false;
    }
    if (tokens >> token) return false;
    std::istringstream in(text); unsigned exists;
    if (!(in >> exists >> id->device >> id->inode >> id->size >> id->links >> id->mode
        >> id->owner >> id->group >> id->modifiedSeconds >> id->modifiedNanoseconds
        >> id->changedSeconds >> id->changedNanoseconds) || exists > 1) return false;
    std::string excess; if (in >> excess) return false;
    if (id->modifiedNanoseconds < 0 || id->modifiedNanoseconds >= 1000000000 ||
        id->changedNanoseconds < 0 || id->changedNanoseconds >= 1000000000) return false;
    id->exists = exists != 0; return true;
}
bool SameStat(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_size != b.st_size ||
        a.st_mode != b.st_mode || a.st_uid != b.st_uid || a.st_gid != b.st_gid || a.st_nlink != b.st_nlink) return false;
#ifdef __APPLE__
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
FileIdentity IdentityOf(const struct stat &st) {
    FileIdentity identity;
    identity.exists = true; identity.device = st.st_dev; identity.inode = st.st_ino;
    identity.size = st.st_size; identity.links = st.st_nlink; identity.mode = st.st_mode;
    identity.owner = st.st_uid; identity.group = st.st_gid;
#ifdef __APPLE__
    identity.modifiedSeconds = st.st_mtimespec.tv_sec; identity.modifiedNanoseconds = st.st_mtimespec.tv_nsec;
    identity.changedSeconds = st.st_ctimespec.tv_sec; identity.changedNanoseconds = st.st_ctimespec.tv_nsec;
#else
    identity.modifiedSeconds = st.st_mtim.tv_sec; identity.modifiedNanoseconds = st.st_mtim.tv_nsec;
    identity.changedSeconds = st.st_ctim.tv_sec; identity.changedNanoseconds = st.st_ctim.tv_nsec;
#endif
    return identity;
}
struct RawFile { bool present; std::string bytes; struct stat st; RawFile() : present(false), st() {} };
bool ReadRaw(int parent, const std::string &leaf, uid_t owner, RawFile *file, bool sharedState = false) {
    if (sharedState) return CydiaRuntime::SharedState::Read(parent, leaf, &file->present, &file->bytes, &file->st);
    const FD fd(openat(parent, leaf.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    if (fd.get() < 0) return errno == ENOENT;
    if (fstat(fd.get(), &file->st) != 0 || !SafeFile(file->st, owner) || file->st.st_size < 0 ||
        static_cast<std::uint64_t>(file->st.st_size) > Limit) return false;
    file->present = true;
    char buffer[16384];
    for (;;) {
        const ssize_t count(read(fd.get(), buffer, sizeof(buffer)));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return false;
        if (count == 0) break;
        if (file->bytes.size() + count > Limit) return false;
        file->bytes.append(buffer, count);
    }
    struct stat after;
    return fstat(fd.get(), &after) == 0 && SameStat(file->st, after);
}
CommitResult Result(CommitStatus status, int error = 0) { CommitResult result = {status, error}; return result; }

CommitResult WriteAtomic(int parent, const std::string &leaf, const RawFile &expected,
    const std::string &bytes, uid_t owner, bool sharedState = false) {
    if (bytes.size() > Limit) return Result(CommitStatus::InvalidRequest);
    RawFile before;
    if (!ReadRaw(parent, leaf, owner, &before, sharedState)) return Result(CommitStatus::UnsafePath, errno);
    if (before.present != expected.present || before.bytes != expected.bytes ||
        (before.present && !SameStat(before.st, expected.st))) return Result(CommitStatus::StaleSnapshot);
    if (before.present && before.bytes == bytes) return Result(CommitStatus::Unchanged);
    std::string temporary;
    int descriptor(-1);
    for (unsigned attempt(0); attempt != 32; ++attempt) {
        temporary = ".cydia-source-" + std::to_string(getpid()) + '-' + std::to_string(attempt);
        descriptor = openat(parent, temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (descriptor >= 0 || errno != EEXIST) break;
    }
    if (descriptor < 0) return Result(CommitStatus::IOFailure, errno);
    const FD fd(descriptor);
    auto fail = [&](CommitStatus status) { const int error(errno); unlinkat(parent, temporary.c_str(), 0); return Result(status, error); };
    std::size_t offset(0);
    while (offset < bytes.size()) {
        const ssize_t count(write(fd.get(), bytes.data() + offset, bytes.size() - offset));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return fail(CommitStatus::IOFailure);
        offset += count;
    }
    if (before.present) {
#ifdef __APPLE__
        const FD original(openat(parent, leaf.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC));
        struct stat attributes;
        if (original.get() < 0 || fstat(original.get(), &attributes) != 0 || !SameStat(attributes, before.st) ||
            fcopyfile(original.get(), fd.get(), NULL, COPYFILE_ACL | COPYFILE_XATTR) != 0)
            return fail(CommitStatus::IOFailure);
#endif
        if (fchown(fd.get(), before.st.st_uid, before.st.st_gid) != 0 ||
            fchmod(fd.get(), before.st.st_mode & 0777) != 0) return fail(CommitStatus::IOFailure);
    }
    if (!before.present && fchmod(fd.get(), 0644) != 0) return fail(CommitStatus::IOFailure);
    if (fsync(fd.get()) != 0) return fail(CommitStatus::IOFailure);
    RawFile current;
    if (!ReadRaw(parent, leaf, owner, &current, sharedState)) return fail(CommitStatus::UnsafePath);
    if (current.present != before.present || current.bytes != before.bytes ||
        (current.present && !SameStat(current.st, before.st))) return fail(CommitStatus::StaleSnapshot);
    if (renameat(parent, temporary.c_str(), parent, leaf.c_str()) != 0) return fail(CommitStatus::IOFailure);
    if (fsync(parent) != 0 && errno != EINVAL) return Result(CommitStatus::IOFailure, errno);
    return Result(CommitStatus::Completed);
}
} // namespace

bool ReadProtectedFile(const std::string &path, ProtectedFileSnapshot *snapshot, uid_t owner) {
    if (snapshot == NULL) return false;
    const FD parent(TrustedParent(path, owner)); RawFile raw;
    if (parent.get() < 0 || !ReadRaw(parent.get(), Leaf(path), owner, &raw)) return false;
    snapshot->bytes = raw.bytes;
    snapshot->identity = raw.present ? IdentityOf(raw.st) : FileIdentity();
    return true;
}
CommitResult ReplaceProtectedFile(const std::string &path, const ProtectedFileSnapshot &expected,
    const std::string &updated, uid_t owner) {
    const FD parent(TrustedParent(path, owner)); RawFile raw;
    if (parent.get() < 0 || !ReadRaw(parent.get(), Leaf(path), owner, &raw)) return Result(CommitStatus::UnsafePath, errno);
    if (raw.present != expected.identity.exists || raw.bytes != expected.bytes ||
        (raw.present && !IdentityOf(raw.st).sameVersion(expected.identity))) return Result(CommitStatus::StaleSnapshot);
    return WriteAtomic(parent.get(), Leaf(path), raw, updated, owner);
}
bool ReadSharedStateFile(const std::string &path, ProtectedFileSnapshot *snapshot) {
    if (snapshot == NULL) return false;
    const FD parent(CydiaRuntime::SharedState::OpenParent(path, true)); RawFile raw;
    if (parent.get() < 0 || !ReadRaw(parent.get(), Leaf(path), 0, &raw, true)) return false;
    snapshot->bytes = raw.bytes;
    snapshot->identity = raw.present ? IdentityOf(raw.st) : FileIdentity();
    return true;
}
CommitResult ReplaceSharedStateFile(const std::string &path, const ProtectedFileSnapshot &expected,
    const std::string &updated) {
    const FD parent(CydiaRuntime::SharedState::OpenParent(path, true)); RawFile raw;
    if (parent.get() < 0 || !ReadRaw(parent.get(), Leaf(path), 0, &raw, true)) return Result(CommitStatus::UnsafePath, errno);
    if (raw.present != expected.identity.exists || raw.bytes != expected.bytes ||
        (raw.present && !IdentityOf(raw.st).sameVersion(expected.identity))) return Result(CommitStatus::StaleSnapshot);
    return WriteAtomic(parent.get(), Leaf(path), raw, updated, 0, true);
}

std::string SerializeProtectionPolicy(const std::vector<ProtectionSelector> &selectors) {
    std::string bytes(PolicyHeader); Put(bytes, std::to_string(selectors.size()));
    for (const ProtectionSelector &selector : selectors) {
        Put(bytes, selector.setIdentifier); Put(bytes, selector.originPath); Put(bytes, selector.semanticKey);
        Put(bytes, std::to_string(selector.uris.size()));
        for (const std::string &uri : selector.uris) Put(bytes, uri);
    }
    return bytes;
}
bool ParseProtectionPolicy(const std::string &bytes, std::vector<ProtectionSelector> *selectors) {
    if (selectors == NULL || !Header(bytes, PolicyHeader)) return false;
    Reader reader(bytes, PolicyHeader); std::size_t count;
    if (!reader.number(&count) || count > 4096) return false;
    std::vector<ProtectionSelector> parsed;
    for (std::size_t index(0); index != count; ++index) {
        ProtectionSelector selector; std::size_t uris;
        if (!reader.get(&selector.setIdentifier) || !Text(selector.setIdentifier, 256) ||
            !reader.get(&selector.originPath) || !Text(selector.originPath) || selector.originPath[0] != '/' ||
            !reader.get(&selector.semanticKey) || selector.semanticKey.empty() ||
            !reader.number(&uris) || uris == 0 || uris > 4096) return false;
        for (std::size_t uri(0); uri != uris; ++uri) {
            std::string value; if (!reader.get(&value) || !Text(value)) return false;
            selector.uris.push_back(value);
        }
        parsed.push_back(selector);
    }
    if (!reader.done()) return false;
    selectors->swap(parsed); return true;
}
PolicySnapshot ReadProtectionPolicy(const std::string &path, uid_t owner) {
    PolicySnapshot result; const FD parent(TrustedParent(path, owner)); RawFile raw;
    if (parent.get() < 0 || !ReadRaw(parent.get(), Leaf(path), owner, &raw)) return result;
    result.present = raw.present; result.bytes = raw.bytes;
    result.valid = raw.present && ParseProtectionPolicy(raw.bytes, &result.selectors);
    return result;
}

std::string SerializeCommitRequest(const CommitRequest &request) {
    std::string bytes(RequestHeader);
    Put(bytes, std::to_string(static_cast<unsigned>(request.kind)));
    Put(bytes, request.expected.document.path);
    Put(bytes, request.expected.document.format == Format::Deb822 ? "1" : "0");
    Put(bytes, request.expected.document.bytes); Put(bytes, request.expected.canonicalPath);
    Put(bytes, IdentityText(request.expected.identity));
    Put(bytes, std::to_string(static_cast<unsigned>(request.mutation.kind)));
    Put(bytes, std::to_string(request.mutation.ordinal)); Put(bytes, request.mutation.enabled ? "1" : "0");
    Put(bytes, request.mutation.contents); Put(bytes, request.access == Access::AdvancedSettings ? "1" : "0");
    Put(bytes, request.expectedPolicy); Put(bytes, request.initializePolicy ? "1" : "0");
    Put(bytes, SerializeProtectionPolicy(request.selectors)); return bytes;
}
bool ParseCommitRequest(const std::string &bytes, CommitRequest *request) {
    if (request == NULL || !Header(bytes, RequestHeader)) return false;
    Reader reader(bytes, RequestHeader); CommitRequest parsed;
    std::size_t kind, format, edit, ordinal, enabled, access, initialize;
    std::string path, original, canonical, identity, contents, policy, selectors;
    if (!reader.number(&kind) || kind > 1 || !reader.get(&path) || !reader.number(&format) || format > 1 ||
        !reader.get(&original) || !reader.get(&canonical) || !reader.get(&identity) ||
        !ParseIdentity(identity, &parsed.expected.identity) || !reader.number(&edit) || edit > 4 ||
        !reader.number(&ordinal) || !reader.number(&enabled) || enabled > 1 || !reader.get(&contents) ||
        !reader.number(&access) || access > 1 || !reader.get(&policy) || !reader.number(&initialize) || initialize > 1 ||
        !reader.get(&selectors) || !reader.done() || !ParseProtectionPolicy(selectors, &parsed.selectors)) return false;
    parsed.kind = static_cast<CommitKind>(kind);
    parsed.expected.document = ParseDocument(path, format == 1 ? Format::Deb822 : Format::OneLine, original);
    parsed.expected.canonicalPath = canonical;
    parsed.mutation.kind = static_cast<EditKind>(edit); parsed.mutation.ordinal = ordinal;
    parsed.mutation.enabled = enabled != 0; parsed.mutation.contents = contents;
    parsed.access = access == 1 ? Access::AdvancedSettings : Access::Ordinary;
    parsed.expectedPolicy = policy; parsed.initializePolicy = initialize != 0;
    *request = parsed; return true;
}

CommitResult CommitSourceRequest(const EffectiveLocations &locations, const std::string &policyPath,
    const CommitRequest &request, uid_t owner) {
    const FD policyParent(TrustedParent(policyPath, owner)); RawFile policy;
    if (policyParent.get() < 0 || !ReadRaw(policyParent.get(), Leaf(policyPath), owner, &policy)) return Result(CommitStatus::UnsafePath, errno);
    if (policy.bytes != request.expectedPolicy) return Result(CommitStatus::StaleSnapshot);
    std::vector<ProtectionSelector> selectors;
    const bool validPolicy(policy.present && ParseProtectionPolicy(policy.bytes, &selectors));
    if (request.kind == CommitKind::SetProtectionPolicy) {
        if (request.access != Access::AdvancedSettings || (!validPolicy && !request.initializePolicy))
            return Result(CommitStatus::ProtectionReviewRequired);
        std::vector<ProtectionSelector> checked;
        const std::string newPolicy(SerializeProtectionPolicy(request.selectors));
        if (!ParseProtectionPolicy(newPolicy, &checked)) return Result(CommitStatus::InvalidRequest);
        const StoreSnapshot fresh(ReadEffectiveDocuments(locations));
        if (!fresh.ready()) return Result(CommitStatus::StaleSnapshot);
        std::vector<Document> documents;
        for (const StoredDocument &stored : fresh.documents) documents.push_back(stored.document);
        for (const ProtectionSelector &selector : request.selectors) {
            bool found(false);
            for (const Document &document : documents) for (const Definition &definition : document.definitions)
                if (selector.originPath == document.path && selector.semanticKey == definition.semanticKey &&
                    EvaluateProtection(documents, request.selectors, document.path, definition.ordinal).state == ProtectionState::Protected) found = true;
            if (!found) return Result(CommitStatus::ProtectionReviewRequired);
        }
        return WriteAtomic(policyParent.get(), Leaf(policyPath), policy, newPolicy, owner);
    }
    if (!validPolicy) return Result(CommitStatus::ProtectionReviewRequired);
    const FD parent(TrustedParent(request.expected.document.path, owner));
    if (parent.get() < 0 || !IsEffectiveDestination(locations, request.expected.document.path)) return Result(CommitStatus::UnsafePath);
    const StorePlan plan(PlanStoredMutation(locations, request.expected, request.mutation, selectors, request.access));
    if (!plan.ready()) {
        if (plan.edit.status == EditStatus::ProtectedDefinition) return Result(CommitStatus::ProtectedDefinition);
        if (plan.edit.status == EditStatus::ProtectionReviewRequired) return Result(CommitStatus::ProtectionReviewRequired);
        return Result(CommitStatus::StaleSnapshot);
    }
    RawFile target;
    if (!ReadRaw(parent.get(), Leaf(request.expected.document.path), owner, &target)) return Result(CommitStatus::UnsafePath, errno);
    if (target.present != plan.target.identity.exists || target.bytes != plan.edit.original ||
        (target.present && !IdentityOf(target.st).sameVersion(plan.target.identity))) return Result(CommitStatus::StaleSnapshot);
    // A fresh policy check prevents a concurrent protection change being lost.
    RawFile currentPolicy;
    if (!ReadRaw(policyParent.get(), Leaf(policyPath), owner, &currentPolicy) || !currentPolicy.present ||
        currentPolicy.bytes != policy.bytes || !SameStat(currentPolicy.st, policy.st)) return Result(CommitStatus::StaleSnapshot);
    return WriteAtomic(parent.get(), Leaf(request.expected.document.path), target, plan.edit.updated, owner);
}
CommitResult CommitSourceRequestWithProtectionRefresh(const EffectiveLocations &locations,
    const std::string &policyPath, const CommitRequest &request, uid_t owner,
    bool (*beforePolicyWrite)(void *), void *context) {
    if (request.kind != CommitKind::EditDocument || request.access != Access::AdvancedSettings ||
        request.initializePolicy || request.mutation.kind == EditKind::ReplaceDocument)
        return Result(CommitStatus::InvalidRequest);
    if (request.mutation.kind == EditKind::AppendDefinition)
        return CommitSourceRequest(locations, policyPath, request, owner);
    const Document previousDocument(ParseDocument(request.expected.document.path,
        request.expected.document.format, request.expected.document.bytes));
    if (!previousDocument.valid() || request.mutation.ordinal >= previousDocument.definitions.size())
        return Result(CommitStatus::InvalidRequest);
    ProtectedFileSnapshot policy;
    std::vector<ProtectionSelector> selectors;
    if (!ReadProtectedFile(policyPath, &policy, owner) || !policy.identity.exists ||
        !ParseProtectionPolicy(policy.bytes, &selectors)) return Result(CommitStatus::ProtectionReviewRequired);
    if (policy.bytes != request.expectedPolicy) return Result(CommitStatus::StaleSnapshot);
    const Definition &previous(previousDocument.definitions[request.mutation.ordinal]);
    const auto matches = [&](const ProtectionSelector &selector) {
        return selector.originPath == previous.path && selector.semanticKey == previous.semanticKey;
    };
    const bool affected(std::find_if(selectors.begin(), selectors.end(), matches) != selectors.end());
    if (!affected) return CommitSourceRequest(locations, policyPath, request, owner);

    const StorePlan planned(PlanStoredMutation(locations, request.expected, request.mutation, selectors, request.access));
    if (!planned.ready()) return Result(CommitStatus::StaleSnapshot);
    std::vector<Document> before;
    for (const auto &stored : planned.fresh.documents) before.push_back(stored.document);
    // A selector that matches two definitions cannot identify which one owns
    // the bootstrap role, even after a native caller chooses an ordinal.
    if (EvaluateProtection(before, selectors, previous.path, request.mutation.ordinal).state != ProtectionState::Protected)
        return Result(CommitStatus::ProtectionReviewRequired);
    const Document intended(ParseDocument(previous.path, previousDocument.format, planned.edit.updated));
    const bool removing(request.mutation.kind == EditKind::RemoveDefinition);
    std::size_t replacementCount(1);
    if (request.mutation.kind == EditKind::ReplaceDefinition) {
        const Document replacement(ParseDocument(previous.path, previousDocument.format, request.mutation.contents));
        if (!IsSingleSourceAddition(replacement)) return Result(CommitStatus::InvalidRequest);
        replacementCount = replacement.definitions.size();
    }
    if (!intended.valid() || (!removing && (request.mutation.ordinal >= intended.definitions.size() ||
        replacementCount > intended.definitions.size() - request.mutation.ordinal)))
        return Result(CommitStatus::InvalidRequest);
    std::vector<ProtectionSelector> updated;
    for (const auto &selector : selectors) {
        if (!matches(selector)) updated.push_back(selector);
        else if (!removing) {
            // A classic deb/deb-src replacement is one source expressed as two
            // records. Every resulting record inherits every reviewed role,
            // regardless of whether the binary or source record comes first.
            for (std::size_t index(0); index != replacementCount; ++index) {
                const Definition &replacement(intended.definitions[request.mutation.ordinal + index]);
                ProtectionSelector refreshed(selector);
                refreshed.semanticKey = replacement.semanticKey; refreshed.uris = replacement.uris;
                updated.push_back(refreshed);
            }
        }
    }
    std::vector<Document> after(before);
    for (auto &document : after) if (document.path == previous.path) document = intended;
    if (EvaluateProtection(after, updated, "", 0).state == ProtectionState::ReviewRequired)
        return Result(CommitStatus::ProtectionReviewRequired);

    const CommitResult source(CommitSourceRequest(locations, policyPath, request, owner));
    if (!source.succeeded()) return source;
    if (SerializeProtectionPolicy(updated) == policy.bytes) return source;
    const StoreSnapshot fresh(ReadEffectiveDocuments(locations));
    bool sourceMatches(false);
    std::vector<Document> documents;
    for (const auto &stored : fresh.documents) {
        documents.push_back(stored.document);
        if (stored.document.path == previous.path && stored.document.bytes == planned.edit.updated)
            sourceMatches = true;
    }
    if (!fresh.ready() || !sourceMatches ||
        EvaluateProtection(documents, updated, "", 0).state == ProtectionState::ReviewRequired ||
        (beforePolicyWrite && !beforePolicyWrite(context))) return Result(CommitStatus::SourceAppliedPolicyReviewRequired);
    const CommitResult refresh(ReplaceProtectedFile(policyPath, policy, SerializeProtectionPolicy(updated), owner));
    return refresh.succeeded() ? source : Result(CommitStatus::SourceAppliedPolicyReviewRequired, refresh.errorNumber);
}

} // namespace CydiaSources
