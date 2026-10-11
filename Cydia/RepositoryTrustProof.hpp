/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RepositoryTrustProof_HPP
#define Cydia_RepositoryTrustProof_HPP
#include <string>
namespace CydiaRuntime {
/* A process-local record of an actual successful refresh. Persisting this
 * beside mobile-writable indexes would let a replaced cache forge its proof. */
class RepositoryTrustProof {
    std::string context_, indexes_;
    static bool Digest(const std::string &value) {
        if (value.size() != 64) return false;
        for (char c : value)
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        return true;
    }
public:
    bool RecordCompletedRefresh(const std::string &beforeContext,
        const std::string &afterContext, const std::string &indexes, bool complete) {
        if (!complete || !Digest(beforeContext) || beforeContext != afterContext || !Digest(indexes)) return false;
        context_ = afterContext; indexes_ = indexes; return true;
    }
    bool Matches(const std::string &context, const std::string &indexes) const {
        return Digest(context) && Digest(indexes) && context == context_ && indexes == indexes_;
    }
};
}
#endif
