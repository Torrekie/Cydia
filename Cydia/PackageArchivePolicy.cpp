/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PackageArchivePolicy.hpp"
#include <algorithm>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <sstream>

namespace CydiaPackages {
namespace {
bool Below(const std::string &path, const std::string &root) {
    return root == "/" || path == root ||
        (path.size() > root.size() && path.compare(0, root.size(), root) == 0 && path[root.size()] == '/');
}
bool CleanBytes(const std::string &value) {
    for (unsigned char c : value) if (c < 32 || c == 127) return false;
    return true;
}
bool Normalize(const std::string &value, std::string *path, bool allowParent = false,
               const std::string &base = "/") {
    if (value.empty() || !CleanBytes(value)) return false;
    std::vector<std::string> parts;
    if (value[0] != '/' && base != "/") {
        std::istringstream input(base); std::string part;
        while (std::getline(input, part, '/')) if (!part.empty()) parts.push_back(part);
    }
    std::istringstream input(value); std::string part;
    while (std::getline(input, part, '/')) {
        if (part.empty() || part == ".") continue;
        if (part == "..") {
            if (!allowParent || parts.empty()) return false;
            parts.pop_back();
        } else parts.push_back(part);
    }
    *path = "/";
    for (std::size_t i = 0; i < parts.size(); ++i) {
        if (i != 0) path->push_back('/');
        path->append(parts[i]);
    }
    return true;
}
bool Field(const unsigned char *bytes, std::size_t length, std::string *value) {
    std::size_t end(0);
    while (end < length && bytes[end] != 0) ++end;
    value->assign(reinterpret_cast<const char *>(bytes), end);
    while (end < length) if (bytes[end++] != 0) return false;
    return true;
}
bool Number(const unsigned char *bytes, std::size_t length, std::uint64_t *value) {
    *value = 0;
    if (length != 0 && bytes[0] == 0x80) {
        for (std::size_t i = 1; i < length; ++i) {
            if (*value > (std::numeric_limits<std::uint64_t>::max() - bytes[i]) / 256) return false;
            *value = *value * 256 + bytes[i];
        }
        return true;
    }
    std::size_t i(0);
    while (i < length && bytes[i] == ' ') ++i;
    while (i < length && bytes[i] >= '0' && bytes[i] <= '7') {
        if (*value > (std::numeric_limits<std::uint64_t>::max() - 7) / 8) return false;
        *value = *value * 8 + bytes[i++] - '0';
    }
    while (i < length && (bytes[i] == 0 || bytes[i] == ' ')) ++i;
    return i == length;
}
std::string Lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return value;
}
std::string Trim(const std::string &value) {
    const auto first(value.find_first_not_of(" \t\r"));
    if (first == std::string::npos) return "";
    return value.substr(first, value.find_last_not_of(" \t\r") - first + 1);
}
}

struct PackageArchivePolicy::Impl {
    ArchiveIdentity expected;
    ArchiveLayout layout;
    ArchiveLimits limits;
    ArchivePolicyResult result;
    std::size_t entries = 0, metadata = 0;
    std::uint64_t streamed = 0;
    bool controlDone = false, dataDone = false, stopped = false;
    std::set<std::string> controlNames;
    std::map<std::string, char> dataNames;
    std::map<std::string, std::string> hardLinks;
    std::string control;

    Impl(const ArchiveIdentity &identity, const ArchiveLayout &target, const ArchiveLimits &bounds)
        : expected(identity), layout(target), limits(bounds) {
        std::string prefix;
        if (expected.package.empty() || expected.version.empty() || expected.architecture.empty() ||
            !CleanBytes(expected.package) || !CleanBytes(expected.version) || !CleanBytes(expected.architecture))
            Stop(ArchivePolicyStatus::Invalid, "control", "invalid_expected_identity");
        if (layout.prefix.empty() || layout.prefix[0] != '/' || !Normalize(layout.prefix, &prefix))
            Stop(ArchivePolicyStatus::Invalid, layout.prefix, "invalid_layout_prefix");
        else layout.prefix = prefix;
        for (std::string &foreign : layout.foreignPrefixes) {
            if (foreign.empty() || foreign[0] != '/' || !Normalize(foreign, &prefix) || prefix == "/")
                Stop(ArchivePolicyStatus::Invalid, foreign, "invalid_foreign_prefix");
            else foreign = prefix;
        }
    }
    bool Stop(ArchivePolicyStatus status, const std::string &path, const char *reason) {
        result.status = status; result.path = path; result.reason = reason;
        result.complete = false; stopped = true; return false;
    }
    void Unverified(const std::string &path, const char *reason) {
        if (result.status == ArchivePolicyStatus::Accepted) {
            result.status = ArchivePolicyStatus::Unverified; result.path = path; result.reason = reason;
        }
    }
    bool Read(const ArchiveRead &read, void *bytes, std::size_t size) {
        if (size > limits.maxStreamBytes || streamed > limits.maxStreamBytes - size)
            return Stop(ArchivePolicyStatus::Unverified, "", "inspection_limit");
        streamed += size;
        if (!read || !read(bytes, size)) return Stop(ArchivePolicyStatus::Invalid, "", "truncated_tar");
        return true;
    }
    bool Account(const std::string &path, std::size_t bytes) {
        if (bytes > limits.maxMetadataBytes || metadata > limits.maxMetadataBytes - bytes)
            return Stop(ArchivePolicyStatus::Unverified, path, "inspection_limit");
        metadata += bytes; return true;
    }
    bool Body(const ArchiveRead &read, std::uint64_t size, std::string *save) {
        if (size > limits.maxStreamBytes || streamed > limits.maxStreamBytes - size)
            return Stop(ArchivePolicyStatus::Unverified, "", "inspection_limit");
        unsigned char bytes[32768];
        while (size != 0) {
            const std::size_t amount(static_cast<std::size_t>(std::min<std::uint64_t>(size, sizeof(bytes))));
            if (!Read(read, bytes, amount)) return false;
            if (save != NULL) save->append(reinterpret_cast<const char *>(bytes), amount);
            size -= amount;
        }
        return true;
    }
    bool Destination(const std::string &path, char type) {
        if (Below(layout.prefix, path)) {
            if (type == '5') return true;
            return Stop(ArchivePolicyStatus::Invalid, path, "non_directory_installation_ancestor");
        }
        for (const auto &foreign : layout.foreignPrefixes)
            if (foreign != layout.prefix && Below(path, foreign)) {
                // The selected prefix may itself live below a known foreign
                // prefix. Allow its own payload, not siblings or an embedded
                // foreign prefix beneath a broader selected destination.
                if (Below(layout.prefix, foreign) && Below(path, layout.prefix)) continue;
                if (type == '5') { Unverified(path, "directory_destination_unverified"); return true; }
                return Stop(ArchivePolicyStatus::LayoutMismatch, path, "different_installation_prefix");
            }
        if (Below(path, layout.prefix)) return true;
        // Empty directories can be staging scaffolding. Their ownership and
        // modes still warrant a warning, but do not prove a layout conflict.
        // A later substantive descendant is independently classified below.
        if (type == '5') { Unverified(path, "directory_destination_unverified"); return true; }
        for (const char *root : {"/bin", "/sbin", "/etc", "/Applications", "/usr/bin", "/usr/sbin",
                                "/usr/lib", "/usr/libexec", "/usr/include", "/usr/share", "/var/lib/dpkg",
                                "/var/lib/apt", "/var/cache/apt", "/var/log/apt", "/Library/MobileSubstrate",
                                "/Library/PreferenceBundles", "/Library/PreferenceLoader"})
            if (Below(path, root))
                return Stop(ArchivePolicyStatus::LayoutMismatch, path, "unprefixed_bootstrap_destination");
        for (const char *shared : {"/var/mobile", "/private/var/mobile", "/var/Keychains", "/tmp", "/var/tmp"})
            if (Below(path, shared)) return true;
        Unverified(path, "shared_destination_unverified");
        return true;
    }
    bool DataItem(const std::string &path, char type, const std::string &link) {
        const auto existing(dataNames.find(path));
        if (existing != dataNames.end() && existing->second == '5' && type == '5')
            return true;
        if (existing != dataNames.end())
            return Stop(ArchivePolicyStatus::Invalid, path, "duplicate_archive_path");
        for (auto end(path.rfind('/')); end != std::string::npos && end != 0; end = path.rfind('/', end - 1)) {
            const auto parent(dataNames.find(path.substr(0, end)));
            if (parent != dataNames.end() && parent->second != '5')
                return Stop(ArchivePolicyStatus::Invalid, path, "non_directory_ancestor");
        }
        if (type != '5') {
            const auto child(dataNames.lower_bound(path + '/'));
            if (child != dataNames.end() && Below(child->first, path))
                return Stop(ArchivePolicyStatus::Invalid, path, "non_directory_ancestor");
        }
        if (!Destination(path, type)) return false;
        if (type == '1' || type == '2') {
            std::string target;
            if (link.empty() || link.size() > limits.maxPathBytes ||
                !Normalize(link, &target, type == '2', type == '2' ? path.substr(0, path.rfind('/')) : "/"))
                return Stop(ArchivePolicyStatus::Invalid, path, "unsafe_link_target");
            if (!Account(path, target.size())) return false;
            if (type == '1') hardLinks[path] = target;
            // Absolute symlinks into /System or /usr/lib can intentionally
            // reference Apple's files. Their targets are not payload writes.
        } else if (!link.empty()) return Stop(ArchivePolicyStatus::Invalid, path, "unexpected_link_target");
        dataNames[path] = type; return true;
    }
    bool ControlIdentity() {
        if (control.empty()) return Stop(ArchivePolicyStatus::Invalid, "control", "missing_control");
        std::map<std::string, std::string> fields;
        std::istringstream input(control); std::string line, previous; bool ended(false);
        while (std::getline(input, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.find('\0') != std::string::npos) return Stop(ArchivePolicyStatus::Invalid, "control", "invalid_control");
            if (line.empty()) { if (!fields.empty()) ended = true; continue; }
            if (ended) return Stop(ArchivePolicyStatus::Invalid, "control", "multiple_control_records");
            if (line[0] == ' ' || line[0] == '\t') {
                if (previous.empty() || previous == "package" || previous == "version" || previous == "architecture")
                    return Stop(ArchivePolicyStatus::Invalid, "control", "invalid_control_continuation");
                continue;
            }
            const auto colon(line.find(':'));
            if (colon == std::string::npos || colon == 0)
                return Stop(ArchivePolicyStatus::Invalid, "control", "invalid_control");
            previous = Lower(line.substr(0, colon));
            for (char c : previous) if ((c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-')
                return Stop(ArchivePolicyStatus::Invalid, "control", "invalid_control_field");
            if (fields.size() >= 4096) return Stop(ArchivePolicyStatus::Unverified, "control", "inspection_limit");
            if (!fields.emplace(previous, Trim(line.substr(colon + 1))).second)
                return Stop(ArchivePolicyStatus::Invalid, "control", "duplicate_control_field");
        }
        for (const auto &field : std::vector<std::pair<std::string, std::string> >{
                {"package", expected.package}, {"version", expected.version}, {"architecture", expected.architecture}}) {
            const auto found(fields.find(field.first));
            if (found == fields.end() || found->second.empty())
                return Stop(ArchivePolicyStatus::Invalid, "control", "missing_identity_field");
            if (found->second != field.second)
                return Stop(ArchivePolicyStatus::IdentityMismatch, field.first, "archive_identity_mismatch");
        }
        result.identityVerified = true; return true;
    }
    bool Tar(const ArchiveRead &read, bool isControl) {
        if (stopped) return false;
        if ((isControl && controlDone) || (!isControl && (!controlDone || dataDone)))
            return Stop(ArchivePolicyStatus::Invalid, "", "invalid_inspection_order");
        std::string longName, longLink;
        while (true) {
            unsigned char header[512];
            if (!Read(read, header, sizeof(header))) return false;
            if (std::all_of(header, header + sizeof(header), [](unsigned char c) { return c == 0; })) {
                if (!longName.empty() || !longLink.empty()) return Stop(ArchivePolicyStatus::Invalid, "", "orphan_long_name");
                if (!Read(read, header, sizeof(header))) return false;
                if (!std::all_of(header, header + sizeof(header), [](unsigned char c) { return c == 0; }))
                    return Stop(ArchivePolicyStatus::Invalid, "", "invalid_tar_terminator");
                if (isControl) { controlDone = true; return ControlIdentity(); }
                dataDone = true; return true;
            }
            if (++entries > limits.maxEntries) return Stop(ArchivePolicyStatus::Unverified, "", "inspection_limit");
            std::uint64_t checksum, size, actual(0);
            if (!Number(header + 148, 8, &checksum) || !Number(header + 124, 12, &size))
                return Stop(ArchivePolicyStatus::Invalid, "", "invalid_tar_number");
            for (std::size_t i = 0; i != sizeof(header); ++i) actual += i >= 148 && i < 156 ? ' ' : header[i];
            if (checksum != actual) return Stop(ArchivePolicyStatus::Invalid, "", "invalid_tar_checksum");
            std::string name, link, prefix;
            if (!Field(header, 100, &name) || !Field(header + 157, 100, &link))
                return Stop(ArchivePolicyStatus::Invalid, "", "invalid_tar_name");
            if (std::memcmp(header + 257, "ustar\0", 6) == 0) {
                if (std::memcmp(header + 263, "00", 2) != 0)
                    return Stop(ArchivePolicyStatus::Unverified, name, "unsupported_tar_format");
                if (!Field(header + 345, 155, &prefix)) return Stop(ArchivePolicyStatus::Invalid, name, "invalid_tar_prefix");
                if (!prefix.empty()) name = prefix + '/' + name;
            } else if (std::memcmp(header + 257, "ustar ", 6) != 0 &&
                       !std::all_of(header + 257, header + 512, [](unsigned char c) { return c == 0; }))
                return Stop(ArchivePolicyStatus::Unverified, name, "unsupported_tar_format");
            const char type(header[156] == 0 ? '0' : header[156]);
            if (type == 'L' || type == 'K') {
                if (size == 0 || size > limits.maxPathBytes + 1 || !Account(name, static_cast<std::size_t>(size)))
                    return stopped ? false : Stop(ArchivePolicyStatus::Unverified, name, "inspection_limit");
                std::string &value(type == 'L' ? longName : longLink);
                if (!value.empty()) return Stop(ArchivePolicyStatus::Invalid, name, "duplicate_long_name");
                if (!Body(read, size, &value) || !Body(read, (512 - size % 512) % 512, NULL)) return false;
                if (value.back() != 0 || value.find('\0') != value.size() - 1)
                    return Stop(ArchivePolicyStatus::Invalid, name, "invalid_long_name");
                value.pop_back();
                if (value.empty()) return Stop(ArchivePolicyStatus::Invalid, name, "invalid_long_name");
                continue;
            }
            if (!longName.empty()) name.swap(longName);
            if (!longLink.empty()) link.swap(longLink);
            longName.clear(); longLink.clear();
            std::string path;
            if (name.size() > limits.maxPathBytes)
                return Stop(ArchivePolicyStatus::Unverified, name, "inspection_limit");
            if (!Normalize(name, &path) || (path == "/" && type != '5'))
                return Stop(ArchivePolicyStatus::Invalid, name, "unsafe_archive_path");
            if (type != '0' && type != '1' && type != '2' && type != '5')
                return Stop(ArchivePolicyStatus::Unverified, path, "unsupported_tar_semantics");
            if (type != '0' && size != 0) return Stop(ArchivePolicyStatus::Invalid, path, "unexpected_entry_data");
            if (!Account(path, path.size())) return false;
            std::string *save(NULL);
            if (isControl) {
                if (!link.empty()) return Stop(ArchivePolicyStatus::Invalid, path, "unexpected_link_target");
                if (!controlNames.insert(path).second)
                    return Stop(ArchivePolicyStatus::Invalid, path, "duplicate_control_member");
                if (path != "/" && (type != '0' || path.find('/', 1) != std::string::npos))
                    return Stop(ArchivePolicyStatus::Invalid, path, "invalid_control_member");
                if (size > limits.maxMetadataBytes || !Account(path, static_cast<std::size_t>(size)))
                    return stopped ? false : Stop(ArchivePolicyStatus::Unverified, path, "inspection_limit");
                if (path == "/control") save = &control;
                else if (path != "/" && path != "/md5sums" && path != "/conffiles")
                    Unverified(path, "maintainer_semantics_unverified");
            } else if (!DataItem(path, type, link)) return false;
            if (!Body(read, size, save) || !Body(read, (512 - size % 512) % 512, NULL)) return false;
        }
    }
    ArchivePolicyResult Finish() {
        if (stopped) return result;
        if (!controlDone || !dataDone) { Stop(ArchivePolicyStatus::Invalid, "", "incomplete_archive"); return result; }
        std::set<std::string> resolved;
        for (const auto &link : hardLinks) {
            if (resolved.count(link.first)) continue;
            std::set<std::string> chain;
            std::string target(link.first);
            while (!resolved.count(target)) {
                const auto entry(dataNames.find(target));
                if (entry == dataNames.end() || (entry->second != '0' && entry->second != '1')) {
                    Stop(ArchivePolicyStatus::Invalid, link.first, "invalid_hardlink_target"); return result;
                }
                if (entry->second == '0') break;
                if (!chain.insert(target).second) {
                    Stop(ArchivePolicyStatus::Invalid, link.first, "hardlink_cycle"); return result;
                }
                target = hardLinks.find(target)->second;
            }
            if (chain.size() > 1) Unverified(link.first, "chained_hardlink_unverified");
            resolved.insert(chain.begin(), chain.end());
        }
        result.complete = true; return result;
    }
};

PackageArchivePolicy::PackageArchivePolicy(const ArchiveIdentity &expected, const ArchiveLayout &layout,
                                         const ArchiveLimits &limits) : impl_(new Impl(expected, layout, limits)) {}
PackageArchivePolicy::~PackageArchivePolicy() {}
bool PackageArchivePolicy::ReadControlTar(const ArchiveRead &read) { return impl_->Tar(read, true); }
bool PackageArchivePolicy::ReadDataTar(const ArchiveRead &read) { return impl_->Tar(read, false); }
ArchivePolicyResult PackageArchivePolicy::Finish() { return impl_->Finish(); }
}
