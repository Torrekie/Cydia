/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDpkgState.hpp"
#include "Cydia/ExtendedState.hpp"
#include <algorithm>
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
    if (record.status == DpkgPackageStatus::TriggersPending && record.triggersPending.empty()) return false;
    if (record.status == DpkgPackageStatus::TriggersAwaited && record.triggersAwaited.empty()) return false;
    for (const bool awaited : {false, true}) {
        const auto &values = awaited ? record.triggersAwaited : record.triggersPending;
        if (values.size() > 4096 || !std::is_sorted(values.begin(), values.end()) ||
            std::adjacent_find(values.begin(), values.end()) != values.end()) return false;
        for (const auto &value : values)
            if (!Visible(value) || (awaited && !ParsePackageSelector(value).valid())) return false;
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
    if (request.action == ExecutionAction::Triggers || !Option(request.arguments, "--no-triggers"))
        return Fail(error, "provider_trigger_targets_unknown");
    std::map<std::uint64_t, const ReviewedAction *> actions;
    for (const auto &action : review.execution.actions)
        if (!action.identifier || !actions.emplace(action.identifier, &action).second)
            return Fail(error, "provider_invalid_execution_review");
    std::set<std::uint64_t> requested;
    for (const auto id : request.actions) {
        const auto action = actions.find(id);
        if (action == actions.end() || !requested.insert(id).second || action->second->action != request.action)
            return Fail(error, "provider_unreviewed_batch_target");
        if (request.action == ExecutionAction::Unpack) {
            for (const auto &record : state.packages)
                if (record.second.package.package == action->second->package.package &&
                    (record.second.package.architecture == action->second->package.architecture ||
                     record.second.package.architecture == "all" || action->second->package.architecture == "all") &&
                    !EmptyTriggers(record.second)) return Fail(error, "provider_trigger_targets_unknown");
            continue;
        }
        const auto record = state.packages.find(Key(action->second->package));
        if (record == state.packages.end() || record->second.reinstallRequired ||
            !SamePackage(record->second.package, action->second->package))
            return Fail(error, "provider_dpkg_target_changed");
        if (!EmptyTriggers(record->second)) return Fail(error, "provider_trigger_targets_unknown");
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
