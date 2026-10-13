/* Bounded native binary relationship evidence, never execution authority.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptProviderBinaryRelationships_HPP
#define Cydia_AptProviderBinaryRelationships_HPP
#include <cstddef>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace CydiaAPT { namespace Provider { namespace BinaryRelationships {
constexpr std::size_t MaximumFieldBytes = 1024 * 1024;
constexpr std::size_t MaximumGroups = 4096;
constexpr std::size_t MaximumAtoms = 16384;
constexpr std::size_t MaximumCandidates = 4096;
constexpr std::size_t MaximumMatchSteps = 65536;
constexpr std::size_t MaximumInputBytes = 32 * 1024 * 1024;
constexpr std::size_t MaximumWitnessBytes = 32 * 1024 * 1024;
constexpr std::size_t DirectPackage = static_cast<std::size_t>(-1);

enum class Kind { Depends, PreDepends, Breaks, Conflicts, Provides, Replaces };
enum class Qualifier { Implicit, Any, Native, Exact };
enum class Relation { None, Less, LessEqual, Equal, GreaterEqual, Greater };
enum class MultiArch { No, Same, Foreign, Allowed };
// These are distinct native dpkg call sites, not a worker-selected policy.
// depisok (unpack/conflict checks) and dependencies_ok/breakses_ok (configure)
// differ for virtual-provider architecture/version checks. No status, force
// option, pending action, cycle break or Config-Version is inferred here.
enum class Use { UnpackChecks, ConfigureChecks };
enum class ErrorCode {
    None, InvalidInput, InvalidSyntax, InvalidPackage, InvalidArchitecture,
    InvalidVersion, InvalidMultiArch, AlternativesForbidden, ProvidesRelation,
    UnsupportedRestrictions, UnsupportedNativeQualifier, UnsupportedUse,
    LimitExceeded, ComparisonUnavailable, ComparisonInvalidVersion, ComparisonFailed
};
struct Error { ErrorCode code = ErrorCode::None; std::size_t offset = 0; };

struct Atom {
    const std::string package, architecture, version;
    const Qualifier qualifier;
    const Relation relation;
    Atom(std::string package, std::string architecture, std::string version,
         Qualifier qualifier, Relation relation);
};
struct Group {
    const std::vector<Atom> alternatives;
    explicit Group(std::vector<Atom> alternatives);
};
class Parser;
struct Field {
    const Kind kind;
    const std::vector<Group> groups;
    const std::string canonical;
    const std::size_t atomCount;
private:
    Field(Kind, std::vector<Group>, std::string, std::size_t);
    friend class Parser;
};
struct Package {
    const std::string name, version, architecture;
    const MultiArch multiArch;
    const std::shared_ptr<const Field> provides;
private:
    Package(std::string, std::string, std::string, MultiArch, std::shared_ptr<const Field>);
    friend bool ParsePackage(const std::string &, const std::string &, const std::string &,
        const std::string &, const std::string &, std::shared_ptr<const Package> *, Error *);
};
// Pure parsing establishes no provenance. Callers retain independent protected
// installed/index/archive evidence and pass these immutable values by const.
// Only binary grammar is accepted; source arch/profile restrictions refuse.
// :native is retained for display, but Evaluate refuses it: native dpkg does
// not apply APT's binary-control :native rewrite (deblistparser.cc).
bool ValidVersion(const std::string &);
bool ParseField(Kind, const std::string &, std::shared_ptr<const Field> *, Error *);
bool ParsePackage(const std::string &name, const std::string &version, const std::string &architecture,
    const std::string &multiArch, const std::string &provides, std::shared_ptr<const Package> *, Error *);

enum class ComparisonStatus { Compared, Unavailable, InvalidVersion, Failed };
struct VersionComparison {
    ComparisonStatus status = ComparisonStatus::Unavailable;
    int ordering = 0; // Negative/equal/positive; used only for Compared.
};
// Trusted parent implementation, bound to selected native version semantics.
// A worker comparator, fallback lexical ordering or invocation of a guessed
// external executable is never accepted. Exceptions become ComparisonFailed.
using VersionComparator = std::function<VersionComparison(const std::string &, const std::string &)>;
struct Witness {
    std::size_t group = 0, alternative = 0, candidate = 0, provide = DirectPackage;
    std::string package, version, architecture, comparedVersion;
};
struct GroupMatches { std::vector<Witness> witnesses; };
struct Evaluation {
    std::vector<GroupMatches> groups;
    bool anyGroupMatched = false, allGroupsMatched = false;
};
// Returns every direct/provider match in deterministic input order, bounded
// by MaximumMatchSteps. Each dependency group is OR; the field is AND. For
// Breaks/Conflicts/Replaces the matches describe individual relation causes,
// not permission to deconfigure/remove/overwrite. Replaces matches only real
// package names, never Provides. Evaluating a Provides field refuses.
// Candidate presence/configuration eligibility is supplied by the parent;
// matching alone does not prove dependency satisfaction or a final endpoint.
bool Evaluate(const Field &, const Package &source, const std::vector<std::shared_ptr<const Package>> &candidates,
    const std::string &nativeArchitecture, Use, const VersionComparator &, Evaluation *, Error *);
}}}
#endif
