/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PackageArchiveReader.hpp"
#include <apt-pkg/aptconfiguration.h>
#include <apt-pkg/debfile.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <algorithm>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <set>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

namespace CydiaPackages {
namespace {
struct ErrorScope {
    ErrorScope() { _error->PushToStack(); }
    ~ErrorScope() { _error->RevertToStack(); }
};
struct GzipInput {
    FileFd *input = NULL;
    z_stream decoder = {};
    unsigned char buffer[32768];
    bool active = false, boundary = false, finished = false;
    ~GzipInput() { if (active) inflateEnd(&decoder); }
    bool Open(FileFd *source) {
        if (inflateInit2(&decoder, MAX_WBITS + 16) != Z_OK) return false;
        input = source; active = true; return true;
    }
    bool Read(void *bytes, std::size_t size, unsigned long long *actual) {
        *actual = 0;
        if (finished) return true;
        decoder.next_out = static_cast<Bytef *>(bytes);
        decoder.avail_out = static_cast<uInt>(size);
        while (decoder.avail_out != 0) {
            if (decoder.avail_in == 0) {
                unsigned long long amount(0);
                if (!input->Read(buffer, sizeof(buffer), &amount)) return false;
                if (amount == 0) {
                    if (!boundary) return false; // A header, body or trailer is truncated.
                    finished = true; break;
                }
                decoder.next_in = buffer;
                decoder.avail_in = static_cast<uInt>(amount);
            }
            if (boundary) {
                // Validate every concatenated frame. gzread silently ignores
                // non-gzip bytes after a frame, so it cannot prove member EOF.
                Bytef *nextIn(decoder.next_in), *nextOut(decoder.next_out);
                const uInt in(decoder.avail_in), out(decoder.avail_out);
                if (inflateReset(&decoder) != Z_OK) return false;
                decoder.next_in = nextIn; decoder.avail_in = in;
                decoder.next_out = nextOut; decoder.avail_out = out;
                boundary = false;
            }
            const uInt in(decoder.avail_in), out(decoder.avail_out);
            const int result(inflate(&decoder, Z_NO_FLUSH));
            if (result == Z_STREAM_END) boundary = true;
            else if (result != Z_OK || (in == decoder.avail_in && out == decoder.avail_out)) return false;
        }
        *actual = size - decoder.avail_out;
        return true;
    }
    bool Close() {
        if (!active) return true;
        const int result(inflateEnd(&decoder)); active = false;
        return finished && result == Z_OK;
    }
};
bool ReadDecoded(FileFd &stream, GzipInput &gzip, void *bytes, std::size_t size, unsigned long long *actual) {
    return gzip.active ? gzip.Read(bytes, size, actual) : stream.Read(bytes, size, actual);
}
ArchivePolicyResult Failure(ArchivePolicyStatus status, const std::string &path, const char *reason,
                            bool identityVerified = false) {
    ArchivePolicyResult result; result.status = status; result.path = path; result.reason = reason;
    result.identityVerified = identityVerified; return result;
}
bool Decimal(const char *value, std::size_t length, std::uint64_t *number) {
    *number = 0; std::size_t index(0);
    while (index < length && value[index] == ' ') ++index;
    const std::size_t first(index);
    while (index < length && value[index] >= '0' && value[index] <= '9') {
        const unsigned digit(value[index++] - '0');
        if (*number > (std::numeric_limits<std::uint64_t>::max() - digit) / 10) return false;
        *number = *number * 10 + digit;
    }
    if (index == first) return false;
    while (index < length && value[index] == ' ') ++index;
    return index == length;
}
struct Members { std::string control, data; };
/* Preflight before debDebFile/ARArchive allocates its member list: a .deb
 * needs three ordinary ar members, not an unbounded general-purpose ar. */
bool Container(FileFd &file, const ArchiveLimits &limits, Members *members, ArchivePolicyResult *result) {
    const std::uint64_t total(file.Size());
    if (total > limits.maxStreamBytes) {
        *result = Failure(ArchivePolicyStatus::Unverified, "", "inspection_limit"); return false;
    }
    char magic[8];
    if (!file.Seek(0) || !file.Read(magic, sizeof(magic)) || std::memcmp(magic, "!<arch>\n", 8) != 0) {
        *result = Failure(ArchivePolicyStatus::Invalid, "", "invalid_deb_container"); return false;
    }
    std::uint64_t offset(8); std::size_t count(0); std::set<std::string> seen;
    while (offset < total) {
        if (++count > 32) { *result = Failure(ArchivePolicyStatus::Unverified, "", "inspection_limit"); return false; }
        char header[60]; std::uint64_t size;
        if (total - offset < sizeof(header) || !file.Read(header, sizeof(header)) ||
            std::memcmp(header + 58, "`\n", 2) != 0 || !Decimal(header + 48, 10, &size)) {
            *result = Failure(ArchivePolicyStatus::Invalid, "", "invalid_deb_member"); return false;
        }
        offset += sizeof(header);
        if (size > total - offset || size % 2 > total - offset - size) {
            *result = Failure(ArchivePolicyStatus::Invalid, "", "truncated_deb_member"); return false;
        }
        std::string name(header, 16);
        while (!name.empty() && name.back() == ' ') name.pop_back();
        if (!name.empty() && name.back() == '/') name.pop_back();
        for (unsigned char c : name) if (c < 33 || c > 126) {
            *result = Failure(ArchivePolicyStatus::Invalid, name, "invalid_deb_member_name"); return false;
        }
        if (name.empty() || name.find('/') != std::string::npos || name.find('\0') != std::string::npos) {
            *result = Failure(ArchivePolicyStatus::Unverified, name, "unsupported_ar_name"); return false;
        }
        if (!seen.insert(name).second) {
            *result = Failure(ArchivePolicyStatus::Invalid, name, "duplicate_deb_member"); return false;
        }
        if (count == 1) {
            char version[4];
            if (name != "debian-binary" || size != 4 || !file.Read(version, 4) || std::memcmp(version, "2.0\n", 4) != 0) {
                *result = Failure(ArchivePolicyStatus::Invalid, name, "invalid_deb_version"); return false;
            }
        } else if (name == "control.tar" || name.compare(0, 12, "control.tar.") == 0) {
            if (!members->control.empty() || !members->data.empty()) {
                *result = Failure(ArchivePolicyStatus::Invalid, name, "duplicate_or_misordered_control"); return false;
            }
            members->control = name;
        } else if (name == "data.tar" || name.compare(0, 9, "data.tar.") == 0) {
            if (!members->data.empty() || members->control.empty()) {
                *result = Failure(ArchivePolicyStatus::Invalid, name, "duplicate_or_misordered_data"); return false;
            }
            members->data = name;
        } else if (name[0] != '_') {
            *result = Failure(ArchivePolicyStatus::Unverified, name, "unsupported_deb_member"); return false;
        }
        offset += size + size % 2;
        if (!file.Seek(offset)) { *result = Failure(ArchivePolicyStatus::Invalid, name, "archive_read_failed"); return false; }
    }
    if (members->control.empty() || members->data.empty()) {
        *result = Failure(ArchivePolicyStatus::Invalid, "", "missing_deb_member"); return false;
    }
    return file.Seek(0);
}
bool OpenTar(debDebFile &deb, const std::string &name, FileFd *spool,
             FileFd *stream, GzipInput *gzip, std::uint64_t *remaining) {
    const auto member(deb.GotoMember(name.c_str()));
    if (member == NULL) return false;
    *remaining = std::numeric_limits<std::uint64_t>::max();
    if (name == "control.tar" || name == "data.tar") {
        *remaining = member->Size;
        return stream->OpenDescriptor(deb.GetFile().Fd(), FileFd::ReadOnly, FileFd::None, false);
    }
    const auto compressors(APT::Configuration::getCompressors());
    for (const auto &compressor : compressors) {
        if (!compressor.Extension.empty() && name.size() > compressor.Extension.size() &&
            name.compare(name.size() - compressor.Extension.size(), compressor.Extension.size(), compressor.Extension) == 0) {
            // A decoder attached to the .deb descriptor could consume the
            // following ar members. Give it exactly this compressed member,
            // on an immediately unlinked fd, without extracting any payload.
            if (GetTempFile("cydia-archive-member", true, spool) == NULL) return false;
            std::uint64_t left(member->Size); unsigned char bytes[32768];
            while (left != 0) {
                const std::size_t amount(static_cast<std::size_t>(std::min<std::uint64_t>(left, sizeof(bytes))));
                if (!deb.GetFile().Read(bytes, amount) || !spool->Write(bytes, amount)) return false;
                left -= amount;
            }
            if (!spool->Seek(0)) return false;
            if (compressor.Name == "gzip") {
                return gzip->Open(spool);
            }
            // Some bundled native codecs stop at the first compressed frame
            // without exposing unused input (notably XZ flags=0). Use the
            // configured tool's complete-stream validation, as device APT
            // already does, retaining its selected binary and arguments.
            auto strict(compressor);
            strict.Name = "cydia-archive-" + compressor.Name;
            return stream->OpenDescriptor(spool->Fd(), FileFd::ReadOnly, strict, false);
        }
    }
    return false;
}
}

ArchivePolicyResult InspectPackageArchive(const std::string &path, const ArchiveIdentity &expected,
                                         const ArchiveLayout &layout, const ArchiveLimits &limits) {
    ErrorScope errors;
    const int descriptor(open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (descriptor < 0) return Failure(ArchivePolicyStatus::Invalid, path, "archive_open_failed");
    FileFd file(descriptor, true);
    struct stat before;
    if (fstat(file.Fd(), &before) != 0 || !S_ISREG(before.st_mode))
        return Failure(ArchivePolicyStatus::Invalid, path, "archive_not_regular");
    Members members; ArchivePolicyResult result;
    if (!Container(file, limits, &members, &result)) return result;
    debDebFile deb(file);
    if (_error->PendingError()) return Failure(ArchivePolicyStatus::Invalid, path, "invalid_deb_container");
    PackageArchivePolicy policy(expected, layout, limits);
    std::uint64_t decoded(0);
    for (bool control : {true, false}) {
        const std::string &name(control ? members.control : members.data);
        FileFd spool, stream; GzipInput gzip; std::uint64_t remaining; bool exhausted(false);
        if (!OpenTar(deb, name, &spool, &stream, &gzip, &remaining))
            return Failure(ArchivePolicyStatus::Unverified, name, "archive_decoder_unavailable", !control);
        const ArchiveRead read([&](void *bytes, std::size_t size) {
            if (size > limits.maxStreamBytes || decoded > limits.maxStreamBytes - size) {
                exhausted = true; return false;
            }
            if (size > remaining) return false;
            remaining -= size; decoded += size;
            unsigned long long actual(0);
            return ReadDecoded(stream, gzip, bytes, size, &actual) && actual == size;
        });
        const bool inspected(control ? policy.ReadControlTar(read) : policy.ReadDataTar(read));
        if (!inspected) {
            stream.Close();
            gzip.Close();
            if (exhausted) return Failure(ArchivePolicyStatus::Unverified, name, "inspection_limit", !control);
            return policy.Finish();
        }
        // Read through the compressed trailer and wait for the decoder.
        // Closing after the tar terminator can otherwise kill an external
        // gzip on large zero padding, or miss corrupt/truncated trailers.
        while (remaining != 0) {
            unsigned char bytes[32768]; unsigned long long actual(0);
            const std::uint64_t available(limits.maxStreamBytes - decoded);
            const std::size_t amount(static_cast<std::size_t>(std::min<std::uint64_t>(
                std::min<std::uint64_t>(remaining, sizeof(bytes)), available < sizeof(bytes) ? available + 1 : sizeof(bytes))));
            if (!ReadDecoded(stream, gzip, bytes, amount, &actual))
                return Failure(ArchivePolicyStatus::Invalid, name, "archive_decode_failed", true);
            if (actual == 0) {
                if (remaining != std::numeric_limits<std::uint64_t>::max() && name.find(".tar.") == std::string::npos)
                    return Failure(ArchivePolicyStatus::Invalid, name, "truncated_tar", true);
                break;
            }
            if (actual > available) return Failure(ArchivePolicyStatus::Unverified, name, "inspection_limit", true);
            remaining -= actual; decoded += actual;
            if (!std::all_of(bytes, bytes + actual, [](unsigned char c) { return c == 0; }))
                return Failure(ArchivePolicyStatus::Unverified, name, "trailing_tar_data", true);
        }
        const bool gzipClosed(gzip.Close()), streamClosed(stream.Close());
        if (!gzipClosed || !streamClosed) return Failure(ArchivePolicyStatus::Invalid, name, "archive_decode_failed", true);
    }
    struct stat after;
    if (fstat(file.Fd(), &after) != 0 || before.st_size != after.st_size || before.st_mtime != after.st_mtime ||
        before.st_ctime != after.st_ctime || before.st_ino != after.st_ino || before.st_dev != after.st_dev)
        return Failure(ArchivePolicyStatus::Invalid, path, "archive_changed");
    return policy.Finish();
}
}
