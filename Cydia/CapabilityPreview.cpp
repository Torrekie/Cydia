/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/CapabilityPreview.hpp"
#include <set>

namespace CydiaRuntime {
namespace {
bool Decode(const std::string &input, std::string *output) {
    output->clear();
    for (std::size_t index = 0; index != input.size(); ++index) {
        if (input[index] != '%') { output->push_back(input[index]); continue; }
        if (index + 2 >= input.size()) return false;
        const std::string escape = input.substr(index + 1, 2);
        if (escape == "25") output->push_back('%');
        else if (escape == "09") output->push_back('\t');
        else if (escape == "0D") output->push_back('\r');
        else if (escape == "0A") output->push_back('\n');
        else return false;
        index += 2;
    }
    return true;
}

bool Split(const std::string &line, std::vector<std::string> *fields) {
    fields->clear();
    std::size_t start = 0;
    for (;;) {
        const std::size_t end = line.find('\t', start);
        std::string value;
        if (!Decode(line.substr(start, end == std::string::npos ? end : end - start), &value)) return false;
        fields->push_back(value);
        if (end == std::string::npos) return true;
        start = end + 1;
    }
}

bool Token(const std::string &value) {
    if (value.size() != 64) return false;
    for (char c : value) if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) return false;
    return true;
}
} // namespace

bool ParseCapabilityPreview(const std::string &bytes, CapabilityPreview *preview) {
    if (preview == NULL || bytes.empty() || bytes.size() > 8 * 1024 * 1024 ||
        bytes.find('\0') != std::string::npos || bytes.find('\r') != std::string::npos) return false;
    CapabilityPreview result;
    bool header = false, environment = false, reviewed = false;
    std::set<std::string> tools, collectors, changedPackages;
    std::size_t start = 0;
    while (start < bytes.size()) {
        const std::size_t end = bytes.find('\n', start);
        if (end == std::string::npos) return false;
        std::vector<std::string> fields;
        if (!Split(bytes.substr(start, end - start), &fields) || fields.empty() || reviewed) return false;
        start = end + 1;
        if (!header) {
            if (fields != std::vector<std::string>({"cydia-firmware-preview", "1"})) return false;
            header = true; continue;
        }
        if (fields[0] == "environment") {
            if (environment || fields.size() != 5 || fields[1].empty() || fields[3].empty() || fields[4].empty()) return false;
            result.architecture = fields[1]; result.prefix = fields[2];
            result.adminDirectory = fields[3]; result.rootDirectory = fields[4]; environment = true;
        } else if (fields[0] == "tool") {
            if (fields.size() != 3 || (fields[1] != "dpkg" && fields[1] != "dpkg-query" && fields[1] != "dpkg-deb") ||
                fields[2].empty() || !tools.insert(fields[1]).second) return false;
        } else if (fields[0] == "collector") {
            if (fields.size() != 3 || !collectors.insert(fields[1]).second ||
                (fields[1] == "mobilegestalt" ? fields[2] != "complete" :
                 fields[1] != "gssc" || (fields[2] != "available" && fields[2] != "unavailable"))) return false;
        } else if (fields[0] == "candidate") {
            const std::set<std::string> reasons = {"missing", "owned-update", "current", "newer-provider", "unknown-version",
                "package-state", "multiple-providers", "foreign-architecture", "external-provider", "virtual-provider", "retained-provider"};
            if (fields.size() != 10 || fields[1].empty() || reasons.count(fields[4]) == 0) return false;
            CapabilityCandidate candidate = {fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7], fields[8], fields[9]};
            if (candidate.action == "create" || candidate.action == "update") {
                if (candidate.version.empty() || !changedPackages.insert(candidate.package).second ||
                    (candidate.action == "create" ? candidate.reason != "missing" : candidate.reason != "owned-update")) return false;
                result.changes.push_back(candidate);
            } else if (candidate.action == "preserve") result.preserved.push_back(candidate);
            else return false;
        } else if (fields[0] == "review") {
            if (fields.size() != 2 || !Token(fields[1]) || start != bytes.size()) return false;
            result.reviewToken = fields[1]; reviewed = true;
        } else return false;
    }
    if (!header || !environment || !reviewed || tools.size() != 3 || collectors.size() != 2) return false;
    *preview = result;
    return true;
}
} // namespace CydiaRuntime
