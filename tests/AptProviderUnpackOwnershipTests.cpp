/* Pure native sufficient-condition fixtures. No files, child or authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderUnpackOwnership.hpp"
#include <cstdlib>
#include <iostream>

namespace {
namespace A = CydiaAPT::Provider;
namespace C = CydiaPackages;
using Ready = A::UnpackOwnershipReadiness;
using Error = A::UnpackOwnershipError;
using Kind = A::UnpackOwnershipWitnessKind;
void Require(bool yes, const char *why) {
    if (!yes) { std::cerr << "[unpack-ownership] " << why << '\n'; std::exit(1); }
}
std::string Key(const A::ExecutionPackage &p) { return p.package + ':' + p.architecture; }
C::ArchiveDataInventoryEntry Member(const std::string &name, char type = '0', const std::string &link = "") {
    C::ArchiveDataInventoryEntry result; result.name = name; result.type = result.headerType = type; result.link = link;
    if (type == '1') result.hardlinkTarget = link;
    return result;
}
struct Fixture {
    A::InstalledOwnershipMetadata installed;
    std::vector<A::UnpackOwnershipArchive> batch;
    A::NativeUnpackListEvidence proofs;
    Fixture() : installed() {
        installed.complete = true; installed.infoFormat = 1;
        installed.packageStateIdentity = "state:fixture"; installed.evidenceIdentity.assign(64, 'a');
    }
    void Installed(A::ExecutionPackage package, std::vector<std::string> paths, const std::string &multi = "no",
        A::DpkgPackageStatus phase = A::DpkgPackageStatus::Installed, bool absent = false) {
        A::InstalledPackageOwnership item; item.package = package; item.multiArch = multi;
        item.status = item.diskStatus = phase; item.selection = A::DpkgSelection::Install;
        item.disappearanceEligible = phase > A::DpkgPackageStatus::ConfigFiles;
        item.controlIdentity.assign(64, 'b'); item.evidenceIdentity.assign(64, 'c');
        item.list = CydiaRuntime::Privileged::Evidence(); item.list.path = "/fixture/info/" + Key(package) + ".list";
        item.list.absent = absent; item.paths = std::move(paths);
        for (const auto &path : item.paths) item.list.bytes += path + '\n';
        installed.packages[Key(package)] = std::move(item);
    }
    void Archive(std::uint64_t action, A::ExecutionPackage package, std::vector<C::ArchiveDataInventoryEntry> entries,
        const std::string &multi = "no") {
        A::UnpackOwnershipArchive item; item.action.identifier = action; item.action.action = A::ExecutionAction::Unpack;
        item.action.package = package; item.action.archive = "archive:" + std::to_string(action);
        item.multiArch = multi; item.archiveFileIdentity = "file:" + std::to_string(action);
        std::shared_ptr<C::ArchiveDataInventory> inventory(new C::ArchiveDataInventory()); inventory->complete = true;
        inventory->identity = {package.package, package.version, package.architecture};
        for (std::size_t i = 0; i < entries.size(); ++i) entries[i].ordinal = i + 1;
        inventory->entries = std::move(entries); item.inventory = inventory; batch.push_back(std::move(item));
    }
    void Rules(std::size_t index, std::vector<std::uint64_t> members = {1}, bool empty = false) {
        const auto &archive = batch.at(index);
        proofs.nativeAuthorityIdentity = "native:fixture"; proofs.ownershipIdentity = installed.evidenceIdentity;
        A::NativeUnpackArchiveListEvidence proof; proof.action = archive.action.identifier;
        proof.archive = archive.action.archive; proof.archiveFileIdentity = archive.archiveFileIdentity;
        proof.failureLists = A::NativeUnpackFailureLists::PreviousOrCompleteReplacement;
        proof.namesBoundedByPreviousAndArchive = true;
        proof.replacement = empty ? A::NativeUnpackReplacementList::EmptyOrRootOnly : A::NativeUnpackReplacementList::GuaranteedMembers;
        proof.guaranteedMembers = std::move(members); proofs.archives.push_back(std::move(proof));
    }
    A::UnpackOwnershipResult Check() const { return A::EvaluateUnpackOwnership(installed, batch, "amd64", proofs); }
};
bool Witness(const A::UnpackOwnershipResult &result, const std::string &name, Kind kind, std::uint64_t action = 0,
    std::uint64_t introduced = 0) {
    for (const auto &witness : result.witnesses) if (witness.package.package == name && witness.kind == kind &&
        (!action || witness.unpackAction == action) && witness.introducedBy == introduced) return true;
    return false;
}
void NativeSavingNames() {
    Fixture f; f.Installed({"victim", "1", "amd64"}, {"/not-required-to-exist"});
    f.Archive(9, {"incoming", "1", "amd64"}, {Member("/new")});
    Require(f.Check().readiness == Ready::Ready && Witness(f.Check(), "victim", Kind::UntouchedSavingName),
        "logical exclusive name saves without filesystem type/existence guesses");
    f.batch.clear(); f.Archive(9, {"incoming", "1", "amd64"}, {Member("/not-required-to-exist", '5')});
    auto result = f.Check();
    Require(result.readiness == Ready::PotentialDisappearance && result.package.package == "victim" && result.witnesses.empty(),
        "directory member still prevents saving; no partial witnesses published");
    Fixture shared; shared.Installed({"victim", "1", "amd64"}, {"/shared"});
    shared.Installed({"residual", "1", "all"}, {"/shared"}, "no", A::DpkgPackageStatus::ConfigFiles);
    shared.Archive(1, {"incoming", "1", "amd64"}, {Member("/unrelated")});
    Require(shared.Check().readiness == Ready::PotentialDisappearance,
        "ConfigFiles third-party ownership matters even without incoming overlap");
    shared.installed.packages.erase("residual:all");
    shared.Installed({"incoming", "0", "amd64"}, {"/shared"});
    Require(shared.Check().readiness == Ready::Ready, "current target is not a third-party owner");
    Fixture links; links.Installed({"victim", "1", "amd64"}, {"/target"});
    links.Archive(2, {"incoming", "1", "amd64"}, {Member("/link", '2', "/target")});
    Require(links.Check().readiness == Ready::Ready, "link target is not a second payload member");
    links.batch.clear(); links.Archive(2, {"incoming", "1", "amd64"}, {Member("/target", '2', "/elsewhere")});
    Require(links.Check().readiness == Ready::PotentialDisappearance, "link's own native name counts as incoming");
}
void NativeEmptyAndInstances() {
    Fixture f; f.Installed({"absent", "1", "amd64"}, {}, "no", A::DpkgPackageStatus::Installed, true);
    f.Installed({"empty", "1", "amd64"}, {}); f.Installed({"root", "1", "amd64"}, {"/.", "/."});
    f.Installed({"residual", "1", "amd64"}, {"/conf"}, "no", A::DpkgPackageStatus::ConfigFiles);
    f.Archive(1, {"incoming", "1", "amd64"}, {Member("/.", '5')});
    const auto result = f.Check();
    Require(result.readiness == Ready::Ready && Witness(result, "absent", Kind::AbsentNativeList) &&
        Witness(result, "empty", Kind::EmptyNativeList) && Witness(result, "root", Kind::RootOnlyNativeList),
        "missing, explicitly empty and exact root sentinel are separate native loader cases");
    Fixture same; same.Installed({"library", "1", "i386"}, {"/shared"}, "same");
    same.Archive(1, {"library", "2", "amd64"}, {Member("/shared")}, "same");
    Require(same.Check().readiness == Ready::Ready && Witness(same.Check(), "library", Kind::MultiArchSame),
        "native same-name coinstallable skip is independent of sibling deconfiguration admission");
    same.Installed({"library", "1", "amd64"}, {"/shared"}, "same");
    same.batch.clear(); same.Archive(2, {"other", "1", "amd64"}, {Member("/new")});
    Require(same.Check().readiness == Ready::Ready, "same victim package-set siblings do not take over its saving name");
    Fixture portable; portable.Installed({"portable", "1", "all"}, {"/owned"});
    portable.Archive(1, {"portable", "2", "amd64"}, {Member("/owned")});
    Require(portable.Check().readiness == Ready::Ready && Witness(portable.Check(), "portable", Kind::CurrentTarget),
        "all-to-native singleton maps to the actual native reused target slot");
    portable.batch.clear(); portable.Archive(1, {"portable", "2", "i386"}, {Member("/owned")});
    Require(portable.Check().error == Error::UnsupportedArchitectureTransition, "unsupported crossgrade refuses rather than inventing a target");
}
Fixture UpgradeBatch() {
    Fixture f; f.Installed({"alpha", "1", "amd64"}, {"/alpha"}); f.Installed({"beta", "1", "amd64"}, {"/beta"});
    // Actual argv order deliberately differs from action-ID sort order.
    f.Archive(20, {"alpha", "2", "amd64"}, {Member("/alpha")});
    f.Archive(10, {"beta", "2", "amd64"}, {Member("/beta")}); return f;
}
void ConditionalBatchProofs() {
    auto f = UpgradeBatch();
    Require(f.Check().readiness == Ready::RequiresFreshBoundary && f.Check().unpackAction == 20,
        "complete inventories alone do not authorize an intermediate installed list");
    f.Rules(0); const auto result = f.Check();
    Require(result.readiness == Ready::Ready && Witness(result, "alpha", Kind::UntouchedSavingName, 10, 20),
        "trusted common old/new private witness preserves an ordinary actual-ordered upgrade batch");
    f.proofs.archives[0].namesBoundedByPreviousAndArchive = false;
    Require(f.Check().readiness == Ready::RequiresFreshBoundary, "effective list name bound cannot be omitted");
    f.proofs.archives[0].namesBoundedByPreviousAndArchive = true;
    f.proofs.archives[0].failureLists = A::NativeUnpackFailureLists::Unverified;
    Require(f.Check().readiness == Ready::RequiresFreshBoundary, "success-only projection cannot cover dpkg per-archive error continuation");
    f.proofs.archives[0].failureLists = A::NativeUnpackFailureLists::PreviousOrCompleteReplacement;
    f.proofs.archives[0].archiveFileIdentity = "another:file";
    Require(f.Check().error == Error::InconsistentListEvidence && f.Check().witnesses.empty(), "native rule proof binds retained archive bytes");
    f.proofs.archives[0].archiveFileIdentity = f.batch[0].archiveFileIdentity;
    f.proofs.archives[0].guaranteedMembers = {2};
    Require(f.Check().error == Error::InconsistentListEvidence, "native inclusion ordinals must exist in exact archive");
}
void EarlierErrorsAndIntroducedVictims() {
    Fixture old; old.Installed({"alpha", "1", "amd64"}, {"/old-alpha"}); old.Installed({"beta", "1", "amd64"}, {"/beta"});
    old.Archive(20, {"alpha", "2", "amd64"}, {Member("/new-alpha")});
    old.Archive(10, {"beta", "2", "amd64"}, {Member("/old-alpha"), Member("/beta")}); old.Rules(0);
    auto result = old.Check();
    Require(result.readiness == Ready::PotentialDisappearance && result.package.version == "1" && result.introducedBy == 0 && result.unpackAction == 10,
        "old-list failure outcome remains checked even when successful replacement has a safe new witness");
    auto &initial = old.installed.packages.at("alpha:amd64");
    initial.status = initial.diskStatus = A::DpkgPackageStatus::ConfigFiles; initial.disappearanceEligible = false;
    Require(old.Check().readiness == Ready::PotentialDisappearance,
        "failed attempted ConfigFiles reinstall can become HalfInstalled and eligible before later archive");
    Fixture fresh; fresh.Archive(20, {"alpha", "1", "amd64"}, {Member("/taken")});
    fresh.Archive(10, {"beta", "1", "amd64"}, {Member("/taken")}); fresh.Rules(0);
    result = fresh.Check();
    Require(result.readiness == Ready::PotentialDisappearance && result.package.package == "alpha" && result.introducedBy == 20,
        "earlier introduced package can disappear in a later archive of the same child");
    fresh.batch.clear(); fresh.proofs.archives.clear();
    fresh.Archive(20, {"alpha", "1", "amd64"}, {Member("/.", '5')});
    fresh.Archive(10, {"beta", "1", "amd64"}, {Member("/beta")}); fresh.Rules(0, {}, true);
    Require(fresh.Check().readiness == Ready::Ready && Witness(fresh.Check(), "alpha", Kind::ParentProvenEmptyOrRootOnly, 10, 20),
        "explicit native empty/root-only replacement proof remains conditional and separately identified");
}
void AtomicInvalidAndBounds() {
    Fixture repeated;
    repeated.Archive(20, {"portable", "1", "all"}, {Member("/old")});
    repeated.Archive(10, {"portable", "2", "all"}, {Member("/new")}); repeated.Rules(0);
    Require(repeated.Check().error == Error::InvalidInput && repeated.Check().witnesses.empty(),
        "distinct action/archive IDs cannot unpack the same native target slot twice");
    repeated.batch.pop_back(); repeated.Archive(10, {"portable", "2", "amd64"}, {Member("/new")});
    Require(repeated.Check().error == Error::InvalidInput && repeated.Check().witnesses.empty(),
        "all-to-native singleton reuse cannot hide a repeated target slot");
    auto f = UpgradeBatch(); f.batch.resize(1);
    const auto native = A::EvaluateUnpackOwnership(f.installed, f.batch,
        std::string(A::MaximumUnpackOwnershipBytes + 1, 'a'));
    Require(native.error == Error::InvalidInput && native.witnesses.empty(),
        "oversized native architecture is rejected before deriving copied package metadata");
    auto inventory = std::make_shared<C::ArchiveDataInventory>(*f.batch[0].inventory); f.batch[0].inventory = inventory;
    inventory->complete = false;
    Require(f.Check().error == Error::IncompleteInventory, "partial inventory does not become no-disappearance proof");
    inventory->complete = true; inventory->entries[0].name = "/a/./b";
    Require(f.Check().error == Error::InvalidInventory, "native name ambiguity cannot use layout normalization");
    inventory->entries[0].name = "/alpha"; inventory->entries[0].headerType = '0'; inventory->entries[0].type = '5';
    Require(f.Check().error == Error::InvalidInventory, "legacy trailing slash dispatch does not establish regular native semantics");
    inventory->entries[0].type = '0'; inventory->entries[0].ordinal = 2;
    Require(f.Check().error == Error::InvalidInventory, "actual native member ordinal is required");
    inventory->entries[0].ordinal = 1;
    f.installed.packages.at("beta:amd64").paths[0] = "/invented";
    Require(f.Check().error == Error::InconsistentListEvidence && f.Check().witnesses.empty(), "parsed ownership must match retained raw list");
    f = UpgradeBatch(); f.Rules(0); f.proofs.nativeAuthorityIdentity.assign(A::MaximumUnpackOwnershipBytes + 1, 'x');
    Require(f.Check().readiness == Ready::Unsupported && f.Check().witnesses.empty(), "oversized parent binding is not copied into output");
    Fixture count;
    count.Archive(1, {"incoming", "1", "amd64"}, {});
    count.batch.resize(A::MaximumUnpackOwnershipArchives + 1, count.batch[0]);
    Require(count.Check().readiness == Ready::Unsupported, "batch item count is bounded before deriving slots");
    Fixture amplification;
    // Small shared strings can still create many witnesses; the step/output
    // bounds cover derived work rather than trusting raw input byte size.
    for (unsigned i = 0; i != 1100; ++i) amplification.Installed({"package" + std::to_string(i), "1", "amd64"}, {});
    for (unsigned i = 0; i != 1100; ++i) amplification.Archive(i + 1, {"incoming" + std::to_string(i), "1", "amd64"}, {});
    for (unsigned i = 0; i + 1 != amplification.batch.size(); ++i) amplification.Rules(i, {}, true);
    const auto bounded = amplification.Check();
    Require(bounded.readiness == Ready::Unsupported && bounded.error == Error::LimitExceeded && bounded.witnesses.empty(),
        "generation/witness amplification refuses atomically within explicit derived budgets");
}
}
int main() {
    NativeSavingNames(); NativeEmptyAndInstances(); ConditionalBatchProofs(); EarlierErrorsAndIntroducedVictims(); AtomicInvalidAndBounds();
    std::cout << "[unpack-ownership] PASS: native saving names, conditional intermediate lists, failure continuation and bounded atomicity\n";
}
