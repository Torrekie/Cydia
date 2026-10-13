/* Native dpkg relationship cases, based on upstream tests/t-multiarch,
 * tests/t-provides, tests/t-provides-self and tests/t-breaks. The optional
 * native-APT build supplies the real debVS comparator, without a resolver.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBinaryRelationships.hpp"
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <utility>
#if defined(CYDIA_BINARY_RELATIONSHIPS_NATIVE_APT)
#include <apt-pkg/debversion.h>
#include <apt-pkg/pkgcache.h>
#endif

namespace {
namespace B = CydiaAPT::Provider::BinaryRelationships;
using Package = std::shared_ptr<const B::Package>;
using Field = std::shared_ptr<const B::Field>;
void Require(bool condition, const char *message) {
    if (!condition) { std::cerr << "[binary-relationships][FAIL] " << message << '\n'; std::exit(1); }
}
B::VersionComparison Compared(int value) {
    B::VersionComparison result; result.status = B::ComparisonStatus::Compared; result.ordering = value; return result;
}
B::VersionComparison Compare(const std::string &a, const std::string &b) {
#if defined(CYDIA_BINARY_RELATIONSHIPS_NATIVE_APT)
    return Compared(debVS.CmpVersion(a, b));
#else
    // Deliberately limited trusted fixture answers, not a second version
    // ordering implementation hidden in a pure test.
    if (a == b) return Compared(0);
    const std::vector<std::string> order{"0", "1", "2", "3", "9", "10", "20"};
    for (std::size_t i = 0; i < order.size(); ++i) for (std::size_t j = 0; j < order.size(); ++j)
        if (a == order[i] && b == order[j]) return Compared(i < j ? -1 : 1);
    B::VersionComparison failed; failed.status = B::ComparisonStatus::InvalidVersion; return failed;
#endif
}
Package P(const std::string &name, const std::string &version = "1", const std::string &arch = "amd64",
          const std::string &multi = "no", const std::string &provides = "") {
    Package package; B::Error error;
    Require(B::ParsePackage(name, version, arch, multi, provides, &package, &error), "package fixture parse");
    return package;
}
Field F(B::Kind kind, const std::string &text) {
    Field field; B::Error error;
    Require(B::ParseField(kind, text, &field, &error), "field fixture parse"); return field;
}
B::Evaluation E(B::Kind kind, const std::string &text, const Package &source, const std::vector<Package> &candidates,
                B::Use use = B::Use::ConfigureChecks) {
    B::Evaluation result; B::Error error;
    Require(B::Evaluate(*F(kind, text), *source, candidates, "amd64", use, Compare, &result, &error), "evaluation fixture");
    return result;
}
void Parsing() {
    const auto field = F(B::Kind::Depends, " core:any (>= 1:2.0~rc1-3)\n | fallback , exact:iphoneos-arm64 ");
    Require(field->canonical == "core:any (>= 1:2.0~rc1-3) | fallback, exact:iphoneos-arm64" &&
        field->groups.size() == 2 && field->atomCount == 3 &&
        field->groups[0].alternatives[0].qualifier == B::Qualifier::Any &&
        field->groups[1].alternatives[0].architecture == "iphoneos-arm64", "lost binary relation structure");
    Require(F(B::Kind::Depends, "core (< 2), core (> 1)")->canonical == "core (<= 2), core (>= 1)",
        "dpkg obsolete single-angle operators changed meaning");
    Require(F(B::Kind::Provides, "virt (= 1), virt (= 2)")->groups.size() == 2,
        "multiple provided versions collapsed");
    Field output; B::Error error;
    for (const auto kind : {B::Kind::Breaks, B::Kind::Conflicts, B::Kind::Provides, B::Kind::Replaces})
        Require(!B::ParseField(kind, "first | second", &output, &error) && !output &&
            error.code == B::ErrorCode::AlternativesForbidden, "forbidden alternatives accepted");
    for (const auto &text : {"pkg [amd64]", "pkg <!stage1>", "pkg:any-amd64", "pkg:linux-any"})
        Require(!B::ParseField(B::Kind::Depends, text, &output, &error) &&
            error.code == B::ErrorCode::UnsupportedRestrictions, "source-only grammar treated as binary relationship");
    for (const auto &text : {"pkg,", "pkg |", "pkg another", "pkg ()", "pkg (== 1)", "pkg (= 1-)",
            "pkg (= 2147483648:1)", "pkg (= :1)", "pkg (= 1 2)", "UPPER", "pkg:", "pkg:amd64:extra"})
        Require(!B::ParseField(B::Kind::Depends, text, &output, &error) && !output, "malformed binary relation accepted");
    Require(!B::ParseField(B::Kind::Provides, "virt (>= 1)", &output, &error) &&
        error.code == B::ErrorCode::ProvidesRelation, "non-equal provided version given authority");
    Require(!B::ParseField(B::Kind::Depends, std::string("aa\0bb", 5), &output, &error), "NUL relation accepted");
    Package package;
    Require(!B::ParsePackage("portable", "1", "all", "same", "", &package, &error), "Multi-Arch:same all accepted");
    Require(!B::ParsePackage("pkg", "1", "any", "no", "", &package, &error), "wildcard actual package accepted");
    Require(!B::ParsePackage("pkg", "1", "amd64", "unknown", "", &package, &error), "unknown Multi-Arch accepted");
}
void Architectures() {
    const auto native = P("consumer"), foreign = P("consumer", "1", "i386"), portable = P("consumer", "1", "all");
    for (const auto kind : {B::Kind::Depends, B::Kind::PreDepends}) {
        Require(!E(kind, "target", foreign, {P("target")}).allGroupsMatched, "unqualified foreign dependency crossed architecture");
        Require(E(kind, "target", foreign, {P("target", "1", "amd64", "foreign")}).allGroupsMatched,
            "Multi-Arch:foreign did not satisfy foreign unqualified dependency");
        Require(!E(kind, "target", foreign, {P("target", "1", "all", "allowed")}).allGroupsMatched,
            "Architecture:all inherited foreign consumer architecture");
        Require(E(kind, "target", portable, {P("target")}).allGroupsMatched, "all consumer did not use native architecture");
        Require(E(kind, "target:any", foreign, {P("target", "1", "all", "allowed")}).allGroupsMatched,
            "allowed:any all target rejected");
        Require(!E(kind, "target:any", native, {P("target", "1", "amd64", "foreign")}).allGroupsMatched,
            "foreign substituted for allowed:any");
        Require(!E(kind, "target:any", native, {P("target", "1", "amd64", "same")}).allGroupsMatched,
            "same substituted for allowed:any");
        Require(E(kind, "target:i386", native, {P("target", "1", "i386", "same")}).allGroupsMatched,
            "explicit concrete architecture rejected");
        Require(!E(kind, "target:i386", native, {P("target", "1", "amd64", "foreign")}).allGroupsMatched,
            "Multi-Arch:foreign overrode explicit architecture");
        Require(E(kind, "target:all", foreign, {P("target")}).allGroupsMatched,
            "native dpkg all qualifier semantics changed");
    }
    for (const auto kind : {B::Kind::Breaks, B::Kind::Conflicts, B::Kind::Replaces}) {
        Require(E(kind, "target", native, {P("target", "1", "i386")}, B::Use::UnpackChecks).anyGroupMatched,
            "unqualified negative relationship missed foreign instance");
        Require(!E(kind, "target:amd64", native, {P("target", "1", "i386")}, B::Use::UnpackChecks).anyGroupMatched,
            "qualified negative relationship crossed architecture");
    }
    B::Evaluation result; B::Error error;
    auto preserved = F(B::Kind::Depends, "target:native");
    Require(preserved->canonical == "target:native" && !B::Evaluate(*preserved, *foreign, {P("target")}, "amd64",
        B::Use::ConfigureChecks, Compare, &result, &error) && error.code == B::ErrorCode::UnsupportedNativeQualifier,
        "APT-only binary :native rewrite silently authorized native dpkg effect");
    Require(!B::Evaluate(*F(B::Kind::Depends, "target"), *native, {P("target")}, "all", B::Use::ConfigureChecks,
        Compare, &result, &error), "nonconcrete native architecture accepted");
}
void VirtualAndCallsiteSemantics() {
    const auto consumer = P("consumer");
    const auto unversioned = P("provider", "20", "amd64", "no", "virtual");
    Require(!E(B::Kind::Depends, "virtual (>= 1)", consumer, {unversioned}).allGroupsMatched,
        "real package version substituted for versionless Provides");
    Require(E(B::Kind::Depends, "virtual", consumer, {unversioned}).allGroupsMatched, "versionless Provides rejected");
    auto many = E(B::Kind::Depends, "virtual (>= 20), virtual (<= 10)", consumer,
        {P("provider", "1", "amd64", "no", "virtual (= 10), virtual (= 20)")});
    Require(many.allGroupsMatched && many.groups[0].witnesses.size() == 1 && many.groups[1].witnesses.size() == 1 &&
        many.groups[0].witnesses[0].provide == 1 && many.groups[0].witnesses[0].comparedVersion == "20" &&
        many.groups[1].witnesses[0].provide == 0, "lost exact multiple-Provides witness");
    auto alternatives = E(B::Kind::PreDepends, "missing | virtual (>= 10), absent", consumer,
        {P("provider", "1", "amd64", "no", "virtual (= 10)")});
    Require(alternatives.anyGroupMatched && !alternatives.allGroupsMatched && alternatives.groups[0].witnesses[0].alternative == 1,
        "OR alternative or AND group meaning lost");
    const auto otherArch = P("provider", "1", "i386", "no", "virtual (= 10)");
    Require(!E(B::Kind::Depends, "virtual", consumer, {otherArch}).allGroupsMatched &&
        E(B::Kind::Depends, "virtual", consumer, {otherArch}, B::Use::UnpackChecks).allGroupsMatched,
        "depisok/dependencies_ok virtual architecture distinction lost");
    Require(E(B::Kind::Depends, "virtual", consumer, {P("provider", "1", "i386", "foreign", "virtual")}).allGroupsMatched,
        "foreign virtual provider rejected");
    Require(E(B::Kind::Depends, "virtual:any", consumer, {P("provider", "1", "i386", "allowed", "virtual")}).allGroupsMatched,
        "allowed virtual provider did not satisfy any");
    Require(E(B::Kind::Depends, "virtual:i386", consumer,
        {P("provider", "1", "amd64", "no", "virtual:i386")}).allGroupsMatched,
        "qualified Provides architecture was replaced with real package architecture");
    Require(E(B::Kind::Depends, "virtual:any", consumer,
        {P("provider", "1", "amd64", "no", "virtual:any")}).allGroupsMatched,
        "explicit native Provides:any architecture lost");
    const auto differentVersions = P("provider", "1", "amd64", "no", "virtual (= 20)");
    Require(E(B::Kind::Breaks, "virtual (>= 10)", consumer, {differentVersions}, B::Use::UnpackChecks).anyGroupMatched &&
        !E(B::Kind::Breaks, "virtual (>= 10)", consumer, {differentVersions}, B::Use::ConfigureChecks).anyGroupMatched,
        "native Breaks configuration real-and-provided version checks lost");
    Require(!E(B::Kind::Replaces, "virtual", consumer, {unversioned}, B::Use::UnpackChecks).anyGroupMatched,
        "Replaces followed virtual Provides");
    const auto self = P("consumer", "1", "amd64", "same", "virtual");
    const auto sibling = P("consumer", "1", "i386", "same", "virtual");
    Require(!E(B::Kind::Conflicts, "consumer", self, {self, sibling}, B::Use::UnpackChecks).anyGroupMatched &&
        !E(B::Kind::Conflicts, "virtual", self, {self, sibling}, B::Use::UnpackChecks).anyGroupMatched,
        "self package-set Conflict/Provides exclusion lost");
    Require(E(B::Kind::Conflicts, "consumer", self, {P("other", "1", "amd64", "no", "consumer")}, B::Use::UnpackChecks).anyGroupMatched,
        "self Conflict excluded another provider");
    auto breaks = E(B::Kind::Breaks, "consumer", self, {self, sibling}, B::Use::ConfigureChecks);
    Require(breaks.groups[0].witnesses.size() == 1 && breaks.groups[0].witnesses[0].architecture == "i386",
        "configuration Breaks excluded sibling along with exact self");
}
void FailureAndBounds() {
    const auto source = P("source"), target = P("target", "2"); const auto field = F(B::Kind::Depends, "target (>= 1)");
    B::Evaluation result; B::Error error;
    for (const auto status : {B::ComparisonStatus::Unavailable, B::ComparisonStatus::InvalidVersion, B::ComparisonStatus::Failed}) {
        const auto compare = [status](const std::string &, const std::string &) { B::VersionComparison value; value.status = status; return value; };
        Require(!B::Evaluate(*field, *source, {target}, "amd64", B::Use::ConfigureChecks, compare, &result, &error) &&
            result.groups.empty(), "comparator failure became nonmatch or partial success");
    }
    Require(!B::Evaluate(*field, *source, {target}, "amd64", B::Use::ConfigureChecks, {}, &result, &error) &&
        error.code == B::ErrorCode::ComparisonUnavailable, "missing comparator silently fell back");
    const auto throwing = [](const std::string &, const std::string &) -> B::VersionComparison { throw std::runtime_error("fixture"); };
    Require(!B::Evaluate(*field, *source, {target}, "amd64", B::Use::ConfigureChecks, throwing, &result, &error) &&
        error.code == B::ErrorCode::ComparisonFailed, "comparator exception escaped");
    unsigned comparisons = 0;
    const auto partiallyFailing = [&](const std::string &, const std::string &) {
        if (++comparisons == 1) return Compared(1);
        B::VersionComparison value; value.status = B::ComparisonStatus::Failed; return value;
    };
    Require(!B::Evaluate(*F(B::Kind::Depends, "target (>= 1), target (>= 2)"), *source, {target}, "amd64",
        B::Use::ConfigureChecks, partiallyFailing, &result, &error) && result.groups.empty() && !result.allGroupsMatched,
        "earlier successful group survived failed comparison");
    Require(!B::Evaluate(*F(B::Kind::Provides, "target"), *source, {target}, "amd64", B::Use::UnpackChecks,
        Compare, &result, &error) && error.code == B::ErrorCode::UnsupportedUse, "Provides used as dependency field");
    Field parsed;
    Require(!B::ParseField(B::Kind::Depends, std::string(B::MaximumFieldBytes + 1, 'a'), &parsed, &error) &&
        error.code == B::ErrorCode::LimitExceeded, "field byte limit ignored");
    std::string groups;
    for (std::size_t i = 0; i <= B::MaximumGroups; ++i) { if (i) groups += ','; groups += "target"; }
    Require(!B::ParseField(B::Kind::Depends, groups, &parsed, &error) && error.code == B::ErrorCode::LimitExceeded,
        "field group limit ignored");
    std::string atoms;
    for (std::size_t i = 0; i <= B::MaximumAtoms; ++i) { if (i) atoms += '|'; atoms += "target"; }
    Require(!B::ParseField(B::Kind::Depends, atoms, &parsed, &error) && error.code == B::ErrorCode::LimitExceeded,
        "field atom limit ignored");
    std::vector<Package> candidates(B::MaximumCandidates + 1, target);
    Require(!B::Evaluate(*field, *source, candidates, "amd64", B::Use::ConfigureChecks, Compare, &result, &error) &&
        error.code == B::ErrorCode::LimitExceeded, "candidate limit ignored");
    candidates.resize(B::MaximumCandidates); groups.clear();
    for (unsigned i = 0; i != 17; ++i) { if (i) groups += ','; groups += "absent"; }
    Require(!B::Evaluate(*F(B::Kind::Depends, groups), *source, candidates, "amd64", B::Use::ConfigureChecks,
        Compare, &result, &error) && error.code == B::ErrorCode::LimitExceeded && result.groups.empty(),
        "matching budget produced partial evidence");
    groups.clear();
    for (unsigned i = 0; i != 64; ++i) { if (i) groups += ','; groups += "target"; }
    candidates.assign(512, P("target", std::string(1024, '1')));
    Require(!B::Evaluate(*F(B::Kind::Depends, groups), *source, candidates, "amd64", B::Use::ConfigureChecks,
        Compare, &result, &error) && error.code == B::ErrorCode::LimitExceeded && result.groups.empty(),
        "witness byte limit produced partial evidence");
    const auto empty = E(B::Kind::Depends, "", source, {});
    Require(empty.groups.empty() && empty.allGroupsMatched && !empty.anyGroupMatched, "empty field semantics changed");
}
#if defined(CYDIA_BINARY_RELATIONSHIPS_NATIVE_APT)
void NativeVersions() {
    // Debian comparison vectors exercise the selected native APT debVS,
    // never a worker answer or a test-local semantic-version approximation.
    const auto source = P("source");
    for (const auto &pair : std::vector<std::pair<std::string, std::string>>{
        {"1", "0:1-0"}, {"1.0002-0003", "1.2-3"}, {"0002:1~rc0001-0", "2:1~rc1"}})
        Require(E(B::Kind::Depends, "target (= " + pair.first + ')', source, {P("target", pair.second)}).allGroupsMatched,
            "native Debian equivalent versions rejected");
    for (const auto &pair : std::vector<std::pair<std::string, std::string>>{
        {"1~rc1", "1"}, {"1~~", "1~"}, {"1.9", "1.10"}, {"1-1", "1-2"}, {"9:9", "10:0"}, {"1+1", "1+a"}})
        Require(E(B::Kind::Depends, "target (<< " + pair.second + ')', source, {P("target", pair.first)}).allGroupsMatched,
            "native Debian ordering rejected");
    const std::vector<std::pair<std::string, int>> operators{
        {"<<", pkgCache::Dep::Less}, {"<=", pkgCache::Dep::LessEq}, {"=", pkgCache::Dep::Equals},
        {">=", pkgCache::Dep::GreaterEq}, {">>", pkgCache::Dep::Greater},
        {"<", pkgCache::Dep::LessEq}, {">", pkgCache::Dep::GreaterEq}};
    const std::vector<std::string> versions{"1", "0:1-0", "1~~", "1~rc1", "1.09", "1.10", "2:0", "1+a", "1+1"};
    for (const auto &a : versions) for (const auto &b : versions) for (const auto &operation : operators) {
        const auto result = E(B::Kind::Depends, "target (" + operation.first + ' ' + b + ')', source, {P("target", a)});
        Require(result.allGroupsMatched == debVS.CheckDep(a.c_str(), operation.second, b.c_str()),
            "relation evaluator disagrees with native APT Debian comparison");
    }
}
#endif
}
int main() {
    Parsing(); Architectures(); VirtualAndCallsiteSemantics(); FailureAndBounds();
#if defined(CYDIA_BINARY_RELATIONSHIPS_NATIVE_APT)
    NativeVersions();
#endif
    std::cout << "[binary-relationships] OK\n";
}
