/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderArchiveEvidence.hpp"
#include "Cydia/PackageArchiveReader.hpp"
#include "Cydia/SourceDocumentStore.hpp"
#include <apt-pkg/aptconfiguration.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/hashes.h>
#include <apt-pkg/strutl.h>
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <limits>
#include <set>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

namespace CydiaAPT { namespace Provider {
namespace {
constexpr std::uint64_t MaximumIndexBytes = 512ull * 1024 * 1024;
constexpr std::uint64_t MaximumRecordBytes = 1024 * 1024;
constexpr std::uint64_t MaximumRetainedBytes = 64ull * 1024 * 1024;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Cancelled(const std::function<bool()> &cancelled, std::string *error) {
    return cancelled && cancelled() ? !Fail(error, "provider_cancelled") : false;
}
struct ErrorScope { ErrorScope() { _error->PushToStack(); } ~ErrorScope() { _error->RevertToStack(); } };
struct File {
    int fd = -1;
    std::string path;
    struct stat identity = {};
    ~File() { if (fd >= 0) close(fd); }
};
bool Same(const struct stat &a, const struct stat &b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
        a.st_uid == b.st_uid && a.st_gid == b.st_gid && a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
#ifdef __APPLE__
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
        a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
bool Recheck(const File &file) {
    struct stat retained, named;
    return fstat(file.fd, &retained) == 0 && lstat(file.path.c_str(), &named) == 0 &&
        Same(file.identity, retained) && Same(file.identity, named);
}
bool Path(const std::string &path) {
    if (path.empty() || path.front() != '/' || path.back() == '/' || path.find_first_of("\r\n\t") != std::string::npos ||
        path.find('\0') != std::string::npos) return false;
    std::size_t offset = 1;
    while (offset < path.size()) {
        const auto slash = path.find('/', offset);
        const std::string part = path.substr(offset, slash == std::string::npos ? slash : slash - offset);
        if (part.empty() || part == "." || part == "..") return false;
        if (slash == std::string::npos) return true;
        offset = slash + 1;
    }
    return false;
}
std::shared_ptr<File> Open(const std::string &path, std::uint64_t maximum, std::string *error) {
    if (!Path(path)) { Fail(error, "provider_evidence_invalid_path"); return nullptr; }
    auto file = std::make_shared<File>(); file->path = path;
    file->fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (file->fd < 0 || fstat(file->fd, &file->identity) != 0 || !S_ISREG(file->identity.st_mode) ||
        file->identity.st_size <= 0 || static_cast<std::uint64_t>(file->identity.st_size) > maximum || !Recheck(*file)) {
        Fail(error, "provider_evidence_file_unavailable"); return nullptr;
    }
    return file;
}
bool Hash(const File &file, std::map<std::string, std::string> *result,
          const std::function<bool()> &cancelled, std::string *error) {
    if (!Recheck(file) || lseek(file.fd, 0, SEEK_SET) != 0) return Fail(error, "provider_evidence_changed");
    Hashes hashes(Hashes::MD5SUM | Hashes::SHA1SUM | Hashes::SHA256SUM | Hashes::SHA512SUM);
    std::uint64_t remaining = file.identity.st_size;
    while (remaining) {
        if (Cancelled(cancelled, error)) return false;
        unsigned char bytes[65536];
        const auto wanted = static_cast<std::size_t>(std::min<std::uint64_t>(remaining, sizeof(bytes)));
        ssize_t count; do { count = read(file.fd, bytes, wanted); } while (count < 0 && errno == EINTR);
        if (count <= 0 || !hashes.Add(bytes, static_cast<unsigned long long>(count))) return Fail(error, "provider_evidence_read_failed");
        remaining -= count;
    }
    if (!Recheck(file)) return Fail(error, "provider_evidence_changed");
    result->clear();
    for (const auto &hash : hashes.GetHashStringList()) (*result)[hash.HashType()] = hash.HashValue();
    return true;
}
bool SameArchive(const ArchiveManifest &a, const ArchiveManifest &b) {
    std::string left, right; return Encode(a, &left) && Encode(b, &right) && left == right;
}
std::string Lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
std::string Trim(const std::string &value) {
    const auto first = value.find_first_not_of(" \t\r");
    if (first == std::string::npos) return "";
    return value.substr(first, value.find_last_not_of(" \t\r") - first + 1);
}
std::vector<std::string> Words(std::string value) {
    std::vector<std::string> result;
    for (char &c : value) if (c == ',') c = ' ';
    std::size_t start = 0;
    while ((start = value.find_first_not_of(" \t\r\n", start)) != std::string::npos) {
        const auto end = value.find_first_of(" \t\r\n", start);
        result.push_back(value.substr(start, end == std::string::npos ? end : end - start));
        if (end == std::string::npos) break;
        start = end;
    }
    return result;
}
bool Has(const std::vector<std::string> &values, const std::string &value) {
    return std::find(values.begin(), values.end(), value) != values.end();
}
std::string Expand(std::string value, const std::string &architecture) {
    std::size_t position = 0;
    while ((position = value.find("$(ARCH)", position)) != std::string::npos) {
        value.replace(position, 7, architecture); position += architecture.size();
    }
    return value;
}
std::string Joined(std::string base, const std::string &tail) {
    if (base.empty() || base.back() != '/') base += '/'; return base + tail;
}
std::string Compression(const std::string &path, const std::string &base) {
    if (path == base) return "none";
    for (const auto &type : std::vector<std::pair<std::string, std::string>>{
            {".gz", "gzip"}, {".bz2", "bzip2"}, {".xz", "xz"}, {".lzma", "lzma"}, {".lz4", "lz4"}, {".zst", "zstd"}})
        if (path == base + type.first) return type.second;
    return "";
}
bool Association(const RuntimeDescriptor &runtime, const CydiaSources::StoreSnapshot &sources,
                 const ArchiveManifest &archive, std::string *compression, std::string *error) {
    const CydiaSources::Definition *definition = nullptr;
    for (const auto &stored : sources.documents) if (stored.document.path == archive.sourceDefinitionPath)
        for (const auto &candidate : stored.document.definitions) if (candidate.ordinal == archive.sourceDefinitionOrdinal) definition = &candidate;
    if (!definition || !definition->enabled || !Has(definition->types, "deb")) return Fail(error, "provider_archive_source_not_configured");
    std::vector<std::string> architectures(runtime.acquisitionArchitectures), added, removed;
    for (const auto &field : definition->fields) {
        const auto key = Lower(field.name);
        if (key == "arch" || key == "architectures") architectures = Words(field.value);
        else if (key == "arch+" || key == "architectures-add") added = Words(field.value);
        else if (key == "arch-" || key == "architectures-remove") removed = Words(field.value);
    }
    for (const auto &arch : added) if (!Has(architectures, arch)) architectures.push_back(arch);
    architectures.erase(std::remove_if(architectures.begin(), architectures.end(), [&](const std::string &arch) { return Has(removed, arch); }), architectures.end());
    // APT implicitly considers a separate binary-all target unless the source
    // explicitly removes it. This is index association only: all packages in
    // a native/foreign Packages index retain their ordinary install meaning.
    std::vector<std::string> indexArchitectures(architectures);
    if (!Has(removed, "all") && !Has(indexArchitectures, "all")) indexArchitectures.push_back("all");
    bool sourceMatches = false, targetMatches = false;
    for (const auto &uri : definition->uris) {
        const std::string base = Expand(uri, runtime.architecture);
        if (base != archive.sourceURI) continue;
        sourceMatches = true;
        for (const auto &rawSuite : definition->suites) {
            const std::string suite = Expand(rawSuite, runtime.architecture);
            if (!suite.empty() && suite.back() == '/') {
                if (definition->components.empty() && archive.sourceIndexURI == Joined(base, suite) + "Packages") targetMatches = true;
            } else for (const auto &component : definition->components) for (const auto &architecture : indexArchitectures)
                if (archive.sourceIndexURI == Joined(base, "dists/" + suite + "/" + component + "/binary-" + architecture + "/Packages")) {
                    if (archive.package.architecture == "all" || archive.package.architecture == architecture) targetMatches = true;
                }
        }
    }
    if (!sourceMatches || !targetMatches ||
        (archive.package.architecture != "all" && !Has(architectures, archive.package.architecture))) return Fail(error, "provider_archive_index_not_configured");
    *compression = Compression(archive.sourceIndexPath, Joined(runtime.listsDirectory, URItoFileName(archive.sourceIndexURI)));
    if (compression->empty()) return Fail(error, "provider_archive_index_path_mismatch");
    return true;
}
bool SameSources(const CydiaSources::StoreSnapshot &left, const CydiaSources::StoreSnapshot &right) {
    if (!left.ready() || !right.ready() || left.documents.size() != right.documents.size()) return false;
    for (std::size_t i = 0; i < left.documents.size(); ++i) {
        const auto &a = left.documents[i], &b = right.documents[i];
        if (a.document.path != b.document.path || a.canonicalPath != b.canonicalPath ||
            a.document.bytes != b.document.bytes || !a.identity.sameVersion(b.identity)) return false;
    }
    return true;
}
// Length-prefixed streaming fields avoid ambiguous concatenation and do not
// allocate another copy of the retained source documents.
class EvidenceHash {
    Hashes hash_{Hashes::SHA256SUM};
    bool valid_ = true;
public:
    bool field(const std::string &value) {
        const std::string length = std::to_string(value.size()) + ':';
        return valid_ = valid_ && hash_.Add(length.data(), length.size()) &&
            hash_.Add(value.data(), value.size()) && hash_.Add(",", 1);
    }
    template<class T> bool number(T value) { return field(std::to_string(value)); }
    std::string finish() { return valid_ ? hash_.GetHashString(Hashes::SHA256SUM).HashValue() : ""; }
};
bool SourceIdentity(const CydiaSources::EffectiveLocations &locations, const CydiaSources::StoreSnapshot &sources,
    std::string *identity, const std::function<bool()> &cancelled, std::string *error) {
    EvidenceHash hash;
    hash.field("CYDIA-INDEX-CONTROL-SOURCES-1"); hash.field(locations.mainFile); hash.field(locations.partsDirectory);
    hash.number(sources.documents.size());
    for (const auto &stored : sources.documents) {
        if (Cancelled(cancelled, error)) return false;
        hash.field(stored.document.path); hash.field(stored.canonicalPath); hash.field(stored.document.bytes);
        const auto &file = stored.identity;
        hash.number(file.exists); hash.number(file.device); hash.number(file.inode); hash.number(file.size);
        hash.number(file.links); hash.number(file.mode); hash.number(file.owner); hash.number(file.group);
        hash.number(file.modifiedSeconds); hash.number(file.modifiedNanoseconds);
        hash.number(file.changedSeconds); hash.number(file.changedNanoseconds);
    }
    *identity = hash.finish();
    return !identity->empty() || Fail(error, "provider_archive_identity_failed");
}
std::string IndexIdentity(const File &file, const std::string &content, const std::string &compression) {
    EvidenceHash hash;
    hash.field("CYDIA-INDEX-CONTROL-INDEX-1"); hash.field(file.path); hash.field(content); hash.field(compression);
    const auto &stat = file.identity;
    hash.number(stat.st_dev); hash.number(stat.st_ino); hash.number(stat.st_mode); hash.number(stat.st_uid);
    hash.number(stat.st_gid); hash.number(stat.st_nlink); hash.number(stat.st_size);
#ifdef __APPLE__
    hash.number(stat.st_mtimespec.tv_sec); hash.number(stat.st_mtimespec.tv_nsec);
    hash.number(stat.st_ctimespec.tv_sec); hash.number(stat.st_ctimespec.tv_nsec);
#else
    hash.number(stat.st_mtim.tv_sec); hash.number(stat.st_mtim.tv_nsec);
    hash.number(stat.st_ctim.tv_sec); hash.number(stat.st_ctim.tv_nsec);
#endif
    return hash.finish();
}
struct Range {
    ArchiveManifest archive;
    std::uint64_t begin = 0, end = 0;
    std::string bytes;
    bool commercial = false;
    std::map<std::string, std::string> controls;
    std::vector<std::string> dependencyOrder;
    std::string rawControlRecord;
};
// The decoder receives only a retained descriptor, and absolute trusted tools
// with fixed arguments. No APT compressor options or policy are consulted.
bool Decode(const File &file, const std::string &compression,
    const std::map<std::string, std::string> &decoders,
    const std::function<bool(const unsigned char *, std::size_t)> &consume,
    const std::function<bool()> &cancelled, std::string *error) {
    if (lseek(file.fd, 0, SEEK_SET) != 0) return Fail(error, "provider_index_read_failed");
    if (compression == "gzip") {
        z_stream stream = {};
        if (inflateInit2(&stream, MAX_WBITS + 16) != Z_OK) return Fail(error, "provider_index_decoder_unavailable");
        struct End { z_stream *stream; ~End() { inflateEnd(stream); } } end{&stream};
        unsigned char input[65536], output[65536]; bool boundary = false;
        while (true) {
            if (Cancelled(cancelled, error)) return false;
            if (stream.avail_in == 0) {
                ssize_t count; do { count = read(file.fd, input, sizeof(input)); } while (count < 0 && errno == EINTR);
                if (count == 0) return boundary ? true : Fail(error, "provider_index_decode_failed");
                if (count < 0) return Fail(error, "provider_index_read_failed");
                stream.next_in = input; stream.avail_in = count;
            }
            if (boundary) {
                Bytef *next = stream.next_in; const auto available = stream.avail_in;
                if (inflateReset(&stream) != Z_OK) return Fail(error, "provider_index_decode_failed");
                stream.next_in = next; stream.avail_in = available; boundary = false;
            }
            stream.next_out = output; stream.avail_out = sizeof(output);
            const auto before = stream.avail_in;
            const int status = inflate(&stream, Z_NO_FLUSH);
            if (!consume(output, sizeof(output) - stream.avail_out)) return false;
            if (status == Z_STREAM_END) boundary = true;
            else if (status != Z_OK || (before == stream.avail_in && stream.avail_out == sizeof(output)))
                return Fail(error, "provider_index_decode_failed");
        }
    }
    FileFd stream;
    if (compression == "none") {
        if (!stream.OpenDescriptor(file.fd, FileFd::ReadOnly, FileFd::None, false)) return Fail(error, "provider_index_read_failed");
    } else {
        const auto binary = decoders.find(compression);
        CydiaRuntime::Privileged::Error ignored;
        if (binary == decoders.end() || !CydiaRuntime::Privileged::ValidateRootOwnedPath(binary->second, false, true, &ignored))
            return Fail(error, "provider_index_decoder_unavailable");
        std::vector<std::string> arguments{"-d", "-c"};
        if (compression == "lzma") arguments.push_back("--format=lzma");
        if (CydiaPackages::StreamArchiveDecoder(file.fd, binary->second, arguments, MaximumIndexBytes, 30000, consume, cancelled))
            return true;
        if (Cancelled(cancelled, error)) return false;
        if (error && !error->empty()) return false;
        return Fail(error, "provider_index_decode_failed");
    }
    while (true) {
        if (Cancelled(cancelled, error)) return false;
        unsigned char buffer[65536]; unsigned long long count = 0;
        if (!stream.Read(buffer, sizeof(buffer), &count)) return Fail(error, "provider_index_decode_failed");
        if (!count) break;
        if (!consume(buffer, count)) return false;
    }
    return stream.Close() ? true : Fail(error, "provider_index_decode_failed");
}
bool Decimal(const std::string &text, std::uint64_t *value) {
    *value = 0; if (text.empty()) return false;
    for (unsigned char c : text) {
        if (c < '0' || c > '9' || *value > (std::numeric_limits<std::uint64_t>::max() - (c - '0')) / 10) return false;
        *value = *value * 10 + c - '0';
    }
    return true;
}
bool Record(const std::string &bytes, const ArchiveManifest &archive, std::string *error, bool *commercial,
    std::map<std::string, std::string> *controls, std::vector<std::string> *dependencyOrder) {
    std::map<std::string, std::string> fields; std::vector<std::string> fieldOrder;
    std::string previous; bool ended = false; std::size_t start = 0;
    while (start < bytes.size()) {
        const auto end = bytes.find('\n', start);
        std::string line = bytes.substr(start, end == std::string::npos ? end : end - start);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) { if (fields.empty()) return Fail(error, "provider_index_invalid_record"); ended = true; }
        else {
            if (ended || line.find('\0') != std::string::npos) return Fail(error, "provider_index_invalid_record");
            if (line.front() == ' ' || line.front() == '\t') {
                if (previous.empty()) return Fail(error, "provider_index_invalid_record");
                fields[previous] += '\n' + Trim(line);
            } else {
                const auto colon = line.find(':');
                if (colon == std::string::npos || colon == 0) return Fail(error, "provider_index_invalid_record");
                previous = Lower(line.substr(0, colon));
                if (previous.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-") != std::string::npos ||
                    !fields.emplace(previous, Trim(line.substr(colon + 1))).second) return Fail(error, "provider_index_invalid_record");
                fieldOrder.push_back(previous);
            }
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    std::uint64_t size = 0;
    if (fields["package"] != archive.package.package || fields["version"] != archive.package.version ||
        fields["architecture"] != archive.package.architecture || fields["filename"] != archive.filename ||
        archive.filename.empty() || !Decimal(fields["size"], &size) || size != archive.size || size == 0)
        return Fail(error, "provider_index_package_mismatch");
    std::map<std::string, std::string> hashes;
    for (const auto &kind : std::vector<std::pair<std::string, std::size_t>>{{"MD5Sum", 32}, {"SHA1", 40}, {"SHA256", 64}, {"SHA512", 128}}) {
        const auto found = fields.find(Lower(kind.first)); if (found == fields.end()) continue;
        const std::string hash = Lower(found->second);
        if (hash.size() != kind.second || hash.find_first_not_of("0123456789abcdef") != std::string::npos)
            return Fail(error, "provider_index_invalid_hash");
        hashes[kind.first] = hash;
    }
    if ((!hashes.count("SHA256") && !hashes.count("SHA512")) || hashes != archive.hashes)
        return Fail(error, "provider_index_hash_mismatch");
    *commercial = Has(Words(fields["tag"]), "cydia::commercial");
    std::string reason;
    if (!CydiaPackages::CanonicalPackageEffectControlFields(fields, controls, &reason) ||
        !CydiaPackages::PackageEffectControlFieldOrder(*controls, fieldOrder, dependencyOrder, &reason))
        return Fail(error, "provider_index_control_unsupported");
    return true;
}
bool ReadRecords(const File &file, const std::string &compression, const std::map<std::string, std::string> &decoders,
    std::vector<Range> *ranges, const std::function<bool()> &cancelled, std::string *error) {
    std::sort(ranges->begin(), ranges->end(), [](const Range &a, const Range &b) { return a.begin < b.begin; });
    std::uint64_t offset = 0; std::size_t first = 0;
    if (!Decode(file, compression, decoders, [&](const unsigned char *bytes, std::size_t count) {
        if (count > MaximumIndexBytes - offset) return Fail(error, "provider_index_too_large");
        while (first < ranges->size() && (*ranges)[first].end <= offset) ++first;
        for (std::size_t i = first; i < ranges->size() && (*ranges)[i].begin < offset + count; ++i) {
            auto &range = (*ranges)[i];
            if (range.end <= offset) continue;
            const auto begin = std::max(offset, range.begin), end = std::min(offset + count, range.end);
            range.bytes.append(reinterpret_cast<const char *>(bytes + begin - offset), end - begin);
        }
        offset += count; return true;
    }, cancelled, error)) return false;
    for (auto &range : *ranges) {
        const auto &archive = range.archive;
        const std::size_t prefix = archive.recordOffset - range.begin;
        if (archive.recordOffset + archive.recordSize > offset || range.bytes.size() < prefix + archive.recordSize)
            return Fail(error, "provider_index_record_out_of_range");
        const std::string before = range.bytes.substr(0, prefix);
        if (archive.recordOffset != 0 && !(before.size() >= 2 && before.compare(before.size() - 2, 2, "\n\n") == 0) &&
            !(before.size() >= 4 && before.compare(before.size() - 4, 4, "\r\n\r\n") == 0))
            return Fail(error, "provider_index_record_boundary");
        const std::string record = range.bytes.substr(prefix, archive.recordSize);
        const std::string after = range.bytes.substr(prefix + archive.recordSize);
        if (archive.recordOffset + archive.recordSize != offset &&
            !(record.size() >= 2 && record.compare(record.size() - 2, 2, "\n\n") == 0) &&
            !(record.size() >= 4 && record.compare(record.size() - 4, 4, "\r\n\r\n") == 0) &&
            !(record.back() == '\n' && (!after.empty() && (after[0] == '\n' || after.compare(0, 2, "\r\n") == 0))))
            return Fail(error, "provider_index_record_boundary");
        if (!Record(record, archive, error, &range.commercial, &range.controls, &range.dependencyOrder)) return false;
        range.rawControlRecord = record;
    }
    return true;
}
} // namespace

class ArchiveEvidenceSnapshot::Implementation {
public:
    struct Index { std::shared_ptr<File> file; std::string hash, compression; std::vector<Range> ranges; };
    CydiaSources::EffectiveLocations locations;
    CydiaSources::StoreSnapshot sources;
    std::map<std::string, std::string> decoders;
    std::map<std::string, Index> indexes;
    std::map<std::string, ArchiveManifest> archives;
    std::set<std::string> commercial;
    std::map<std::string, std::map<std::string, std::string>> controls;
    std::map<std::string, std::vector<std::string>> dependencyOrders;
    std::map<std::string, std::string> rawControlRecords;
};
ArchiveEvidenceSnapshot::ArchiveEvidenceSnapshot() : implementation_(new Implementation) {}
ArchiveEvidenceSnapshot::~ArchiveEvidenceSnapshot() {}

std::shared_ptr<ArchiveEvidenceSnapshot> ArchiveEvidenceSnapshot::Capture(const RuntimeDescriptor &runtime,
    const ReviewedTransaction &review, const std::string &searchPath,
    const std::function<bool()> &cancelled, std::string *error) {
    if (error) error->clear();
    ErrorScope errors;
    auto result = std::shared_ptr<ArchiveEvidenceSnapshot>(new ArchiveEvidenceSnapshot);
    auto &capture = *result->implementation_;
    if (review.binding.providerIdentifier != runtime.binding.providerIdentifier || review.binding.session != runtime.binding.session ||
        review.binding.configurationIdentity != runtime.binding.configurationIdentity || review.binding.policyIdentity != runtime.binding.policyIdentity) {
        Fail(error, "provider_archive_binding_mismatch"); return nullptr;
    }
    capture.locations = CydiaSources::EffectiveLocations(runtime.sourceListPath, runtime.sourcePartsDirectory);
    capture.sources = CydiaSources::ReadEffectiveDocuments(capture.locations);
    if (!capture.sources.ready()) { Fail(error, "provider_archive_sources_unavailable"); return nullptr; }
    if (!CydiaPackages::ResolveTrustedArchiveDecoders(searchPath, &capture.decoders, error)) return nullptr;
    std::uint64_t retained = 0;
    for (const auto &archive : review.execution.archives) {
        if (Cancelled(cancelled, error)) return nullptr;
        if (archive.recordSize == 0 || archive.recordSize > MaximumRecordBytes ||
            archive.recordOffset > MaximumIndexBytes || archive.recordSize > MaximumIndexBytes - archive.recordOffset ||
            archive.recordSize + 6 > MaximumRetainedBytes - retained ||
            !capture.archives.emplace(archive.identifier, archive).second) {
            Fail(error, "provider_archive_invalid_record_locator"); return nullptr;
        }
        retained += archive.recordSize + 6;
        std::string compression;
        if (!Association(runtime, capture.sources, archive, &compression, error)) return nullptr;
        auto &index = capture.indexes[archive.sourceIndexPath];
        if (!index.file) {
            index.file = Open(archive.sourceIndexPath, MaximumIndexBytes, error);
            if (!index.file) return nullptr;
            std::map<std::string, std::string> hashes;
            if (!Hash(*index.file, &hashes, cancelled, error)) return nullptr;
            index.hash = "SHA256:" + hashes["SHA256"]; index.compression = compression;
        }
        if (archive.sourceIndexIdentity != index.hash || index.compression != compression) {
            Fail(error, "provider_archive_index_changed"); return nullptr;
        }
        Range range; range.archive = archive;
        range.begin = archive.recordOffset > 4 ? archive.recordOffset - 4 : 0;
        range.end = archive.recordOffset + archive.recordSize + 2;
        index.ranges.push_back(std::move(range));
    }
    for (auto &item : capture.indexes) {
        auto &index = item.second;
        if (!ReadRecords(*index.file, index.compression, capture.decoders, &index.ranges, cancelled, error)) return nullptr;
        std::map<std::string, std::string> hashes;
        if (!Hash(*index.file, &hashes, cancelled, error) || "SHA256:" + hashes["SHA256"] != index.hash) {
            if (error && error->empty()) *error = "provider_archive_index_changed";
            return nullptr;
        }
        for (const auto &range : index.ranges) {
            if (range.commercial) capture.commercial.insert(range.archive.identifier);
            capture.controls.emplace(range.archive.identifier, range.controls);
            capture.dependencyOrders.emplace(range.archive.identifier, range.dependencyOrder);
            capture.rawControlRecords.emplace(range.archive.identifier, range.rawControlRecord);
        }
        // Keep the exact selected raw records and parsed fields/order. Do not
        // retain whole decoded indexes or substitute worker relationship data.
        index.ranges.clear();
    }
    if (!SameSources(capture.sources, CydiaSources::ReadEffectiveDocuments(capture.locations))) {
        Fail(error, "provider_archive_sources_changed"); return nullptr;
    }
    if (error) error->clear();
    return result;
}

bool ArchiveEvidenceSnapshot::AuthorizationRequest(const ArchiveManifest &requested,
    CydiaRuntime::RepositoryArchiveAuthorizationRequest *request, bool *commercial,
    const std::function<bool()> &cancelled, std::string *error) const {
    if (error) error->clear();
    if (!request || !commercial) return Fail(error, "provider_archive_evidence_missing");
    *request = CydiaRuntime::RepositoryArchiveAuthorizationRequest(); *commercial = false;
    ErrorScope errors;
    const auto &capture = *implementation_;
    const auto found = capture.archives.find(requested.identifier);
    if (found == capture.archives.end() || !SameArchive(requested, found->second))
        return Fail(error, "provider_archive_not_reviewed");
    if (Cancelled(cancelled, error)) return false;
    if (!SameSources(capture.sources, CydiaSources::ReadEffectiveDocuments(capture.locations)))
        return Fail(error, "provider_archive_sources_changed");
    const auto index = capture.indexes.find(found->second.sourceIndexPath);
    std::map<std::string, std::string> hashes;
    if (index == capture.indexes.end() || !Hash(*index->second.file, &hashes, cancelled, error)) return false;
    if ("SHA256:" + hashes["SHA256"] != index->second.hash) return Fail(error, "provider_archive_index_changed");
    if (!SameSources(capture.sources, CydiaSources::ReadEffectiveDocuments(capture.locations)))
        return Fail(error, "provider_archive_sources_changed");
    const auto &archive = found->second;
    request->sourceURL = archive.sourceURI; request->package = archive.package.package;
    request->version = archive.package.version; request->architecture = archive.package.architecture;
    *commercial = capture.commercial.count(archive.identifier) != 0;
    return true;
}

bool ArchiveEvidenceSnapshot::ControlFields(const ArchiveManifest &requested,
    std::map<std::string, std::string> *controls, const std::function<bool()> &cancelled, std::string *error) const {
    if (!controls) return Fail(error, "provider_archive_evidence_missing");
    controls->clear();
    CydiaRuntime::RepositoryArchiveAuthorizationRequest identity; bool commercial = false;
    if (!AuthorizationRequest(requested, &identity, &commercial, cancelled, error)) return false;
    const auto found = implementation_->controls.find(requested.identifier);
    if (found == implementation_->controls.end()) return Fail(error, "provider_archive_control_missing");
    *controls = found->second; return true;
}
bool ArchiveEvidenceSnapshot::ControlEvidence(const std::vector<ArchiveManifest> &requested,
    std::vector<VerifiedIndexControlEvidence> *evidence, const std::function<bool()> &cancelled, std::string *error) const {
    if (error) error->clear();
    if (!evidence) return Fail(error, "provider_archive_evidence_missing");
    evidence->clear();
    if (requested.size() > MaximumIndexControlRecords) return Fail(error, "provider_index_control_limit");
    ErrorScope errors;
    const auto &capture = *implementation_;
    struct Record { const ArchiveManifest *archive; const std::map<std::string, std::string> *controls;
        const std::vector<std::string> *order; const std::string *raw;
        std::string manifest, fields, ordered; };
    std::vector<Record> records;
    std::set<std::string> seen, indexes;
    std::size_t bytes = 0;
    for (const auto &archive : requested) {
        if (Cancelled(cancelled, error)) return false;
        const auto approved = capture.archives.find(archive.identifier);
        if (approved == capture.archives.end() || !seen.insert(archive.identifier).second)
            return Fail(error, "provider_archive_not_reviewed");
        Record record; record.archive = &approved->second;
        std::string claimed;
        if (!Encode(archive, &claimed) || !Encode(approved->second, &record.manifest))
            return Fail(error, "provider_index_control_limit");
        if (claimed != record.manifest) return Fail(error, "provider_archive_not_reviewed");
        const auto controls = capture.controls.find(archive.identifier);
        if (controls == capture.controls.end()) return Fail(error, "provider_archive_control_missing");
        record.controls = &controls->second;
        const auto order = capture.dependencyOrders.find(archive.identifier);
        const auto raw = capture.rawControlRecords.find(archive.identifier);
        if (order == capture.dependencyOrders.end() || raw == capture.rawControlRecords.end() ||
            !CydiaPackages::ValidPackageEffectControlFieldOrder(controls->second, order->second))
            return Fail(error, "provider_archive_control_order_missing");
        record.order = &order->second; record.raw = &raw->second;
        if (!Encode(order->second, &record.ordered) || !Encode(controls->second, &record.fields)) return Fail(error, "provider_index_control_limit");
        // Include the encoded 64-character SHA256 identity string in the
        // aggregate limit, before retaining/copying any complete output.
        for (const auto size : {record.manifest.size(), record.fields.size(), record.ordered.size(), record.raw->size(), std::size_t(68)}) {
            if (size > MaximumIndexControlBytes - bytes) return Fail(error, "provider_index_control_limit");
            bytes += size;
        }
        indexes.insert(archive.sourceIndexPath); records.push_back(std::move(record));
    }
    if (Cancelled(cancelled, error)) return false;
    if (!SameSources(capture.sources, CydiaSources::ReadEffectiveDocuments(capture.locations)))
        return Fail(error, "provider_archive_sources_changed");
    std::string sources;
    if (!SourceIdentity(capture.locations, capture.sources, &sources, cancelled, error)) return false;
    std::map<std::string, std::string> identities;
    for (const auto &path : indexes) {
        const auto index = capture.indexes.find(path);
        if (index == capture.indexes.end()) return Fail(error, "provider_archive_index_changed");
        std::map<std::string, std::string> hashes;
        if (!Hash(*index->second.file, &hashes, cancelled, error)) return false;
        if ("SHA256:" + hashes["SHA256"] != index->second.hash) return Fail(error, "provider_archive_index_changed");
        const auto identity = IndexIdentity(*index->second.file, index->second.hash, index->second.compression);
        if (identity.empty()) return Fail(error, "provider_archive_identity_failed");
        identities.emplace(path, identity);
    }
    std::vector<VerifiedIndexControlEvidence> result;
    result.reserve(records.size());
    for (const auto &record : records) {
        if (Cancelled(cancelled, error)) return false;
        EvidenceHash hash;
        hash.field("CYDIA-INDEX-CONTROL-EVIDENCE-2"); hash.field(record.manifest); hash.field(record.fields);
        hash.field(record.ordered); hash.field(*record.raw);
        hash.field(sources); hash.field(identities.at(record.archive->sourceIndexPath));
        VerifiedIndexControlEvidence checked;
        checked.evidenceIdentity = hash.finish();
        if (checked.evidenceIdentity.empty()) return Fail(error, "provider_archive_identity_failed");
        checked.archive = *record.archive; checked.controls = *record.controls;
        checked.dependencyOrderVerified = true; checked.dependencyOrder = *record.order; checked.rawControlRecord = *record.raw;
        result.push_back(std::move(checked));
    }
    if (Cancelled(cancelled, error)) return false;
    if (!SameSources(capture.sources, CydiaSources::ReadEffectiveDocuments(capture.locations)))
        return Fail(error, "provider_archive_sources_changed");
    // A previously hashed index may have changed while another index was
    // being checked. Retained descriptor and named inode must both still match.
    for (const auto &path : indexes) if (!Recheck(*capture.indexes.at(path).file))
        return Fail(error, "provider_evidence_changed");
    *evidence = std::move(result);
    return true;
}
bool ArchiveEvidenceSnapshot::Verify(const std::vector<ArchiveManifest> &requested,
    std::vector<VerifiedArchiveEvidence> *evidence, const std::function<bool()> &cancelled, std::string *error) const {
    return VerifyImpl(requested, evidence, nullptr, cancelled, error);
}
bool ArchiveEvidenceSnapshot::VerifyControl(const std::vector<ArchiveManifest> &requested,
    std::vector<VerifiedArchiveControlEvidence> *evidence, const std::function<bool()> &cancelled, std::string *error) const {
    if (!evidence) return Fail(error, "provider_archive_evidence_missing");
    evidence->clear(); std::vector<VerifiedArchiveEvidence> ignored;
    return VerifyImpl(requested, &ignored, evidence, cancelled, error);
}
bool ArchiveEvidenceSnapshot::VerifyImpl(const std::vector<ArchiveManifest> &requested,
    std::vector<VerifiedArchiveEvidence> *evidence, std::vector<VerifiedArchiveControlEvidence> *controlEvidence,
    const std::function<bool()> &cancelled, std::string *error) const {
    if (error) error->clear();
    ErrorScope errors;
    if (!evidence) return Fail(error, "provider_archive_evidence_missing");
    evidence->clear();
    const auto &capture = *implementation_;
    if (!SameSources(capture.sources, CydiaSources::ReadEffectiveDocuments(capture.locations)))
        return Fail(error, "provider_archive_sources_changed");
    for (const auto &item : capture.indexes) {
        std::map<std::string, std::string> hashes;
        if (!Hash(*item.second.file, &hashes, cancelled, error)) return false;
        if ("SHA256:" + hashes["SHA256"] != item.second.hash) return Fail(error, "provider_archive_index_changed");
    }
    std::set<std::string> seen; std::vector<VerifiedArchiveEvidence> result;
    std::vector<VerifiedArchiveControlEvidence> controlResult;
    for (const auto &archive : requested) {
        if (Cancelled(cancelled, error)) return false;
        const auto approved = capture.archives.find(archive.identifier);
        if (approved == capture.archives.end() || !seen.insert(archive.identifier).second || !SameArchive(archive, approved->second))
            return Fail(error, "provider_archive_not_reviewed");
        auto file = Open(archive.path, CydiaPackages::ArchiveLimits().maxStreamBytes, error);
        if (!file) return false;
        if (static_cast<std::uint64_t>(file->identity.st_size) != archive.size) return Fail(error, "provider_archive_size_changed");
        std::map<std::string, std::string> hashes;
        if (!Hash(*file, &hashes, cancelled, error)) return false;
        for (const auto &hash : archive.hashes) if (hashes[hash.first] != hash.second) return Fail(error, "provider_archive_hash_changed");
        for (const auto &decoder : capture.decoders) {
            CydiaRuntime::Privileged::Error ignored;
            if (!CydiaRuntime::Privileged::ValidateRootOwnedPath(decoder.second, false, true, &ignored))
                return Fail(error, "provider_archive_decoder_changed");
        }
        VerifiedArchiveEvidence checked; checked.archive = approved->second;
        CydiaPackages::ArchiveControlMetadata control;
        if (controlEvidence) {
            const auto inspected = CydiaPackages::InspectPackageArchiveControlWithDecoders(archive.path,
                {archive.package.package, archive.package.version, archive.package.architecture}, archive.layout,
                capture.decoders, CydiaPackages::ArchiveLimits(), cancelled);
            checked.inspection = inspected.archive; control = inspected.control;
            if (Cancelled(cancelled, error)) return false;
            const auto expected = capture.controls.find(archive.identifier);
            if (!control.complete || !control.dependencyOrderVerified ||
                !CydiaPackages::ValidPackageEffectControlFieldOrder(control.controls, control.dependencyOrder) ||
                expected == capture.controls.end() || control.controls != expected->second)
                return Fail(error, "provider_archive_control_index_mismatch");
        } else checked.inspection = CydiaPackages::InspectPackageArchiveWithDecoders(archive.path,
            {archive.package.package, archive.package.version, archive.package.architecture}, archive.layout,
            capture.decoders, CydiaPackages::ArchiveLimits(), cancelled);
        if (Cancelled(cancelled, error)) return false;
        if (!checked.inspection.identityVerified || !checked.inspection.complete ||
            (checked.inspection.status != CydiaPackages::ArchivePolicyStatus::Accepted &&
             checked.inspection.status != CydiaPackages::ArchivePolicyStatus::Unverified)) return Fail(error, "provider_archive_inspection_failed");
        if (!Hash(*file, &hashes, cancelled, error)) return false;
        for (const auto &hash : archive.hashes) if (hashes[hash.first] != hash.second) return Fail(error, "provider_archive_hash_changed");
        const std::string identity = CydiaRuntime::Privileged::SerializeFields({archive.path,
            std::to_string(file->identity.st_dev), std::to_string(file->identity.st_ino),
            std::to_string(file->identity.st_size), hashes["SHA256"]});
        Hashes identityHash(Hashes::SHA256SUM);
        if (!identityHash.Add(identity.data(), identity.size())) return Fail(error, "provider_archive_identity_failed");
        checked.fileIdentity = "sha256:" + identityHash.GetHashString(Hashes::SHA256SUM).HashValue();
        if (controlEvidence) {
            VerifiedArchiveControlEvidence proven; proven.archive = checked; proven.control = std::move(control);
            controlResult.push_back(std::move(proven));
        }
        result.push_back(std::move(checked));
    }
    if (!SameSources(capture.sources, CydiaSources::ReadEffectiveDocuments(capture.locations)))
        return Fail(error, "provider_archive_sources_changed");
    *evidence = std::move(result);
    if (controlEvidence) *controlEvidence = std::move(controlResult);
    if (error) error->clear();
    return true;
}
}} // namespace CydiaAPT::Provider
