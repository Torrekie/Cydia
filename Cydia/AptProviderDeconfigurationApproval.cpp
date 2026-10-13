/* Pure bounded codec; no native I/O, hashing, relationship evaluation or child.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderDeconfigurationApproval.hpp"
#include <algorithm>
#include <limits>
#include <set>

namespace CydiaAPT { namespace Provider {
namespace {
namespace B = BinaryRelationships;
const char Tag[] = "CYDIA-DECONFIGURATION-APPROVAL-1";
bool Fail(std::string *error, const char *code = "provider_deconfiguration_approval_invalid") {
    if (error) *error = code;
    return false;
}
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
std::string Slot(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
std::string Generation(const ExecutionPackage &p) { return Slot(p) + '@' + p.version; }
bool Same(const ExecutionPackage &a, const ExecutionPackage &b) {
    return a.package == b.package && a.version == b.version && a.architecture == b.architecture;
}
bool Package(const ExecutionPackage &p) {
    std::shared_ptr<const B::Package> parsed; B::Error error;
    return B::ParsePackage(p.package, p.version, p.architecture, "no", "", &parsed, &error);
}
bool TransactionShape(const TransactionData &v) {
    if (v.registeredArchitectures.size() > 128 || v.packages.size() > MaximumDeconfigurationActions ||
        v.issues.size() > MaximumDeconfigurationActions) return false;
    for (const auto *list : {&v.installs, &v.reinstalls, &v.upgrades, &v.downgrades, &v.removes, &v.purges})
        if (list->size() > MaximumDeconfigurationActions) return false;
    for (const auto &item : v.packages)
        if (!Package({item.second.identity.baseName, item.second.version, item.second.identity.versionArchitecture})) return false;
    return true;
}
struct Action {
    const ReviewedAction *value = nullptr;
    std::size_t position = 0;
    std::uint64_t precedingUnpack = 0;
};
bool ReviewShape(const ReviewedTransaction &review, std::map<std::uint64_t, Action> *actions) {
    Message binding; binding.sequence = 1; binding.operation = Operation::RunPackageManager; binding.binding = review.binding;
    if (!ValidRequestBinding(binding) || !TransactionShape(review.transaction) || review.execution.actions.empty() ||
        review.execution.actions.size() > MaximumDeconfigurationActions || review.execution.archives.size() > MaximumDeconfigurationActions) return false;
    std::map<std::string, const ArchiveManifest *> archives;
    for (const auto &archive : review.execution.archives)
        if (!ValidIdentityToken(archive.identifier) || !Package(archive.package) ||
            !archives.emplace(archive.identifier, &archive).second) return false;
    std::set<std::string> used, unique;
    std::map<std::string, std::uint64_t> unpacked;
    for (std::size_t position = 0; position < review.execution.actions.size(); ++position) {
        const auto &item = review.execution.actions[position];
        if (!item.identifier || !Package(item.package) || static_cast<unsigned>(item.action) > static_cast<unsigned>(ExecutionAction::Purge) ||
            !unique.insert(std::to_string(static_cast<unsigned>(item.action)) + ':' + Generation(item.package)).second) return false;
        Action action; action.value = &item; action.position = position;
        const auto prior = unpacked.find(Slot(item.package));
        if (prior != unpacked.end()) action.precedingUnpack = prior->second;
        if (!actions->emplace(item.identifier, action).second) return false;
        if (item.action == ExecutionAction::Unpack) {
            const auto archive = archives.find(item.archive);
            if (archive == archives.end() || !Same(archive->second->package, item.package) || !used.insert(item.archive).second) return false;
            unpacked[Slot(item.package)] = item.identifier;
        } else if (!item.archive.empty()) return false;
    }
    return used.size() == archives.size();
}
bool Shape(const DeconfigurationAllowanceSet &value, std::string *error) {
    if (!Digest(value.identity) || !Digest(value.initialCheckpoint) || !Digest(value.nativeAuthorityIdentity) ||
        value.allowances.size() > MaximumDeconfigurationActions) return Fail(error);
    std::map<std::uint64_t, Action> actions;
    if (!ReviewShape(value.primaryReview, &actions)) return Fail(error);
    std::size_t causes = 0, relationBytes = 0;
    for (const auto &entry : value.allowances) {
        const auto &allowance = entry.second;
        if (!Package(allowance.installed) || entry.first != Generation(allowance.installed) ||
            static_cast<unsigned>(allowance.selection) > static_cast<unsigned>(DpkgSelection::Purge) ||
            allowance.initialStatus <= DpkgPackageStatus::HalfConfigured || allowance.initialStatus > DpkgPackageStatus::Installed ||
            allowance.diskStatus <= DpkgPackageStatus::HalfConfigured || allowance.diskStatus > DpkgPackageStatus::Installed ||
            (!allowance.configVersion.empty() && !B::ValidVersion(allowance.configVersion)) ||
            !Digest(allowance.installedControlIdentity) || !Digest(allowance.installedScriptsIdentity) || allowance.causes.empty() ||
            allowance.causes.size() > MaximumDeconfigurationCauses - causes) return Fail(error);
        causes += allowance.causes.size();
        std::size_t lastPosition = 0; bool first = true;
        std::set<std::string> unique;
        for (const auto &cause : allowance.causes) {
            const auto action = actions.find(cause.unpackAction);
            if (action == actions.end() || action->second.value->action != ExecutionAction::Unpack ||
                action->second.value->archive != cause.archive || (!first && action->second.position < lastPosition) ||
                static_cast<unsigned>(cause.kind) > static_cast<unsigned>(DeconfigurationCauseKind::SiblingVersionMismatch) ||
                cause.group >= B::MaximumGroups || cause.alternative >= B::MaximumAtoms ||
                (cause.provide != B::DirectPackage && cause.provide >= B::MaximumGroups) ||
                (!cause.comparedVersion.empty() && !B::ValidVersion(cause.comparedVersion))) return Fail(error);
            if (cause.canonicalRelation.size() > MaximumDeconfigurationApprovalBytes - relationBytes)
                return Fail(error, "provider_deconfiguration_approval_limit");
            relationBytes += cause.canonicalRelation.size();
            if (!unique.insert(std::to_string(cause.unpackAction) + ':' + std::to_string(static_cast<unsigned>(cause.kind)) + ':' +
                std::to_string(cause.group) + ':' + std::to_string(cause.alternative) + ':' + std::to_string(cause.provide)).second) return Fail(error);
            if (cause.kind == DeconfigurationCauseKind::Breaks) {
                std::shared_ptr<const B::Field> field; B::Error reason;
                if (!B::ParseField(B::Kind::Breaks, cause.canonicalRelation, &field, &reason) ||
                    field->canonical != cause.canonicalRelation || cause.group >= field->groups.size() ||
                    cause.alternative >= field->groups[cause.group].alternatives.size() ||
                    (cause.provide == B::DirectPackage && cause.comparedVersion != allowance.installed.version)) return Fail(error);
            } else if (!cause.canonicalRelation.empty() || cause.group || cause.alternative || cause.provide != B::DirectPackage ||
                cause.comparedVersion != allowance.installed.version || action->second.value->package.package != allowance.installed.package ||
                action->second.value->package.architecture == allowance.installed.architecture) return Fail(error);
            lastPosition = action->second.position; first = false;
        }
        const auto &endpoint = allowance.endpoint; const auto found = actions.find(endpoint.action);
        if (found == actions.end() || found->second.position <= lastPosition ||
            (endpoint.kind != ExecutionAction::Configure && endpoint.kind != ExecutionAction::Remove && endpoint.kind != ExecutionAction::Purge) ||
            found->second.value->action != endpoint.kind || !Same(found->second.value->package, endpoint.package) ||
            Slot(endpoint.package) != Slot(allowance.installed) || endpoint.precedingUnpack != found->second.precedingUnpack) return Fail(error);
        if (endpoint.precedingUnpack) {
            const auto unpack = actions.find(endpoint.precedingUnpack);
            if (unpack == actions.end() || unpack->second.value->action != ExecutionAction::Unpack ||
                unpack->second.position <= lastPosition || !Same(unpack->second.value->package, endpoint.package)) return Fail(error);
        } else if (!Same(endpoint.package, allowance.installed)) return Fail(error);
    }
    return true;
}
class Output {
    Writer writer_;
public:
    bool Raw(const std::string &bytes) {
        return bytes.size() <= MaximumDeconfigurationApprovalBytes - writer_.result().size() && writer_.bytes(bytes.data(), bytes.size());
    }
    bool Number(std::uint64_t value, unsigned width = 8) {
        return width <= MaximumDeconfigurationApprovalBytes - writer_.result().size() && writer_.integer(value, width);
    }
    bool String(const std::string &value) {
        return value.size() <= MaximumDeconfigurationApprovalBytes && Number(value.size(), 4) && Raw(value);
    }
    bool PackageValue(const ExecutionPackage &p) { return String(p.package) && String(p.version) && String(p.architecture); }
    const std::string &Bytes() const { return writer_.result(); }
};
bool String(Reader &reader, std::string *value, std::size_t maximum) {
    std::uint64_t size; return reader.integer(&size, 4) && size <= maximum && reader.bytes(size, value);
}
template<class T> bool Vector(Reader &reader, std::vector<T> *value, std::size_t maximum) {
    std::uint64_t count;
    if (!reader.integer(&count, 4) || count > maximum || !reader.collection(count)) return false;
    for (std::uint64_t i = 0; i < count; ++i) {
        T item; if (!reader(item)) { reader.endCollection(); return false; }
        value->push_back(std::move(item));
    }
    reader.endCollection(); return true;
}
bool ReadReview(const std::string &bytes, ReviewedTransaction *review) {
    // Same normative protocol field order; explicit outer counts prevent an
    // 8 MiB approval from reserving the protocol's much larger action limit.
    // Changing that field order requires a new standalone approval tag too.
    Reader reader(bytes); auto &t = review->transaction;
    if (!Vector(reader, &t.registeredArchitectures, 128)) return false;
    for (auto *list : {&t.installs, &t.reinstalls, &t.upgrades, &t.downgrades, &t.removes, &t.purges})
        if (!Vector(reader, list, MaximumDeconfigurationActions)) return false;
    if (!Vector(reader, &t.issues, MaximumDeconfigurationActions)) return false;
    std::uint64_t count;
    if (!reader.integer(&count, 4) || count > MaximumDeconfigurationActions || !reader.collection(count)) return false;
    for (std::uint64_t i = 0; i < count; ++i) {
        std::string name; TransactionPackageData package;
        if (!reader(name, package) || !t.packages.emplace(name, std::move(package)).second) { reader.endCollection(); return false; }
    }
    reader.endCollection();
    return reader(t.downloading, t.resuming, t.removesEssential, t.substrate, review->binding) &&
        Vector(reader, &review->execution.archives, MaximumDeconfigurationActions) &&
        Vector(reader, &review->execution.actions, MaximumDeconfigurationActions) && reader.complete();
}
bool Write(const DeconfigurationAllowanceSet &value, const std::string &review, Output *out) {
    if (!out->String(Tag) || !out->String(value.identity) || !out->String(value.initialCheckpoint) ||
        !out->String(value.nativeAuthorityIdentity) || !out->String(review) || !out->Number(value.allowances.size(), 4)) return false;
    for (const auto &entry : value.allowances) {
        const auto &a = entry.second;
        if (!out->String(entry.first) || !out->PackageValue(a.installed) || !out->Number(static_cast<unsigned>(a.selection), 4) ||
            !out->Number(static_cast<unsigned>(a.initialStatus), 4) || !out->Number(static_cast<unsigned>(a.diskStatus), 4) ||
            !out->String(a.configVersion) || !out->String(a.installedControlIdentity) || !out->String(a.installedScriptsIdentity) ||
            !out->Number(a.causes.size(), 4)) return false;
        for (const auto &cause : a.causes)
            if (!out->Number(static_cast<unsigned>(cause.kind), 4) || !out->Number(cause.unpackAction) ||
                !out->String(cause.archive) || !out->String(cause.canonicalRelation) || !out->String(cause.comparedVersion) ||
                !out->Number(cause.group) || !out->Number(cause.alternative) ||
                !out->Number(cause.provide == B::DirectPackage ? std::numeric_limits<std::uint64_t>::max() : cause.provide)) return false;
        if (!out->Number(a.endpoint.action) || !out->Number(a.endpoint.precedingUnpack) ||
            !out->Number(static_cast<unsigned>(a.endpoint.kind), 4) || !out->PackageValue(a.endpoint.package)) return false;
    }
    return true;
}
bool Enum(Reader &reader, std::uint64_t *value, unsigned maximum) {
    return reader.integer(value, 4) && *value <= maximum;
}
bool Read(const std::string &bytes, DeconfigurationAllowanceSet *value) {
    Reader reader(bytes); std::string tag, review;
    if (!String(reader, &tag, sizeof(Tag)) || tag != Tag || !String(reader, &value->identity, 64) ||
        !String(reader, &value->initialCheckpoint, 64) || !String(reader, &value->nativeAuthorityIdentity, 64) ||
        !String(reader, &review, MaximumDeconfigurationApprovalBytes) || !ReadReview(review, &value->primaryReview)) return false;
    std::uint64_t count;
    if (!reader.integer(&count, 4) || count > MaximumDeconfigurationActions || !reader.collection(count)) return false;
    std::size_t totalCauses = 0;
    for (std::uint64_t i = 0; i < count; ++i) {
        std::string key; DeconfigurationAllowance a; std::uint64_t selection, initial, disk, causes;
        if (!String(reader, &key, 4096) || !reader(a.installed) || !Enum(reader, &selection, static_cast<unsigned>(DpkgSelection::Purge)) ||
            !Enum(reader, &initial, static_cast<unsigned>(DpkgPackageStatus::Installed)) ||
            !Enum(reader, &disk, static_cast<unsigned>(DpkgPackageStatus::Installed)) || !String(reader, &a.configVersion, 1024) ||
            !String(reader, &a.installedControlIdentity, 64) || !String(reader, &a.installedScriptsIdentity, 64) ||
            !reader.integer(&causes, 4) || causes > MaximumDeconfigurationCauses - totalCauses || !reader.collection(causes)) return false;
        a.selection = static_cast<DpkgSelection>(selection); a.initialStatus = static_cast<DpkgPackageStatus>(initial);
        a.diskStatus = static_cast<DpkgPackageStatus>(disk); totalCauses += causes;
        for (std::uint64_t c = 0; c < causes; ++c) {
            DeconfigurationCause cause; std::uint64_t kind, group, alternative, provide;
            if (!Enum(reader, &kind, static_cast<unsigned>(DeconfigurationCauseKind::SiblingVersionMismatch)) || !reader(cause.unpackAction) ||
                !String(reader, &cause.archive, 512) || !String(reader, &cause.canonicalRelation, B::MaximumFieldBytes) ||
                !String(reader, &cause.comparedVersion, 1024) || !reader(group, alternative, provide) ||
                group >= B::MaximumGroups || alternative >= B::MaximumAtoms ||
                (provide != std::numeric_limits<std::uint64_t>::max() && provide >= B::MaximumGroups)) return false;
            cause.kind = static_cast<DeconfigurationCauseKind>(kind); cause.group = group; cause.alternative = alternative;
            cause.provide = provide == std::numeric_limits<std::uint64_t>::max() ? B::DirectPackage : static_cast<std::size_t>(provide);
            a.causes.push_back(std::move(cause));
        }
        reader.endCollection(); std::uint64_t kind;
        if (!reader(a.endpoint.action, a.endpoint.precedingUnpack) || !Enum(reader, &kind, static_cast<unsigned>(ExecutionAction::Purge)) ||
            !reader(a.endpoint.package)) return false;
        a.endpoint.kind = static_cast<ExecutionAction>(kind);
        if (!value->allowances.emplace(std::move(key), std::move(a)).second) return false;
    }
    reader.endCollection(); return reader.complete();
}
}
bool EncodeDeconfigurationApproval(const DeconfigurationAllowanceSet &value, std::string *bytes, std::string *error) {
    if (!bytes) return Fail(error);
    bytes->clear();
    if (!Shape(value, error)) return false;
    std::string review;
    if (!Encode(value.primaryReview, &review) || review.size() > MaximumDeconfigurationApprovalBytes)
        return Fail(error, "provider_deconfiguration_approval_limit");
    Output output;
    if (!Write(value, review, &output)) return Fail(error, "provider_deconfiguration_approval_limit");
    *bytes = output.Bytes(); if (error) error->clear(); return true;
}
bool DecodeDeconfigurationApproval(const std::string &bytes, DeconfigurationAllowanceSet *value, std::string *error) {
    if (!value) return Fail(error);
    *value = DeconfigurationAllowanceSet();
    if (bytes.size() > MaximumDeconfigurationApprovalBytes) return Fail(error, "provider_deconfiguration_approval_limit");
    DeconfigurationAllowanceSet parsed; std::string canonical;
    if (!Read(bytes, &parsed)) return Fail(error);
    if (!EncodeDeconfigurationApproval(parsed, &canonical, error)) return false;
    if (canonical != bytes) return Fail(error);
    *value = std::move(parsed); if (error) error->clear(); return true;
}
}}
