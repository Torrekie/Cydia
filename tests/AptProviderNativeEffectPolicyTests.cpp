/* Consumer fixtures only; digest callbacks are exact-preimage test doubles.
 * No native process, policy producer, filesystem authority or activation.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderNativeEffectPolicy.hpp"
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {
namespace N = CydiaAPT::Provider::NativeEffectPolicy;
const std::string A(64, 'a'), B(64, 'b'), C(64, 'c'), D(64, 'd');
void Require(bool value, const char *why) {
    if (value) return;
    std::cerr << "[native-effect-policy] " << why << '\n'; std::exit(1);
}
std::string F(const std::string &value) { return std::to_string(value.size()) + ':' + value + ','; }
std::string List(const std::vector<std::string> &values) {
    std::string result; for (const auto &value : values) result += F(value); return result;
}
std::vector<std::string> Split(const std::string &bytes) {
    std::vector<std::string> result; std::size_t at = 0;
    while (at < bytes.size()) {
        const auto colon = bytes.find(':', at); Require(colon != std::string::npos, "test fixture framing has a length");
        const auto count = static_cast<std::size_t>(std::stoul(bytes.substr(at, colon - at)));
        Require(count < bytes.size() - colon && bytes[colon + count + 1] == ',', "test fixture framing has a delimiter");
        result.push_back(bytes.substr(colon + 1, count)); at = colon + count + 2;
    }
    return result;
}
N::ContentInput File(const std::string &path, const std::string &hash, N::InputRole role = N::InputRole::Configuration) {
    N::ContentInput result; result.path = path; result.present = true; result.size = 7; result.sha256 = hash; result.role = role; return result;
}
N::Inputs Input() {
    N::Inputs result; result.semanticProfile = "dpkg-1.23.7-effects-1";
    result.executorPath = "/usr/bin/dpkg"; result.executorSHA256 = A; result.platformIdentity = B;
    result.dpkgRoot = "/"; result.dpkgAdmin = "/var/lib/dpkg"; result.executableSearchPath = "/usr/bin:/bin";
    N::ComponentInput component; component.path = result.executorPath; component.sha256 = A; result.components.push_back(component);
    component.path = "/usr/lib/libdpkg.dylib"; component.sha256 = C; result.components.push_back(component);
    result.configuration.push_back(File("/etc/dpkg/dpkg.cfg", D));
    N::ContentInput absent; absent.path = "/.dpkg.cfg"; result.configuration.push_back(absent);
    N::ContentInput directory; directory.path = "/etc/dpkg/dpkg.cfg.d"; directory.kind = N::ContentKind::Directory;
    directory.present = true; directory.members = {"20-local", "10-default"}; result.configuration.push_back(directory);
    result.configuration.push_back(File("/share/cydia/native-dpkg.conf", A, N::InputRole::Declaration));
    result.configuration.push_back(File("/share/cydia/policy-output", B, N::InputRole::PolicyOutput));
    Require(CydiaRuntime::NativeLaunchEnvironment::FromEntries({"HOME=/", "PATH=/usr/bin:/bin", "TMPDIR=/tmp",
        "DPKG_FRONTEND_LOCKED=1", "LC_MESSAGES=zh_CN.UTF-8", "PRIVATE_NOTE=ignored-by-policy"}, &result.environment), "construct immutable environment");
    result.optionPrefix = {"--root=/", "--admindir=/var/lib/dpkg", "--no-triggers", "--status-fd=3", "--unpack"}; return result;
}
std::string ExpectedInput() {
    const std::vector<std::string> names = {"DEBIAN_FRONTEND", "DPKG_ADMINDIR", "DPKG_COLORS", "DPKG_DEBUG", "DPKG_FORCE", "DPKG_FRONTEND_LOCKED",
        "DPKG_NLS", "DPKG_PAGER", "DPKG_PATH_GROUP", "DPKG_PATH_PASSWD", "DPKG_ROOT", "DPKG_RUNNING_VERSION",
        "HOME", "LANG", "LANGUAGE", "LC_ADDRESS", "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_IDENTIFICATION", "LC_MEASUREMENT",
        "LC_MESSAGES", "LC_MONETARY", "LC_NAME", "LC_NUMERIC", "LC_PAPER", "LC_TELEPHONE", "LC_TIME", "PAGER", "PATH", "SHELL", "TERM", "TMPDIR"};
    std::string environment;
    for (const auto &name : names) {
        const bool present = name == "DPKG_FRONTEND_LOCKED" || name == "HOME" || name == "LC_MESSAGES" || name == "PATH" || name == "TMPDIR";
        const auto value = name == "DPKG_FRONTEND_LOCKED" ? "1" : name == "HOME" ? "/" : name == "LC_MESSAGES" ? "zh_CN.UTF-8" :
            name == "PATH" ? "/usr/bin:/bin" : name == "TMPDIR" ? "/tmp" : "";
        environment += F(name) + F(present ? "1" : "0") + F(value);
    }
    const auto config = List({List({"/.dpkg.cfg", "file", "0", "0", "", ""}),
        List({"/etc/dpkg/dpkg.cfg", "file", "1", "7", D, ""}),
        List({"/etc/dpkg/dpkg.cfg.d", "directory", "1", "0", "", List({"10-default", "20-local"})})});
    return List({"CYDIA-NATIVE-EFFECT-INPUTS-1", "dpkg-1.23.7-effects-1", "/usr/bin/dpkg", A, B, "/", "/var/lib/dpkg",
        "/usr/bin:/bin", "0", config, List({"/usr/bin/dpkg", A, "/usr/lib/libdpkg.dylib", C}), environment,
        List({"--root=/", "--admindir=/var/lib/dpkg", "--no-triggers", "--status-fd=3", "--unpack"})});
}
N::Record Record() {
    const auto input = Input(); N::Record record;
    record.semanticProfile = input.semanticProfile; record.executorPath = input.executorPath; record.executorSHA256 = input.executorSHA256;
    record.inputIdentity = A; record.role = input.role; record.optionPrefix = input.optionPrefix;
    record.settings.autoDeconfigure = true; record.settings.abortAfter = 50;
    record.settings.triggers = N::TriggerMode::Disabled;
    record.settings.forces = {N::Force::Downgrade, N::Force::SecurityMAC};
    N::Hook hook; hook.command = "first hook"; record.settings.hooks.push_back(hook);
    hook.phase = N::HookPhase::PostInvoke; hook.command = "second hook"; record.settings.hooks.push_back(hook);
    N::Filter filter; filter.kind = N::FilterKind::Exclude; filter.pattern = "/usr/share/*"; record.settings.filters.push_back(filter);
    filter.kind = N::FilterKind::Include; filter.pattern = "/usr/share/keep"; record.settings.filters.push_back(filter); return record;
}
std::string ExpectedRecord() {
    const auto input = Input();
    const auto settings = List({"1", "0", "0", "0", "0", "0", "0", "0", "0", "2", "50", "0", "0", "", List({"downgrade", "security-mac"}), "",
        List({List({"0", "first hook"}), List({"1", "second hook"})}), "",
        List({List({"1", "/usr/share/*"}), List({"0", "/usr/share/keep"})}), "", ""});
    return List({"CYDIA-NATIVE-EFFECT-POLICY-1", input.semanticProfile, input.executorPath, A, A, "0",
        List(input.optionPrefix), settings, "asserted-native-effect-settings"});
}
N::SHA256 Digests() {
    // Test double checks exact complete domain-separated preimages; production
    // must use real parent-owned SHA256. This does not test cryptography.
    return [](const std::string &bytes) {
        if (bytes == ExpectedInput()) return A;
        if (bytes == ExpectedRecord()) return B;
        throw std::runtime_error("unplanned identity preimage");
    };
}
void ExactFramingAndMatch() {
    const auto input = Input(); const auto record = Record(); std::string bytes, identity; N::Error error;
    Require(N::EncodeInputs(input, &bytes, &error) && error == N::Error::None && bytes == ExpectedInput(),
        "lookup preimage exactly binds content, required environment tuples, selected paths and ordered options");
    Require(N::InputIdentity(input, Digests(), &identity) && identity == A, "identity callback receives the exact input preimage");
    Require(N::EncodeRecords({record}, &bytes) && bytes == List({"CYDIA-NATIVE-EFFECT-POLICIES-1", List({ExpectedRecord()})}),
        "typed asserted policy framing is exact and domain separated");
    std::vector<N::Record> decoded;
    Require(N::DecodeRecords(bytes, &decoded) && decoded.size() == 1 && decoded[0].settings.autoDeconfigure &&
        decoded[0].settings.forces == record.settings.forces && decoded[0].settings.filters[0].kind == N::FilterKind::Exclude,
        "closed settings and ordered filters survive canonical decode");
    const auto result = N::MatchRecord(decoded, input, Digests());
    Require(result.status == N::Status::Matched && result.error == N::Error::None && result.inputIdentity == A &&
        result.recordIdentity == B && result.settings && result.settings->autoDeconfigure,
        "matched returns the asserted policy, including unsafe flags, without claiming authorization");
    Require(N::MatchRecord({}, input, Digests()).status == N::Status::Missing, "graph-v1 absence is a missing optional policy");
    auto stale = record; stale.inputIdentity = C;
    auto failed = N::MatchRecord({stale}, input, Digests());
    Require(failed.status == N::Status::InputMismatch && !failed.settings && failed.recordIdentity.empty() && failed.inputIdentity.empty(),
        "stale declaration publishes no partial matched policy");
    Require(N::MatchRecord({record, record}, input, Digests()).status == N::Status::Ambiguous,
        "duplicate matching records cannot silently choose an assertion");
}
void ContentAndProjection() {
    const auto original = Input(); std::string baseline, bytes;
    Require(N::EncodeInputs(original, &baseline), "encode baseline lookup");
    auto same = original;
    std::reverse(same.configuration.begin(), same.configuration.end()); std::reverse(same.components.begin(), same.components.end());
    Require(N::EncodeInputs(same, &bytes) && bytes == baseline, "capture traversal order is not native read order or lookup identity");
    same = original; same.configuration[3].sha256 = D; same.configuration[3].size = 800;
    same.configuration[4].sha256 = C; same.configuration[4].size = 900;
    Require(N::EncodeInputs(same, &bytes) && bytes == baseline, "declaration and policy-output contents never create circular identity inputs");
    std::vector<N::Inputs> changes;
    auto changed = original; changed.configuration[0].sha256 = A; changes.push_back(changed);
    changed = original; changed.configuration[1] = File("/.dpkg.cfg", A); changes.push_back(changed);
    changed = original; changed.configuration[2].members.push_back("30-added"); changes.push_back(changed);
    changed = original; changed.components[1].sha256 = D; changes.push_back(changed);
    changed = original; changed.platformIdentity = C; changes.push_back(changed);
    changed = original; changed.role = N::Role::Configure; changes.push_back(changed);
    changed = original; std::swap(changed.optionPrefix[2], changed.optionPrefix[3]); changes.push_back(changed);
    changed = original; Require(changed.environment.Overlay({"DPKG_FORCE="}, {}, &changed.environment), "add empty force value"); changes.push_back(changed);
    changed = original; Require(changed.environment.Overlay({"LC_VENDOR_SETTING=exact"}, {}, &changed.environment), "add unknown locale variable"); changes.push_back(changed);
    changed = original; Require(changed.environment.Overlay({"DPKG_DEBUG=1"}, {}, &changed.environment), "add native debug environment"); changes.push_back(changed);
    changed = original; Require(changed.environment.Overlay({"DPKG_VENDOR_SETTING=exact"}, {}, &changed.environment), "add unknown native variable"); changes.push_back(changed);
    for (const auto &value : changes) Require(N::EncodeInputs(value, &bytes) && bytes != baseline,
        "content, absence, membership, component, role, option-order or relevant env changes invalidate lookup");
    same = original; Require(same.environment.Overlay({"PRIVATE_NOTE=changed"}, {}, &same.environment), "change unrelated launch-only value");
    Require(N::EncodeInputs(same, &bytes) && bytes == baseline, "record cannot select env names, but unrelated values belong to full launch binding");
    auto argv = original.optionPrefix; argv.push_back("/private/staged/one.deb"); std::string launch, other;
    Require(N::EncodeLaunch(original, argv, &launch) && N::EncodeLaunch(same, argv, &other) && launch != other,
        "full environment changes always invalidate per-child identity");
    const auto expected = List({"CYDIA-NATIVE-EFFECT-LAUNCH-1", ExpectedInput(), List(original.environment.entries()), List(argv), "stdin:0", "status:3"});
    Require(launch == expected, "launch preimage binds exact argv, complete environment and fixed child descriptor roles");
    std::string identity;
    Require(N::LaunchIdentity(original, argv, [&](const std::string &s) { Require(s == expected, "digest receives exact launch frame"); return D; }, &identity) && identity == D,
        "launch hashing uses the parent callback");
    argv.back() = "/private/staged/two.deb";
    Require(N::EncodeLaunch(original, argv, &other) && launch != other, "different exact retained operands cannot reuse a child binding");
    argv[0] = "--root=/other";
    Require(!N::EncodeLaunch(original, argv, &other) && other.empty(), "launch cannot silently rebind its matched option prefix");
}
void UnsupportedAndAtomicCodec() {
    auto future = Record(); future.semanticProfile = "dpkg-future-effects-2"; future.settings = N::Settings();
    future.unsupportedSettings = std::string("future\0settings", 15);
    std::string encoded; std::vector<N::Record> decoded;
    Require(N::EncodeRecords({future}, &encoded) && N::DecodeRecords(encoded, &decoded) && decoded[0].unsupportedSettings == future.unsupportedSettings,
        "unknown profile bytes can be retained without interpreting future settings");
    const auto result = N::MatchRecord(decoded, Input(), Digests());
    Require(result.status == N::Status::Unsupported && !result.settings && result.inputIdentity.empty(),
        "unknown semantic profile never becomes a usable policy");
    const auto record = Record(); Require(N::EncodeRecords({record}, &encoded), "encode truncation fixture");
    for (std::size_t i = 0; i < encoded.size(); ++i) {
        decoded = {record};
        Require(!N::DecodeRecords(encoded.substr(0, i), &decoded) && decoded.empty(), "truncated nested framing publishes no partial records");
    }
    decoded = {record}; Require(!N::DecodeRecords("0" + encoded, &decoded) && decoded.empty(), "noncanonical leading-zero length refuses atomically");
    auto f = Split(ExpectedRecord()); auto settings = Split(f[7]); settings[0] = "2"; f[7] = List(settings);
    Require(!N::DecodeRecords(List({"CYDIA-NATIVE-EFFECT-POLICIES-1", List({List(f)})}), &decoded) && decoded.empty(),
        "closed bool settings cannot accept unrecognized numeric values");
    settings = Split(Split(ExpectedRecord())[7]); settings[14] = List({"all"}); f[7] = List(settings);
    Require(!N::DecodeRecords(List({"CYDIA-NATIVE-EFFECT-POLICIES-1", List({List(f)})}), &decoded),
        "force all shorthand is not falsely interpreted as a complete resolved flag set");
    auto second = record; second.inputIdentity = D; std::string ordered, reverse;
    Require(N::EncodeRecords({record, second}, &ordered) && N::EncodeRecords({second, record}, &reverse) && ordered == reverse,
        "record containers have a canonical order independent of insertion order");
    auto outer = Split(ordered); auto records = Split(outer[1]); std::reverse(records.begin(), records.end()); outer[1] = List(records);
    Require(!N::DecodeRecords(List(outer), &decoded) && decoded.empty(), "noncanonical record order refuses rather than normalizing supplied bytes");
}
void InvalidInputsAndBounds() {
    std::string bytes = "stale"; N::Error error;
    auto input = Input(); input.optionPrefix[0] = "--root=/elsewhere";
    Require(!N::EncodeInputs(input, &bytes) && bytes.empty(), "lookup requires actual canonical selected root/admin prefix");
    input = Input(); input.environment = CydiaRuntime::NativeLaunchEnvironment();
    Require(!N::EncodeInputs(input, &bytes) && bytes.empty(), "default environment is not an empty or inherited environment");
    input = Input(); input.components[0].sha256 = C;
    Require(!N::EncodeInputs(input, &bytes), "executor must be in exact observed component set");
    input = Input(); input.configuration.push_back(input.configuration.back()); input.configuration.back().role = N::InputRole::Configuration;
    Require(!N::EncodeInputs(input, &bytes), "declaration/output paths cannot also be native configuration inputs");
    input = Input(); input.components[1].path = input.configuration[3].path;
    Require(!N::EncodeInputs(input, &bytes), "excluded declaration cannot re-enter its lookup identity as a component hash");
    input = Input(); input.configuration[2].members.push_back("10-default");
    Require(!N::EncodeInputs(input, &bytes), "duplicate directory members do not become a canonical membership assertion");
    input = Input(); input.configuration[1].sha256 = A;
    Require(!N::EncodeInputs(input, &bytes), "absent file cannot carry invented file contents");
    input = Input(); input.configuration[0].path = "/etc/../dpkg.cfg";
    Require(!N::EncodeInputs(input, &bytes), "content inputs require unambiguous absolute paths");
    auto record = Record(); record.optionPrefix[0].assign(N::MaximumValueBytes + 1, 'x');
    Require(!N::EncodeRecords({record}, &bytes, &error) && bytes.empty() && error == N::Error::Limit,
        "oversized value refuses without publishing a record");
    Require(!N::EncodeRecords(std::vector<N::Record>(N::MaximumRecords + 1), &bytes, &error) && error == N::Error::Limit,
        "record count is bounded before record traversal");
    std::vector<N::Record> decoded = {Record()};
    Require(!N::DecodeRecords(std::string(N::MaximumBytes + 1, 'x'), &decoded, &error) && error == N::Error::Limit && decoded.empty(),
        "maximum declaration bytes are checked before parsing or partial allocation");
    record = Record(); record.settings.forces = {N::Force::Downgrade, N::Force::Downgrade};
    Require(!N::EncodeRecords({record}, &bytes), "duplicate force entries cannot become multiple meanings");
    record.settings.forces = {static_cast<N::Force>(99)};
    Require(!N::EncodeRecords({record}, &bytes), "unrecognized force enum refuses in a known profile");
    record = Record(); record.settings.abortAfter = static_cast<std::uint32_t>(INT32_MAX);
    Require(N::EncodeRecords({record}, &bytes) && N::DecodeRecords(bytes, &decoded) && decoded[0].settings.abortAfter == INT32_MAX,
        "maximum native signed error limit survives exact decoding");
    record.settings.abortAfter += 1;
    Require(!N::EncodeRecords({record}, &bytes) && bytes.empty(), "native abort-after cannot silently wrap into a negative int");
    input = Input(); input.optionPrefix.resize(N::MaximumItems + 1, "--no-triggers");
    Require(!N::EncodeInputs(input, &bytes, &error) && error == N::Error::Limit && bytes.empty(), "ordered options have an explicit count bound");
}
void EmptyValuesAndNul() {
    auto record = Record(); record.settings.hooks[0].command.clear(); record.settings.filters[0].pattern.clear();
    record.settings.statusLoggers.push_back(""); record.optionPrefix.push_back("--pre-invoke"); record.optionPrefix.push_back("");
    std::string bytes; std::vector<N::Record> decoded;
    Require(N::EncodeRecords({record}, &bytes) && N::DecodeRecords(bytes, &decoded) &&
        decoded[0].settings.hooks[0].command.empty() && decoded[0].settings.filters[0].pattern.empty() &&
        decoded[0].settings.statusLoggers.size() == 1 && decoded[0].settings.statusLoggers[0].empty() && decoded[0].optionPrefix.back().empty(),
        "native empty hook/filter/logger values remain values rather than absent entries");
    auto input = Input(); input.optionPrefix = record.optionPrefix;
    auto argv = input.optionPrefix; argv.push_back("/private/staged/one.deb");
    Require(N::EncodeLaunch(input, argv, &bytes), "exact empty option arguments are retained in the launch binding");
    input.optionPrefix.back() = std::string("a\0b", 3);
    Require(!N::EncodeInputs(input, &bytes) && bytes.empty(), "embedded NUL never becomes a truncated native argument");
}
void NativeResolvedState() {
    const auto baseline = Record(); std::string automatic, enabled, disabled; std::vector<N::Record> decoded;
    auto record = baseline;
    record.settings.triggers = N::TriggerMode::Automatic;
    Require(N::EncodeRecords({record}, &automatic), "native automatic trigger state has an explicit representation");
    record.settings.triggers = N::TriggerMode::Enabled;
    Require(N::EncodeRecords({record}, &enabled), "explicit enabled trigger state encodes");
    record.settings.triggers = N::TriggerMode::Disabled;
    Require(N::EncodeRecords({record}, &disabled) && automatic != enabled && enabled != disabled && disabled != automatic &&
        N::DecodeRecords(disabled, &decoded) && decoded[0].settings.triggers == N::TriggerMode::Disabled,
        "native automatic, enabled and disabled triggers cannot collapse into a bool");
    record.settings.pending = true; record.settings.noDebsig = true; record.settings.robot = true; record.settings.noPager = true;
    record.settings.debugMask = 1; record.settings.logFilePresent = true; record.settings.logFile = "/var/log/dpkg.log";
    record.settings.statusDescriptors = {3, 4, 3};
    Require(N::EncodeRecords({record}, &enabled) && N::DecodeRecords(enabled, &decoded) && decoded[0].settings.pending &&
        decoded[0].settings.noDebsig && decoded[0].settings.robot && decoded[0].settings.noPager && decoded[0].settings.debugMask == 1 &&
        decoded[0].settings.logFilePresent && decoded[0].settings.logFile == "/var/log/dpkg.log" &&
        decoded[0].settings.statusDescriptors == record.settings.statusDescriptors,
        "resolved mutation scope, signature checking and ordered status/output options are retained");
    record = baseline; record.settings.triggers = N::TriggerMode::Automatic; record.settings.logFilePresent = true;
    Require(N::EncodeRecords({record}, &enabled) && enabled != automatic && N::DecodeRecords(enabled, &decoded) &&
        decoded[0].settings.logFilePresent && decoded[0].settings.logFile.empty(), "explicit empty log path differs from null log output");
    record = baseline; record.settings.unmodeledOptions = {"vendor-implicit-effect"};
    Require(N::EncodeRecords({record}, &enabled) && N::DecodeRecords(enabled, &decoded), "unmodeled effect state remains visible in a bounded record");
    const auto result = N::MatchRecord(decoded, Input(), Digests());
    Require(result.status == N::Status::Unsupported && !result.settings && result.inputIdentity.empty() && result.recordIdentity.empty(),
        "unknown effective settings never become a matched usable policy even when input identity matches");
}
void DigestFailuresAndOrder() {
    const auto input = Input(); std::string identity = "stale"; N::Error error;
    Require(!N::InputIdentity(input, {}, &identity, &error) && error == N::Error::DigestUnavailable && identity.empty(), "missing digest callback cannot fake an identity");
    for (const auto &bad : {std::string(), std::string(64, 'A'), std::string(63, 'a'), std::string(64, 'g')}) {
        identity = "stale";
        Require(!N::InputIdentity(input, [&](const std::string &) { return bad; }, &identity, &error) &&
            error == N::Error::DigestFailed && identity.empty(), "invalid digest outputs refuse atomically");
    }
    auto failed = N::MatchRecord({Record()}, input, [](const std::string &) -> std::string { throw std::runtime_error("failure"); });
    Require(failed.status == N::Status::Invalid && failed.error == N::Error::DigestFailed && !failed.settings && failed.inputIdentity.empty(),
        "throwing parent digest cannot expose a partially matched policy");
    unsigned calls = 0;
    failed = N::MatchRecord({Record()}, input, [&](const std::string &value) {
        ++calls; if (calls == 1) { Require(value == ExpectedInput(), "input hash is first"); return A; }
        Require(value == ExpectedRecord(), "record hash is second"); return std::string("invalid");
    });
    Require(calls == 2 && failed.status == N::Status::Invalid && failed.inputIdentity.empty() && !failed.settings,
        "record digest failure after input match remains fully atomic");
    auto first = Record(), second = first; std::swap(second.settings.filters[0], second.settings.filters[1]);
    std::string a, b; Require(N::EncodeRecords({first}, &a) && N::EncodeRecords({second}, &b) && a != b,
        "ordered include/exclude settings are not reduced or sorted");
    std::swap(second.settings.hooks[0], second.settings.hooks[1]);
    Require(N::EncodeRecords({second}, &b) && a != b, "hook execution order remains part of the assertion");
}
}
int main() {
    ExactFramingAndMatch(); ContentAndProjection(); UnsupportedAndAtomicCodec(); InvalidInputsAndBounds();
    EmptyValuesAndNul(); NativeResolvedState(); DigestFailuresAndOrder();
    std::cout << "[native-effect-policy] PASS: bounded canonical consumer, content bindings, unsupported profiles and explicit launch identity\n";
}
