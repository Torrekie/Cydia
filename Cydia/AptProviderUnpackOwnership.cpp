/* Native sufficient saving-name proofs, not a dpkg simulator.
 * dpkg 1.21/1.23: archives.c::filesavespackage/archivefiles;
 * unpack.c::pkg_disappear_others; lib/dpkg/db-fsys-files.c.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderUnpackOwnership.hpp"
#include "Cydia/AptProviderBinaryRelationships.hpp"
#include <algorithm>
#include <set>

namespace CydiaAPT { namespace Provider {
namespace {
namespace B = BinaryRelationships;
using Error = UnpackOwnershipError;
using Ready = UnpackOwnershipReadiness;
using Kind = UnpackOwnershipWitnessKind;
struct Budget {
    std::size_t bytes = 0, steps = 0, output = 0, retained = 0;
    bool Input(std::size_t n) { if (n > MaximumUnpackOwnershipBytes - bytes) return false; bytes += n; return true; }
    bool Step() { return ++steps <= MaximumUnpackOwnershipSteps; }
    bool Output(std::size_t n) { if (n > MaximumUnpackOwnershipBytes - output) return false; output += n; return true; }
    bool Retain(std::size_t n) { if (n > MaximumUnpackOwnershipBytes - retained) return false; retained += n; return true; }
};
bool Token(const std::string &s) {
    if (s.empty() || s.size() > 512) return false;
    for (unsigned char c : s) if (c <= 32 || c >= 127) return false;
    return true;
}
bool Digest(const std::string &s) { return s.size() == 64 && s.find_first_not_of("0123456789abcdef") == std::string::npos; }
bool Path(const std::string &s) {
    if (s.empty() || s.size() > MaximumOwnershipPathBytes || s.front() != '/') return false;
    for (unsigned char c : s) if (c < 32 || c == 127) return false;
    if (s == "/." || s == "/") return true;
    std::size_t at = 1;
    while (at < s.size()) {
        const auto end = s.find('/', at), count = end == std::string::npos ? s.size() - at : end - at;
        if (!count || (count == 1 && s[at] == '.') || (count == 2 && s.compare(at, 2, "..") == 0)) return false;
        if (end == std::string::npos) return true;
        at = end + 1;
    }
    return false;
}
bool Bytes(const ExecutionPackage &p, Budget *b) {
    return b->Input(p.package.size()) && b->Input(p.version.size()) && b->Input(p.architecture.size());
}
bool Package(const ExecutionPackage &p, const std::string &multi) {
    std::shared_ptr<const B::Package> parsed; B::Error error;
    return B::ParsePackage(p.package, p.version, p.architecture, multi, "", &parsed, &error);
}
std::string Key(const ExecutionPackage &p) { return p.package + ':' + p.architecture; }
UnpackOwnershipResult Failure(Error code, Ready readiness = Ready::Unsupported,
    const ExecutionPackage &package = {}, std::uint64_t action = 0, std::uint64_t introduced = 0) {
    UnpackOwnershipResult result; result.error = code; result.readiness = readiness;
    result.package = package; result.unpackAction = action; result.introducedBy = introduced; return result;
}
// Check consistency of a protected capture's parsed list without acquiring
// new provenance or interpreting any filesystem path. This is the same narrow
// list subset documented by ParseInstalledOwnershipList.
bool SameList(const InstalledPackageOwnership &item, Budget *budget, Error *error) {
    *error = Error::InconsistentListEvidence;
    if (item.paths.size() > MaximumOwnershipPaths || item.list.bytes.size() > MaximumOwnershipFileBytes ||
        !budget->Input(item.list.bytes.size()) || !budget->Input(item.list.path.size())) { *error = Error::LimitExceeded; return false; }
    if (!Path(item.list.path)) return false;
    if (item.list.absent) return item.list.bytes.empty() && item.paths.empty();
    std::size_t at = 0, index = 0;
    while (at < item.list.bytes.size()) {
        if (!budget->Step()) { *error = Error::LimitExceeded; return false; }
        if (index >= item.paths.size()) return false;
        const auto end = item.list.bytes.find('\n', at);
        if (end == std::string::npos || end - at > MaximumOwnershipPathBytes + 1) return false;
        std::size_t count = end - at;
        if (count && item.list.bytes[at + count - 1] == '/') --count;
        const auto &name = item.paths[index++];
        if (!Path(name) || name == "/" || name.size() != count || item.list.bytes.compare(at, count, name) != 0) return false;
        if (!budget->Input(name.size())) { *error = Error::LimitExceeded; return false; }
        at = end + 1;
    }
    return index == item.paths.size();
}
struct Slot {
    std::string name;
    std::set<std::string> architectures, modes;
};
struct Generation {
    ExecutionPackage package;
    std::string slot, multi;
    bool eligible = false;
    std::uint64_t introduced = 0;
    Kind listKind = Kind::UntouchedSavingName;
    const std::vector<std::string> *names = nullptr;
    std::shared_ptr<const std::vector<std::string>> ownedNames;
};
bool AllSame(const Slot &slot) { return slot.modes.size() == 1 && slot.modes.count("same"); }
bool RootOnly(const std::vector<std::string> &names) {
    return !names.empty() && std::all_of(names.begin(), names.end(), [](const std::string &name) { return name == "/."; });
}
bool AddWitness(const Generation &generation, std::uint64_t action, Kind kind, const std::string &name,
    Budget *budget, UnpackOwnershipResult *result) {
    if (!budget->Output(sizeof(UnpackOwnershipWitness) + generation.package.package.size() +
        generation.package.version.size() + generation.package.architecture.size() + name.size())) return false;
    UnpackOwnershipWitness witness; witness.package = generation.package; witness.unpackAction = action;
    witness.introducedBy = generation.introduced; witness.kind = kind; witness.name = name;
    result->witnesses.push_back(std::move(witness)); return true;
}
bool AddOwner(std::map<std::string, std::set<std::string>> *owners, const std::string &name,
    const std::string &slot, Budget *budget) {
    if (!budget->Step()) return false;
    auto found = owners->find(name);
    if (found == owners->end()) {
        if (!budget->Retain(128 + name.size())) return false;
        found = owners->emplace(name, std::set<std::string>()).first;
    }
    if (!found->second.count(slot)) {
        if (!budget->Retain(64 + slot.size())) return false;
        found->second.insert(slot);
    }
    return true;
}
}

UnpackOwnershipResult EvaluateUnpackOwnership(const InstalledOwnershipMetadata &initial,
    const std::vector<UnpackOwnershipArchive> &batch, const std::string &native, const NativeUnpackListEvidence &nativeLists) {
    Budget budget;
    if (initial.packages.size() > MaximumOwnershipPackages || batch.size() > MaximumUnpackOwnershipArchives)
        return Failure(Error::LimitExceeded);
    if (!initial.complete || !Digest(initial.evidenceIdentity) || !Token(initial.packageStateIdentity) ||
        initial.infoFormat > 1 || batch.empty() || nativeLists.archives.size() > batch.size()) return Failure(Error::InvalidInput);
    if ((!nativeLists.nativeAuthorityIdentity.empty() && !Token(nativeLists.nativeAuthorityIdentity)) ||
        (!nativeLists.ownershipIdentity.empty() && !Digest(nativeLists.ownershipIdentity))) return Failure(Error::InvalidInput);
    if (native.empty() || native.size() > 255) return Failure(Error::InvalidInput);
    ExecutionPackage nativeProbe{"native-probe", "1", native};
    if (native == "all" || !Package(nativeProbe, "no")) return Failure(Error::InvalidInput);
    std::map<std::string, Slot> slots;
    std::map<std::string, std::vector<std::string>> byName;
    std::map<std::string, std::set<std::string>> owners;
    std::vector<Generation> generations;
    std::size_t names = 0;
    for (const auto &entry : initial.packages) {
        const auto &item = entry.second;
        if (!budget.Input(entry.first.size()) || !Bytes(item.package, &budget) || !budget.Input(item.multiArch.size()) ||
            !budget.Input(item.configVersion.size())) return Failure(Error::LimitExceeded);
        if (item.status == DpkgPackageStatus::NotInstalled || static_cast<unsigned>(item.status) > static_cast<unsigned>(DpkgPackageStatus::Installed) ||
            static_cast<unsigned>(item.diskStatus) > static_cast<unsigned>(DpkgPackageStatus::Installed) ||
            static_cast<unsigned>(item.selection) > static_cast<unsigned>(DpkgSelection::Purge) ||
            item.disappearanceEligible != (item.status > DpkgPackageStatus::ConfigFiles) ||
            (item.status != item.diskStatus && !(item.status >= DpkgPackageStatus::TriggersAwaited && item.diskStatus >= DpkgPackageStatus::TriggersAwaited)) ||
            !Digest(item.controlIdentity) || !Digest(item.evidenceIdentity) || !Package(item.package, item.multiArch) || entry.first != Key(item.package))
            return Failure(Error::InvalidInput);
        Error listError;
        if (!SameList(item, &budget, &listError)) return Failure(listError);
        if (item.paths.size() > MaximumOwnershipPaths - names) return Failure(Error::LimitExceeded);
        names += item.paths.size();
        if (!budget.Retain(512 + entry.first.size() * 3 + item.package.package.size() * 3 + item.package.architecture.size() +
            item.package.version.size() + item.multiArch.size() * 2)) return Failure(Error::LimitExceeded);
        Slot slot; slot.name = item.package.package; slot.architectures.insert(item.package.architecture); slot.modes.insert(item.multiArch);
        slots.emplace(entry.first, std::move(slot)); byName[item.package.package].push_back(entry.first);
        Generation generation; generation.package = item.package; generation.slot = entry.first; generation.multi = item.multiArch;
        generation.eligible = item.disappearanceEligible; generation.names = &item.paths;
        if (item.list.absent) generation.listKind = Kind::AbsentNativeList;
        else if (item.paths.empty()) generation.listKind = Kind::EmptyNativeList;
        else if (RootOnly(item.paths)) generation.listKind = Kind::RootOnlyNativeList;
        generations.push_back(std::move(generation));
        for (const auto &name : item.paths) if (!AddOwner(&owners, name, entry.first, &budget)) return Failure(Error::LimitExceeded);
    }
    for (const auto &group : byName) if (group.second.size() > 1)
        for (const auto &slot : group.second) if (!AllSame(slots.at(slot))) return Failure(Error::UnsupportedArchitectureTransition);

    std::set<std::uint64_t> actionIDs; std::set<std::string> archiveIDs, targetIDs;
    std::vector<std::string> targets; std::vector<std::set<std::string>> incoming;
    for (const auto &item : batch) {
        if (!budget.Input(item.action.archive.size()) || !Bytes(item.action.package, &budget) ||
            !budget.Input(item.archiveFileIdentity.size()) || !budget.Input(item.multiArch.size())) return Failure(Error::LimitExceeded);
        if (!budget.Retain(256 + item.action.archive.size())) return Failure(Error::LimitExceeded);
        if (item.action.action != ExecutionAction::Unpack || !item.action.identifier || !Token(item.action.archive) ||
            !Token(item.archiveFileIdentity) || !actionIDs.insert(item.action.identifier).second || !archiveIDs.insert(item.action.archive).second ||
            !Package(item.action.package, item.multiArch)) return Failure(Error::InvalidInput);
        if (!item.inventory || !item.inventory->complete || !item.inventory->reason.empty()) return Failure(Error::IncompleteInventory);
        const auto &inventory = *item.inventory; const auto &package = item.action.package;
        if (inventory.identity.package != package.package || inventory.identity.version != package.version ||
            inventory.identity.architecture != package.architecture || inventory.entries.size() > 100000) return Failure(Error::InvalidInventory);
        std::string target; auto &group = byName[package.package];
        for (const auto &id : group) {
            if (!budget.Step()) return Failure(Error::LimitExceeded);
            if (slots.at(id).architectures.count(package.architecture)) target = id;
        }
        if (group.size() > 1 && item.multiArch != "same") return Failure(Error::UnsupportedArchitectureTransition);
        if (target.empty() && group.size() == 1) {
            const auto &old = slots.at(group.front());
            if (!(AllSame(old) && item.multiArch == "same")) {
                const bool portable = (package.architecture == "all" || package.architecture == native) &&
                    std::all_of(old.architectures.begin(), old.architectures.end(), [&](const std::string &arch) { return arch == "all" || arch == native; });
                if (!portable) return Failure(Error::UnsupportedArchitectureTransition);
                target = group.front();
            }
        }
        if (target.empty()) {
            for (const auto &id : group) if (!AllSame(slots.at(id)) || item.multiArch != "same") return Failure(Error::UnsupportedArchitectureTransition);
            target = Key(package);
            if (!budget.Retain(512 + target.size() * 3 + package.package.size() * 2)) return Failure(Error::LimitExceeded);
            Slot slot; slot.name = package.package;
            slots.emplace(target, std::move(slot)); group.push_back(target);
        }
        // Repeated target unpacks can elide a prior saving name. This model
        // retains old/new generations, but does not simulate repeated lists.
        if (targetIDs.count(target)) return Failure(Error::InvalidInput);
        if (!budget.Retain(256 + package.architecture.size() + item.multiArch.size() + target.size() * 2)) return Failure(Error::LimitExceeded);
        targetIDs.insert(target);
        slots.at(target).architectures.insert(package.architecture); slots.at(target).modes.insert(item.multiArch); targets.push_back(target);
        std::set<std::string> archiveNames;
        for (std::size_t i = 0; i < inventory.entries.size(); ++i) {
            const auto &member = inventory.entries[i];
            if (!budget.Step() || !budget.Input(member.name.size()) || !budget.Input(member.link.size()) ||
                !budget.Input(member.hardlinkTarget.size())) return Failure(Error::LimitExceeded);
            if (!Path(member.name) || member.ordinal != i + 1 || (member.type != '0' && member.type != '1' && member.type != '2' && member.type != '5') ||
                member.type != member.headerType ||
                member.link.size() > MaximumOwnershipPathBytes || member.hardlinkTarget.size() > MaximumOwnershipPathBytes ||
                ((member.name == "/." || member.name == "/") && member.type != '5')) return Failure(Error::InvalidInventory);
            if (!archiveNames.count(member.name)) {
                if (!budget.Retain(64 + member.name.size())) return Failure(Error::LimitExceeded);
                archiveNames.insert(member.name);
            } else if (member.type != '5') return Failure(Error::InvalidInventory);
            if (!AddOwner(&owners, member.name, target, &budget)) return Failure(Error::LimitExceeded);
        }
        if (archiveNames.size() > MaximumOwnershipPaths - names) return Failure(Error::LimitExceeded);
        names += archiveNames.size(); incoming.push_back(std::move(archiveNames));
    }
    std::map<std::uint64_t, const NativeUnpackArchiveListEvidence *> proofs;
    if (!nativeLists.archives.empty() && (!Token(nativeLists.nativeAuthorityIdentity) || nativeLists.ownershipIdentity != initial.evidenceIdentity))
        return Failure(Error::InconsistentListEvidence);
    for (const auto &proof : nativeLists.archives) {
        if (!budget.Input(proof.archive.size()) || !budget.Input(proof.archiveFileIdentity.size()) ||
            proof.guaranteedMembers.size() > 100000 || !budget.Input(proof.guaranteedMembers.size() * sizeof(std::uint64_t))) return Failure(Error::LimitExceeded);
        if (!proofs.emplace(proof.action, &proof).second || !actionIDs.count(proof.action)) return Failure(Error::InconsistentListEvidence);
    }
    // Validate the complete prefix before evaluating any provisional proof.
    // No partial success can be mistaken for permission to start a batch.
    std::vector<std::shared_ptr<const std::vector<std::string>>> replacementNames(batch.size());
    std::vector<Kind> replacementKinds(batch.size(), Kind::UntouchedSavingName);
    for (std::size_t i = 0; i < batch.size(); ++i) {
        const auto found = proofs.find(batch[i].action.identifier);
        if (found == proofs.end()) {
            if (i + 1 == batch.size()) continue;
            return Failure(Error::NativeListContinuityMissing, Ready::RequiresFreshBoundary, batch[i].action.package, batch[i].action.identifier);
        }
        const auto &proof = *found->second;
        if (proof.archive != batch[i].action.archive || proof.archiveFileIdentity != batch[i].archiveFileIdentity)
            return Failure(Error::InconsistentListEvidence);
        if (proof.failureLists != NativeUnpackFailureLists::PreviousOrCompleteReplacement || !proof.namesBoundedByPreviousAndArchive ||
            (proof.replacement != NativeUnpackReplacementList::EmptyOrRootOnly && proof.replacement != NativeUnpackReplacementList::GuaranteedMembers))
            return Failure(Error::NativeListContinuityMissing, Ready::RequiresFreshBoundary, batch[i].action.package, batch[i].action.identifier);
        std::shared_ptr<std::vector<std::string>> guaranteed(new std::vector<std::string>());
        std::uint64_t last = 0;
        for (const auto ordinal : proof.guaranteedMembers) {
            if (!budget.Step()) return Failure(Error::LimitExceeded);
            if (!ordinal || ordinal <= last || ordinal > batch[i].inventory->entries.size()) return Failure(Error::InconsistentListEvidence);
            const auto &name = batch[i].inventory->entries[ordinal - 1].name;
            if (!budget.Retain(sizeof(std::string) + name.size())) return Failure(Error::LimitExceeded);
            last = ordinal; guaranteed->push_back(name);
        }
        if ((proof.replacement == NativeUnpackReplacementList::GuaranteedMembers) == guaranteed->empty()) return Failure(Error::InconsistentListEvidence);
        if (proof.replacement == NativeUnpackReplacementList::EmptyOrRootOnly) replacementKinds[i] = Kind::ParentProvenEmptyOrRootOnly;
        replacementNames[i] = std::move(guaranteed);
    }
    UnpackOwnershipResult result; result.readiness = Ready::Ready;
    result.ownershipIdentity = initial.evidenceIdentity; result.nativeAuthorityIdentity = nativeLists.nativeAuthorityIdentity;
    for (std::size_t i = 0; i < batch.size(); ++i) {
        const auto &item = batch[i];
        for (const auto &generation : generations) {
            if (!budget.Step()) return Failure(Error::LimitExceeded);
            if (!generation.eligible) continue;
            Kind kind = generation.listKind; std::string saving;
            if (generation.slot == targets[i]) kind = Kind::CurrentTarget;
            else if (generation.multi == "same" && item.multiArch == "same" && generation.package.package == item.action.package.package) kind = Kind::MultiArchSame;
            else if (kind == Kind::UntouchedSavingName) {
                for (const auto &name : *generation.names) {
                    if (!budget.Step()) return Failure(Error::LimitExceeded);
                    if (incoming[i].count(name)) continue;
                    bool shared = false;
                    for (const auto &owner : owners.at(name)) {
                        if (!budget.Step()) return Failure(Error::LimitExceeded);
                        if (owner == generation.slot || owner == targets[i] ||
                            (generation.multi == "same" && slots.at(owner).name == generation.package.package)) continue;
                        shared = true; break;
                    }
                    if (!shared) { saving = name; break; }
                }
                if (saving.empty()) return Failure(Error::SavingPathMissing, Ready::PotentialDisappearance,
                    generation.package, item.action.identifier, generation.introduced);
            }
            if (!AddWitness(generation, item.action.identifier, kind, saving, &budget, &result)) return Failure(Error::LimitExceeded);
        }
        if (i + 1 == batch.size()) continue;
        // An earlier error can leave the old binary/list in half-installed
        // state, even when it started as ConfigFiles. Never discard that case.
        for (auto &generation : generations) {
            if (!budget.Step()) return Failure(Error::LimitExceeded);
            if (generation.slot == targets[i]) generation.eligible = true;
        }
        if (!budget.Retain(sizeof(Generation) + item.action.package.package.size() + item.action.package.version.size() +
            item.action.package.architecture.size() + targets[i].size() + item.multiArch.size())) return Failure(Error::LimitExceeded);
        Generation added; added.package = item.action.package; added.slot = targets[i]; added.multi = item.multiArch;
        added.eligible = true; added.introduced = item.action.identifier; added.listKind = replacementKinds[i];
        added.ownedNames = replacementNames[i]; added.names = added.ownedNames.get(); generations.push_back(std::move(added));
    }
    return result;
}
}}
