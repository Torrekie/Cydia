/* Protected declaration consumer values, not native execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderNativeEffectPolicy_HPP
#define Cydia_AptProviderNativeEffectPolicy_HPP
#include "Cydia/NativeLaunchEnvironment.hpp"
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace CydiaAPT { namespace Provider { namespace NativeEffectPolicy {
constexpr std::size_t MaximumBytes = 1024 * 1024;
constexpr std::size_t MaximumRecords = 64;
constexpr std::size_t MaximumRecordBytes = 64 * 1024;
constexpr std::size_t MaximumValueBytes = 64 * 1024;
constexpr std::size_t MaximumItems = 256;
constexpr std::size_t MaximumInputs = 4096;
enum class Error { None, Invalid, Limit, UnsupportedProfile, DigestUnavailable, DigestFailed };
enum class Role { Unpack, Configure, Remove, Purge, TriggerDrain };
// Native f_triggers has three states, with action-sensitive default behavior.
enum class TriggerMode { Automatic, Enabled, Disabled };
// Closed vocabulary from dpkg 1.23.7 src/common/force.{c,h}. These are wire
// identifiers, not native bit flags; "all" is an input shorthand, not a flag.
enum class Force {
    Architecture, BadPath, BadVerify, BadVersion, Breaks, Confask, Confdef,
    Confmiss, Confnew, Confold, ConfigureAny, Conflicts, Depends, DependsVersion,
    Downgrade, Hold, NotRoot, Overwrite, OverwriteDir, OverwriteDiverted,
    RemoveEssential, RemoveReinstreq, ScriptChrootless, UnsafeIO,
    StatoverrideAdd, StatoverrideRemove, SecurityMAC, RemoveProtected
};
enum class HookPhase { PreInvoke, PostInvoke };
struct Hook { HookPhase phase = HookPhase::PreInvoke; std::string command; };
enum class FilterKind { Include, Exclude };
struct Filter { FilterKind kind = FilterKind::Include; std::string pattern; };
struct Settings {
    // Resolved assertions for mutation-role options in native main.c and
    // options.c. Initial C++ values are inert DTO defaults, not assertions
    // about any compiled binary or its effective configuration.
    bool autoDeconfigure = false, noAct = false, recursive = false;
    bool selectedOnly = false, skipSameVersion = false;
    bool pending = false, noDebsig = false, robot = false, noPager = false;
    TriggerMode triggers = TriggerMode::Automatic;
    // dpkg_options_parse_arg_int accepts 0..INT32_MAX for this profile.
    std::uint32_t abortAfter = 0;
    std::uint32_t debugMask = 0;
    bool logFilePresent = false;
    std::string logFile; // Null/absent differs from an explicit empty value.
    // Complete enabled subset of the profile's closed vocabulary. Sorted,
    // unique enum values; disabled flags are explicit by omission from this
    // complete set. No compiled or environment default is guessed here.
    std::vector<Force> forces;
    std::vector<std::string> ignoreDepends, statusLoggers;
    std::vector<Hook> hooks; // Order retained, including empty/repeated commands.
    std::vector<Filter> filters; // Last-match order is never sorted/deduplicated.
    std::vector<std::uint32_t> statusDescriptors; // Native insertion order, including duplicates.
    // Supported mutation-role main globals/options are represented above;
    // a producer which cannot express an effective setting must retain it
    // here or use an unsupported profile. Nonempty always matches Unsupported.
    std::vector<std::string> unmodeledOptions;
};
struct Record {
    std::string semanticProfile, executorPath, executorSHA256, inputIdentity;
    Role role = Role::Unpack;
    std::vector<std::string> optionPrefix;
    Settings settings;
    // Only an unknown semantic profile uses this bounded uninterpreted field.
    // It can round-trip but can never produce a Matched result.
    std::string unsupportedSettings;
};
enum class InputRole { Configuration, Declaration, PolicyOutput };
enum class ContentKind { File, Directory };
struct ContentInput {
    InputRole role = InputRole::Configuration;
    ContentKind kind = ContentKind::File;
    std::string path;
    bool present = false;
    std::uint64_t size = 0;
    std::string sha256;
    std::vector<std::string> members;
};
struct ComponentInput { std::string path, sha256; };
struct Inputs {
    std::string semanticProfile, executorPath, executorSHA256, platformIdentity;
    std::string dpkgRoot, dpkgAdmin, executableSearchPath;
    std::vector<ContentInput> configuration;
    std::vector<ComponentInput> components;
    CydiaRuntime::NativeLaunchEnvironment environment;
    Role role = Role::Unpack;
    // Exact ordered prefix AFTER parent BindDpkgArguments and final status-fd
    // preparation. Do not derive this from an unordered option map or a worker
    // policy assertion. The consumer does not interpret or reduce these tokens.
    std::vector<std::string> optionPrefix;
};
// Parent supplies real SHA256, not a worker implementation. Missing callback,
// exceptions or a non-lowercase-64-hex result refuse atomically. Public values
// and callback shape never establish filesystem/loader/policy provenance.
using SHA256 = std::function<std::string(const std::string &)>;
bool SupportedProfile(const std::string &);
// Canonical netstrings; record order is canonical encoded-byte order. Duplicate
// records may decode but make an otherwise matching lookup Ambiguous. Unknown
// profile settings remain opaque. No graph-v1 parsing or activation occurs.
bool EncodeRecords(const std::vector<Record> &, std::string *, Error * = nullptr);
bool DecodeRecords(const std::string &, std::vector<Record> *, Error * = nullptr);
// Content-only preimage: no declaration/self-output bytes or local stat/group
// fields. Declaration/PolicyOutput nodes are excluded, but may not also appear
// as native configuration. Caller must prove these roles and input completeness;
// an actually native-read file cannot be excluded by assigning a different role.
// Directory membership is sorted bytewise as content, NOT claimed native read
// order. Distributor semantics must account for locale/runtime-dependent order.
// Required environment names have explicit present/value tuples. Unknown LC_*
// and DPKG_* variables are included too. A record cannot choose a smaller subset.
bool EncodeInputs(const Inputs &, std::string *, Error * = nullptr);
bool InputIdentity(const Inputs &, const SHA256 &, std::string *, Error * = nullptr);
// Per-child binding includes the complete frozen environment and exact argv,
// including operands, plus fixed child stdin=0/status=3 roles. argv must start
// with optionPrefix; it excludes argv[0], whose executable is bound separately.
// Input names/hashes are not permission to run that argv;
// the parent separately verifies reviewed operands and actual descriptor setup.
bool EncodeLaunch(const Inputs &, const std::vector<std::string> &argv, std::string *, Error * = nullptr);
bool LaunchIdentity(const Inputs &, const std::vector<std::string> &argv, const SHA256 &, std::string *, Error * = nullptr);
enum class Status { Missing, Unsupported, InputMismatch, Ambiguous, Matched, Invalid };
struct Match {
    Status status = Status::Invalid;
    Error error = Error::None;
    std::string inputIdentity, recordIdentity;
    std::shared_ptr<const Settings> settings; // Present only for Matched.
};
// Matched means an externally asserted policy binds to the supplied content
// inputs. It is NOT native-policy truth, graph authority, safe options, trigger
// readiness, deconfiguration permission or a replacement for existing gates.
Match MatchRecord(const std::vector<Record> &, const Inputs &, const SHA256 &);
}}}
#endif
