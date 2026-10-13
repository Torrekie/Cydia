/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PackageArchiveReader.hpp"
#include <apt-pkg/aptconfiguration.h>
#include <apt-pkg/debfile.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <set>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

namespace CydiaPackages {
namespace {
struct ErrorScope {
    ErrorScope() { _error->PushToStack(); }
    ~ErrorScope() { _error->RevertToStack(); }
};
// One bounded, shell-free reader for protected index and archive decoders.
// The input is an already retained regular descriptor; it is never reopened by
// a worker-provided name. Failure owns cancellation and reaps this child only.
class DecoderInput {
    using Clock = std::chrono::steady_clock;
    int output_ = -1;
    pid_t child_ = -1;
    bool eof_ = false, failed_ = false, exhausted_ = false;
    std::uint64_t maximum_ = 0, total_ = 0;
    Clock::time_point deadline_;
    std::function<bool()> cancelled_;
    bool Fail() { failed_ = true; Abort(); return false; }
    bool Active() {
        try { if (failed_ || Clock::now() >= deadline_ || (cancelled_ && cancelled_())) return Fail(); }
        catch (...) { return Fail(); }
        return true;
    }
    static int Owned(int fd) {
        if (fd < 0) return -1;
        const int copy = fcntl(fd, F_DUPFD_CLOEXEC, 3); close(fd); return copy;
    }
public:
    ~DecoderInput() { Abort(); }
    bool exhausted() const { return exhausted_; }
    bool active() const { return output_ >= 0 || child_ > 0 || eof_; }
    void Abort() {
        if (output_ >= 0) { close(output_); output_ = -1; }
        if (child_ > 0) {
            const pid_t owned = child_; child_ = -1;
            siginfo_t state{}; int observed;
            do { observed = waitid(P_PID, static_cast<id_t>(owned), &state, WEXITED | WNOHANG | WNOWAIT); }
            while (observed < 0 && errno == EINTR);
            // Never signal an identity already consumed by another reaper.
            if (observed != 0) return;
            (void) kill(-owned, SIGKILL); (void) kill(owned, SIGKILL);
            int status; while (waitpid(owned, &status, 0) < 0 && errno == EINTR) {}
        }
    }
    bool Open(int input, const std::string &executable, const std::vector<std::string> &arguments,
        std::uint64_t maximum, unsigned timeout, const std::function<bool()> &cancelled) {
        if (active() || input < 0 || executable.empty() || executable.front() != '/' || executable.size() > 4096 ||
            executable.find('\0') != std::string::npos || arguments.size() > 16 || !maximum || !timeout || timeout > 300000)
            return false;
        std::size_t bytes = 0;
        for (const auto &argument : arguments) {
            if (argument.size() > 4096 || argument.find('\0') != std::string::npos || argument.size() > 16384 - bytes) return false;
            bytes += argument.size();
        }
        struct stat identity;
        const int flags = fcntl(input, F_GETFL);
        if (flags < 0 || (flags & O_ACCMODE) == O_WRONLY || fstat(input, &identity) != 0 || !S_ISREG(identity.st_mode)) return false;
        maximum_ = maximum; deadline_ = Clock::now() + std::chrono::milliseconds(timeout); cancelled_ = cancelled;
        if (!Active()) return false;
        // Finish all potentially allocating argument preparation before owning
        // raw descriptors or initialized spawn objects.
        std::vector<std::string> storage{executable}; storage.insert(storage.end(), arguments.begin(), arguments.end());
        std::vector<char *> argv; argv.reserve(storage.size() + 1);
        for (auto &argument : storage) argv.push_back(const_cast<char *>(argument.c_str()));
        argv.push_back(nullptr);
        int pipefd[2]; if (pipe(pipefd) != 0) return false;
        const int readfd = Owned(pipefd[0]), writefd = Owned(pipefd[1]);
        const int source = fcntl(input, F_DUPFD_CLOEXEC, 3);
        if (readfd < 0 || writefd < 0 || source < 0) {
            if (readfd >= 0) close(readfd);
            if (writefd >= 0) close(writefd);
            if (source >= 0) close(source);
            return false;
        }
        posix_spawn_file_actions_t actions; posix_spawnattr_t attributes;
        const bool actionsReady = posix_spawn_file_actions_init(&actions) == 0;
        const bool attributesReady = posix_spawnattr_init(&attributes) == 0;
        int result = !actionsReady || !attributesReady ? EINVAL : 0;
        if (!result) result = posix_spawn_file_actions_adddup2(&actions, source, STDIN_FILENO);
        if (!result) result = posix_spawn_file_actions_adddup2(&actions, writefd, STDOUT_FILENO);
        if (!result) result = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        for (const int fd : {readfd, writefd, source}) if (!result) result = posix_spawn_file_actions_addclose(&actions, fd);
        // The caller retains its descriptor; the child gets only the stdin
        // duplicate even if the caller's original was not close-on-exec.
        if (!result && input > STDERR_FILENO) result = posix_spawn_file_actions_addclose(&actions, input);
        sigset_t empty, defaults; sigemptyset(&empty); sigemptyset(&defaults); sigaddset(&defaults, SIGPIPE);
        if (!result) result = posix_spawnattr_setsigmask(&attributes, &empty);
        if (!result) result = posix_spawnattr_setsigdefault(&attributes, &defaults);
        if (!result) result = posix_spawnattr_setpgroup(&attributes, 0);
        short spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
        spawnFlags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
        if (!result) result = posix_spawnattr_setflags(&attributes, spawnFlags);
        // Decoder behavior is independent of ambient XZ_DEFAULTS/GZIP and
        // loader overrides; the caller supplies an absolute verified tool.
        char language[] = "LANG=C", locale[] = "LC_ALL=C"; char *environment[] = {language, locale, nullptr};
        if (!result) result = posix_spawn(&child_, executable.c_str(), &actions, &attributes, argv.data(), environment);
        if (actionsReady) posix_spawn_file_actions_destroy(&actions);
        if (attributesReady) posix_spawnattr_destroy(&attributes);
        close(writefd); close(source);
        if (result) { close(readfd); child_ = -1; return false; }
        output_ = readfd;
        const int options = fcntl(output_, F_GETFL);
        if (options < 0 || fcntl(output_, F_SETFL, options | O_NONBLOCK) != 0) return Fail();
        return Active();
    }
    bool Read(void *bytes, std::size_t size, unsigned long long *actual) {
        *actual = 0;
        if (failed_ || (!active() && !eof_)) return false;
        while (*actual < size && !eof_) {
            if (!Active()) return false;
            const auto count = read(output_, static_cast<unsigned char *>(bytes) + *actual, size - *actual);
            if (count > 0) {
                if (static_cast<std::uint64_t>(count) > maximum_ - total_) { exhausted_ = true; return Fail(); }
                total_ += count; *actual += count; continue;
            }
            if (count == 0) { eof_ = true; close(output_); output_ = -1; break; }
            if (errno == EINTR) continue;
            if (errno != EAGAIN && errno != EWOULDBLOCK) return Fail();
            pollfd poller{output_, POLLIN, 0};
            const int ready = poll(&poller, 1, 25);
            if (ready < 0 && errno != EINTR) return Fail();
            if (ready > 0 && (poller.revents & POLLNVAL)) return Fail();
        }
        return true;
    }
    bool Close() {
        if (failed_ || !eof_) return Fail();
        while (child_ > 0) {
            if (!Active()) return false;
            siginfo_t exited{};
            const int ready = waitid(P_PID, static_cast<id_t>(child_), &exited, WEXITED | WNOHANG | WNOWAIT);
            if (ready == 0 && exited.si_pid == child_) {
                // Keep the exited leader unreaped while cancelling its group:
                // its retained PID prevents signaling a reused process group.
                // A decoder descendant may have closed stdout before the
                // successful leader exited, so EOF alone is not settlement.
                if (kill(-child_, SIGKILL) != 0 && errno != ESRCH) return Fail();
                const pid_t owned = child_; child_ = -1;
                int status = 0; pid_t reaped;
                do { reaped = waitpid(owned, &status, 0); } while (reaped < 0 && errno == EINTR);
                failed_ = reaped != owned || !WIFEXITED(status) || WEXITSTATUS(status) != 0; return !failed_;
            }
            if (ready < 0 && errno != EINTR) {
                // Another reaper would break the ownership contract. Do not
                // signal a PID/group whose unreaped identity is no longer ours.
                if (errno == ECHILD) child_ = -1;
                return Fail();
            }
            (void) poll(nullptr, 0, 25);
        }
        return true;
    }
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
bool ReadDecoded(FileFd &stream, GzipInput &gzip, DecoderInput &decoder, void *bytes, std::size_t size, unsigned long long *actual) {
    return gzip.active ? gzip.Read(bytes, size, actual) : decoder.active() ? decoder.Read(bytes, size, actual) : stream.Read(bytes, size, actual);
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
bool SamePayloadArchive(const struct stat &a, const struct stat &b) {
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
             FileFd *stream, GzipInput *gzip, DecoderInput *decoder, std::uint64_t *remaining, std::uint64_t maximum,
             const std::map<std::string, std::string> *decoders,
             const std::function<bool()> &cancelled) {
    const auto member(deb.GotoMember(name.c_str()));
    if (member == NULL) return false;
    *remaining = std::numeric_limits<std::uint64_t>::max();
    if (name == "control.tar" || name == "data.tar") {
        *remaining = member->Size;
        return stream->OpenDescriptor(deb.GetFile().Fd(), FileFd::ReadOnly, FileFd::None, false);
    }
    std::vector<APT::Configuration::Compressor> compressors;
    if (decoders == nullptr) compressors = APT::Configuration::getCompressors();
    else {
        for (const auto &format : std::vector<std::pair<std::string, std::string>>{
                {"gzip", ".gz"}, {"bzip2", ".bz2"}, {"xz", ".xz"},
                {"lzma", ".lzma"}, {"lz4", ".lz4"}, {"zstd", ".zst"}}) {
            const auto binary(decoders->find(format.first));
            if (format.first != "gzip" && binary == decoders->end()) continue;
            APT::Configuration::Compressor compressor;
            compressor.Name = format.first; compressor.Extension = format.second;
            compressor.Binary = binary == decoders->end() ? "" : binary->second;
            compressor.UncompressArgs = {"-d", "-c"};
            if (format.first == "lzma") compressor.UncompressArgs.push_back("--format=lzma");
            compressors.push_back(compressor);
        }
    }
    for (const auto &compressor : compressors) {
        if (!compressor.Extension.empty() && name.size() > compressor.Extension.size() &&
            name.compare(name.size() - compressor.Extension.size(), compressor.Extension.size(), compressor.Extension) == 0) {
            // A decoder attached to the .deb descriptor could consume the
            // following ar members. Give it exactly this compressed member,
            // on an immediately unlinked fd, without extracting any payload.
            if (GetTempFile("cydia-archive-member", true, spool) == NULL) return false;
            std::uint64_t left(member->Size); unsigned char bytes[32768];
            while (left != 0) {
                if (cancelled && cancelled()) return false;
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
            if (decoders != nullptr)
                return decoder->Open(spool->Fd(), compressor.Binary, compressor.UncompressArgs, maximum, 30000, cancelled);
            auto strict(compressor);
            strict.Name = "cydia-archive-" + compressor.Name;
            return stream->OpenDescriptor(spool->Fd(), FileFd::ReadOnly, strict, false);
        }
    }
    return false;
}
}

bool StreamArchiveDecoder(int descriptor, const std::string &executable, const std::vector<std::string> &arguments,
    std::uint64_t maximum, unsigned timeout, const ArchiveDecodedConsumer &consume, const std::function<bool()> &cancelled) {
    if (!consume) return false;
    DecoderInput decoder;
    try {
        if (!decoder.Open(descriptor, executable, arguments, maximum, timeout, cancelled)) return false;
        for (;;) {
            unsigned char bytes[65536]; unsigned long long actual = 0;
            if (!decoder.Read(bytes, sizeof(bytes), &actual)) return false;
            if (!actual) break;
            if (!consume(bytes, static_cast<std::size_t>(actual))) return false;
        }
        return decoder.Close();
    } catch (...) { return false; }
}

static ArchivePolicyResult InspectPackageArchiveImpl(const std::string &path, const ArchiveIdentity &expected,
    const ArchiveLayout &layout, const ArchiveLimits &limits, const std::map<std::string, std::string> *decoders,
    const std::function<bool()> &cancelled, const std::vector<std::string> *payloadPaths = nullptr,
    ArchivePayloadEvidence *payloadEvidence = nullptr, ArchiveControlMetadata *controlMetadata = nullptr,
    ArchiveDataInventory *dataInventory = nullptr) {
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
    std::map<std::string, ArchivePayloadFileEvidence> payloadFiles;
    const ArchivePayloadConsumer consume([&](const ArchivePayloadFileMetadata &metadata, const ArchiveRead &read) {
        Hashes hashes(Hashes::SHA256SUM); std::uint64_t remaining(metadata.size);
        unsigned char bytes[32768];
        while (remaining != 0) {
            const std::size_t amount(static_cast<std::size_t>(std::min<std::uint64_t>(remaining, sizeof(bytes))));
            if (!read(bytes, amount) || !hashes.Add(bytes, amount)) return false;
            remaining -= amount;
        }
        ArchivePayloadFileEvidence file; file.metadata = metadata;
        file.sha256 = hashes.GetHashString(Hashes::SHA256SUM).HashValue();
        if (file.sha256.size() != 64) return false;
        return payloadFiles.emplace(metadata.path, file).second;
    });
    std::uint64_t decoded(0);
    for (bool control : {true, false}) {
        const std::string &name(control ? members.control : members.data);
        FileFd spool, stream; GzipInput gzip; DecoderInput decoder; std::uint64_t remaining; bool exhausted(false);
        if (cancelled && cancelled()) return Failure(ArchivePolicyStatus::Unverified, name, "inspection_cancelled");
        if (!OpenTar(deb, name, &spool, &stream, &gzip, &decoder, &remaining, limits.maxStreamBytes - decoded, decoders, cancelled))
            return Failure(ArchivePolicyStatus::Unverified, name, "archive_decoder_unavailable", !control);
        const ArchiveRead read([&](void *bytes, std::size_t size) {
            if (cancelled && cancelled()) return false;
            if (size > limits.maxStreamBytes || decoded > limits.maxStreamBytes - size) {
                exhausted = true; return false;
            }
            if (size > remaining) return false;
            remaining -= size; decoded += size;
            unsigned long long actual(0);
            if (!ReadDecoded(stream, gzip, decoder, bytes, size, &actual)) {
                exhausted = decoder.exhausted(); return false;
            }
            return actual == size;
        });
        const bool inspected(control ? policy.ReadControlTar(read) : payloadPaths != nullptr ?
            policy.ReadDataTar(read, *payloadPaths, consume) : dataInventory != nullptr ?
            policy.ReadDataTarWithInventory(read) : policy.ReadDataTar(read));
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
            if (cancelled && cancelled()) return Failure(ArchivePolicyStatus::Unverified, name, "inspection_cancelled");
            unsigned char bytes[32768]; unsigned long long actual(0);
            const std::uint64_t available(limits.maxStreamBytes - decoded);
            const std::size_t amount(static_cast<std::size_t>(std::min<std::uint64_t>(
                std::min<std::uint64_t>(remaining, sizeof(bytes)), available < sizeof(bytes) ? available + 1 : sizeof(bytes))));
            if (!ReadDecoded(stream, gzip, decoder, bytes, amount, &actual))
                return decoder.exhausted() ? Failure(ArchivePolicyStatus::Unverified, name, "inspection_limit", true) :
                    Failure(ArchivePolicyStatus::Invalid, name, "archive_decode_failed", true);
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
        const bool gzipClosed(gzip.Close()), streamClosed(stream.Close()), decoderClosed(!decoder.active() || decoder.Close());
        if (!gzipClosed || !streamClosed || !decoderClosed) return Failure(ArchivePolicyStatus::Invalid, name, "archive_decode_failed", true);
    }
    struct stat after;
    if (fstat(file.Fd(), &after) != 0 || before.st_size != after.st_size || before.st_mtime != after.st_mtime ||
        before.st_ctime != after.st_ctime || before.st_ino != after.st_ino || before.st_dev != after.st_dev)
        return Failure(ArchivePolicyStatus::Invalid, path, "archive_changed");
    if (payloadEvidence != nullptr || controlMetadata != nullptr || dataInventory != nullptr) {
        struct stat named;
        if (!SamePayloadArchive(before, after) || lstat(path.c_str(), &named) != 0 || !SamePayloadArchive(after, named))
            return Failure(ArchivePolicyStatus::Invalid, path, "archive_changed");
    }
    const ArchivePolicyResult finished(policy.Finish());
    if (controlMetadata != nullptr && finished.complete && finished.identityVerified)
        *controlMetadata = policy.ControlMetadata();
    if (dataInventory != nullptr && finished.complete && finished.identityVerified)
        *dataInventory = policy.DataInventory();
    if (payloadEvidence != nullptr && finished.complete && finished.identityVerified) {
        payloadEvidence->payload = policy.PayloadInspection();
        if (payloadEvidence->payload.complete) payloadEvidence->files.swap(payloadFiles);
    }
    return finished;
}

ArchivePolicyResult InspectPackageArchive(const std::string &path, const ArchiveIdentity &expected,
    const ArchiveLayout &layout, const ArchiveLimits &limits) {
    return InspectPackageArchiveImpl(path, expected, layout, limits, nullptr, std::function<bool()>());
}

ArchivePolicyResult InspectPackageArchiveWithDecoders(const std::string &path, const ArchiveIdentity &expected,
    const ArchiveLayout &layout, const std::map<std::string, std::string> &decoders,
    const ArchiveLimits &limits, const std::function<bool()> &cancelled) {
    return InspectPackageArchiveImpl(path, expected, layout, limits, &decoders, cancelled);
}

ArchiveControlEvidence InspectPackageArchiveControlWithDecoders(const std::string &path,
    const ArchiveIdentity &expected, const ArchiveLayout &layout,
    const std::map<std::string, std::string> &decoders, const ArchiveLimits &limits,
    const std::function<bool()> &cancelled) {
    ArchiveControlEvidence result;
    result.archive = InspectPackageArchiveImpl(path, expected, layout, limits, &decoders, cancelled, nullptr, nullptr, &result.control);
    if (!result.control.complete && result.control.reason.empty())
        result.control.reason = result.archive.reason.empty() ? "control_metadata_incomplete" : result.archive.reason;
    return result;
}

ArchiveDataInventoryEvidence InspectPackageArchiveDataInventoryWithDecoders(const std::string &path,
    const ArchiveIdentity &expected, const ArchiveLayout &layout,
    const std::map<std::string, std::string> &decoders, const ArchiveLimits &limits,
    const std::function<bool()> &cancelled) {
    ArchiveDataInventoryEvidence result;
    result.archive = InspectPackageArchiveImpl(path, expected, layout, limits, &decoders, cancelled,
        nullptr, nullptr, nullptr, &result.inventory);
    if (!result.inventory.complete && result.inventory.reason.empty()) {
        result.inventory.path = result.archive.path;
        result.inventory.reason = result.archive.reason.empty() ? "data_inventory_incomplete" : result.archive.reason;
    }
    return result;
}

ArchivePayloadEvidence InspectPackageArchivePayloadWithDecoders(const std::string &path,
    const ArchiveIdentity &expected, const ArchiveLayout &layout,
    const std::vector<std::string> &paths, const std::map<std::string, std::string> &decoders,
    const ArchiveLimits &limits, const std::function<bool()> &cancelled) {
    ArchivePayloadEvidence result;
    result.archive = InspectPackageArchiveImpl(path, expected, layout, limits, &decoders, cancelled, &paths, &result);
    if (!result.payload.complete && result.payload.reason.empty()) {
        result.payload.path = result.archive.path;
        result.payload.reason = result.archive.reason.empty() ? "payload_inspection_incomplete" : result.archive.reason;
    }
    return result;
}

}
