/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ApplicationSession_HPP
#define Cydia_ApplicationSession_HPP
#include "Cydia/PrivilegedRuntime.hpp"
#include <climits>
#include <cstdint>
#include <limits>

namespace CydiaRuntime { namespace Privileged {
struct ApplicationProcessIdentity {
    std::string pid, boot, start, hash;
    bool operator==(const ApplicationProcessIdentity &other) const {
        return pid == other.pid && boot == other.boot && start == other.start && hash == other.hash;
    }
};
struct ApplicationSession {
    ApplicationProcessIdentity process;
    std::string admin;
    // Zero is the active transaction phase. Once the lock is observed released,
    // this changes once to a finite monotonic deadline and cannot be renewed.
    uint64_t graceDeadline = 0;
};
inline bool ApplicationIdentityNumber(const std::string &value, uint64_t maximum, uint64_t *number) {
    if (value.empty() || (value.size() > 1 && value[0] == '0')) return false;
    uint64_t parsed = 0;
    for (char digit : value) {
        if (digit < '0' || digit > '9' || static_cast<uint64_t>(digit - '0') > maximum ||
            parsed > (maximum - (digit - '0')) / 10) return false;
        parsed = parsed * 10 + digit - '0';
    }
    if (number) *number = parsed;
    return true;
}
inline bool ApplicationIdentityTime(const std::string &value) {
    const auto separator = value.find('.');
    uint64_t seconds = 0;
    return separator != std::string::npos &&
        ApplicationIdentityNumber(value.substr(0, separator), INT64_MAX, &seconds) && seconds > 0 &&
        ApplicationIdentityNumber(value.substr(separator + 1), 999999, nullptr);
}
inline bool ValidApplicationProcessIdentity(const ApplicationProcessIdentity &process) {
    uint64_t pid = 0;
    if (!ApplicationIdentityNumber(process.pid, INT_MAX, &pid) || pid <= 1 ||
        !ApplicationIdentityTime(process.boot) || !ApplicationIdentityTime(process.start) ||
        process.hash.empty() || process.hash.size() > 6 * 40 || process.hash.size() % 40 != 0 ||
        process.hash.find_first_not_of("0123456789abcdef") != std::string::npos) return false;
    // The kernel reader stores a sorted set of truncated SHA256 directories.
    // One primary directory and up to five alternate slots are supported.
    for (std::size_t offset = 40; offset < process.hash.size(); offset += 40)
        if (process.hash.compare(offset - 40, 40, process.hash, offset, 40) >= 0) return false;
    return true;
}
inline std::string SerializeApplicationSession(const ApplicationSession &session) {
    return SerializeFields({session.process.pid, session.process.boot, session.process.start,
        session.process.hash, session.admin, std::to_string(session.graceDeadline)});
}
inline bool ParseApplicationSession(const std::string &bytes, ApplicationSession *session) {
    if (!session || bytes.size() > 8192) return false;
    std::vector<std::string> fields; Error error;
    if (!ParseFields(bytes, 6, &fields, &error) || fields[4].empty() || fields[4][0] != '/' ||
        fields[4].find('\0') != std::string::npos || fields[5].empty()) return false;
    const ApplicationProcessIdentity process{fields[0], fields[1], fields[2], fields[3]};
    if (!ValidApplicationProcessIdentity(process)) return false;
    uint64_t deadline = 0;
    for (char digit : fields[5]) {
        if (digit < '0' || digit > '9' || deadline > (std::numeric_limits<uint64_t>::max() - (digit - '0')) / 10) return false;
        deadline = deadline * 10 + digit - '0';
    }
    session->process = process;
    session->admin = fields[4]; session->graceDeadline = deadline; return true;
}
inline bool ApplicationSessionAllows(const ApplicationSession &session, const ApplicationProcessIdentity &process,
                                    uint64_t now, bool parentOwnsLock) {
    return ValidApplicationProcessIdentity(process) && session.process == process && now != 0 &&
        (session.graceDeadline == 0 ? parentOwnsLock : now < session.graceDeadline);
}
} }
#endif
