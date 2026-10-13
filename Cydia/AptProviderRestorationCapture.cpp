/* Protected capture only; never a deconfiguration permission or state solver.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderRestorationCapture.hpp"
#include "Cydia/RuntimeSnapshotInputs.hpp"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/ExtendedState.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <set>
#include <unistd.h>
namespace CydiaAPT { namespace Provider {
namespace {
namespace P = CydiaRuntime::Privileged;
constexpr std::size_t MaximumCaptureBytes = 64 * 1024 * 1024;
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Active(const std::function<bool()> &cancelled, std::string *error) {
    return !(cancelled && cancelled()) || Fail(error, "provider_restoration_capture_cancelled");
}
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
std::string Slot(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool ValidPackage(const ExecutionPackage &p) {
    return p.package.size() <= 255 && p.architecture.size() <= 255 && p.version.size() <= 1024 &&
        CydiaRuntime::ValidPackageName(p.package) && CydiaRuntime::ValidArchitectureName(p.architecture) &&
        BinaryRelationships::ValidVersion(p.version);
}
struct Budget {
    std::size_t used = 0;
    bool Add(std::size_t size) {
        if (size > MaximumCaptureBytes - used) return false;
        used += size; return true;
    }
};
class RestorationWriter {
    Hashes hash_{Hashes::SHA256SUM}; Budget &budget_; bool valid_ = true;
public:
    RestorationWriter(const std::string &tag, Budget &budget) : budget_(budget) { Field(tag); }
    bool Field(const std::string &s) {
        if (!valid_ || !budget_.Add(s.size()) || !budget_.Add(32)) return valid_ = false;
        const std::string length = std::to_string(s.size()) + ':';
        return valid_ = hash_.Add(length.data(), length.size()) && hash_.Add(s.data(), s.size()) && hash_.Add(",", 1);
    }
    std::string Result() { return valid_ ? hash_.GetHashString(Hashes::SHA256SUM).HashValue() : ""; }
};
bool Slots(const DeconfigurationAllowanceSet &approval, std::map<std::string, std::string> *slots) {
    if (!Digest(approval.identity) || approval.allowances.size() > MaximumTriggerEffectPackages) return false;
    for (const auto &item : approval.allowances) {
        const auto &package = item.second.installed;
        if (!ValidPackage(package) || item.first.size() > 2048 || item.first != Slot(package) + '@' + package.version ||
            !slots->emplace(Slot(package), item.first).second) return false;
    }
    return true;
}
// Seal exactly the parent-review data this producer consumes. The approval
// digest remains separately bound; this is not approval validation or consent.
std::string SuccessorScope(const DeconfigurationAllowanceSet &approval) {
    if (approval.primaryReview.execution.actions.size() > MaximumDeconfigurationActions) return "";
    Budget budget; RestorationWriter out("CYDIA-RESTORATION-SUCCESSOR-SCOPE-1", budget);
    out.Field(approval.identity);
    for (const auto &action : approval.primaryReview.execution.actions) {
        if (!action.identifier || !ValidPackage(action.package) || action.archive.size() > 512 ||
            static_cast<unsigned>(action.action) > static_cast<unsigned>(ExecutionAction::Deconfigure)) return "";
        for (const auto &s : {std::to_string(action.identifier), std::to_string(static_cast<unsigned>(action.action)),
            action.package.package, action.package.version, action.package.architecture, action.archive}) out.Field(s);
    }
    out.Field("");
    for (const auto &item : approval.allowances) {
        const auto &endpoint = item.second.endpoint;
        if (!ValidPackage(endpoint.package) || !endpoint.action ||
            (endpoint.kind != ExecutionAction::Configure && endpoint.kind != ExecutionAction::Remove && endpoint.kind != ExecutionAction::Purge)) return "";
        for (const auto &s : {item.first, std::to_string(endpoint.action), std::to_string(endpoint.precedingUnpack),
            std::to_string(static_cast<unsigned>(endpoint.kind)), endpoint.package.package, endpoint.package.version,
            endpoint.package.architecture}) out.Field(s);
    }
    return out.Result();
}
std::string EnvironmentBytes(const P::Environment &environment) {
    std::string value;
    return Encode(static_cast<const P::ExpectedEnvironment &>(environment), &value) ? value : "";
}
using Files = std::map<std::string, const P::Evidence *>;
bool IndexFiles(const std::vector<P::Evidence> &files, Files *index) {
    if (files.size() > 4 + 4 * MaximumTriggerEffectPackages) return false;
    for (const auto &file : files) {
        if (file.path.size() > 4096) return false;
        const auto found = index->emplace(file.path, &file);
        // Co-installed same-name instances share the unused bare-name absence.
        // The protected producer already checked each read and its final state.
        if (!found.second && (!found.first->second->absent || !file.absent)) return false;
    }
    return true;
}
const P::Evidence *Find(const Files &files, const std::string &path) {
    const auto found = files.find(path); return found == files.end() ? nullptr : found->second;
}
bool EvidenceShape(const P::Evidence &file) {
    return file.path.size() <= 4096 && file.bytes.size() <= MaximumInstalledScriptBytes &&
        file.sourceReaderGroups.values.size() <= MaximumDeconfigurationEvidenceGroups &&
        file.entries.empty() && file.sourceDelegation.empty() && !file.directory && !file.identityOnly &&
        !file.sourceInput && !file.sharedState && file.adminAccess &&
        (file.absent || (S_ISREG(file.identity.st_mode) && file.identity.st_nlink == 1 && file.identity.st_uid == 0 &&
            !(file.identity.st_mode & 0022) && file.identity.st_size >= 0 &&
            static_cast<std::uint64_t>(file.identity.st_size) == file.bytes.size()));
}
// Content-generation identity includes the complete selected leaf identity
// (bytes, inode, timestamps, mode/owner, path and absence). It excludes only
// phase/history and unrelated status/info-directory contents. Reader groups
// are access evidence, not file content, and remain in the full phase proof.
bool Leaf(RestorationWriter &writer, const P::Evidence &file) {
    if (!EvidenceShape(file)) return false;
    writer.Field(file.path); writer.Field(file.absent ? "absent" : "present");
    if (file.absent) return writer.Field("");
    const auto &st = file.identity;
    for (const auto &s : {std::to_string(st.st_dev), std::to_string(st.st_ino), std::to_string(st.st_nlink),
        std::to_string(st.st_mode), std::to_string(st.st_uid), std::to_string(st.st_gid), std::to_string(st.st_size)}) writer.Field(s);
#ifdef __APPLE__
    writer.Field(std::to_string(st.st_mtimespec.tv_sec)); writer.Field(std::to_string(st.st_mtimespec.tv_nsec));
    writer.Field(std::to_string(st.st_ctimespec.tv_sec)); writer.Field(std::to_string(st.st_ctimespec.tv_nsec));
#else
    writer.Field(std::to_string(st.st_mtim.tv_sec)); writer.Field(std::to_string(st.st_mtim.tv_nsec));
    writer.Field(std::to_string(st.st_ctim.tv_sec)); writer.Field(std::to_string(st.st_ctim.tv_nsec));
#endif
    return writer.Field(file.bytes);
}
bool Layout(RestorationWriter &writer, const Files &files, const std::string &admin) {
    const auto *info = Find(files, admin + "/info"), *format = Find(files, admin + "/info/format"),
        *migration = Find(files, admin + "/info/format-new");
    if (!info || !format || !migration || !migration->absent || !info->directory || !info->identityOnly || info->absent) return false;
    // Creating another package's scripts must not change this generation.
    // Canonical info-directory identity/permissions matter; its mtime does not.
    writer.Field(info->path);
    for (const auto &s : {std::to_string(info->identity.st_dev), std::to_string(info->identity.st_ino),
        std::to_string(info->identity.st_uid), std::to_string(info->identity.st_gid), std::to_string(info->identity.st_mode)}) writer.Field(s);
    return Leaf(writer, *format) && Leaf(writer, *migration);
}
bool ScriptIdentity(const InstalledPackageScripts &scripts, Budget &budget, std::string *identity) {
    if (!EvidenceShape(scripts.prerm) || !EvidenceShape(scripts.postinst) || !Digest(scripts.evidenceIdentity)) return false;
    // Exactly the allowance builder's phase-bound identity, including its
    // original empty tag (no extra domain field may be inserted here).
    const auto prerm = P::SerializeSnapshotEvidence(scripts.prerm), postinst = P::SerializeSnapshotEvidence(scripts.postinst);
    if (!budget.Add(prerm.size() + postinst.size() + 128)) return false;
    Hashes hash(Hashes::SHA256SUM);
    for (const auto *value : {&scripts.evidenceIdentity, &prerm, &postinst}) {
        const auto length = std::to_string(value->size()) + ':';
        if (!hash.Add(length.data(), length.size()) || !hash.Add(value->data(), value->size()) || !hash.Add(",", 1)) return false;
    }
    *identity = hash.GetHashString(Hashes::SHA256SUM).HashValue(); return Digest(*identity);
}
// A supplied snapshot is the owner's frozen-environment reader. Only the
// ordinary default is adapted here; every native lock wait receives the same
// cancellation callback as the enclosing protected capture.
TriggerStateSnapshot EffectiveSnapshot(const P::Environment &environment,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) {
    if (snapshot) return snapshot;
    return [&environment, &cancelled](std::string *state, std::string *error) {
        P::Error failure;
        if (P::RuntimeSnapshot(environment, state, &failure, cancelled)) return true;
        if (error) *error = failure.code.empty() ? "provider_restoration_capture_changed" : failure.code;
        return false;
    };
}
bool Recheck(const P::Environment &environment, const TriggerCaptureLock &lock, const TriggerEffectCheckpoint &trigger,
    const InstalledScriptMetadata &scripts, std::string *error, const std::function<bool()> &cancelled,
    const TriggerStateSnapshot &snapshot) {
    if (geteuid() != 0 || !Active(cancelled, error) || !TriggerCaptureLockHeld(environment, lock)) return Fail(error, "provider_frontend_lock_missing");
    P::Error ignored; std::string state;
    if ((!snapshot || !snapshot(&state, error)) || state != trigger.packages.packageStateIdentity ||
        !P::RecheckEvidence(trigger.metadata.files, &ignored) || !Active(cancelled, error) ||
        !P::RecheckEvidence(scripts.files, &ignored) || !RecheckProtectedTriggerEvidence(environment, trigger.registry, error, cancelled) ||
        !TriggerCaptureLockHeld(environment, lock)) return Fail(error, "provider_restoration_capture_changed");
    std::string after;
    if ((!snapshot || !snapshot(&after, error)) || after != state ||
        !TriggerCaptureLockHeld(environment, lock)) return Fail(error, "provider_restoration_capture_changed");
    return Active(cancelled, error);
}
const P::Evidence *Declaration(const Files &files, const std::string &admin, const TriggerPackageMetadata &metadata) {
    const auto *bare = Find(files, admin + "/info/" + metadata.package.package + ".triggers");
    const auto *qualified = Find(files, admin + "/info/" + Slot(metadata.package) + ".triggers");
    if (!bare || !qualified || (!bare->absent && !qualified->absent)) return nullptr;
    // The protected metadata producer already chose the native format. Match
    // its existing exact declaration identity; never guess from architecture.
    for (const auto *file : {bare, qualified}) {
        if (!EvidenceShape(*file)) return nullptr;
        const auto bytes = P::SerializeSnapshotEvidence(*file); Hashes hash(Hashes::SHA256SUM);
        if (hash.Add(bytes.data(), bytes.size()) && hash.GetHashString(Hashes::SHA256SUM).HashValue() == metadata.declarationIdentity) return file;
    }
    return nullptr;
}
bool ScriptMatches(const CydiaPackages::ArchiveMaintainerScript &incoming, const P::Evidence &installed) {
    if (!EvidenceShape(installed) || incoming.present == installed.absent) return false;
    if (!incoming.present) return incoming.bytes.empty() && !incoming.mode && !incoming.uid && !incoming.gid;
    // dpkg 1.23.7 src/main/unpack.c:pkg_infodb_update renames extracted
    // prerm/postinst, and unlinks an old file if absent in the new control tar.
    // src/deb/extract.c:do_control uses external tar -x without -p. Do NOT
    // predict extraction ownership/umask/name mapping; only exact observed
    // bytes + numeric owner/mode preservation is admitted by this first slice.
    return incoming.bytes == installed.bytes && incoming.mode == (installed.identity.st_mode & 07777) &&
        incoming.uid == installed.identity.st_uid && incoming.gid == installed.identity.st_gid;
}
}
struct ProtectedRestorationCheckpoint::Data {
    std::string environment, approval, successorScope;
    std::map<std::string, std::string> slots;
    TriggerEffectCheckpoint trigger;
    InstalledScriptMetadata scripts;
    RestorationCheckpoint observation;
};
ProtectedRestorationCheckpoint::ProtectedRestorationCheckpoint(std::unique_ptr<Data> data) : data_(std::move(data)) {}
ProtectedRestorationCheckpoint::~ProtectedRestorationCheckpoint() = default;
const RestorationCheckpoint &ProtectedRestorationCheckpoint::observation() const { return data_->observation; }
const TriggerEffectCheckpoint &ProtectedRestorationCheckpoint::trigger() const { return data_->trigger; }
const InstalledScriptMetadata &ProtectedRestorationCheckpoint::scripts() const { return data_->scripts; }
bool ProtectedRestorationCheckpoint::Capture(const P::Environment &environment, const DpkgState &state,
    const TriggerCaptureLock &lock, const DeconfigurationAllowanceSet &approval,
    std::shared_ptr<const ProtectedRestorationCheckpoint> *output, std::string *error,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) {
    if (!output) return Fail(error, "provider_restoration_capture_invalid");
    output->reset(); if (error) error->clear();
    const auto effectiveSnapshot = EffectiveSnapshot(environment, cancelled, snapshot);
    if (geteuid() != 0) return Fail(error, "provider_frontend_lock_missing");
    std::unique_ptr<Data> result(new Data);
    if (!Slots(approval, &result->slots) || !Active(cancelled, error)) return Fail(error, "provider_restoration_capture_invalid");
    result->approval = approval.identity; result->environment = EnvironmentBytes(environment); result->successorScope = SuccessorScope(approval);
    if (!Digest(result->successorScope)) return Fail(error, "provider_restoration_capture_invalid");
    if (result->environment.empty() || !CaptureTriggerEffectCheckpoint(environment, state, lock, &result->trigger, error, cancelled, effectiveSnapshot)) return false;
    std::vector<ExecutionPackage> targets;
    for (const auto &slot : result->slots) {
        const auto found = state.packages.find(slot.first);
        if (found == state.packages.end()) continue;
        if (!ValidPackage(found->second.package))
            return Fail(error, "provider_restoration_phase_unsupported");
        targets.push_back(found->second.package);
    }
    if (!CaptureInstalledScripts(environment, state, lock, targets, &result->scripts, error, cancelled, effectiveSnapshot)) return false;
    auto &point = result->observation; point.identity = result->trigger.identity;
    point.deferredQueueEmpty = result->trigger.registry.state.deferred.empty(); Budget budget;
    std::size_t observationBytes = 0;
    Files controlFiles, scriptFiles;
    if (!IndexFiles(result->trigger.metadata.files, &controlFiles) || !IndexFiles(result->scripts.files, &scriptFiles))
        return Fail(error, "provider_restoration_capture_invalid");
    for (const auto &slot : result->slots) {
        if (!Active(cancelled, error)) return false;
        if (slot.first.size() + 1024 > MaximumRestorationObservationBytes - observationBytes)
            return Fail(error, "provider_restoration_capture_limit");
        observationBytes += slot.first.size() + 1024;
        RestorationObservation value; const auto current = state.packages.find(slot.first);
        if (current == state.packages.end()) { point.packages.emplace(slot.first, value); continue; }
        const auto meta = result->trigger.metadata.packages.find(slot.first);
        const auto script = result->scripts.packages.find(slot.first);
        if (meta == result->trigger.metadata.packages.end() || script == result->scripts.packages.end() ||
            !Same(current->second.package, meta->second.package) || !Same(current->second.package, script->second.package) ||
            meta->second.diskStatus != script->second.diskStatus || meta->second.configVersion != script->second.configVersion)
            return Fail(error, "provider_restoration_capture_changed");
        const auto &metadata = meta->second; const auto &scripts = script->second;
        const auto *declaration = Declaration(controlFiles, environment.dpkgAdmin, metadata);
        if (!declaration) return Fail(error, "provider_restoration_declaration_unverified");
        RestorationWriter content("CYDIA-RESTORATION-CONTENT-1", budget), scriptContent("CYDIA-RESTORATION-SCRIPTS-1", budget);
        for (const auto &part : {metadata.package.package, metadata.package.version, metadata.package.architecture}) {
            content.Field(part); scriptContent.Field(part);
        }
        for (const auto &control : metadata.controls) { content.Field(control.first); content.Field(control.second); }
        if (!Layout(content, controlFiles, environment.dpkgAdmin) || !Leaf(content, *declaration) ||
            !Layout(scriptContent, scriptFiles, environment.dpkgAdmin)) return Fail(error, "provider_restoration_content_invalid");
        // Both native candidate filenames, including unused-name absence, are
        // part of this generation. No global status or info membership hashes.
        for (const char *name : {"prerm", "postinst"}) {
            for (const auto &key : {metadata.package.package, slot.first}) {
                const auto *file = Find(scriptFiles, environment.dpkgAdmin + "/info/" + key + '.' + name);
                if (!file || !Leaf(scriptContent, *file)) return Fail(error, "provider_restoration_content_invalid");
            }
        }
        for (const auto *text : {&metadata.package.package, &metadata.package.version, &metadata.package.architecture, &metadata.configVersion}) {
            if (text->size() > MaximumRestorationObservationBytes - observationBytes)
                return Fail(error, "provider_restoration_capture_limit");
            observationBytes += text->size();
        }
        for (const auto *triggers : {&current->second.triggersPending, &current->second.triggersAwaited}) {
            if (triggers->size() > MaximumTriggerRelations) return Fail(error, "provider_restoration_capture_limit");
            for (const auto &trigger : *triggers) {
                if (trigger.size() > 2046 || trigger.size() + 32 > MaximumRestorationObservationBytes - observationBytes)
                    return Fail(error, "provider_restoration_capture_limit");
                observationBytes += trigger.size() + 32;
            }
        }
        value.present = true; value.package = current->second.package; value.selection = current->second.selection;
        value.reinstallRequired = current->second.reinstallRequired; value.status = current->second.status;
        value.diskStatus = metadata.diskStatus; value.configVersion = metadata.configVersion;
        value.controlIdentity = metadata.evidenceIdentity;
        value.contentIdentity = content.Result(); value.scriptContentIdentity = scriptContent.Result();
        if (!Digest(value.contentIdentity) || !Digest(value.scriptContentIdentity) || !ScriptIdentity(scripts, budget, &value.scriptsIdentity))
            return Fail(error, "provider_restoration_capture_limit");
        value.triggersPending = current->second.triggersPending; value.triggersAwaited = current->second.triggersAwaited;
        point.packages.emplace(slot.first, std::move(value));
    }
    if (!Recheck(environment, lock, result->trigger, result->scripts, error, cancelled, effectiveSnapshot)) return false;
    output->reset(new ProtectedRestorationCheckpoint(std::move(result))); return true;
}
bool VerifyRestorationSuccessors(const P::Environment &environment, const TriggerCaptureLock &lock,
    const DeconfigurationAllowanceSet &approval, const AuthorizedExecution &batch,
    const ProtectedRestorationCheckpoint &before, const ProtectedRestorationCheckpoint &after,
    const TransactionArchiveStore &store, std::vector<RestorationSuccessorProof> *output, std::string *error,
    const std::function<bool()> &cancelled, const TriggerStateSnapshot &snapshot) {
    if (!output) return Fail(error, "provider_restoration_successor_invalid");
    output->clear(); if (error) error->clear();
    const auto effectiveSnapshot = EffectiveSnapshot(environment, cancelled, snapshot);
    std::map<std::string, std::string> slots;
    if (!Slots(approval, &slots) || before.data_->slots != slots || after.data_->slots != slots ||
        before.data_->approval != approval.identity || after.data_->approval != approval.identity ||
        before.data_->successorScope != SuccessorScope(approval) || after.data_->successorScope != before.data_->successorScope ||
        before.data_->environment != EnvironmentBytes(environment) || after.data_->environment != before.data_->environment ||
        batch.action != ExecutionAction::Unpack || batch.actions.empty() || batch.actions.size() > MaximumDeconfigurationActions ||
        approval.primaryReview.execution.actions.size() > MaximumDeconfigurationActions || batch.archives.size() != batch.actions.size() ||
        store.archives().size() > MaximumDeconfigurationActions || store.effectControls().size() != store.archives().size())
        return Fail(error, "provider_restoration_successor_invalid");
    if (!Recheck(environment, lock, after.data_->trigger, after.data_->scripts, error, cancelled, effectiveSnapshot)) return false;
    Files controlFiles;
    if (!IndexFiles(after.data_->trigger.metadata.files, &controlFiles)) return Fail(error, "provider_restoration_capture_invalid");
    std::vector<StagedArchiveEvidence> staged;
    if (!store.Capture(&staged, error, cancelled)) return false;
    std::map<std::uint64_t, const ReviewedAction *> actions;
    for (const auto &action : approval.primaryReview.execution.actions)
        if (!actions.emplace(action.identifier, &action).second) return Fail(error, "provider_restoration_successor_invalid");
    std::map<std::string, const RetainedTransactionArchive *> archives;
    for (const auto &archive : store.archives())
        if (!archives.emplace(archive.source.archive.identifier, &archive).second) return Fail(error, "provider_restoration_successor_invalid");
    std::map<std::string, const VerifiedArchiveControlEvidence *> controls;
    for (const auto &control : store.effectControls())
        if (!controls.emplace(control.archive.archive.identifier, &control).second) return Fail(error, "provider_restoration_successor_invalid");
    std::map<std::string, const VerifiedArchiveEvidence *> selected;
    Budget budget;
    for (const auto &archive : batch.archives) {
        const auto retained = archives.find(archive.archive.identifier); std::string given, actual;
        if (retained == archives.end() || archive.fileIdentity != retained->second->source.fileIdentity ||
            !Encode(archive.archive, &given) || !Encode(retained->second->source.archive, &actual) || given != actual ||
            !budget.Add(given.size() + actual.size()) || !selected.emplace(archive.archive.identifier, &archive).second)
            return Fail(error, "provider_restoration_archive_changed");
    }
    std::set<std::uint64_t> ids; std::set<std::string> usedArchives, changedSlots;
    std::vector<RestorationSuccessorProof> result;
    for (const auto id : batch.actions) {
        if (!Active(cancelled, error)) return false;
        const auto action = actions.find(id);
        if (!ids.insert(id).second || action == actions.end() || action->second->action != ExecutionAction::Unpack ||
            !selected.count(action->second->archive) || !usedArchives.insert(action->second->archive).second ||
            !ValidPackage(action->second->package) || !changedSlots.insert(Slot(action->second->package)).second)
            return Fail(error, "provider_restoration_successor_invalid");
        const auto slot = slots.find(Slot(action->second->package));
        if (slot == slots.end()) continue; // Ordinary target: full owner verifier remains responsible.
        const auto &allowance = approval.allowances.at(slot->second);
        const auto &old = before.data_->observation.packages.at(slot->first), &now = after.data_->observation.packages.at(slot->first);
        const auto foundControl = controls.find(action->second->archive);
        if (allowance.endpoint.precedingUnpack != id || !Same(allowance.endpoint.package, action->second->package) ||
            !old.present || !Same(old.package, allowance.installed) || !now.present || !Same(now.package, action->second->package) ||
            (now.status != DpkgPackageStatus::Unpacked && now.status != DpkgPackageStatus::TriggersPending && now.status != DpkgPackageStatus::TriggersAwaited) ||
            (now.diskStatus != DpkgPackageStatus::Unpacked && now.diskStatus != DpkgPackageStatus::TriggersPending && now.diskStatus != DpkgPackageStatus::TriggersAwaited) ||
            foundControl == controls.end()) return Fail(error, "provider_restoration_successor_generation");
        const auto &incoming = foundControl->second->control;
        const auto &metadata = after.data_->trigger.metadata.packages.at(slot->first);
        const auto &scripts = after.data_->scripts.packages.at(slot->first);
        const auto *declaration = Declaration(controlFiles, environment.dpkgAdmin, metadata);
        if (!incoming.complete || incoming.identity.package != now.package.package || incoming.identity.version != now.package.version ||
            incoming.identity.architecture != now.package.architecture || incoming.controls != metadata.controls || !declaration ||
            incoming.triggersPresent == declaration->absent || incoming.triggers != declaration->bytes ||
            !ScriptMatches(incoming.prerm, scripts.prerm) || !ScriptMatches(incoming.postinst, scripts.postinst))
            return Fail(error, "provider_restoration_successor_content_changed");
        RestorationSuccessorProof proof; proof.unpackAction = id; proof.oldGeneration = slot->second; proof.archive = action->second->archive;
        proof.retainedArchiveIdentity = selected.at(proof.archive)->fileIdentity;
        proof.beforeCheckpoint = before.observation().identity; proof.afterCheckpoint = after.observation().identity;
        proof.installedControlIdentity = now.controlIdentity; proof.installedScriptsIdentity = now.scriptsIdentity;
        proof.installedMultiArch = metadata.controls.at("multi-arch");
        proof.installedContentIdentity = now.contentIdentity; proof.installedScriptContentIdentity = now.scriptContentIdentity;
        for (const auto *value : {&proof.oldGeneration, &proof.archive, &proof.retainedArchiveIdentity})
            if (!budget.Add(value->size() + 256)) return Fail(error, "provider_restoration_capture_limit");
        result.push_back(std::move(proof));
    }
    if (!store.Capture(&staged, error, cancelled) || !Recheck(environment, lock, after.data_->trigger, after.data_->scripts, error, cancelled, effectiveSnapshot)) return false;
    *output = std::move(result); return true;
}
}}
