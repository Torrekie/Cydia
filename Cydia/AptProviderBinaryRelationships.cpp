/* Native semantics: dpkg 1.21/1.23 lib/dpkg/{fields,depcon,parse}.c,
 * src/main/{depcon,packages,archives}.c. No resolver or mutation policy.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderBinaryRelationships.hpp"
#include <climits>
#include <utility>

namespace CydiaAPT { namespace Provider { namespace BinaryRelationships {
namespace {
bool Fail(Error *error, ErrorCode code, std::size_t offset = 0) {
    if (error) { error->code = code; error->offset = offset; } return false;
}
bool Digit(char c) { return c >= '0' && c <= '9'; }
bool Letter(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
bool Space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
bool NameByte(char c) { return (c >= 'a' && c <= 'z') || Digit(c) || c == '+' || c == '-' || c == '.'; }
bool Name(const std::string &name) {
    if (name.empty() || name.size() > 255 || (!Digit(name[0]) && !(name[0] >= 'a' && name[0] <= 'z'))) return false;
    for (char c : name) if (!NameByte(c)) return false;
    return true;
}
bool Architecture(const std::string &arch) {
    if (arch.empty() || arch.size() > 255 || (!Letter(arch[0]) && !Digit(arch[0]))) return false;
    for (char c : arch) if (!Letter(c) && !Digit(c) && c != '-') return false;
    return true;
}
bool ConcreteArchitecture(const std::string &arch) {
    return Architecture(arch) && arch != "any" && arch != "native" &&
        arch.compare(0, 4, "any-") != 0 && (arch.size() < 4 || arch.compare(arch.size() - 4, 4, "-any") != 0);
}
bool Version(const std::string &version) {
    if (version.empty() || version.size() > 1024) return false;
    std::size_t begin = 0;
    const auto colon = version.find(':');
    if (colon != std::string::npos) {
        if (!colon) return false;
        unsigned epoch = 0;
        for (std::size_t i = 0; i < colon; ++i) {
            if (!Digit(version[i]) || epoch > (INT_MAX - unsigned(version[i] - '0')) / 10) return false;
            epoch = epoch * 10 + unsigned(version[i] - '0');
        }
        begin = colon + 1;
    }
    if (begin == version.size() || !Digit(version[begin])) return false;
    const auto hyphen = version.rfind('-');
    const auto upstreamEnd = hyphen == std::string::npos ? version.size() : hyphen;
    if (upstreamEnd <= begin || upstreamEnd + 1 == version.size()) return false;
    for (std::size_t i = begin; i < version.size(); ++i) {
        const char c = version[i];
        if (Digit(c) || Letter(c) || c == '.' || c == '+' || c == '~') continue;
        if (i <= upstreamEnd && (c == '-' || c == ':')) continue;
        return false;
    }
    return true;
}
bool Negative(Kind kind) { return kind == Kind::Breaks || kind == Kind::Conflicts || kind == Kind::Replaces; }
const char *Operator(Relation relation) {
    switch (relation) {
        case Relation::Less: return "<<"; case Relation::LessEqual: return "<=";
        case Relation::Equal: return "="; case Relation::GreaterEqual: return ">=";
        case Relation::Greater: return ">>"; case Relation::None: return "";
    }
    return "";
}
bool Restricted(char c) { return c == '[' || c == ']' || c == '<' || c == '>' || c == '!'; }
}
bool ValidVersion(const std::string &version) { return Version(version); }
Atom::Atom(std::string name, std::string arch, std::string ver, Qualifier q, Relation r) :
    package(std::move(name)), architecture(std::move(arch)), version(std::move(ver)), qualifier(q), relation(r) {}
Group::Group(std::vector<Atom> values) : alternatives(std::move(values)) {}
Field::Field(Kind k, std::vector<Group> g, std::string text, std::size_t count) :
    kind(k), groups(std::move(g)), canonical(std::move(text)), atomCount(count) {}
Package::Package(std::string n, std::string v, std::string a, MultiArch m, std::shared_ptr<const Field> p) :
    name(std::move(n)), version(std::move(v)), architecture(std::move(a)), multiArch(m), provides(std::move(p)) {}

class Parser {
    const std::string &input_; Kind kind_; std::size_t position_ = 0;
    void Whitespace() { while (position_ < input_.size() && Space(input_[position_])) ++position_; }
public:
    Parser(Kind kind, const std::string &input) : input_(input), kind_(kind) {}
    bool Parse(std::shared_ptr<const Field> *field, Error *error) {
        std::vector<Group> groups; std::vector<Atom> alternatives; std::string canonical; std::size_t count = 0;
        Whitespace();
        while (position_ < input_.size()) {
            if (++count > MaximumAtoms) return Fail(error, ErrorCode::LimitExceeded, position_);
            const auto start = position_;
            while (position_ < input_.size() && NameByte(input_[position_])) ++position_;
            const auto name = input_.substr(start, position_ - start);
            if (!Name(name)) return Fail(error, position_ < input_.size() && Restricted(input_[position_]) ?
                ErrorCode::UnsupportedRestrictions : ErrorCode::InvalidPackage, start);
            std::string architecture, version; Qualifier qualifier = Qualifier::Implicit; Relation relation = Relation::None;
            if (position_ < input_.size() && input_[position_] == ':') {
                const auto begin = ++position_;
                while (position_ < input_.size() && (Letter(input_[position_]) ||
                    Digit(input_[position_]) || input_[position_] == '-')) ++position_;
                architecture = input_.substr(begin, position_ - begin);
                if (!Architecture(architecture)) return Fail(error, ErrorCode::InvalidArchitecture, begin);
                if (architecture == "any") qualifier = Qualifier::Any;
                else if (architecture == "native") qualifier = Qualifier::Native;
                else {
                    if (!ConcreteArchitecture(architecture)) return Fail(error, ErrorCode::UnsupportedRestrictions, begin);
                    qualifier = Qualifier::Exact;
                }
            }
            Whitespace();
            if (position_ < input_.size() && input_[position_] == '(') {
                ++position_; Whitespace(); const auto begin = position_;
                while (position_ < input_.size() && (input_[position_] == '<' || input_[position_] == '>' || input_[position_] == '=')) ++position_;
                const auto operation = input_.substr(begin, position_ - begin);
                if (operation == "<<") relation = Relation::Less;
                else if (operation == "<=" || operation == "<") relation = Relation::LessEqual;
                else if (operation == "=") relation = Relation::Equal;
                else if (operation == ">=" || operation == ">") relation = Relation::GreaterEqual;
                else if (operation == ">>") relation = Relation::Greater;
                else return Fail(error, ErrorCode::InvalidSyntax, begin);
                if (kind_ == Kind::Provides && relation != Relation::Equal) return Fail(error, ErrorCode::ProvidesRelation, begin);
                Whitespace(); const auto versionStart = position_;
                while (position_ < input_.size() && !Space(input_[position_]) && input_[position_] != ')') ++position_;
                version = input_.substr(versionStart, position_ - versionStart);
                if (!Version(version)) return Fail(error, ErrorCode::InvalidVersion, versionStart);
                Whitespace();
                if (position_ == input_.size() || input_[position_++] != ')') return Fail(error, ErrorCode::InvalidSyntax, position_);
                Whitespace();
            }
            canonical += name;
            if (qualifier != Qualifier::Implicit) canonical += ':' + architecture;
            if (relation != Relation::None) canonical += " (" + std::string(Operator(relation)) + ' ' + version + ')';
            alternatives.emplace_back(name, architecture, version, qualifier, relation);
            if (position_ == input_.size() || input_[position_] == ',') {
                if (groups.size() == MaximumGroups) return Fail(error, ErrorCode::LimitExceeded, position_);
                groups.emplace_back(std::move(alternatives)); alternatives.clear();
                if (position_ == input_.size()) break;
                canonical += ", ";
            } else if (input_[position_] == '|') {
                if (kind_ != Kind::Depends && kind_ != Kind::PreDepends) return Fail(error, ErrorCode::AlternativesForbidden, position_);
                canonical += " | ";
            } else return Fail(error, Restricted(input_[position_]) ? ErrorCode::UnsupportedRestrictions : ErrorCode::InvalidSyntax, position_);
            ++position_; Whitespace();
            if (position_ == input_.size()) return Fail(error, ErrorCode::InvalidSyntax, position_);
        }
        if (canonical.size() > MaximumFieldBytes) return Fail(error, ErrorCode::LimitExceeded);
        *field = std::shared_ptr<const Field>(new Field(kind_, std::move(groups), std::move(canonical), count));
        return true;
    }
};
bool ParseField(Kind kind, const std::string &text, std::shared_ptr<const Field> *field, Error *error) {
    if (error) *error = Error();
    if (!field) return Fail(error, ErrorCode::InvalidInput);
    field->reset();
    if (static_cast<unsigned>(kind) > static_cast<unsigned>(Kind::Replaces)) return Fail(error, ErrorCode::InvalidInput);
    if (text.size() > MaximumFieldBytes) return Fail(error, ErrorCode::LimitExceeded);
    for (std::size_t i = 0; i < text.size(); ++i) {
        const auto c = static_cast<unsigned char>(text[i]);
        if ((c < 32 && !Space(text[i])) || c >= 127) return Fail(error, ErrorCode::InvalidSyntax, i);
    }
    return Parser(kind, text).Parse(field, error);
}
bool ParsePackage(const std::string &name, const std::string &version, const std::string &architecture,
    const std::string &multiArch, const std::string &provides, std::shared_ptr<const Package> *package, Error *error) {
    if (error) *error = Error();
    if (!package) return Fail(error, ErrorCode::InvalidInput);
    package->reset();
    if (!Name(name)) return Fail(error, ErrorCode::InvalidPackage);
    if (!Version(version)) return Fail(error, ErrorCode::InvalidVersion);
    if (!ConcreteArchitecture(architecture)) return Fail(error, ErrorCode::InvalidArchitecture);
    MultiArch mode;
    if (multiArch.empty() || multiArch == "no") mode = MultiArch::No;
    else if (multiArch == "same" && architecture != "all") mode = MultiArch::Same;
    else if (multiArch == "foreign") mode = MultiArch::Foreign;
    else if (multiArch == "allowed") mode = MultiArch::Allowed;
    else return Fail(error, ErrorCode::InvalidMultiArch);
    std::shared_ptr<const Field> parsed;
    if (!ParseField(Kind::Provides, provides, &parsed, error)) return false;
    *package = std::shared_ptr<const Package>(new Package(name, version, architecture, mode, std::move(parsed)));
    return true;
}

namespace {
struct Matcher {
    const Package &source; const std::string &native; Use use; const VersionComparator &compare; Error *error;
    std::size_t steps = 0;
    Matcher(const Package &s, const std::string &n, Use u, const VersionComparator &c, Error *e) :
        source(s), native(n), use(u), compare(c), error(e) {}
    bool Step() { return ++steps <= MaximumMatchSteps || Fail(error, ErrorCode::LimitExceeded); }
    bool VersionMatches(const Atom &atom, const std::string &version, bool *matches) {
        *matches = false;
        if (atom.relation == Relation::None) { *matches = true; return true; }
        if (version.empty()) return true; // Unversioned Provides cannot satisfy a versioned relation.
        if (!compare) return Fail(error, ErrorCode::ComparisonUnavailable);
        VersionComparison result;
        try { result = compare(version, atom.version); }
        catch (...) { return Fail(error, ErrorCode::ComparisonFailed); }
        switch (result.status) {
            case ComparisonStatus::Unavailable: return Fail(error, ErrorCode::ComparisonUnavailable);
            case ComparisonStatus::InvalidVersion: return Fail(error, ErrorCode::ComparisonInvalidVersion);
            case ComparisonStatus::Failed: return Fail(error, ErrorCode::ComparisonFailed);
            case ComparisonStatus::Compared: break;
            default: return Fail(error, ErrorCode::ComparisonFailed);
        }
        switch (atom.relation) {
            case Relation::Less: *matches = result.ordering < 0; break;
            case Relation::LessEqual: *matches = result.ordering <= 0; break;
            case Relation::Equal: *matches = result.ordering == 0; break;
            case Relation::GreaterEqual: *matches = result.ordering >= 0; break;
            case Relation::Greater: *matches = result.ordering > 0; break;
            case Relation::None: break;
        }
        return true;
    }
    bool ArchitectureMatches(Kind kind, const Atom &atom, const Package &candidate, const std::string &provided) const {
        // lib/dpkg/depcon.c::deparchsatisfied. "all" aliases native here,
        // not the architecture of the depending foreign binary.
        if (atom.qualifier == Qualifier::Implicit && candidate.multiArch == MultiArch::Foreign) return true;
        std::string wanted = atom.qualifier == Qualifier::Implicit ? (Negative(kind) ? "any" : source.architecture) : atom.architecture;
        if (wanted == "any" && (candidate.multiArch == MultiArch::Allowed || Negative(kind))) return true;
        if (wanted == "all") wanted = native;
        return wanted == (provided == "all" ? native : provided);
    }
    bool Matches(Kind kind, const Atom &atom, const Package &candidate, const Atom *provide, bool *matched) {
        *matched = false;
        if (!Step()) return false;
        if ((provide ? provide->package : candidate.name) != atom.package) return true;
        if (provide && provide->qualifier == Qualifier::Native) return Fail(error, ErrorCode::UnsupportedNativeQualifier);
        if (kind == Kind::Breaks || kind == Kind::Conflicts) {
            // depisok excludes self package sets; breakses_ok excludes the
            // exact broken==breaker instance when checking configuration.
            if (use == Use::UnpackChecks && (provide ? candidate.name == source.name : atom.package == source.name)) return true;
            if (use == Use::ConfigureChecks && candidate.name == source.name && candidate.architecture == source.architecture) return true;
        }
        if (!provide) {
            if (!ArchitectureMatches(kind, atom, candidate, candidate.architecture)) return true;
        } else if (use == Use::ConfigureChecks) {
            const auto arch = kind == Kind::Breaks || provide->qualifier == Qualifier::Implicit ?
                candidate.architecture : provide->architecture;
            if (!ArchitectureMatches(kind, atom, candidate, arch)) return true;
            // src/main/packages.c::breaks_check_one checks the real version
            // before checking the provided version. depisok does not.
            if (kind == Kind::Breaks) {
                bool actual = false;
                if (!VersionMatches(atom, candidate.version, &actual)) return false;
                if (!actual) return true;
            }
        }
        return VersionMatches(atom, provide ? provide->version : candidate.version, matched);
    }
};
std::size_t Bytes(const Package &package) {
    return package.name.size() + package.version.size() + package.architecture.size() + package.provides->canonical.size();
}
}
bool Evaluate(const Field &field, const Package &source, const std::vector<std::shared_ptr<const Package>> &candidates,
    const std::string &native, Use use, const VersionComparator &compare, Evaluation *output, Error *error) {
    if (error) *error = Error();
    if (!output) return Fail(error, ErrorCode::InvalidInput);
    *output = Evaluation();
    if (!ConcreteArchitecture(native) || native == "all") return Fail(error, ErrorCode::InvalidArchitecture);
    if (static_cast<unsigned>(use) > static_cast<unsigned>(Use::ConfigureChecks) || field.kind == Kind::Provides ||
        (use == Use::ConfigureChecks && (field.kind == Kind::Conflicts || field.kind == Kind::Replaces)))
        return Fail(error, ErrorCode::UnsupportedUse);
    if (candidates.size() > MaximumCandidates) return Fail(error, ErrorCode::LimitExceeded);
    std::size_t bytes = field.canonical.size() + Bytes(source);
    for (const auto &candidate : candidates) {
        if (!candidate) return Fail(error, ErrorCode::InvalidInput);
        const auto count = Bytes(*candidate);
        if (count > MaximumInputBytes - bytes) return Fail(error, ErrorCode::LimitExceeded);
        bytes += count;
    }
    for (const auto &group : field.groups) for (const auto &atom : group.alternatives)
        if (atom.qualifier == Qualifier::Native) return Fail(error, ErrorCode::UnsupportedNativeQualifier);
    Matcher matcher{source, native, use, compare, error}; Evaluation result; std::size_t witnessBytes = 0;
    for (std::size_t g = 0; g < field.groups.size(); ++g) {
        GroupMatches matches;
        const auto &group = field.groups[g];
        for (std::size_t a = 0; a < group.alternatives.size(); ++a) {
            const auto &atom = group.alternatives[a];
            for (std::size_t p = 0; p < candidates.size(); ++p) {
                const auto &candidate = *candidates[p]; bool matched = false;
                const auto add = [&](std::size_t provided, const std::string &version) {
                    const auto bytes = sizeof(Witness) + candidate.name.size() + candidate.version.size() +
                        candidate.architecture.size() + version.size();
                    if (bytes > MaximumWitnessBytes - witnessBytes) return Fail(error, ErrorCode::LimitExceeded);
                    witnessBytes += bytes;
                    Witness witness; witness.group = g; witness.alternative = a; witness.candidate = p; witness.provide = provided;
                    witness.package = candidate.name; witness.version = candidate.version; witness.architecture = candidate.architecture;
                    witness.comparedVersion = version; matches.witnesses.push_back(std::move(witness)); return true;
                };
                if (!matcher.Matches(field.kind, atom, candidate, nullptr, &matched)) return false;
                if (matched && !add(DirectPackage, candidate.version)) return false;
                if (field.kind == Kind::Replaces) continue;
                for (std::size_t provided = 0; provided < candidate.provides->groups.size(); ++provided) {
                    const auto &declaration = candidate.provides->groups[provided].alternatives.front();
                    if (!matcher.Matches(field.kind, atom, candidate, &declaration, &matched)) return false;
                    if (matched && !add(provided, declaration.version)) return false;
                }
            }
        }
        result.anyGroupMatched = result.anyGroupMatched || !matches.witnesses.empty();
        result.groups.push_back(std::move(matches));
    }
    result.allGroupsMatched = true;
    for (const auto &group : result.groups) result.allGroupsMatched = result.allGroupsMatched && !group.witnesses.empty();
    *output = std::move(result); return true;
}
}}}
