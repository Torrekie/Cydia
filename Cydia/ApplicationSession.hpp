/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ApplicationSession_HPP
#define Cydia_ApplicationSession_HPP
#include "Cydia/PrivilegedRuntime.hpp"
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
inline std::string SerializeApplicationSession(const ApplicationSession &session) {
    return SerializeFields({session.process.pid, session.process.boot, session.process.start,
        session.process.hash, session.admin, std::to_string(session.graceDeadline)});
}
inline bool ParseApplicationSession(const std::string &bytes, ApplicationSession *session) {
    if (bytes.size() > 8192) return false;
    std::vector<std::string> fields; Error error;
    if (!ParseFields(bytes, 6, &fields, &error) || fields[0].empty() || fields[1].empty() ||
        fields[2].empty() || fields[3].size() != 40 || fields[4].empty() || fields[4][0] != '/' || fields[5].empty()) return false;
    uint64_t deadline = 0;
    for (char digit : fields[5]) {
        if (digit < '0' || digit > '9' || deadline > (std::numeric_limits<uint64_t>::max() - (digit - '0')) / 10) return false;
        deadline = deadline * 10 + digit - '0';
    }
    session->process = {fields[0], fields[1], fields[2], fields[3]};
    session->admin = fields[4]; session->graceDeadline = deadline; return true;
}
inline bool ApplicationSessionAllows(const ApplicationSession &session, const ApplicationProcessIdentity &process,
                                    uint64_t now, bool parentOwnsLock) {
    return session.process == process && now != 0 &&
        (session.graceDeadline == 0 ? parentOwnsLock : now < session.graceDeadline);
}
} }
#endif
