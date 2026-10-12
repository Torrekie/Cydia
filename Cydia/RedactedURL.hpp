/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RedactedURL_HPP
#define Cydia_RedactedURL_HPP
#include <string>
#include <cctype>
namespace CydiaRuntime {
/* Diagnostics are not transport. A signed URL may put a secret in its path,
 * query, fragment or userinfo, so retaining only its origin is intentional. */
inline std::string RedactDiagnosticURLs(const std::string &text) {
    std::string result; size_t cursor = 0;
    while (cursor < text.size()) {
        size_t begin = text.find("://", cursor);
        if (begin == std::string::npos) { result.append(text, cursor, std::string::npos); break; }
        size_t scheme = begin;
        while (scheme > cursor && (std::isalnum(static_cast<unsigned char>(text[scheme - 1])) ||
            text[scheme - 1] == '+' || text[scheme - 1] == '-' || text[scheme - 1] == '.')) --scheme;
        if (scheme == begin) { result.append(text, cursor, begin + 3 - cursor); cursor = begin + 3; continue; }
        size_t end = text.find_first_of(" \t\r\n<>\"'", begin + 3);
        if (end == std::string::npos) end = text.size();
        size_t authorityEnd = text.find_first_of("/?#", begin + 3);
        if (authorityEnd == std::string::npos || authorityEnd > end) authorityEnd = end;
        size_t user = text.rfind('@', authorityEnd == 0 ? 0 : authorityEnd - 1);
        size_t authority = user != std::string::npos && user >= begin + 3 ? user + 1 : begin + 3;
        result.append(text, cursor, begin + 3 - cursor);
        result.append(text, authority, authorityEnd - authority);
        if (authorityEnd < end) result += "/[redacted]";
        cursor = end;
    }
    return result;
}
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
static inline NSString *CydiaRedactedDiagnostic(NSString *value) {
    if (!value) return nil;
    const char *UTF8 = value.UTF8String;
    return UTF8 ? [NSString stringWithUTF8String:CydiaRuntime::RedactDiagnosticURLs(UTF8).c_str()] : value;
}
#endif
#endif
