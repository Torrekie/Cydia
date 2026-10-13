/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/ExtendedState.hpp"
#include <algorithm>
#include <climits>
#include <set>
#include <sstream>

namespace CydiaAPT { namespace Provider {
namespace {
const std::size_t MaximumStateBytes = 32 * 1024 * 1024;
bool Fail(std::string *error, const char *code) {
    if (error) *error = code;
    return false;
}
std::string Key(const ExecutionPackage &package) { return package.package + ':' + package.architecture; }
bool SamePackage(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool Version(const std::string &value) {
    return !value.empty() && value.size() <= 1024 && value.find_first_not_of(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+:~-") == std::string::npos;
}
// Equality only, following dpkg's lib/dpkg/version.c verrevcmp and
// lib/dpkg/parsehelp.c parseversion. Numeric runs ignore leading zeroes;
// an absent revision equals revision 0. Do not reject a synchronized sibling
// merely because its version uses another equivalent spelling.
bool SameVersionPart(const std::string &a, const std::string &b) {
    const auto digit = [](char c) { return c >= '0' && c <= '9'; };
    std::size_t i = 0, j = 0;
    while (i < a.size() || j < b.size()) {
        while ((i < a.size() && !digit(a[i])) || (j < b.size() && !digit(b[j]))) {
            if (i == a.size() || j == b.size() || a[i] != b[j]) return false;
            ++i; ++j;
        }
        while (i < a.size() && a[i] == '0') ++i;
        while (j < b.size() && b[j] == '0') ++j;
        while (i < a.size() && j < b.size() && digit(a[i]) && digit(b[j])) {
            if (a[i] != b[j]) return false;
            ++i; ++j;
        }
        if ((i < a.size() && digit(a[i])) || (j < b.size() && digit(b[j]))) return false;
    }
    return true;
}
bool SplitVersion(const std::string &value, unsigned *epoch, std::string *upstream, std::string *revision) {
    if (!Version(value)) return false;
    *epoch = 0;
    const auto colon = value.find(':');
    if (colon != std::string::npos) {
        if (!colon) return false;
        std::size_t begin = (value[0] == '+' || value[0] == '-') ? 1 : 0;
        if (begin == colon) return false;
        for (std::size_t i = begin; i < colon; ++i) {
            if (value[i] < '0' || value[i] > '9' || *epoch > (INT_MAX - unsigned(value[i] - '0')) / 10)
                return false;
            *epoch = *epoch * 10 + unsigned(value[i] - '0');
        }
        if (value[0] == '-' && *epoch != 0) return false;
    }
    *upstream = value.substr(colon == std::string::npos ? 0 : colon + 1);
    const auto hyphen = upstream->rfind('-');
    *revision = hyphen == std::string::npos ? "" : upstream->substr(hyphen + 1);
    if (hyphen != std::string::npos) {
        if (revision->empty()) return false;
        upstream->resize(hyphen);
    }
    return !upstream->empty();
}
bool SameDpkgVersion(const std::string &a, const std::string &b) {
    if (a == b) return Version(a);
    unsigned aEpoch, bEpoch; std::string aUpstream, bUpstream, aRevision, bRevision;
    return SplitVersion(a, &aEpoch, &aUpstream, &aRevision) && SplitVersion(b, &bEpoch, &bUpstream, &bRevision) &&
        aEpoch == bEpoch && SameVersionPart(aUpstream, bUpstream) && SameVersionPart(aRevision, bRevision);
}
bool Architecture(const std::string &value) {
    return CydiaRuntime::ValidArchitectureName(value) && value != "any" && value != "native";
}
bool Visible(const std::string &value) {
    if (value.empty() || value.size() > 4096) return false;
    for (const unsigned char c : value) if (c <= 32 || c >= 127) return false;
    return true;
}
bool Split(const std::string &bytes, char separator, std::vector<std::string> *fields) {
    std::size_t start = 0;
    while (true) {
        const auto end = bytes.find(separator, start);
        fields->push_back(bytes.substr(start, end == std::string::npos ? end : end - start));
        if (end == std::string::npos) return true;
        if (fields->size() > 16) return false;
        start = end + 1;
    }
}
bool TriggerList(const std::string &bytes, bool awaited, std::vector<std::string> *values) {
    std::istringstream input(bytes); std::string token;
    while (input >> token) {
        if (!Visible(token) || values->size() >= 4096) return false;
        if (awaited && !ParsePackageSelector(token).valid()) return false;
        values->push_back(token);
    }
    std::sort(values->begin(), values->end());
    return std::adjacent_find(values->begin(), values->end()) == values->end();
}
bool AwaitedSelector(const std::string &value) {
    const auto selector = ParsePackageSelector(value);
    return selector.valid() && (selector.kind == PackageSelectorKind::Default ||
        selector.kind == PackageSelectorKind::ExactArchitecture);
}
bool RecordValid(const DpkgPackageState &record) {
    if (!CydiaRuntime::ValidPackageName(record.package.package) ||
        static_cast<unsigned>(record.selection) > static_cast<unsigned>(DpkgSelection::Purge) ||
        static_cast<unsigned>(record.status) > static_cast<unsigned>(DpkgPackageStatus::Installed)) return false;
    const bool noMetadata = record.package.architecture.empty() && record.package.version.empty();
    if (noMetadata) {
        if (record.status != DpkgPackageStatus::NotInstalled || record.reinstallRequired || !record.multiArch.empty()) return false;
    } else if (!Architecture(record.package.architecture) || !Version(record.package.version)) return false;
    if (record.multiArch != "" && record.multiArch != "no" && record.multiArch != "same" &&
        record.multiArch != "foreign" && record.multiArch != "allowed") return false;
    if (record.package.architecture == "all" && record.multiArch == "same") return false;
    if ((record.status == DpkgPackageStatus::NotInstalled || record.status == DpkgPackageStatus::ConfigFiles) &&
        (!record.triggersPending.empty() || !record.triggersAwaited.empty())) return false;
    if (!record.triggersPending.empty() && record.status != DpkgPackageStatus::TriggersPending &&
        record.status != DpkgPackageStatus::TriggersAwaited) return false;
    if (record.status == DpkgPackageStatus::TriggersPending && record.triggersPending.empty()) return false;
    if (record.status == DpkgPackageStatus::TriggersAwaited && record.triggersAwaited.empty()) return false;
    for (const bool awaited : {false, true}) {
        const auto &values = awaited ? record.triggersAwaited : record.triggersPending;
        if (values.size() > 4096 || !std::is_sorted(values.begin(), values.end()) ||
            std::adjacent_find(values.begin(), values.end()) != values.end()) return false;
        for (const auto &value : values)
            if (!Visible(value) || (awaited && !AwaitedSelector(value))) return false;
    }
    return true;
}
bool StateValid(const DpkgState &state) {
    if (!ValidIdentityToken(state.packageStateIdentity) || !Architecture(state.nativeArchitecture) ||
        state.nativeArchitecture == "all" || state.registeredArchitectures.empty() ||
        state.registeredArchitectures.front() != state.nativeArchitecture ||
        state.registeredArchitectures.size() > 256 || state.packages.size() > MaximumCollectionItems) return false;
    std::set<std::string> arches;
    for (const auto &arch : state.registeredArchitectures)
        if (!Architecture(arch) || arch == "all" || !arches.insert(arch).second) return false;
    for (const auto &item : state.packages)
        if (item.first != Key(item.second.package) || !RecordValid(item.second)) return false;
    return true;
}
bool SameRecord(const DpkgPackageState &a, const DpkgPackageState &b) {
    return SamePackage(a.package, b.package) && a.selection == b.selection && a.status == b.status &&
        a.reinstallRequired == b.reinstallRequired && a.multiArch == b.multiArch &&
        a.triggersPending == b.triggersPending && a.triggersAwaited == b.triggersAwaited;
}
bool ParseRecord(const std::string &line, DpkgPackageState *record) {
    std::vector<std::string> fields;
    if (!Split(line, '\t', &fields) || fields.size() != 7) return false;
    record->package = {fields[0], fields[1], fields[2]}; record->multiArch = fields[4];
    std::vector<std::string> status;
    if (!Split(fields[3], ' ', &status) || status.size() != 3) return false;
    const char *selections[] = {"unknown", "install", "hold", "deinstall", "purge"};
    const char *states[] = {"not-installed", "config-files", "half-installed", "unpacked", "half-configured",
                           "triggers-awaited", "triggers-pending", "installed"};
    unsigned i = 0;
    while (i < 5 && status[0] != selections[i]) ++i;
    if (i == 5) return false;
    record->selection = static_cast<DpkgSelection>(i);
    if (status[1] != "ok" && status[1] != "reinstreq") return false;
    record->reinstallRequired = status[1] == "reinstreq";
    i = 0; while (i < 8 && status[2] != states[i]) ++i;
    if (i == 8) return false;
    record->status = static_cast<DpkgPackageStatus>(i);
    return TriggerList(fields[5], false, &record->triggersPending) &&
        TriggerList(fields[6], true, &record->triggersAwaited) && RecordValid(*record);
}
bool Forgotten(const DpkgPackageState &record) {
    return record.status == DpkgPackageStatus::NotInstalled && record.selection == DpkgSelection::Unknown &&
        !record.reinstallRequired && record.triggersPending.empty() && record.triggersAwaited.empty();
}
bool EmptyTriggers(const DpkgPackageState &record) {
    return record.triggersPending.empty() && record.triggersAwaited.empty();
}
bool Option(const std::vector<std::string> &arguments, const char *value) {
    for (const auto &argument : arguments) {
        if (argument == "--") break;
        if (argument == value) return true;
    }
    return false;
}
// dpkg's deferred queue obeys --no-triggers, but dependency progress can still
// process pending recipients. Require the whole fresh pending set, not a
// worker-selected subset. Clearing waiters is derived from the existing graph:
// https://git.dpkg.org/cgit/dpkg/dpkg.git/tree/lib/dpkg/triglib.c (trig_clear_awaiters)
// https://git.dpkg.org/cgit/dpkg/dpkg.git/tree/src/main/packages.c (process_queue)
// The successful shutdown checkpoint persists cleared links even on an
// unpacked waiter whose status did not change (lib/dpkg/dbmodify.c).
// Newly activated triggers are deliberately outside this bounded transition.
bool TriggerResult(const DpkgState &before, const std::vector<ExecutionPackage> &targets,
                   DpkgState *result, std::string *error) {
    std::map<std::string, ExecutionPackage> pending;
    for (const auto &item : before.packages) {
        const auto &record = item.second;
        if (record.triggersPending.empty()) continue;
        if (record.reinstallRequired ||
            (record.status != DpkgPackageStatus::TriggersPending && record.status != DpkgPackageStatus::TriggersAwaited) ||
            (record.selection != DpkgSelection::Install && record.selection != DpkgSelection::Hold))
            return Fail(error, "provider_trigger_state_unsettled");
        pending.emplace(item.first, record.package);
    }
    std::set<std::string> selected;
    for (const auto &target : targets) {
        const auto found = pending.find(Key(target));
        if (found == pending.end() || !SamePackage(target, found->second) || !selected.insert(found->first).second)
            return Fail(error, "provider_trigger_targets_changed");
    }
    if (pending.empty() || selected.size() != pending.size())
        return Fail(error, "provider_trigger_targets_incomplete");
    std::map<std::string, std::vector<std::string>> names;
    for (const auto &item : before.packages) names[item.second.package.package].push_back(item.first);
    *result = before;
    for (auto &item : result->packages) {
        auto &record = item.second;
        std::set<std::string> awaitedTargets;
        for (const auto &waiter : record.triggersAwaited) {
            const auto selector = ParsePackageSelector(waiter); std::string target;
            if (selector.kind == PackageSelectorKind::ExactArchitecture) target = waiter;
            else {
                const auto found = names.find(waiter);
                if (found == names.end() || found->second.size() != 1)
                    return Fail(error, "provider_trigger_waiter_ambiguous");
                target = found->second.front();
            }
            // Stale references may be repaired implicitly while dpkg opens the
            // database. They require a separate review, not guessed recipients.
            if (!pending.count(target) || !awaitedTargets.insert(target).second)
                return Fail(error, "provider_trigger_waiter_unresolved");
        }
        record.triggersAwaited.clear();
        if (pending.count(item.first)) record.triggersPending.clear();
        if (record.status == DpkgPackageStatus::TriggersAwaited || pending.count(item.first))
            record.status = record.triggersPending.empty() ? DpkgPackageStatus::Installed : DpkgPackageStatus::TriggersPending;
    }
    return true;
}
}

const char *DpkgStateQueryFormat() {
    // These control fields are not translated, unlike dpkg-query --list.
    return "${Package}\t${Version}\t${Architecture}\t${Status}\t${Multi-Arch}\t${Triggers-Pending}\t${Triggers-Awaited}\n";
}
bool ParseDpkgState(const std::string &queryOutput, const std::string &nativeOutput,
                    const std::string &foreignOutput, const std::string &snapshotIdentity,
                    DpkgState *state, std::string *error) {
    if (!state) return Fail(error, "provider_dpkg_state_invalid");
    *state = DpkgState(); DpkgState result;
    if (queryOutput.size() > MaximumStateBytes || foreignOutput.size() > 32768 ||
        nativeOutput.empty() || nativeOutput.size() > 129 || nativeOutput.back() != '\n' ||
        queryOutput.find('\0') != std::string::npos || queryOutput.find('\r') != std::string::npos)
        return Fail(error, "provider_dpkg_state_invalid");
    result.nativeArchitecture = nativeOutput.substr(0, nativeOutput.size() - 1);
    result.registeredArchitectures.push_back(result.nativeArchitecture);
    result.packageStateIdentity = snapshotIdentity;
    std::istringstream foreign(foreignOutput); std::string line;
    if (!foreignOutput.empty() && foreignOutput.back() != '\n') return Fail(error, "provider_dpkg_state_invalid");
    while (std::getline(foreign, line)) {
        if (result.registeredArchitectures.size() >= 256) return Fail(error, "provider_dpkg_state_invalid");
        result.registeredArchitectures.push_back(line);
    }
    std::sort(result.registeredArchitectures.begin() + 1, result.registeredArchitectures.end());
    if (!queryOutput.empty() && queryOutput.back() != '\n') return Fail(error, "provider_dpkg_state_truncated");
    std::istringstream rows(queryOutput);
    while (std::getline(rows, line)) {
        DpkgPackageState record;
        if (line.size() > 65536 || result.packages.size() >= MaximumCollectionItems ||
            !ParseRecord(line, &record) || !result.packages.emplace(Key(record.package), record).second)
            return Fail(error, "provider_dpkg_state_invalid");
    }
    if (!StateValid(result)) return Fail(error, "provider_dpkg_state_invalid");
    *state = std::move(result);
    if (error) error->clear();
    return true;
}

bool DpkgPendingTargets(const DpkgState &state, ExecutionAction action,
                        std::vector<ExecutionPackage> *targets, std::string *error) {
    if (!targets) return Fail(error, "provider_dpkg_state_invalid");
    targets->clear();
    if (!StateValid(state)) return Fail(error, "provider_dpkg_state_invalid");
    if (action != ExecutionAction::Configure && action != ExecutionAction::Remove &&
        action != ExecutionAction::Purge && action != ExecutionAction::Triggers)
        return Fail(error, "provider_unsupported_pending_action");
    // Match dpkg src/main/packages.c enqueue_pending(), including held
    // configure targets and remove/purge's shared pending selection rules.
    for (const auto &item : state.packages) {
        const auto &record = item.second; bool selected = false;
        if (action == ExecutionAction::Configure || action == ExecutionAction::Triggers) {
            selected = (record.selection == DpkgSelection::Install || record.selection == DpkgSelection::Hold) &&
                (!record.triggersPending.empty() || (action == ExecutionAction::Configure &&
                    (record.status == DpkgPackageStatus::Unpacked || record.status == DpkgPackageStatus::HalfConfigured)));
        } else {
            selected = record.status != DpkgPackageStatus::NotInstalled &&
                (record.selection == DpkgSelection::Purge ||
                    (record.selection == DpkgSelection::Deinstall && record.status != DpkgPackageStatus::ConfigFiles));
        }
        if (selected) targets->push_back(record.package);
    }
    if (error) error->clear();
    return true;
}

bool ApplyDpkgStateEvidence(const DpkgState &state, const ReviewedTransaction &review,
                            const ParentExecutionRequest &request,
                            ParentExecutionEvidence *evidence, std::string *error) {
    if (!evidence) return Fail(error, "provider_dpkg_state_invalid");
    evidence->stateVerified = false; evidence->stateIdentity.clear();
    evidence->pendingTargetsKnown = evidence->deconfigurationTargetsKnown = evidence->triggerTargetsKnown = false;
    evidence->pendingTargets.clear(); evidence->deconfigurationTargets.clear(); evidence->triggerTargets.clear();
    evidence->barePackageTargets.clear();
    if (!StateValid(state) || request.actions.empty() || request.actions.size() > MaximumCollectionItems ||
        review.execution.actions.size() > MaximumCollectionItems)
        return Fail(error, "provider_dpkg_state_invalid");
    if (request.action == ExecutionAction::Deconfigure || Option(request.arguments, "--auto-deconfigure"))
        return Fail(error, "provider_deconfiguration_unknown");
    if (!Option(request.arguments, "--no-triggers"))
        return Fail(error, "provider_trigger_targets_unknown");
    std::map<std::uint64_t, const ReviewedAction *> actions;
    for (const auto &action : review.execution.actions)
        if (!action.identifier || !actions.emplace(action.identifier, &action).second)
            return Fail(error, "provider_invalid_execution_review");
    std::set<std::uint64_t> requested;
    std::vector<ExecutionPackage> triggerTargets;
    for (const auto id : request.actions) {
        const auto action = actions.find(id);
        if (action == actions.end() || !requested.insert(id).second || action->second->action != request.action)
            return Fail(error, "provider_unreviewed_batch_target");
        if (request.action == ExecutionAction::Unpack) {
            for (const auto &record : state.packages) {
                // dpkg src/main/unpack.c deconfigures out-of-sync coinstalled
                // instances before pkg_check_depcon, independently of
                // --auto-deconfigure (dpkg 1.21.9 and 1.23.7). Neither current
                // execution mode has an independently approved restoration
                // envelope for that effect. Refuse before launching dpkg,
                // even if a later archive in this batch updates the sibling.
                if (record.second.package.package == action->second->package.package &&
                    record.second.package.architecture != action->second->package.architecture &&
                    record.second.multiArch == "same" && record.second.status > DpkgPackageStatus::HalfConfigured &&
                    !SameDpkgVersion(record.second.package.version, action->second->package.version))
                    return Fail(error, "provider_deconfiguration_unknown");
                if (record.second.package.package == action->second->package.package &&
                    (record.second.package.architecture == action->second->package.architecture ||
                     record.second.package.architecture == "all" || action->second->package.architecture == "all") &&
                    !EmptyTriggers(record.second)) return Fail(error, "provider_trigger_targets_unknown");
            }
            continue;
        }
        const auto record = state.packages.find(Key(action->second->package));
        if (record == state.packages.end() || record->second.reinstallRequired ||
            !SamePackage(record->second.package, action->second->package))
            return Fail(error, "provider_dpkg_target_changed");
        if (request.action == ExecutionAction::Triggers) triggerTargets.push_back(action->second->package);
        else if (!EmptyTriggers(record->second)) return Fail(error, "provider_trigger_targets_unknown");
    }
    if (request.action == ExecutionAction::Triggers) {
        DpkgState expected;
        if (!TriggerResult(state, triggerTargets, &expected, error)) return false;
    }
    std::map<std::string, std::vector<const DpkgPackageState *> > names;
    for (const auto &item : state.packages) names[item.second.package.package].push_back(&item.second);
    for (const auto &name : names) if (name.second.size() == 1 &&
        name.second.front()->status != DpkgPackageStatus::NotInstalled)
        evidence->barePackageTargets.emplace(name.first, name.second.front()->package);
    if (Option(request.arguments, "--pending")) {
        if (!DpkgPendingTargets(state, request.action, &evidence->pendingTargets, error)) return false;
        // A configure target with pending triggers executes its postinst as
        // a trigger even with --no-triggers. Status alone cannot bound effects.
        if (request.action == ExecutionAction::Configure)
            for (const auto &package : evidence->pendingTargets)
                if (!state.packages.at(Key(package)).triggersPending.empty())
                    return Fail(error, "provider_trigger_targets_unknown");
        evidence->pendingTargetsKnown = true;
    }
    evidence->deconfigurationTargetsKnown = evidence->triggerTargetsKnown = true;
    evidence->stateVerified = true; evidence->stateIdentity = state.packageStateIdentity;
    if (error) error->clear();
    return true;
}

bool VerifyDpkgStateTransition(const DpkgState &before, const DpkgState &after,
                              const ReviewedTransaction &review,
                              const AuthorizedExecution &batch, std::string *error) {
    if (!StateValid(before) || !StateValid(after) || !batch.batch || batch.actions.empty() ||
        batch.actions.size() > MaximumCollectionItems || review.execution.actions.size() > MaximumCollectionItems ||
        before.nativeArchitecture != after.nativeArchitecture ||
        before.registeredArchitectures != after.registeredArchitectures)
        return Fail(error, "provider_dpkg_state_changed");
    if (!Option(batch.arguments, "--no-triggers") || Option(batch.arguments, "--auto-deconfigure"))
        return Fail(error, "provider_dpkg_effects_unknown");
    std::map<std::uint64_t, const ReviewedAction *> actions;
    for (const auto &action : review.execution.actions)
        if (!action.identifier || !actions.emplace(action.identifier, &action).second)
            return Fail(error, "provider_invalid_execution_review");
    if (batch.action == ExecutionAction::Triggers) {
        std::vector<ExecutionPackage> targets; std::set<std::uint64_t> seen;
        for (const auto id : batch.actions) {
            const auto found = actions.find(id);
            if (found == actions.end() || found->second->action != ExecutionAction::Triggers || !seen.insert(id).second)
                return Fail(error, "provider_unreviewed_batch_target");
            targets.push_back(found->second->package);
        }
        DpkgState expected;
        if (!TriggerResult(before, targets, &expected, error)) return false;
        if (after.packages.size() != expected.packages.size()) return Fail(error, "provider_unexpected_dpkg_transition");
        for (const auto &item : expected.packages) {
            const auto observed = after.packages.find(item.first);
            if (observed == after.packages.end() || !SameRecord(item.second, observed->second))
                return Fail(error, "provider_unexpected_dpkg_transition");
        }
        if (error) error->clear();
        return true;
    }
    std::set<std::string> affectedBefore, affectedAfter; std::set<std::uint64_t> seen;
    for (const auto id : batch.actions) {
        const auto found = actions.find(id);
        if (found == actions.end() || !seen.insert(id).second || found->second->action != batch.action)
            return Fail(error, "provider_unreviewed_batch_target");
        const auto &action = *found->second; const auto key = Key(action.package);
        if (action.action == ExecutionAction::Triggers || action.action == ExecutionAction::Deconfigure)
            return Fail(error, "provider_dpkg_effects_unknown");
        auto old = before.packages.find(key); auto now = after.packages.find(key);
        // An all/native transition replaces a single same-name instance. It
        // must never hide a removed coinstalled foreign package.
        if (action.action == ExecutionAction::Unpack && old == before.packages.end()) {
            for (auto candidate = before.packages.begin(); candidate != before.packages.end(); ++candidate)
                if (candidate->second.package.package == action.package.package &&
                    candidate->second.status != DpkgPackageStatus::NotInstalled &&
                    (action.package.architecture == "all" || candidate->second.package.architecture == "all")) {
                    if (old != before.packages.end()) return Fail(error, "provider_ambiguous_dpkg_name");
                    old = candidate;
                }
        }
        if (old != before.packages.end() && !affectedBefore.insert(old->first).second)
            return Fail(error, "provider_duplicate_batch_target");
        if (old != before.packages.end() && !EmptyTriggers(old->second))
            return Fail(error, "provider_dpkg_effects_unknown");
        if (action.action != ExecutionAction::Unpack && (old == before.packages.end() ||
            !SamePackage(old->second.package, action.package) || old->second.reinstallRequired ||
            !EmptyTriggers(old->second))) return Fail(error, "provider_dpkg_target_changed");
        if (action.action == ExecutionAction::Remove || action.action == ExecutionAction::Purge) {
            // dpkg can discard all metadata when a package is purged. Retain
            // any surviving wanted-selection entry without inventing an arch.
            if (now == after.packages.end()) now = after.packages.find(action.package.package + ':');
            if (now != after.packages.end()) {
                const auto &record = now->second;
                if (record.reinstallRequired || !EmptyTriggers(record) ||
                    (record.selection != DpkgSelection::Deinstall && record.selection != DpkgSelection::Purge &&
                     record.selection != DpkgSelection::Unknown) ||
                    (record.status != DpkgPackageStatus::NotInstalled &&
                        (action.action != ExecutionAction::Remove || record.status != DpkgPackageStatus::ConfigFiles)) ||
                    (!record.package.architecture.empty() && !SamePackage(record.package, action.package)) ||
                    (record.status == DpkgPackageStatus::ConfigFiles && record.selection == DpkgSelection::Unknown))
                    return Fail(error, "provider_dpkg_transition_incomplete");
                if (!affectedAfter.insert(now->first).second) return Fail(error, "provider_duplicate_batch_target");
            }
            continue;
        }
        if (now == after.packages.end() || !SamePackage(now->second.package, action.package) ||
            now->second.reinstallRequired || !EmptyTriggers(now->second) ||
            (now->second.selection != DpkgSelection::Install &&
                !(old != before.packages.end() && old->second.selection == DpkgSelection::Hold &&
                  now->second.selection == DpkgSelection::Hold)))
            return Fail(error, "provider_dpkg_transition_incomplete");
        if (action.action == ExecutionAction::Unpack) {
            if (now->second.status != DpkgPackageStatus::Unpacked)
                return Fail(error, "provider_dpkg_transition_incomplete");
        } else if (action.action == ExecutionAction::Configure) {
            if ((old->second.status != DpkgPackageStatus::Unpacked && old->second.status != DpkgPackageStatus::HalfConfigured) ||
                now->second.status != DpkgPackageStatus::Installed || now->second.multiArch != old->second.multiArch)
                return Fail(error, "provider_dpkg_transition_incomplete");
        } else return Fail(error, "provider_unsupported_dpkg_batch");
        if (!affectedAfter.insert(now->first).second) return Fail(error, "provider_duplicate_batch_target");
    }
    for (const auto &item : before.packages) if (!affectedBefore.count(item.first)) {
        const auto now = after.packages.find(item.first);
        if (now == after.packages.end() ? !Forgotten(item.second) : !SameRecord(item.second, now->second))
            return Fail(error, "provider_unexpected_dpkg_transition");
    }
    for (const auto &item : after.packages) if (!affectedAfter.count(item.first)) {
        const auto old = before.packages.find(item.first);
        if (old == before.packages.end() || affectedBefore.count(item.first) || !SameRecord(old->second, item.second))
            return Fail(error, "provider_unexpected_dpkg_transition");
    }
    if (error) error->clear();
    return true;
}

}} // namespace CydiaAPT::Provider
