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
bool NativeName(const std::string &value, std::string *name) {
    if (!CleanBytes(value)) return false;
    // dpkg path_skip_slash_dotslash(), as used by fsys_hash_find_node().
    // Unlike layout normalization, a final solitary dot remains a name.
    std::size_t start = 0;
    while (start < value.size() && (value[start] == '/' ||
        (value[start] == '.' && start + 1 < value.size() && value[start + 1] == '/'))) ++start;
    const std::string tail(value.substr(start));
    if (!tail.empty() && tail != ".") {
        std::size_t begin = 0;
        for (;;) {
            const auto end(tail.find('/', begin));
            const auto component(tail.substr(begin, end == std::string::npos ? end : end - begin));
            // Native dpkg does not perform our layout normalization here.
            // Refuse ambiguous spellings rather than claim a different name.
            if (component.empty() || component == "." || component == "..") return false;
            if (end == std::string::npos) break;
            begin = end + 1;
        }
    }
    *name = '/' + tail; return true;
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

bool Space(char value) { return value == ' ' || value == '\t' || value == '\r' || value == '\n'; }
bool PackageNameByte(char value) {
    return (value >= 'a' && value <= 'z') || (value >= '0' && value <= '9') || value == '+' || value == '-' || value == '.';
}
// Binary relationship grammar only. Canonicalizing tokens after parsing avoids
// silently merging malformed "foo bar" into the different package "foobar".
bool CanonicalRelations(const std::string &input, std::string *output) {
    if (input.size() > 1024 * 1024) return false;
    std::size_t offset = 0;
    const auto space = [&]() { while (offset < input.size() && Space(input[offset])) ++offset; };
    space(); if (offset == input.size()) { output->clear(); return true; }
    std::string result;
    for (;;) {
        const auto begin = offset;
        if (offset == input.size() || !((input[offset] >= 'a' && input[offset] <= 'z') ||
            (input[offset] >= '0' && input[offset] <= '9'))) return false;
        while (offset < input.size() && PackageNameByte(input[offset])) ++offset;
        if (offset < input.size() && input[offset] == ':') {
            ++offset; const auto architecture = offset;
            while (offset < input.size() && ((input[offset] >= 'a' && input[offset] <= 'z') ||
                (input[offset] >= '0' && input[offset] <= '9') || input[offset] == '-')) ++offset;
            if (architecture == offset || input[architecture] == '-') return false;
        }
        result += input.substr(begin, offset - begin); space();
        if (offset < input.size() && input[offset] == '(') {
            ++offset; space(); const auto operatorBegin = offset;
            while (offset < input.size() && (input[offset] == '<' || input[offset] == '>' || input[offset] == '=')) ++offset;
            const auto operation = input.substr(operatorBegin, offset - operatorBegin);
            if (operation != "<<" && operation != "<=" && operation != "=" && operation != ">=" &&
                operation != ">>" && operation != "<" && operation != ">") return false;
            space(); const auto versionBegin = offset;
            while (offset < input.size() && !Space(input[offset]) && input[offset] != ')') {
                const auto byte = input[offset];
                if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                    (byte >= '0' && byte <= '9') || byte == '.' || byte == '+' || byte == '-' || byte == ':' || byte == '~')) return false;
                ++offset;
            }
            const auto version = input.substr(versionBegin, offset - versionBegin); space();
            if (version.empty() || offset == input.size() || input[offset++] != ')') return false;
            result += " (" + operation + ' ' + version + ')'; space();
        }
        if (offset == input.size()) break;
        const char separator = input[offset++];
        if (separator != ',' && separator != '|') return false;
        result += separator == ',' ? ", " : " | "; space();
        if (offset == input.size()) return false;
    }
    *output = std::move(result); return true;
}
}

bool CanonicalPackageEffectControlFields(const std::map<std::string, std::string> &fields,
    std::map<std::string, std::string> *controls, std::string *error) {
    if (error) error->clear();
    if (!controls) { if (error) *error = "control_metadata_missing"; return false; }
    controls->clear(); std::map<std::string, std::string> result;
    for (const char *name : {"depends", "pre-depends", "breaks", "conflicts", "provides", "replaces"}) {
        const auto found = fields.find(name);
        if (!CanonicalRelations(found == fields.end() ? "" : found->second, &result[name])) {
            if (error) *error = "control_relationship_unsupported";
            return false;
        }
    }
    for (const char *name : {"multi-arch", "essential", "protected"}) {
        const auto found = fields.find(name);
        const std::string value = found == fields.end() ? "no" : Trim(found->second);
        if ((value != "no" && value != "yes" && std::string(name) != "multi-arch") ||
            (std::string(name) == "multi-arch" && value != "no" && value != "same" && value != "foreign" && value != "allowed")) {
            if (error) *error = "control_policy_field_invalid";
            return false;
        }
        result[name] = value;
    }
    *controls = std::move(result); return true;
}

namespace {
bool EffectDependencyField(const std::string &name) {
    return name == "depends" || name == "pre-depends" || name == "breaks" ||
        name == "conflicts" || name == "provides" || name == "replaces";
}
}
bool ValidPackageEffectControlFieldOrder(const std::map<std::string, std::string> &controls,
    const std::vector<std::string> &order) {
    std::map<std::string, std::string> canonical; std::string ignored;
    if (order.size() > 6 || !CanonicalPackageEffectControlFields(controls, &canonical, &ignored) || canonical != controls) return false;
    std::set<std::string> names;
    for (const auto &name : order) {
        const auto field = controls.find(name);
        if (!EffectDependencyField(name) || field == controls.end() || field->second.empty() || !names.insert(name).second) return false;
    }
    for (const auto &field : controls)
        if (EffectDependencyField(field.first) && !field.second.empty() && !names.count(field.first)) return false;
    return true;
}
bool PackageEffectControlFieldOrder(const std::map<std::string, std::string> &controls,
    const std::vector<std::string> &encountered, std::vector<std::string> *order, std::string *error) {
    if (error) error->clear();
    if (!order) { if (error) *error = "control_dependency_order_invalid"; return false; }
    order->clear();
    std::vector<std::string> result; std::set<std::string> seen;
    if (encountered.size() > 4096) { if (error) *error = "control_dependency_order_limit"; return false; }
    for (const auto &name : encountered) {
        if (!seen.insert(name).second) { if (error) *error = "control_dependency_order_invalid"; return false; }
        if (!EffectDependencyField(name)) continue;
        const auto field = controls.find(name);
        if (field == controls.end()) { if (error) *error = "control_dependency_order_invalid"; return false; }
        if (!field->second.empty()) result.push_back(name); // f_dependency ignores empty fields.
    }
    if (!ValidPackageEffectControlFieldOrder(controls, result)) {
        if (error) *error = "control_dependency_order_invalid";
        return false;
    }
    *order = std::move(result); return true;
}
bool Dpkg1237WrittenPackageEffectControlFieldOrder(const std::map<std::string, std::string> &controls,
    std::vector<std::string> *order) {
    // lib/dpkg/parse.c fieldinfos[]; lib/dpkg/dump.c write_stanza().
    return PackageEffectControlFieldOrder(controls,
        {"replaces", "provides", "depends", "pre-depends", "breaks", "conflicts"}, order, nullptr);
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
    std::string control, triggers;
    std::map<std::string, std::string> controlFields;
    std::vector<std::string> controlFieldOrder;
    ArchiveMaintainerScript prerm, postinst;
    bool scriptMetadataValid = true;
    bool payloadRequested = false;
    std::set<std::string> payloadPaths, payloadSeen;
    ArchivePayloadConsumer payloadConsumer;
    ArchivePayloadInspection payload;
    bool inventoryRequested = false;
    ArchiveDataInventory inventory;

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
    void PayloadFailure(const std::string &path, const char *reason) {
        if (payload.reason.empty()) { payload.path = path; payload.reason = reason; }
        payload.complete = false;
    }
    void InventoryFailure(const std::string &path, const char *reason) {
        if (inventory.reason.empty()) { inventory.path = path; inventory.reason = reason; }
        inventory.entries.clear(); inventory.complete = false;
    }
    void RequestInventory() {
        if (inventoryRequested || dataDone || stopped) {
            InventoryFailure("", "invalid_data_inventory_order"); return;
        }
        inventoryRequested = true;
    }
    bool InventoryItem(const std::string &name, char type, char headerType, const std::string &link) {
        if (!inventoryRequested || !inventory.reason.empty()) return true;
        if (type != '1' && type != '2' && !link.empty()) {
            InventoryFailure(name, "unexpected_link_target"); return true;
        }
        ArchiveDataInventoryEntry entry;
        // tar_extractor strips exactly one trailing slash for directory
        // members, including the legacy regular-with-trailing-slash case.
        std::string nativeInput(name);
        if (type == '5' && !nativeInput.empty() && nativeInput.back() == '/') nativeInput.pop_back();
        if (!NativeName(nativeInput, &entry.name)) {
            InventoryFailure(name, "data_inventory_ambiguous_name"); return true;
        }
        entry.type = type; entry.headerType = headerType; entry.link = link;
        if (type == '1' && !NativeName(link, &entry.hardlinkTarget)) {
            InventoryFailure(name, "data_inventory_ambiguous_hardlink"); return true;
        }
        if (entry.name.size() > limits.maxPathBytes || entry.link.size() > limits.maxPathBytes ||
            entry.hardlinkTarget.size() > limits.maxPathBytes)
            return Stop(ArchivePolicyStatus::Unverified, name, "inspection_limit");
        if (!Account(name, entry.name.size()) || !Account(name, entry.link.size()) ||
            !Account(name, entry.hardlinkTarget.size())) return false;
        entry.ordinal = inventory.entries.size() + 1;
        inventory.entries.push_back(std::move(entry)); return true;
    }
    void RequestPayload(const std::vector<std::string> &paths, const ArchivePayloadConsumer &consumer) {
        if (payloadRequested || dataDone || stopped) {
            PayloadFailure("", "invalid_payload_inspection_order"); return;
        }
        payloadRequested = true;
        if (paths.empty() || paths.size() > limits.maxPayloadFiles || paths.size() > limits.maxEntries) {
            PayloadFailure("", "invalid_payload_request_count"); return;
        }
        std::size_t bytes = 0;
        for (const std::string &path : paths) {
            std::string normalized;
            if (path.size() > limits.maxPathBytes || path.empty() || path[0] != '/' || path == "/" ||
                !Normalize(path, &normalized) || normalized != path || !payloadPaths.insert(path).second) {
                PayloadFailure(path, "invalid_payload_request_path"); return;
            }
            if (path.size() > limits.maxMetadataBytes || bytes > limits.maxMetadataBytes - path.size()) {
                PayloadFailure(path, "payload_request_limit"); return;
            }
            bytes += path.size();
        }
        if (!consumer) { PayloadFailure("", "missing_payload_consumer"); return; }
        payloadConsumer = consumer;
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
            if (payloadRequested) {
                const auto child(payloadPaths.lower_bound(path + '/'));
                if (child != payloadPaths.end() && Below(*child, path))
                    PayloadFailure(*child, "payload_link_ancestor");
            }
            // Absolute symlinks into /System or /usr/lib can intentionally
            // reference Apple's files. Their targets are not payload writes.
        } else if (!link.empty()) return Stop(ArchivePolicyStatus::Invalid, path, "unexpected_link_target");
        dataNames[path] = type; return true;
    }
    bool PayloadBody(const ArchiveRead &read, const unsigned char *header,
                     const std::string &path, char type, std::uint64_t size) {
        if (!payloadRequested || !payloadPaths.count(path)) return Body(read, size, NULL);
        if (type != '0') {
            PayloadFailure(path, "payload_not_regular"); return Body(read, size, NULL);
        }
        std::uint64_t mode, uid, gid;
        if (!Number(header + 100, 8, &mode) || !Number(header + 108, 8, &uid) ||
            !Number(header + 116, 8, &gid) || mode > 07777 ||
            uid > std::numeric_limits<std::uint32_t>::max() || gid > std::numeric_limits<std::uint32_t>::max()) {
            PayloadFailure(path, "payload_metadata_unverified"); return Body(read, size, NULL);
        }
        if (!payload.reason.empty()) return Body(read, size, NULL);
        ArchivePayloadFileMetadata file;
        file.path = path; file.size = size; file.mode = static_cast<std::uint32_t>(mode);
        file.uid = static_cast<std::uint32_t>(uid); file.gid = static_cast<std::uint32_t>(gid);
        std::uint64_t remaining(size); bool overread = false;
        const ArchiveRead bounded([&](void *bytes, std::size_t count) {
            if (count > remaining) { overread = true; return false; }
            if (!Read(read, bytes, count)) return false;
            remaining -= count; return true;
        });
        const bool consumed(payloadConsumer(file, bounded));
        if (!consumed || overread || remaining != 0) PayloadFailure(path, "payload_consumer_failed");
        else payloadSeen.insert(path);
        return !stopped && Body(read, remaining, NULL);
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
                fields[previous] += '\n' + Trim(line);
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
            controlFieldOrder.push_back(previous);
        }
        for (const auto &field : std::vector<std::pair<std::string, std::string> >{
                {"package", expected.package}, {"version", expected.version}, {"architecture", expected.architecture}}) {
            const auto found(fields.find(field.first));
            if (found == fields.end() || found->second.empty())
                return Stop(ArchivePolicyStatus::Invalid, "control", "missing_identity_field");
            if (found->second != field.second)
                return Stop(ArchivePolicyStatus::IdentityMismatch, field.first, "archive_identity_mismatch");
        }
        controlFields = std::move(fields);
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
            char type(header[156] == 0 ? '0' : header[156]);
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
            const char headerType(type);
            // Keep ordinary layout inspection unchanged. The opt-in native
            // inventory follows dpkg's pre-ANSI directory interpretation.
            if (!isControl && inventoryRequested && type == '0' && !name.empty() && name.back() == '/') type = '5';
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
                else if (path == "/triggers") { save = &triggers; Unverified(path, "maintainer_semantics_unverified"); }
                else if (path == "/prerm" || path == "/postinst") {
                    ArchiveMaintainerScript &script(path == "/prerm" ? prerm : postinst);
                    script.present = true; save = &script.bytes;
                    std::uint64_t mode = 0, uid = 0, gid = 0;
                    if (!Number(header + 100, 8, &mode) || !Number(header + 108, 8, &uid) ||
                        !Number(header + 116, 8, &gid) || mode > 07777 ||
                        uid > std::numeric_limits<std::uint32_t>::max() || gid > std::numeric_limits<std::uint32_t>::max())
                        scriptMetadataValid = false;
                    else {
                        script.mode = static_cast<std::uint32_t>(mode);
                        script.uid = static_cast<std::uint32_t>(uid); script.gid = static_cast<std::uint32_t>(gid);
                    }
                    Unverified(path, "maintainer_semantics_unverified");
                }
                else if (path != "/" && path != "/md5sums" && path != "/conffiles")
                    Unverified(path, "maintainer_semantics_unverified");
            } else if (!DataItem(path, type, link) || !InventoryItem(name, type, headerType, link)) return false;
            if (!(isControl ? Body(read, size, save) : PayloadBody(read, header, path, type, size)) ||
                !Body(read, (512 - size % 512) % 512, NULL)) return false;
        }
    }
    ArchivePolicyResult Finish() {
        if (stopped) return result;
        if (!controlDone || !dataDone) { Stop(ArchivePolicyStatus::Invalid, "", "incomplete_archive"); return result; }
        std::set<std::string> resolved;
        std::map<std::string, std::string> hardLinkRoots;
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
            if (payloadRequested) {
                const auto root(hardLinkRoots.find(target));
                if (root != hardLinkRoots.end()) target = root->second;
                for (const std::string &name : chain) hardLinkRoots[name] = target;
                if (payloadPaths.count(target)) PayloadFailure(target, "payload_hardlink_alias");
            }
            if (chain.size() > 1) Unverified(link.first, "chained_hardlink_unverified");
            resolved.insert(chain.begin(), chain.end());
        }
        result.complete = true;
        if (inventoryRequested && inventory.reason.empty()) inventory.complete = true;
        if (payloadRequested && payload.reason.empty()) {
            for (const std::string &path : payloadPaths) if (!payloadSeen.count(path)) {
                PayloadFailure(path, "payload_file_missing"); break;
            }
            payload.complete = payload.reason.empty();
        }
        return result;
    }
};

PackageArchivePolicy::PackageArchivePolicy(const ArchiveIdentity &expected, const ArchiveLayout &layout,
                                         const ArchiveLimits &limits) : impl_(new Impl(expected, layout, limits)) {}
PackageArchivePolicy::~PackageArchivePolicy() {}
bool PackageArchivePolicy::ReadControlTar(const ArchiveRead &read) { return impl_->Tar(read, true); }
bool PackageArchivePolicy::ReadDataTar(const ArchiveRead &read) { return impl_->Tar(read, false); }
bool PackageArchivePolicy::ReadDataTarWithInventory(const ArchiveRead &read) {
    impl_->RequestInventory(); return impl_->Tar(read, false);
}
bool PackageArchivePolicy::ReadDataTar(const ArchiveRead &read, const std::vector<std::string> &paths,
                                     const ArchivePayloadConsumer &consumer) {
    impl_->RequestPayload(paths, consumer); return impl_->Tar(read, false);
}
ArchivePolicyResult PackageArchivePolicy::Finish() { return impl_->Finish(); }
ArchiveControlMetadata PackageArchivePolicy::ControlMetadata() const {
    ArchiveControlMetadata result;
    if (impl_->stopped || !impl_->result.complete || !impl_->result.identityVerified) {
        result.reason = "control_metadata_incomplete"; return result;
    }
    if (!impl_->scriptMetadataValid) {
        result.reason = "control_script_metadata_unverified"; return result;
    }
    // Native parsedb rejects an EOF during a field value. Keep the existing
    // layout result intact, but never claim native order for that control.
    if (impl_->control.empty() || impl_->control.back() != '\n') {
        result.reason = "control_native_record_unverified"; return result;
    }
    if (!CanonicalPackageEffectControlFields(impl_->controlFields, &result.controls, &result.reason)) return result;
    if (!PackageEffectControlFieldOrder(result.controls, impl_->controlFieldOrder, &result.dependencyOrder, &result.reason)) {
        result.controls.clear(); return result;
    }
    result.dependencyOrderVerified = true; result.rawControlRecord = impl_->control;
    result.identity = impl_->expected; result.triggersPresent = impl_->controlNames.count("/triggers") != 0;
    result.triggers = impl_->triggers; result.prerm = impl_->prerm; result.postinst = impl_->postinst;
    result.complete = true; return result;
}
ArchivePayloadInspection PackageArchivePolicy::PayloadInspection() const {
    ArchivePayloadInspection result(impl_->payload);
    if (impl_->stopped || !impl_->result.complete) result.complete = false;
    return result;
}
ArchiveDataInventory PackageArchivePolicy::DataInventory() const {
    ArchiveDataInventory result;
    if (!impl_->inventoryRequested || impl_->stopped || !impl_->result.complete ||
        !impl_->result.identityVerified || !impl_->inventory.complete) {
        result.path = impl_->inventory.reason.empty() ? impl_->result.path : impl_->inventory.path;
        result.reason = !impl_->inventory.reason.empty() ? impl_->inventory.reason :
            !impl_->result.reason.empty() ? impl_->result.reason : "data_inventory_incomplete";
        return result;
    }
    result = impl_->inventory; result.identity = impl_->expected; return result;
}
}
