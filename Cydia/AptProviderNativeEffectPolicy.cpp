/* No I/O, dpkg parser, producer or executable is provided here.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderNativeEffectPolicy.hpp"
#include <algorithm>
#include <limits>
#include <map>
#include <set>

namespace CydiaAPT { namespace Provider { namespace NativeEffectPolicy {
namespace {
const char Profile[] = "dpkg-1.23.7-effects-1";
const char *Forces[] = {"architecture", "bad-path", "bad-verify", "bad-version", "breaks",
    "confask", "confdef", "confmiss", "confnew", "confold", "configure-any", "conflicts", "depends",
    "depends-version", "downgrade", "hold", "not-root", "overwrite", "overwrite-dir", "overwrite-diverted",
    "remove-essential", "remove-reinstreq", "script-chrootless", "unsafe-io", "statoverride-add",
    "statoverride-remove", "security-mac", "remove-protected"};
bool Fail(Error *error, Error code) {
    if (error) *error = code;
    return false;
}
bool Fail(Error *error) {
    if (error && *error == Error::None) *error = Error::Invalid;
    return false;
}
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
bool Text(const std::string &s, bool empty = false) {
    return (empty || !s.empty()) && s.size() <= MaximumValueBytes && s.find('\0') == std::string::npos;
}
bool Token(const std::string &s) {
    if (s.empty() || s.size() > 128) return false;
    for (unsigned char c : s) if (c <= 32 || c >= 127) return false;
    return true;
}
bool Path(const std::string &s) {
    if (s.empty() || s.size() > 4096 || s[0] != '/' || (s.size() > 1 && s.back() == '/')) return false;
    for (unsigned char c : s) if (c < 32 || c == 127) return false;
    std::size_t at = 1;
    while (at < s.size()) {
        const auto end = s.find('/', at), n = end == std::string::npos ? s.size() - at : end - at;
        if (!n || (n == 1 && s[at] == '.') || (n == 2 && s.compare(at, n, "..") == 0)) return false;
        if (end == std::string::npos) break;
        at = end + 1;
    }
    return true;
}
bool SearchPath(const std::string &s) {
    if (!Text(s)) return false;
    std::size_t at = 0;
    while (at < s.size()) {
        const auto end = s.find(':', at);
        if (!Path(s.substr(at, end == std::string::npos ? end : end - at))) return false;
        if (end == std::string::npos) return true;
        at = end + 1;
    }
    return false;
}
struct Budget {
    std::size_t bytes = 0, items = 0;
    bool Add(std::size_t n, Error *error) {
        if (n > MaximumBytes - bytes) return Fail(error, Error::Limit);
        bytes += n;
        return true;
    }
    bool Items(std::size_t n, Error *error) {
        if (n > 16384 - items) return Fail(error, Error::Limit);
        items += n;
        return true;
    }
    bool String(const std::string &s, Error *error, bool empty = false) {
        if (!Text(s, empty)) return Fail(error, s.size() > MaximumValueBytes ? Error::Limit : Error::Invalid);
        return Add(s.size() + 16, error);
    }
};
struct Writer {
    std::string bytes; std::size_t maximum; bool valid = true;
    explicit Writer(std::size_t limit = MaximumBytes) : maximum(limit) {}
    void Field(const std::string &s) {
        if (!valid) return;
        const auto size = std::to_string(s.size());
        if (s.size() > maximum || size.size() + 2 > maximum - s.size() ||
            s.size() + size.size() + 2 > maximum - bytes.size()) { valid = false; bytes.clear(); return; }
        bytes += size; bytes += ':'; bytes += s; bytes += ',';
    }
};
bool Fields(const std::string &bytes, std::vector<std::string> *fields, std::size_t count, Error *error,
    std::size_t maximum = MaximumBytes) {
    if (bytes.size() > maximum) return Fail(error, Error::Limit);
    std::vector<std::string> result; std::size_t at = 0;
    while (at < bytes.size()) {
        if (result.size() == count) return Fail(error, Error::Limit);
        const auto begin = at; std::size_t length = 0;
        while (at < bytes.size() && bytes[at] >= '0' && bytes[at] <= '9') {
            const unsigned digit = bytes[at++] - '0';
            if (at - begin > 7 || length > (maximum - digit) / 10) return Fail(error, Error::Limit);
            length = length * 10 + digit;
        }
        if (at == begin || (at - begin > 1 && bytes[begin] == '0') || at == bytes.size() || bytes[at++] != ':' ||
            length >= bytes.size() - at || bytes[at + length] != ',') return Fail(error);
        result.emplace_back(bytes, at, length); at += length + 1;
    }
    *fields = std::move(result); return true;
}
bool Number(const std::string &s, std::uint32_t maximum, std::uint32_t *value) {
    if (s.empty() || s.size() > 10 || (s.size() > 1 && s[0] == '0')) return false;
    std::uint32_t n = 0;
    for (unsigned char c : s) {
        if (c < '0' || c > '9') return false;
        const auto digit = static_cast<std::uint32_t>(c - '0');
        if (digit > maximum || n > (maximum - digit) / 10) return false;
        n = n * 10 + digit;
    }
    *value = n; return true;
}
bool Strings(const std::vector<std::string> &values, Writer *writer, Budget *budget, Error *error,
    std::size_t maximum = MaximumItems, bool empty = false) {
    if (values.size() > maximum || !budget->Items(values.size(), error)) return Fail(error, Error::Limit);
    for (const auto &value : values) {
        if (!budget->String(value, error, empty)) return false;
        writer->Field(value);
    }
    return writer->valid || Fail(error, Error::Limit);
}
bool EncodeSettings(const Settings &s, std::string *bytes, Error *error) {
    if (static_cast<unsigned>(s.triggers) > 2 || s.abortAfter > static_cast<std::uint32_t>(INT32_MAX) ||
        s.debugMask > static_cast<std::uint32_t>(INT32_MAX) || (!s.logFilePresent && !s.logFile.empty()) ||
        s.forces.size() > 28 || s.hooks.size() > MaximumItems || s.filters.size() > MaximumItems || s.statusDescriptors.size() > MaximumItems)
        return Fail(error);
    Budget budget; Writer forces, ignores, hooks, loggers, filters, descriptors, unmodeled;
    if (!budget.String(s.logFile, error, true)) return false;
    unsigned previous = 0; bool first = true;
    for (const auto force : s.forces) {
        const auto n = static_cast<unsigned>(force);
        if (n >= 28 || (!first && n <= previous)) return Fail(error);
        forces.Field(Forces[n]); first = false; previous = n;
    }
    if (!Strings(s.ignoreDepends, &ignores, &budget, error) || !Strings(s.statusLoggers, &loggers, &budget, error, MaximumItems, true) ||
        !Strings(s.unmodeledOptions, &unmodeled, &budget, error)) return false;
    for (const auto &hook : s.hooks) {
        if (static_cast<unsigned>(hook.phase) > 1 || !budget.String(hook.command, error, true)) return Fail(error);
        Writer item; item.Field(std::to_string(static_cast<unsigned>(hook.phase))); item.Field(hook.command); hooks.Field(item.bytes);
    }
    for (const auto &filter : s.filters) {
        if (static_cast<unsigned>(filter.kind) > 1 || !budget.String(filter.pattern, error, true)) return Fail(error);
        Writer item; item.Field(std::to_string(static_cast<unsigned>(filter.kind))); item.Field(filter.pattern); filters.Field(item.bytes);
    }
    for (const auto descriptor : s.statusDescriptors) {
        if (descriptor > static_cast<std::uint32_t>(INT32_MAX)) return Fail(error);
        descriptors.Field(std::to_string(descriptor));
    }
    if (!hooks.valid || !filters.valid || !descriptors.valid) return Fail(error, Error::Limit);
    Writer result(MaximumRecordBytes);
    for (const auto flag : {s.autoDeconfigure, s.noAct, s.recursive, s.selectedOnly, s.skipSameVersion,
        s.pending, s.noDebsig, s.robot, s.noPager}) result.Field(flag ? "1" : "0");
    result.Field(std::to_string(static_cast<unsigned>(s.triggers))); result.Field(std::to_string(s.abortAfter));
    result.Field(std::to_string(s.debugMask)); result.Field(s.logFilePresent ? "1" : "0"); result.Field(s.logFile);
    for (const auto *list : {&forces, &ignores, &hooks, &loggers, &filters, &descriptors, &unmodeled}) result.Field(list->bytes);
    if (!result.valid) return Fail(error, Error::Limit);
    *bytes = std::move(result.bytes);
    return true;
}
bool DecodeSettings(const std::string &bytes, Settings *settings, Error *error) {
    std::vector<std::string> fields, forces, hooks, filters, descriptors;
    if (!Fields(bytes, &fields, 21, error, MaximumRecordBytes) || fields.size() != 21) return Fail(error);
    Settings value; bool *flags[] = {&value.autoDeconfigure, &value.noAct, &value.recursive, &value.selectedOnly, &value.skipSameVersion,
        &value.pending, &value.noDebsig, &value.robot, &value.noPager};
    std::uint32_t number;
    for (unsigned i = 0; i < 9; ++i) {
        if (!Number(fields[i], 1, &number)) return Fail(error);
        *flags[i] = number;
    }
    if (!Number(fields[9], 2, &number)) return Fail(error);
    value.triggers = static_cast<TriggerMode>(number);
    if (!Number(fields[10], INT32_MAX, &value.abortAfter) || !Number(fields[11], INT32_MAX, &value.debugMask) ||
        !Number(fields[12], 1, &number)) return Fail(error);
    value.logFilePresent = number; value.logFile = fields[13];
    if (!Fields(fields[14], &forces, 28, error) || !Fields(fields[15], &value.ignoreDepends, MaximumItems, error) ||
        !Fields(fields[16], &hooks, MaximumItems, error) || !Fields(fields[17], &value.statusLoggers, MaximumItems, error) ||
        !Fields(fields[18], &filters, MaximumItems, error) || !Fields(fields[19], &descriptors, MaximumItems, error) ||
        !Fields(fields[20], &value.unmodeledOptions, MaximumItems, error)) return Fail(error);
    for (const auto &force : forces) {
        unsigned i = 0; while (i < 28 && force != Forces[i]) ++i;
        if (i == 28) return Fail(error);
        value.forces.push_back(static_cast<Force>(i));
    }
    for (const auto &hook : hooks) {
        std::vector<std::string> pair;
        if (!Fields(hook, &pair, 2, error) || pair.size() != 2 || !Number(pair[0], 1, &number)) return Fail(error);
        Hook item; item.phase = static_cast<HookPhase>(number); item.command = pair[1]; value.hooks.push_back(std::move(item));
    }
    for (const auto &filter : filters) {
        std::vector<std::string> pair;
        if (!Fields(filter, &pair, 2, error) || pair.size() != 2 || !Number(pair[0], 1, &number)) return Fail(error);
        Filter item; item.kind = static_cast<FilterKind>(number); item.pattern = pair[1]; value.filters.push_back(std::move(item));
    }
    for (const auto &descriptor : descriptors) {
        if (!Number(descriptor, INT32_MAX, &number)) return Fail(error);
        value.statusDescriptors.push_back(number);
    }
    std::string canonical;
    if (!EncodeSettings(value, &canonical, error) || canonical != bytes) return Fail(error);
    *settings = std::move(value); return true;
}
bool EncodeRecord(const Record &record, std::string *bytes, Error *error) {
    if (!Token(record.semanticProfile) || !Path(record.executorPath) || !Digest(record.executorSHA256) ||
        !Digest(record.inputIdentity) || static_cast<unsigned>(record.role) > 4 || record.optionPrefix.empty()) return Fail(error);
    Budget budget; Writer prefix; std::string settings;
    if (!Strings(record.optionPrefix, &prefix, &budget, error, MaximumItems, true)) return false;
    if (SupportedProfile(record.semanticProfile)) {
        if (!record.unsupportedSettings.empty() || !EncodeSettings(record.settings, &settings, error)) return Fail(error);
    } else {
        std::string empty, actual;
        if (!EncodeSettings(Settings(), &empty, error) || !EncodeSettings(record.settings, &actual, error) || empty != actual ||
            record.unsupportedSettings.empty() || record.unsupportedSettings.size() > MaximumRecordBytes) return Fail(error);
        settings = record.unsupportedSettings;
    }
    Writer result(MaximumRecordBytes);
    for (const auto &field : {std::string("CYDIA-NATIVE-EFFECT-POLICY-1"), record.semanticProfile, record.executorPath,
        record.executorSHA256, record.inputIdentity, std::to_string(static_cast<unsigned>(record.role)), prefix.bytes, settings,
        std::string("asserted-native-effect-settings")}) result.Field(field);
    if (!result.valid) return Fail(error, Error::Limit);
    *bytes = std::move(result.bytes);
    return true;
}
bool InputShape(const Inputs &input, Budget *budget, Error *error) {
    if (!SupportedProfile(input.semanticProfile)) return Fail(error, Error::UnsupportedProfile);
    if (!Path(input.executorPath) || !Digest(input.executorSHA256) || !Digest(input.platformIdentity) ||
        !Path(input.dpkgRoot) || !Path(input.dpkgAdmin) || !SearchPath(input.executableSearchPath) ||
        !input.environment.initialized() || static_cast<unsigned>(input.role) > 4 || input.components.empty() || input.optionPrefix.empty()) return Fail(error);
    if (input.components.size() > MaximumInputs || input.configuration.size() > MaximumInputs) return Fail(error, Error::Limit);
    for (const auto *s : {&input.semanticProfile, &input.executorPath, &input.executorSHA256, &input.platformIdentity,
        &input.dpkgRoot, &input.dpkgAdmin, &input.executableSearchPath}) if (!budget->String(*s, error)) return false;
    Writer ignored;
    if (!Strings(input.optionPrefix, &ignored, budget, error, MaximumItems, true) || !Strings(input.environment.entries(), &ignored, budget, error)) return false;
    if (input.optionPrefix.size() < 2 || input.optionPrefix[0] != "--root=" + input.dpkgRoot ||
        input.optionPrefix[1] != "--admindir=" + input.dpkgAdmin) return Fail(error);
    if (!budget->Items(input.configuration.size() + input.components.size(), error)) return false;
    for (const auto &node : input.configuration) {
        if (static_cast<unsigned>(node.role) > 2 || static_cast<unsigned>(node.kind) > 1 || !Path(node.path) ||
            !budget->String(node.path, error) || !budget->String(node.sha256, error, true) || node.members.size() > MaximumInputs ||
            !budget->Items(node.members.size(), error)) return Fail(error);
        if (!node.present) { if (node.size || !node.sha256.empty() || !node.members.empty()) return Fail(error); }
        else if (node.kind == ContentKind::File) { if (!Digest(node.sha256) || !node.members.empty()) return Fail(error); }
        else if (node.size || !node.sha256.empty()) return Fail(error);
        for (const auto &member : node.members)
            if (!budget->String(member, error) || member == "." || member == ".." || member.find('/') != std::string::npos)
                return Fail(error);
    }
    for (const auto &component : input.components)
        if (!Path(component.path) || !Digest(component.sha256) || !budget->String(component.path, error) ||
            !budget->String(component.sha256, error)) return Fail(error);
    return true;
}
bool Hash(const std::string &bytes, const SHA256 &hash, std::string *output, Error *error) {
    if (!hash) return Fail(error, Error::DigestUnavailable);
    try {
        const auto digest = hash(bytes);
        if (!Digest(digest)) return Fail(error, Error::DigestFailed);
        *output = digest; return true;
    } catch (...) { return Fail(error, Error::DigestFailed); }
}
}
bool SupportedProfile(const std::string &profile) { return profile == Profile; }
bool EncodeRecords(const std::vector<Record> &records, std::string *bytes, Error *error) {
    if (error) *error = Error::None;
    if (!bytes) return Fail(error);
    bytes->clear();
    if (records.size() > MaximumRecords) return Fail(error, Error::Limit);
    std::vector<std::string> values; std::size_t total = 0;
    for (const auto &record : records) {
        std::string value; if (!EncodeRecord(record, &value, error)) return false;
        if (value.size() + 16 > MaximumBytes - total) return Fail(error, Error::Limit);
        total += value.size() + 16; values.push_back(std::move(value));
    }
    std::sort(values.begin(), values.end()); Writer list;
    for (const auto &value : values) list.Field(value);
    Writer result; result.Field("CYDIA-NATIVE-EFFECT-POLICIES-1"); result.Field(list.bytes);
    if (!list.valid || !result.valid) return Fail(error, Error::Limit);
    *bytes = std::move(result.bytes); if (error) *error = Error::None;
    return true;
}
bool DecodeRecords(const std::string &bytes, std::vector<Record> *records, Error *error) {
    if (error) *error = Error::None;
    if (!records) return Fail(error);
    records->clear();
    std::vector<std::string> fields, items;
    if (!Fields(bytes, &fields, 2, error) || fields.size() != 2 || fields[0] != "CYDIA-NATIVE-EFFECT-POLICIES-1" ||
        !Fields(fields[1], &items, MaximumRecords, error)) return Fail(error);
    std::vector<Record> result;
    for (const auto &item : items) {
        std::vector<std::string> f; std::uint32_t role; Record value;
        if (!Fields(item, &f, 9, error, MaximumRecordBytes) || f.size() != 9 || f[0] != "CYDIA-NATIVE-EFFECT-POLICY-1" ||
            f[8] != "asserted-native-effect-settings" || !Number(f[5], 4, &role)) return Fail(error);
        value.semanticProfile = f[1]; value.executorPath = f[2]; value.executorSHA256 = f[3]; value.inputIdentity = f[4];
        value.role = static_cast<Role>(role);
        if (!Fields(f[6], &value.optionPrefix, MaximumItems, error)) return false;
        if (SupportedProfile(value.semanticProfile)) { if (!DecodeSettings(f[7], &value.settings, error)) return false; }
        else value.unsupportedSettings = f[7];
        result.push_back(std::move(value));
    }
    std::string canonical;
    if (!EncodeRecords(result, &canonical, error) || canonical != bytes) return Fail(error);
    *records = std::move(result); if (error) *error = Error::None;
    return true;
}
bool EncodeInputs(const Inputs &input, std::string *bytes, Error *error) {
    if (error) *error = Error::None;
    if (!bytes) return Fail(error);
    bytes->clear(); Budget budget;
    if (!InputShape(input, &budget, error)) return false;
    std::map<std::string, const ContentInput *> nodes;
    std::map<std::string, std::string> components, environment;
    for (const auto &node : input.configuration) if (!nodes.emplace(node.path, &node).second) return Fail(error);
    for (const auto &component : input.components) if (!components.emplace(component.path, component.sha256).second) return Fail(error);
    for (const auto &node : nodes)
        if (node.second->role != InputRole::Configuration && components.count(node.first)) return Fail(error);
    const auto executor = components.find(input.executorPath);
    if (executor == components.end() || executor->second != input.executorSHA256) return Fail(error);
    for (const auto &entry : input.environment.entries()) {
        const auto equal = entry.find('='); environment.emplace(entry.substr(0, equal), entry.substr(equal + 1));
    }
    std::set<std::string> required = {"DEBIAN_FRONTEND", "DPKG_ADMINDIR", "DPKG_COLORS", "DPKG_DEBUG", "DPKG_FORCE", "DPKG_FRONTEND_LOCKED",
        "DPKG_NLS", "DPKG_PAGER", "DPKG_PATH_GROUP", "DPKG_PATH_PASSWD", "DPKG_ROOT", "DPKG_RUNNING_VERSION",
        "HOME", "LANG", "LANGUAGE", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES", "LC_NUMERIC", "LC_TIME",
        "LC_MONETARY", "LC_PAPER", "LC_NAME", "LC_ADDRESS", "LC_TELEPHONE", "LC_MEASUREMENT", "LC_IDENTIFICATION",
        "PAGER", "PATH", "SHELL", "TERM", "TMPDIR"};
    for (const auto &entry : environment)
        if (entry.first.compare(0, 3, "LC_") == 0 || entry.first.compare(0, 5, "DPKG_") == 0) required.insert(entry.first);
    Writer config, componentBytes, env, options;
    for (const auto &entry : nodes) {
        const auto &node = *entry.second;
        if (node.role != InputRole::Configuration) continue;
        auto members = node.members; std::sort(members.begin(), members.end());
        if (std::adjacent_find(members.begin(), members.end()) != members.end()) return Fail(error);
        Writer names; for (const auto &member : members) names.Field(member);
        Writer value; value.Field(node.path); value.Field(node.kind == ContentKind::File ? "file" : "directory");
        value.Field(node.present ? "1" : "0"); value.Field(std::to_string(node.size)); value.Field(node.sha256); value.Field(names.bytes);
        if (!names.valid || !value.valid) return Fail(error, Error::Limit);
        config.Field(value.bytes);
    }
    for (const auto &component : components) { componentBytes.Field(component.first); componentBytes.Field(component.second); }
    for (const auto &name : required) {
        const auto found = environment.find(name); env.Field(name); env.Field(found == environment.end() ? "0" : "1");
        env.Field(found == environment.end() ? "" : found->second);
    }
    for (const auto &option : input.optionPrefix) options.Field(option);
    Writer result;
    for (const auto &value : {std::string("CYDIA-NATIVE-EFFECT-INPUTS-1"), input.semanticProfile, input.executorPath,
        input.executorSHA256, input.platformIdentity, input.dpkgRoot, input.dpkgAdmin, input.executableSearchPath,
        std::to_string(static_cast<unsigned>(input.role)), config.bytes, componentBytes.bytes, env.bytes, options.bytes}) result.Field(value);
    if (!config.valid || !componentBytes.valid || !env.valid || !options.valid || !result.valid) return Fail(error, Error::Limit);
    *bytes = std::move(result.bytes); if (error) *error = Error::None;
    return true;
}
bool InputIdentity(const Inputs &input, const SHA256 &hash, std::string *identity, Error *error) {
    if (error) *error = Error::None;
    if (!identity) return Fail(error);
    identity->clear(); std::string bytes;
    if (!EncodeInputs(input, &bytes, error) || !Hash(bytes, hash, identity, error)) return false;
    if (error) *error = Error::None;
    return true;
}
bool EncodeLaunch(const Inputs &input, const std::vector<std::string> &argv, std::string *bytes, Error *error) {
    if (error) *error = Error::None;
    if (!bytes) return Fail(error);
    bytes->clear(); std::string inputs;
    if (!EncodeInputs(input, &inputs, error)) return false;
    if (argv.size() < input.optionPrefix.size() || !std::equal(input.optionPrefix.begin(), input.optionPrefix.end(), argv.begin())) return Fail(error);
    Writer arguments, env; Budget budget;
    if (!Strings(argv, &arguments, &budget, error, MaximumInputs, true) ||
        !Strings(input.environment.entries(), &env, &budget, error)) return false;
    Writer result; result.Field("CYDIA-NATIVE-EFFECT-LAUNCH-1"); result.Field(inputs); result.Field(env.bytes);
    result.Field(arguments.bytes); result.Field("stdin:0"); result.Field("status:3");
    if (!result.valid) return Fail(error, Error::Limit);
    *bytes = std::move(result.bytes);
    if (error) *error = Error::None;
    return true;
}
bool LaunchIdentity(const Inputs &input, const std::vector<std::string> &argv, const SHA256 &hash,
    std::string *identity, Error *error) {
    if (error) *error = Error::None;
    if (!identity) return Fail(error);
    identity->clear(); std::string bytes;
    if (!EncodeLaunch(input, argv, &bytes, error) || !Hash(bytes, hash, identity, error)) return false;
    if (error) *error = Error::None;
    return true;
}
Match MatchRecord(const std::vector<Record> &records, const Inputs &input, const SHA256 &hash) {
    Match result; std::string encoded, identity;
    if (!EncodeRecords(records, &encoded, &result.error)) return result;
    if (!InputIdentity(input, hash, &identity, &result.error)) {
        if (result.error == Error::UnsupportedProfile) result.status = Status::Unsupported;
        return result;
    }
    result.status = records.empty() ? Status::Missing : Status::InputMismatch;
    const Record *match = nullptr; bool unsupported = false;
    for (const auto &record : records) {
        if (record.executorPath != input.executorPath || record.executorSHA256 != input.executorSHA256 ||
            record.role != input.role || record.optionPrefix != input.optionPrefix) continue;
        if (!SupportedProfile(record.semanticProfile)) { unsupported = true; continue; }
        if (record.semanticProfile != input.semanticProfile || record.inputIdentity != identity) continue;
        if (match) { result.status = Status::Ambiguous; return result; }
        match = &record;
    }
    if (!match) { if (unsupported) result.status = Status::Unsupported; return result; }
    if (!match->settings.unmodeledOptions.empty()) { result.status = Status::Unsupported; return result; }
    std::string recordBytes, recordIdentity;
    if (!EncodeRecord(*match, &recordBytes, &result.error) || !Hash(recordBytes, hash, &recordIdentity, &result.error)) {
        result.status = Status::Invalid; return result;
    }
    result.status = Status::Matched; result.inputIdentity = identity; result.recordIdentity = recordIdentity;
    result.settings = std::make_shared<const Settings>(match->settings); return result;
}
}}}
