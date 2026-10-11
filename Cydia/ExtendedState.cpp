/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ExtendedState.hpp"
#include <algorithm>
#include <cctype>
#include <map>
#include <set>

namespace CydiaRuntime {
namespace {
const std::size_t Limit = 8 * 1024 * 1024;
std::string Trim(const std::string &value) {
    const std::size_t first(value.find_first_not_of(" \t\r\n"));
    return first == std::string::npos ? "" : value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}
std::string Lower(std::string value) {
    for (char &c : value) c = std::tolower(static_cast<unsigned char>(c));
    return value;
}
struct Field { std::string name, value; std::size_t begin, end; };
struct Paragraph { std::string bytes; std::map<std::string, Field> fields; std::size_t bodyEnd; };
bool Parse(const std::string &bytes, std::vector<Paragraph> *paragraphs) {
    if (bytes.size() > Limit || bytes.find('\0') != std::string::npos) return false;
    paragraphs->clear();
    std::size_t begin(0);
    while (begin < bytes.size()) {
        std::size_t cursor(begin), bodyEnd(begin);
        bool hadBody(false), separator(false);
        Paragraph paragraph;
        std::string lastField;
        while (cursor < bytes.size()) {
            const std::size_t newline(bytes.find('\n', cursor));
            const std::size_t end(newline == std::string::npos ? bytes.size() : newline + 1);
            const std::string line(bytes.substr(cursor, end - cursor));
            if (Trim(line).empty()) {
                if (hadBody) separator = true;
            } else {
                if (separator) break;
                hadBody = true; bodyEnd = end;
                if (line[0] == '#') { lastField.clear(); }
                else if (line[0] == ' ' || line[0] == '\t') {
                    if (lastField.empty()) return false;
                    paragraph.fields[lastField].value += '\n' + Trim(line);
                    paragraph.fields[lastField].end = end - begin;
                } else {
                    const std::size_t colon(line.find(':'));
                    if (colon == std::string::npos || colon == 0) return false;
                    const std::string name(line.substr(0, colon)), key(Lower(name));
                    for (char c : name) if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-')) return false;
                    if (paragraph.fields.count(key)) return false;
                    paragraph.fields[key] = {name, Trim(line.substr(colon + 1)), cursor - begin, end - begin};
                    lastField = key;
                }
            }
            cursor = end;
        }
        paragraph.bytes = bytes.substr(begin, cursor - begin);
        paragraph.bodyEnd = bodyEnd - begin;
        paragraphs->push_back(paragraph);
        begin = cursor;
    }
    return true;
}
std::string Value(const Paragraph &paragraph, const char *key) {
    const auto found(paragraph.fields.find(key));
    return found == paragraph.fields.end() ? "" : found->second.value;
}
std::string Change(const Paragraph &paragraph, const std::string &architecture, bool automatic) {
    struct Edit { std::size_t begin, end; std::string contents; };
    const std::string newline(paragraph.bytes.find("\r\n") == std::string::npos ? "\n" : "\r\n");
    std::vector<Edit> edits;
    std::string appended;
    for (const auto &entry : std::vector<std::pair<std::string, std::string>>{
        {"architecture", architecture}, {"auto-installed", automatic ? "1" : "0"}}) {
        const auto found(paragraph.fields.find(entry.first));
        if (found != paragraph.fields.end())
            edits.push_back({found->second.begin, found->second.end, found->second.name + ": " + entry.second + newline});
        else appended += (entry.first == "architecture" ? "Architecture" : "Auto-Installed") + std::string(": ") + entry.second + newline;
    }
    if (!appended.empty()) {
        if (paragraph.bodyEnd != 0 && paragraph.bytes[paragraph.bodyEnd - 1] != '\n') appended = newline + appended;
        edits.push_back({paragraph.bodyEnd, paragraph.bodyEnd, appended});
    }
    std::sort(edits.begin(), edits.end(), [](const Edit &a, const Edit &b) { return a.begin > b.begin; });
    std::string result(paragraph.bytes);
    for (const auto &edit : edits) result.replace(edit.begin, edit.end - edit.begin, edit.contents);
    if (result.empty() || result.back() != '\n') result += newline;
    if (result.size() < newline.size() * 2 || result.substr(result.size() - newline.size() * 2) != newline + newline) result += newline;
    return result;
}
}
bool ValidPackageName(const std::string &name) {
    if (name.size() < 2 || name.size() > 256 || !std::isalnum(static_cast<unsigned char>(name[0]))) return false;
    for (char c : name) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.')) return false;
    return true;
}
bool ValidArchitectureName(const std::string &name) {
    if (name.empty() || name.size() > 128) return false;
    for (char c : name) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    return true;
}
bool MergeExtendedState(const std::string &original, const std::string &status,
    const std::string &native, const std::vector<std::string> &architectures,
    const std::vector<AutoStateDelta> &deltas, std::string *updated) {
    if (updated == NULL || !ValidArchitectureName(native) || native == "all" || native == "any" || deltas.size() > 65536) return false;
    std::vector<Paragraph> records, installed;
    if (!Parse(original, &records) || !Parse(status, &installed)) return false;
    std::set<std::string> known{native};
    for (const auto &architecture : architectures) {
        if (!ValidArchitectureName(architecture)) return false;
        if (architecture != "all") known.insert(architecture);
    }
    typedef std::pair<std::string, std::string> Key;
    std::set<Key> installedPackages;
    for (const auto &record : installed) {
        const std::string package(Value(record, "package")), architecture(Value(record, "architecture")), state(Value(record, "status"));
        if (package.empty()) continue;
        if (!ValidPackageName(package) || !ValidArchitectureName(architecture)) return false;
        if (state == "install ok installed" || state == "hold ok installed")
            installedPackages.insert({package, architecture == "all" ? native : architecture});
    }
    std::map<Key, bool> changes;
    for (const auto &delta : deltas) {
        if (!ValidPackageName(delta.package) || !ValidArchitectureName(delta.architecture) ||
            delta.architecture == "all" || known.count(delta.architecture) == 0) return false;
        const Key key(delta.package, delta.architecture);
        if (changes.count(key) || (delta.automatic && installedPackages.count(key) == 0)) return false;
        changes[key] = delta.automatic;
    }
    std::set<Key> seen;
    std::string result;
    for (const auto &record : records) {
        const std::string package(Value(record, "package"));
        const std::string storedArchitecture(Value(record, "architecture"));
        const std::string architecture(storedArchitecture == "any" ? "" : storedArchitecture);
        bool touched(false);
        for (const auto &change : changes) if (change.first.first == package &&
            (architecture.empty() || architecture == change.first.second)) { touched = true; break; }
        if (!touched) { result += record.bytes; continue; }
        const std::string automatic(Value(record, "auto-installed"));
        if (automatic != "" && automatic != "0" && automatic != "1") return false;
        if (architecture.empty()) {
            // All currently configured architectures inherit a legacy record.
            for (const auto &arch : known) {
                const Key key(package, arch); const auto change(changes.find(key));
                const bool value(change == changes.end() ? automatic == "1" : change->second);
                result += Change(record, arch, value);
                if (change != changes.end()) seen.insert(key);
            }
        } else {
            const Key key(package, architecture); const auto change(changes.find(key));
            result += Change(record, architecture, change->second); seen.insert(key);
        }
        if (result.size() > Limit) return false;
    }
    for (const auto &change : changes) if (change.second && seen.count(change.first) == 0) {
        if (!result.empty() && result.back() != '\n') result += '\n';
        const bool separated = (result.size() >= 2 && result.substr(result.size() - 2) == "\n\n") ||
            (result.size() >= 3 && result.substr(result.size() - 3) == "\n\r\n");
        if (!result.empty() && !separated) result += '\n';
        result += "Package: " + change.first.first + "\nArchitecture: " + change.first.second + "\nAuto-Installed: 1\n\n";
    }
    if (result.size() > Limit) return false;
    *updated = result; return true;
}
} // namespace CydiaRuntime
