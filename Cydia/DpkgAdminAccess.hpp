/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_DpkgAdminAccess_HPP
#define Cydia_DpkgAdminAccess_HPP
#include <cstdlib>
#include <cerrno>
#include <functional>
#include <map>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/acl.h>
#endif

namespace CydiaRuntime { namespace AdminAccess {
struct Review {
    std::string selectedPath, admin, token, descriptions;
    std::map<std::string, struct stat> ancestors;
};
inline std::string Canonical(const std::string &path) {
    char *value(realpath(path.c_str(), NULL));
    if (value == NULL) return {};
    const std::string result(value); free(value); return result;
}
inline bool Identity(const struct stat &a, const struct stat &b) {
    // Directory timestamps change on normal lock/journal updates. Enrollment
    // instead binds the namespace, owner, group and complete permission mode.
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid &&
        a.st_gid == b.st_gid && a.st_mode == b.st_mode;
}
inline void Field(std::string *bytes, const std::string &value) {
    *bytes += std::to_string(value.size()) + ':' + value + ',';
}
inline std::string IdentityText(const struct stat &st) {
    std::ostringstream out;
    out << st.st_dev << ' ' << st.st_ino << ' ' << st.st_uid << ' ' << st.st_gid << ' ' << st.st_mode;
    return out.str();
}
inline bool PermissionText(const std::string &path, const struct stat &st, std::string *text) {
    *text = IdentityText(st);
#ifdef __APPLE__
    acl_t acl(acl_get_link_np(path.c_str(), ACL_TYPE_EXTENDED));
    if (acl == NULL) {
        const int error(errno); struct stat current;
        // Darwin reports ENOENT for an existing object with no extended ACL.
        // Bind that absence only after confirming the same object still exists.
        if ((error != ENOENT && error != EOPNOTSUPP) || lstat(path.c_str(), &current) != 0 || !Identity(st, current)) return false;
        *text += error == ENOENT ? "\nno-acl" : "\nacl-unsupported"; return true;
    }
    // Permission-granting ACL entries may name principals absent from the
    // displayed POSIX group. Never enroll those implicit extra writers. Deny
    // entries only restrict access and are retained in the exact review token.
    if (acl_valid(acl) != 0) { acl_free(acl); return false; }
    acl_entry_t entry;
    for (unsigned index = 0; index != 128; ++index) {
        if (acl_get_entry(acl, index == 0 ? ACL_FIRST_ENTRY : ACL_NEXT_ENTRY, &entry) != 0) {
            if (errno != EINVAL) { acl_free(acl); return false; }
            break;
        }
        acl_tag_t tag;
        if (acl_get_tag_type(entry, &tag) != 0 || tag != ACL_EXTENDED_DENY || index == 127) {
            acl_free(acl); return false;
        }
    }
    ssize_t size(0); char *bytes(acl_to_text(acl, &size));
    acl_free(acl);
    if (bytes == NULL || size < 0 || size > 16384) { if (bytes != NULL) acl_free(bytes); return false; }
    text->append("\n", 1); text->append(bytes, size); acl_free(bytes);
#else
    (void)path;
#endif
    return true;
}
inline bool Collect(const std::string &path, Review *review) {
    if (review == NULL || path.empty() || path[0] != '/' || path.size() > 4096 ||
        path.find_first_of("\n\r") != std::string::npos || path.find('\0') != std::string::npos) return false;
    *review = Review(); review->selectedPath = path; review->admin = Canonical(path);
    if (review->admin.empty()) return false;
    std::map<std::string, struct stat> entries;
    // Bind aliases as well as the canonical namespace. Replacing an alias or
    // an ancestor invalidates approval even if the final directory is reused.
    std::function<bool(const std::string &, bool, unsigned)> chain;
    chain = [&](const std::string &raw, bool final, unsigned depth) {
        if (depth > 40 || raw.empty() || raw[0] != '/' || raw.size() > 4096) return false;
        std::string value(raw);
        while (value.size() > 1 && value.back() == '/') value.pop_back();
        for (std::size_t index = 1; index <= value.size(); ++index) {
            if (index != value.size() && value[index] != '/') continue;
            const std::string part(value.substr(0, index)); struct stat st;
            if (lstat(part.c_str(), &st) != 0 || st.st_uid != 0) return false;
            if (S_ISLNK(st.st_mode)) {
                char target[4097];
                const ssize_t count(readlink(part.c_str(), target, sizeof(target) - 1));
                if (count <= 0 || count == static_cast<ssize_t>(sizeof(target) - 1)) return false;
                const std::string alias(target, count);
                const auto slash(part.find_last_of('/'));
                if (!chain(alias[0] == '/' ? alias : part.substr(0, slash + 1) + alias,
                           final && index == value.size(), depth + 1)) return false;
            } else if (!S_ISDIR(st.st_mode) || (st.st_mode & (S_IWOTH | S_ISUID | S_ISGID | S_ISVTX)) != 0 ||
                       (final && index == value.size() && (st.st_mode & S_IWGRP) != 0)) return false;
            entries[part] = st;
        }
        return true;
    };
    if (!chain(path, true, 0) || !chain(review->admin, true, 0)) return false;
    review->token = "CYDIA-ADMIN-ACCESS-1\n"; Field(&review->token, review->admin);
    for (const auto &entry : entries) {
        std::string permissions;
        if (!PermissionText(entry.first, entry.second, &permissions)) return false;
        Field(&review->token, entry.first); Field(&review->token, permissions);
        if (S_ISDIR(entry.second.st_mode) && (entry.second.st_mode & S_IWGRP) != 0) {
            const std::string canonical(Canonical(entry.first));
            if (canonical.empty() || canonical == review->admin ||
                review->admin.compare(0, canonical.size() + 1, canonical + '/') != 0) return false;
            review->ancestors[canonical] = entry.second;
        }
    }
    if (review->token.size() > 32768 || review->ancestors.size() > 64) return false;
    for (const auto &entry : review->ancestors) {
        std::ostringstream line;
        line << entry.first << " [gid=" << entry.second.st_gid << ", mode=0" << std::oct
             << (entry.second.st_mode & 07777) << "]\n";
        review->descriptions += line.str();
    }
    return true;
}
inline std::string &EnrolledToken() { static std::string token; return token; }
inline Review &Active() { static Review review; return review; }
inline void Reset(const std::string &token = {}) { EnrolledToken() = token; Active() = Review(); }
inline const char *InstalledHeader() { return "CYDIA-INSTALLED-ADMIN-ACCESS-1\n"; }
inline std::string InstalledToken(const Review &review) {
    std::string bytes(InstalledHeader());
    Field(&bytes, review.selectedPath); Field(&bytes, review.token);
    return bytes.size() <= 32768 ? bytes : std::string();
}
inline bool InstalledField(const std::string &bytes, std::size_t *offset, std::string *value) {
    const std::size_t start(*offset), colon(bytes.find(':', start));
    if (colon == std::string::npos || colon == start || colon - start > 5 ||
        (bytes[start] == '0' && colon - start != 1)) return false;
    std::size_t length(0);
    for (std::size_t index = start; index < colon; ++index) {
        if (bytes[index] < '0' || bytes[index] > '9') return false;
        length = length * 10 + bytes[index] - '0';
        if (length > 32768) return false;
    }
    if (length >= bytes.size() - colon - 1) return false;
    const std::size_t end(colon + 1 + length);
    if (bytes[end] != ',') return false;
    value->assign(bytes, colon + 1, length); *offset = end + 1; return true;
}
inline bool MatchesEnrollment(const Review &review) {
    if (review.token.empty() || review.admin.empty()) return false;
    if (review.token == EnrolledToken()) return true;
    const std::string &policy(EnrolledToken());
    const std::size_t header(std::char_traits<char>::length(InstalledHeader()));
    if (policy.size() > 32768 || policy.compare(0, header, InstalledHeader()) != 0) return false;
    std::size_t offset(header); std::string selected, token;
    if (!InstalledField(policy, &offset, &selected) || !InstalledField(policy, &offset, &token) ||
        offset != policy.size()) return false;
    Review installed;
    // Installation authorizes the exact root installer-selected namespace.
    // APT may use a different root-owned alias for that same database; its
    // fresh namespace cannot introduce another writable ancestor or database.
    if (!Collect(selected, &installed) || installed.token != token || installed.admin != review.admin) return false;
    for (const auto &entry : review.ancestors) {
        const auto approved(installed.ancestors.find(entry.first));
        if (approved == installed.ancestors.end() || !Identity(approved->second, entry.second)) return false;
    }
    return true;
}
inline bool Activate(const std::string &admin) {
    Review review;
    Active() = Review();
    if (!Collect(admin, &review) || review.ancestors.empty() || !MatchesEnrollment(review)) return false;
    Active() = review; return true;
}
inline bool Matches(const std::string &path) {
    if (Active().admin.empty()) return false;
    Review now;
    if (!Collect(Active().selectedPath, &now) || now.token != Active().token || !MatchesEnrollment(now)) return false;
    const std::string canonical(Canonical(path));
    return canonical == Active().admin || canonical.compare(0, Active().admin.size() + 1, Active().admin + '/') == 0;
}
inline bool Ancestor(const std::string &path, const struct stat &st) {
    const auto found(Active().ancestors.find(Canonical(path)));
    return found != Active().ancestors.end() && Identity(found->second, st);
}
} }
#endif
