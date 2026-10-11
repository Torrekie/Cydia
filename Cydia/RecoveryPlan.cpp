/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RecoveryPlan.hpp"
#include <algorithm>
#include <cctype>
#include <map>
#include <limits>
#include <sstream>
#include <set>

namespace CydiaRuntime { namespace Recovery {
namespace {
const std::size_t Limit = 8 * 1024 * 1024;
std::string Trim(const std::string &text) {
    const auto start(text.find_first_not_of(" \t\r\n"));
    if (start == std::string::npos) return "";
    return text.substr(start, text.find_last_not_of(" \t\r\n") - start + 1);
}
std::string Lower(std::string text) {
    for (char &c : text) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    return text;
}
bool Name(const std::string &text) {
    if (text.size() < 2 || !std::isalnum(static_cast<unsigned char>(text[0]))) return false;
    for (char c : text) if (!(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '+' && c != '-' && c != '.') return false;
    return true;
}
bool Architecture(const std::string &text) {
    if (text.empty()) return false;
    for (char c : text) if (!(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-') return false;
    return true;
}
struct Term { std::string name, architecture, operation, version; };
struct Record {
    std::string name, architecture, version, multiarch, state, stanza;
    bool essential, protectedPackage, active;
    std::vector<std::vector<Term>> dependencies;
    std::vector<Term> provides;
    std::string Identity() const { return multiarch == "same" ? name + ':' + architecture : name; }
};
bool Terms(const std::string &bytes, bool alternatives, std::vector<std::vector<Term>> *groups) {
    if (Trim(bytes).empty()) return true;
    std::size_t offset(0);
    std::vector<Term> group;
    while (offset < bytes.size()) {
        while (offset < bytes.size() && std::isspace(static_cast<unsigned char>(bytes[offset]))) ++offset;
        const auto start(offset);
        while (offset < bytes.size() && (std::isalnum(static_cast<unsigned char>(bytes[offset])) ||
               bytes[offset] == '+' || bytes[offset] == '-' || bytes[offset] == '.' || bytes[offset] == ':')) ++offset;
        const std::string word(bytes.substr(start, offset - start));
        const auto colon(word.find(':'));
        Term term; term.name = word.substr(0, colon);
        if (!Name(term.name)) return false;
        if (colon != std::string::npos) {
            term.architecture = word.substr(colon + 1);
            if (!Architecture(term.architecture)) return false;
        }
        while (offset < bytes.size() && std::isspace(static_cast<unsigned char>(bytes[offset]))) ++offset;
        if (offset < bytes.size() && bytes[offset] == '(') {
            const auto end(bytes.find(')', ++offset));
            if (end == std::string::npos) return false;
            std::istringstream condition(bytes.substr(offset, end - offset)); std::string extra;
            if (!(condition >> term.operation >> term.version) || condition >> extra ||
                (term.operation != "<<" && term.operation != "<=" && term.operation != "=" && term.operation != ">=" && term.operation != ">>")) return false;
            for (char c : term.version) if (!std::isalnum(static_cast<unsigned char>(c)) && c != '.' && c != '+' && c != '-' && c != ':' && c != '~') return false;
            offset = end + 1;
        }
        group.push_back(term);
        while (offset < bytes.size() && std::isspace(static_cast<unsigned char>(bytes[offset]))) ++offset;
        if (offset == bytes.size()) { groups->push_back(group); return true; }
        const char separator(bytes[offset++]);
        if (separator == '|') { if (!alternatives) return false; }
        else if (separator == ',') { groups->push_back(group); group.clear(); }
        else return false;
        if (Trim(bytes.substr(offset)).empty()) return false;
    }
    return false;
}
bool Records(const std::string &bytes, std::vector<Record> *records) {
    if (bytes.empty() || bytes.size() > Limit || bytes.find('\0') != std::string::npos) return false;
    std::istringstream lines(bytes); std::string line, key, stanza;
    std::map<std::string, std::string> fields;
    std::set<std::string> identities;
    const auto finish = [&]() -> bool {
        if (fields.empty()) return true;
        Record record; record.name = fields["package"]; record.architecture = fields["architecture"];
        record.version = fields["version"]; record.multiarch = Lower(fields["multi-arch"]); record.stanza = stanza;
        std::istringstream status(fields["status"]); std::string selected, flag, extra;
        if (!Name(record.name) || !Architecture(record.architecture) ||
            !(status >> selected >> flag >> record.state) || status >> extra ||
            (record.multiarch != "" && record.multiarch != "no" && record.multiarch != "same" && record.multiarch != "foreign" && record.multiarch != "allowed")) return false;
        const std::set<std::string> states{"not-installed", "config-files", "half-installed", "unpacked", "half-configured", "triggers-awaited", "triggers-pending", "installed"};
        const std::set<std::string> selections{"unknown", "install", "hold", "deinstall", "purge"};
        if (states.count(record.state) == 0 || selections.count(selected) == 0 || (flag != "ok" && flag != "reinstreq")) return false;
        const auto boolean = [&](const char *name, bool *result) -> bool {
            const std::string value(Lower(fields[name]));
            if (value != "" && value != "yes" && value != "no") return false;
            *result = value == "yes"; return true;
        };
        if (!boolean("essential", &record.essential) || !boolean("protected", &record.protectedPackage)) return false;
        record.active = record.state != "not-installed" && record.state != "config-files";
        if (record.active && record.version.empty()) return false;
        if (!Terms(fields["depends"], true, &record.dependencies) || !Terms(fields["pre-depends"], true, &record.dependencies)) return false;
        std::vector<std::vector<Term>> provides;
        if (!Terms(fields["provides"], false, &provides)) return false;
        for (const auto &group : provides) {
            if (group.size() != 1 || !group[0].architecture.empty() || (!group[0].operation.empty() && group[0].operation != "=")) return false;
            record.provides.push_back(group[0]);
        }
        if (!identities.insert(record.name + ':' + record.architecture).second) return false;
        records->push_back(record); fields.clear(); stanza.clear(); key.clear(); return true;
    };
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (Trim(line).empty()) { if (!finish()) return false; continue; }
        stanza += line + '\n';
        if (line[0] == ' ' || line[0] == '\t') {
            if (key.empty()) return false;
            fields[key] += ' ' + Trim(line); continue;
        }
        const auto colon(line.find(':'));
        if (colon == std::string::npos || colon == 0) return false;
        key = Lower(line.substr(0, colon));
        if (fields.count(key) != 0) return false;
        fields[key] = Trim(line.substr(colon + 1));
    }
    return finish();
}
int Order(char c) {
    if (c == '~') return -1;
    if (c == 0 || (c >= '0' && c <= '9')) return 0;
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return c;
    return static_cast<unsigned char>(c) + 256;
}
int Fragment(const std::string &a, const std::string &b) {
    std::size_t x(0), y(0);
    while (x < a.size() || y < b.size()) {
        while ((x < a.size() && !std::isdigit(static_cast<unsigned char>(a[x]))) ||
               (y < b.size() && !std::isdigit(static_cast<unsigned char>(b[y])))) {
            const int first(Order(x < a.size() ? a[x] : 0)), second(Order(y < b.size() ? b[y] : 0));
            if (first != second) return first < second ? -1 : 1;
            if (x < a.size()) ++x;
            if (y < b.size()) ++y;
        }
        while (x < a.size() && a[x] == '0') ++x;
        while (y < b.size() && b[y] == '0') ++y;
        int difference(0);
        while (x < a.size() && y < b.size() && std::isdigit(static_cast<unsigned char>(a[x])) && std::isdigit(static_cast<unsigned char>(b[y]))) {
            if (difference == 0) difference = a[x] - b[y];
            ++x; ++y;
        }
        if (x < a.size() && std::isdigit(static_cast<unsigned char>(a[x]))) return 1;
        if (y < b.size() && std::isdigit(static_cast<unsigned char>(b[y]))) return -1;
        if (difference != 0) return difference < 0 ? -1 : 1;
    }
    return 0;
}
std::vector<std::string> VersionParts(const std::string &version) {
    const auto colon(version.find(':'));
    const std::string rest(colon == std::string::npos ? version : version.substr(colon + 1));
    const auto dash(rest.find_last_of('-'));
    return {colon == std::string::npos ? "0" : version.substr(0, colon), rest.substr(0, dash), dash == std::string::npos ? "0" : rest.substr(dash + 1)};
}
bool VersionMatches(const std::string &version, const Term &term) {
    if (term.operation.empty()) return true;
    if (version.empty()) return false;
    const auto a(VersionParts(version)), b(VersionParts(term.version)); int comparison(0);
    for (std::size_t index = 0; index < a.size() && comparison == 0; ++index) comparison = Fragment(a[index], b[index]);
    if (term.operation == "=") return comparison == 0;
    if (term.operation == ">=") return comparison >= 0;
    if (term.operation == ">>") return comparison > 0;
    if (term.operation == "<=") return comparison <= 0;
    return comparison < 0;
}
bool Satisfies(const Record &provider, const Record &consumer, const Term &term, const std::string &native) {
    if (!provider.active) return false;
    bool architecture(false);
    if (term.architecture == "any") architecture = provider.multiarch == "allowed" || provider.multiarch == "foreign";
    else if (term.architecture == "native") architecture = provider.architecture == native || provider.architecture == "all";
    else if (!term.architecture.empty()) architecture = provider.architecture == term.architecture || provider.architecture == "all";
    else architecture = provider.architecture == (consumer.architecture == "all" ? native : consumer.architecture) ||
        provider.architecture == "all" || provider.multiarch == "foreign";
    if (!architecture) return false;
    if (provider.name == term.name && VersionMatches(provider.version, term)) return true;
    for (const auto &provided : provider.provides)
        if (provided.name == term.name && VersionMatches(provided.version, term)) return true;
    return false;
}
void Put(std::string *out, const std::string &value) { *out += std::to_string(value.size()) + ':' + value + ','; }
bool Get(const std::string &bytes, std::size_t *cursor, std::string *value) {
    const auto colon(bytes.find(':', *cursor));
    if (colon == std::string::npos || colon == *cursor || colon - *cursor > 20) return false;
    std::size_t count(0);
    for (std::size_t index(*cursor); index < colon; ++index) {
        const char c(bytes[index]);
        if (c < '0' || c > '9' || count > (Limit - (c - '0')) / 10) return false;
        count = count * 10 + c - '0';
    }
    if (count >= bytes.size() - colon - 1 || bytes[colon + 1 + count] != ',') return false;
    *value = bytes.substr(colon + 1, count); *cursor = colon + 2 + count; return true;
}
std::string List(const std::vector<std::string> &list) {
    std::string output; for (const auto &value : list) Put(&output, value); return output;
}
bool ReadList(const std::string &bytes, std::vector<std::string> *list) {
    std::size_t cursor(0); std::string value;
    while (cursor < bytes.size()) { if (!Get(bytes, &cursor, &value) || list->size() == 65536) return false; list->push_back(value); }
    return true;
}
}
bool ValidPackageIdentity(const std::string &identity) {
    const auto colon(identity.find(':'));
    return identity.size() <= 512 && Name(identity.substr(0, colon)) &&
        (colon == std::string::npos || Architecture(identity.substr(colon + 1)));
}
Analysis AnalyzeStatus(const std::string &status, const std::string &identity,
                       const std::string &nativeArchitecture, const std::string &activeFrontend) {
    Analysis result; result.package = identity; result.reason = "unavailable";
    std::vector<Record> records;
    if (!ValidPackageIdentity(identity) || !Architecture(nativeArchitecture) || !Records(status, &records)) return result;
    const Record *chosen(NULL);
    for (const auto &record : records) {
        if (record.Identity() != identity && record.name + ':' + record.architecture != identity) continue;
        if (chosen != NULL) return result;
        chosen = &record;
    }
    if (chosen == NULL) return result;
    result.package = chosen->Identity(); result.state = chosen->state; result.stanza = chosen->stanza;
    result.canConfigure = chosen->state == "unpacked" || chosen->state == "half-configured" ||
        chosen->state == "triggers-awaited" || chosen->state == "triggers-pending";
    if (chosen->state != "half-installed" && chosen->state != "half-configured" && chosen->state != "unpacked") {
        result.reason = "not-damaged"; return result;
    }
    if (chosen->essential || chosen->protectedPackage) { result.reason = "protected"; return result; }
    if (chosen->name == activeFrontend) { result.reason = "active-frontend"; return result; }
    for (const auto &consumer : records) {
        if (&consumer == chosen || !consumer.active) continue;
        for (const auto &group : consumer.dependencies) {
            bool references(false), alternative(false);
            for (const auto &term : group) {
                Term reference(term); reference.operation.clear();
                references = references || Satisfies(*chosen, consumer, reference, nativeArchitecture);
                for (const auto &provider : records) {
                    if (&provider == chosen || (provider.state != "installed" && provider.state != "triggers-awaited" && provider.state != "triggers-pending")) continue;
                    alternative = alternative || Satisfies(provider, consumer, term, nativeArchitecture);
                }
            }
            if (references && !alternative) { result.affected.push_back(consumer.Identity()); break; }
        }
    }
    std::sort(result.affected.begin(), result.affected.end());
    if (!result.affected.empty()) { result.reason = "dependencies"; return result; }
    result.canEmergencyRemove = true; result.reason = "eligible"; return result;
}
std::string SerializeReview(const Review &review) {
    std::string out("CYDIA-RECOVERY-1\n");
    for (const auto &value : std::vector<std::string>{review.analysis.package, review.analysis.state,
         review.analysis.reason, review.analysis.canConfigure ? "1" : "0", review.analysis.canEmergencyRemove ? "1" : "0",
         List(review.analysis.affected), List(review.scripts), review.token}) Put(&out, value);
    return out;
}
bool ParseReview(const std::string &bytes, Review *review) {
    const std::string header("CYDIA-RECOVERY-1\n");
    if (review == NULL || bytes.size() > Limit || bytes.compare(0, header.size(), header) != 0) return false;
    std::size_t cursor(header.size()); std::vector<std::string> fields(8);
    for (auto &field : fields) if (!Get(bytes, &cursor, &field)) return false;
    if (cursor != bytes.size() || !ValidPackageIdentity(fields[0]) || (fields[3] != "0" && fields[3] != "1") ||
        (fields[4] != "0" && fields[4] != "1") || fields[7].size() != 64) return false;
    for (char c : fields[7]) if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) return false;
    Review result; result.analysis.package = fields[0]; result.analysis.state = fields[1]; result.analysis.reason = fields[2];
    result.analysis.canConfigure = fields[3] == "1"; result.analysis.canEmergencyRemove = fields[4] == "1";
    if (!ReadList(fields[5], &result.analysis.affected) || !ReadList(fields[6], &result.scripts)) return false;
    for (const auto &identity : result.analysis.affected) if (!ValidPackageIdentity(identity)) return false;
    result.token = fields[7]; *review = result; return true;
}
} }
