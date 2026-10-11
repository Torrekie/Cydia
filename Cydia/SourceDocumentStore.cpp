/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/SourceDocumentStore.hpp"
#include "Cydia/ReadOnlySourceAlias.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace CydiaSources {
namespace {

class Descriptor {
  public:
    explicit Descriptor(int value = -1) : value_(value) {}
    ~Descriptor() { if (value_ >= 0) close(value_); }
    int get() const { return value_; }
    int release() { const int value(value_); value_ = -1; return value; }
    Descriptor(const Descriptor &) = delete;
    Descriptor &operator=(const Descriptor &) = delete;
  private:
    int value_;
};

bool Disabled(const std::string &path) { return path.empty() || path == "/dev/null"; }
bool Suffix(const std::string &value, const char *suffix) {
    const std::string ending(suffix);
    return value.size() >= ending.size() && value.compare(value.size() - ending.size(), ending.size(), ending) == 0;
}
Format FileFormat(const std::string &path) { return Suffix(path, ".sources") ? Format::Deb822 : Format::OneLine; }
bool ValidPath(const std::string &path) {
    if (path.empty() || path[0] != '/' || path.back() == '/' || path.find('\0') != std::string::npos) return false;
    std::size_t begin(1);
    while (begin < path.size()) {
        const std::size_t end(path.find('/', begin));
        const std::string component(path.substr(begin, end == std::string::npos ? end : end - begin));
        if (component.empty() || component == "." || component == "..") return false;
        if (end == std::string::npos) break;
        begin = end + 1;
    }
    return true;
}
std::string Directory(std::string path) {
    while (path.size() > 1 && path.back() == '/') path.pop_back();
    return path;
}
std::string Parent(const std::string &path) {
    const std::size_t slash(path.find_last_of('/'));
    return slash == 0 ? "/" : path.substr(0, slash);
}
std::string Leaf(const std::string &path) { return path.substr(path.find_last_of('/') + 1); }
std::string Join(const std::string &parent, const std::string &leaf) { return parent == "/" ? parent + leaf : parent + "/" + leaf; }
bool PartsName(const std::string &name) {
    if (!Suffix(name, ".list") && !Suffix(name, ".sources")) return false;
    for (char character : name)
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') || character == '_' || character == '-' || character == '.' || character == ':')) return false;
    return !name.empty() && name[0] != '.';
}
FileIdentity Identity(const struct stat &value) {
    FileIdentity identity; identity.exists = true;
    identity.device = static_cast<std::uint64_t>(value.st_dev);
    identity.inode = static_cast<std::uint64_t>(value.st_ino);
    identity.size = static_cast<std::uint64_t>(value.st_size);
    identity.links = static_cast<std::uint64_t>(value.st_nlink);
    identity.mode = static_cast<std::uint32_t>(value.st_mode);
    identity.owner = static_cast<std::uint32_t>(value.st_uid);
    identity.group = static_cast<std::uint32_t>(value.st_gid);
#ifdef __APPLE__
    identity.modifiedSeconds = value.st_mtimespec.tv_sec;
    identity.modifiedNanoseconds = value.st_mtimespec.tv_nsec;
    identity.changedSeconds = value.st_ctimespec.tv_sec;
    identity.changedNanoseconds = value.st_ctimespec.tv_nsec;
#else
    identity.modifiedSeconds = value.st_mtim.tv_sec;
    identity.modifiedNanoseconds = value.st_mtim.tv_nsec;
    identity.changedSeconds = value.st_ctim.tv_sec;
    identity.changedNanoseconds = value.st_ctim.tv_nsec;
#endif
    return identity;
}
void Diagnostic(StoreSnapshot *result, StoreError kind, const std::string &path, int error, const char *detail) {
    result->diagnostics.push_back({kind, path, error, detail});
}
int OpenDirectory(const std::string &path, std::string *canonical, int *error) {
    char *resolved(realpath(path.c_str(), NULL));
    if (resolved == NULL) { *error = errno; return -1; }
    *canonical = resolved; free(resolved);
    const int descriptor(open(canonical->c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (descriptor < 0) *error = errno;
    return descriptor;
}
void ReadAt(StoreSnapshot *result, int directory, const std::string &canonicalDirectory,
            const std::string &path, Format format, std::size_t maximumBytes, bool readOnlyAliases = false,
            uid_t readerUID = getuid(), gid_t readerGID = getgid(), const ReaderGroups &readerGroups = ReaderGroups()) {
    const std::string leaf(Leaf(path));
    struct stat aliasBefore;
    const bool alias(fstatat(directory, leaf.c_str(), &aliasBefore, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(aliasBefore.st_mode));
    if (alias && readOnlyAliases) {
        StoredDocument stored; struct stat target; std::string bytes;
        if (!ReadOnlyAlias::Read(path, &bytes, &target, &stored.canonicalPath, readerUID, readerGID, NULL, readerGroups)) {
            Diagnostic(result, StoreError::UnsafeFile, path, errno, "Cannot safely read delegated source data"); return;
        }
        if (bytes.size() > maximumBytes) {
            Diagnostic(result, StoreError::TooLarge, path, 0, "Source file exceeds the reader limit"); return;
        }
        stored.document = ParseDocument(path, format, bytes); stored.identity = Identity(target); stored.readOnly = true;
        if (!stored.document.valid()) Diagnostic(result, StoreError::InvalidDocument, path, 0, "Source document is malformed or ambiguous");
        result->documents.push_back(stored); return;
    }
    const Descriptor descriptor(openat(directory, leaf.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK));
    if (descriptor.get() < 0) {
        Diagnostic(result, errno == ELOOP ? StoreError::UnsafeFile : StoreError::ReadFailed,
                   path, errno, "Cannot safely open source file"); return;
    }
    struct stat before, after;
    if (fstat(descriptor.get(), &before) < 0) {
        Diagnostic(result, StoreError::ReadFailed, path, errno, "Cannot inspect source file"); return;
    }
    if (!S_ISREG(before.st_mode) || before.st_size < 0) {
        Diagnostic(result, StoreError::UnsafeFile, path, 0, "Source file is not a regular file"); return;
    }
    if (static_cast<std::uint64_t>(before.st_size) > maximumBytes) {
        Diagnostic(result, StoreError::TooLarge, path, 0, "Source file exceeds the reader limit"); return;
    }
    std::string bytes;
    char buffer[16384];
    for (;;) {
        const ssize_t count(read(descriptor.get(), buffer, sizeof(buffer)));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { Diagnostic(result, StoreError::ReadFailed, path, errno, "Cannot read source file"); return; }
        if (count == 0) break;
        if (static_cast<std::size_t>(count) > maximumBytes - bytes.size()) {
            Diagnostic(result, StoreError::TooLarge, path, 0, "Source file grew beyond the reader limit"); return;
        }
        bytes.append(buffer, static_cast<std::size_t>(count));
    }
    if (fstat(descriptor.get(), &after) < 0) {
        Diagnostic(result, StoreError::ReadFailed, path, errno, "Cannot recheck source file"); return;
    }
    const FileIdentity identity(Identity(before));
    if (!identity.sameVersion(Identity(after)) || identity.size != bytes.size()) {
        Diagnostic(result, StoreError::ChangedDuringRead, path, 0, "Source file changed while being read"); return;
    }
    struct stat linked;
    if (fstatat(directory, leaf.c_str(), &linked, AT_SYMLINK_NOFOLLOW) < 0 || !identity.sameVersion(Identity(linked))) {
        Diagnostic(result, StoreError::ChangedDuringRead, path, 0, "Source file path changed while being read"); return;
    }
    StoredDocument stored; stored.document = ParseDocument(path, format, bytes); stored.identity = identity;
    stored.canonicalPath = Join(canonicalDirectory, leaf);
    if (!stored.document.valid()) Diagnostic(result, StoreError::InvalidDocument, path, 0, "Source document is malformed or ambiguous");
    result->documents.push_back(stored);
}
void Merge(StoreSnapshot *result, const StoreSnapshot &other) {
    result->documents.insert(result->documents.end(), other.documents.begin(), other.documents.end());
    result->diagnostics.insert(result->diagnostics.end(), other.diagnostics.begin(), other.diagnostics.end());
}
EditResult Refused(const Document &document, EditStatus status, const char *detail) {
    EditResult result; result.status = status; result.original = document.bytes;
    result.updated = document.bytes; result.detail = detail; return result;
}

} // namespace

FileIdentity::FileIdentity() : exists(false), device(0), inode(0), size(0), links(0), mode(0), owner(0), group(0),
    modifiedSeconds(0), modifiedNanoseconds(0), changedSeconds(0), changedNanoseconds(0) {}
bool FileIdentity::sameVersion(const FileIdentity &other) const {
    return exists == other.exists && (!exists || (device == other.device && inode == other.inode && size == other.size &&
        links == other.links && mode == other.mode && owner == other.owner && group == other.group &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds &&
        changedSeconds == other.changedSeconds && changedNanoseconds == other.changedNanoseconds));
}

StoreSnapshot ReadDocument(const std::string &path, Format format, std::size_t maximumBytes, bool readOnlyAliases,
                           uid_t readerUID, gid_t readerGID, const ReaderGroups &readerGroups) {
    StoreSnapshot result;
    if (!ValidPath(path) || Disabled(path)) {
        Diagnostic(&result, StoreError::InvalidPath, path, 0, "Source file must have an explicit absolute path"); return result;
    }
    std::string canonical; int error(0);
    const Descriptor directory(OpenDirectory(Parent(path), &canonical, &error));
    if (directory.get() < 0) {
        Diagnostic(&result, StoreError::ReadFailed, path, error, "Cannot open source file's parent directory"); return result;
    }
    ReadAt(&result, directory.get(), canonical, path, format, maximumBytes, readOnlyAliases, readerUID, readerGID, readerGroups);
    return result;
}

StoreSnapshot ReadEffectiveDocuments(const EffectiveLocations &locations, std::size_t maximumBytes, std::size_t maximumFiles) {
    StoreSnapshot result;
    if (!Disabled(locations.mainFile)) {
        const StoreSnapshot main(ReadDocument(locations.mainFile, FileFormat(locations.mainFile), maximumBytes, true,
                                              locations.readerUID, locations.readerGID, locations.readerGroups));
        // APT accepts an absent main file; a malformed or unsafe file remains
        // an error, including when sourceparts is otherwise available.
        if (!(main.documents.empty() && main.diagnostics.size() == 1 &&
              main.diagnostics[0].kind == StoreError::ReadFailed && main.diagnostics[0].errorNumber == ENOENT)) Merge(&result, main);
    }
    if (result.documents.size() > maximumFiles)
        Diagnostic(&result, StoreError::TooManyFiles, locations.mainFile, 0, "Effective source file count exceeds the reader limit");
    if (Disabled(locations.partsDirectory)) return result;
    const std::string parts(Directory(locations.partsDirectory));
    if (!ValidPath(parts) && parts != "/") {
        Diagnostic(&result, StoreError::InvalidPath, parts, 0, "Sourceparts must have an explicit absolute path"); return result;
    }
    std::string canonical; int error(0);
    Descriptor descriptor(OpenDirectory(parts, &canonical, &error));
    if (descriptor.get() < 0) {
        if (error != ENOENT) Diagnostic(&result, StoreError::ReadFailed, parts, error, "Cannot open effective sourceparts directory");
        return result;
    }
    struct stat before, after;
    if (fstat(descriptor.get(), &before) < 0) {
        Diagnostic(&result, StoreError::ReadFailed, parts, errno, "Cannot inspect sourceparts directory"); return result;
    }
    const int directoryDescriptor(descriptor.release());
    DIR *directory(fdopendir(directoryDescriptor));
    if (directory == NULL) {
        const int error(errno); close(directoryDescriptor);
        Diagnostic(&result, StoreError::ReadFailed, parts, error, "Cannot enumerate sourceparts directory"); return result;
    }
    std::vector<std::string> names;
    errno = 0;
    for (struct dirent *entry; (entry = readdir(directory)) != NULL;) {
        if (!PartsName(entry->d_name)) continue;
        names.push_back(entry->d_name);
        if (names.size() + result.documents.size() > maximumFiles) {
            Diagnostic(&result, StoreError::TooManyFiles, parts, 0, "Effective source file count exceeds the reader limit"); break;
        }
    }
    if (errno != 0) Diagnostic(&result, StoreError::ReadFailed, parts, errno, "Cannot enumerate every sourceparts entry");
    std::sort(names.begin(), names.end());
    // Keep showing safely read entries even when another input is malformed.
    // Diagnostics still make the complete snapshot ineligible for mutation.
    if (names.size() + result.documents.size() <= maximumFiles) for (const std::string &name : names) {
        const std::string path(Join(parts, name));
        if (path == locations.mainFile) continue; // One physical input, not an implicit duplicate.
        ReadAt(&result, dirfd(directory), canonical, path, FileFormat(path), maximumBytes, true,
               locations.readerUID, locations.readerGID, locations.readerGroups);
    }
    if (fstat(dirfd(directory), &after) < 0 || !Identity(before).sameVersion(Identity(after)))
        Diagnostic(&result, StoreError::ChangedDuringRead, parts, 0, "Sourceparts membership changed while being read");
    closedir(directory);
    return result;
}

bool IsEffectiveDestination(const EffectiveLocations &locations, const std::string &path) {
    if (!ValidPath(path) || Disabled(path)) return false;
    if (!Disabled(locations.mainFile) && path == locations.mainFile) return true;
    return !Disabled(locations.partsDirectory) && Parent(path) == Directory(locations.partsDirectory) && PartsName(Leaf(path));
}

StoredDocument NewDocument(const std::string &path, Format format) {
    StoredDocument result; result.document = ParseDocument(path, format, ""); return result;
}

StorePlan PlanStoredMutation(const EffectiveLocations &locations, const StoredDocument &expected, const Mutation &mutation,
                             const std::vector<ProtectionSelector> &policy, Access access, std::size_t maximumBytes) {
    StorePlan result;
    result.target = expected;
    result.edit = Refused(expected.document, EditStatus::InvalidDocument, "Source snapshot is not ready for mutation");
    if (!IsEffectiveDestination(locations, expected.document.path) || expected.document.format != FileFormat(expected.document.path)) {
        Diagnostic(&result.fresh, StoreError::InvalidPath, expected.document.path, 0, "Selected destination is outside effective APT source inputs");
        return result;
    }
    result.fresh = ReadEffectiveDocuments(locations, maximumBytes);
    if (!result.fresh.ready()) return result;
    std::vector<Document> documents;
    bool found(false);
    for (const StoredDocument &document : result.fresh.documents) {
        documents.push_back(document.document);
        if (document.document.path == expected.document.path) { result.target = document; found = true; }
    }
    if ((!found && expected.identity.exists) || (found && !expected.identity.sameVersion(result.target.identity)) ||
        (found && expected.canonicalPath != result.target.canonicalPath) ||
        (found && expected.document.bytes != result.target.document.bytes) ||
        (!found && !expected.document.bytes.empty())) {
        Diagnostic(&result.fresh, StoreError::StaleSnapshot, expected.document.path, 0, "Source definition changed; reload its actual file");
        result.edit = Refused(expected.document, EditStatus::StaleDocument, "Source file identity or contents changed"); return result;
    }
    if (!found && mutation.kind != EditKind::AppendDefinition && mutation.kind != EditKind::ReplaceDocument) {
        result.edit = Refused(expected.document, EditStatus::InvalidMutation, "Only an explicit addition/import can create a source file"); return result;
    }
    if (found && result.target.readOnly) {
        Diagnostic(&result.fresh, StoreError::UnsafeFile, expected.document.path, 0, "Source aliases are read-only"); return result;
    }
    if (found && result.target.identity.links != 1) {
        Diagnostic(&result.fresh, StoreError::UnsafeFile, expected.document.path, 0, "Hard-linked source file requires explicit ownership review"); return result;
    }
    if (!found) {
        // Verify the explicitly selected parent exists. No directory creation,
        // default destination, or repository reconstruction occurs here.
        std::string canonical; int error(0);
        const Descriptor parent(OpenDirectory(Parent(expected.document.path), &canonical, &error));
        if (parent.get() < 0) {
            Diagnostic(&result.fresh, StoreError::ReadFailed, expected.document.path, error, "Explicit source destination's directory is unavailable"); return result;
        }
        struct stat existing;
        if (fstatat(parent.get(), Leaf(expected.document.path).c_str(), &existing, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
            Diagnostic(&result.fresh, StoreError::StaleSnapshot, expected.document.path, 0, "Explicit source destination is no longer absent"); return result;
        }
        result.target.canonicalPath = Join(canonical, Leaf(expected.document.path));
    }
    result.edit = PlanMutation(expected.document, result.target.document.bytes, mutation, documents, policy, access);
    if (result.edit.updated.size() > maximumBytes) result.edit = Refused(expected.document, EditStatus::InvalidMutation, "Edited source document exceeds the reader limit");
    return result;
}

} // namespace CydiaSources
