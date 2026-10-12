/* Bounded native trigger syntax. This file does not access the filesystem.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderTriggerEvidence.hpp"
#include <apt-pkg/hashes.h>
#include <set>

namespace CydiaAPT { namespace Provider {
namespace {
bool Fail(std::string *error, const char *code) { if (error) *error = code; return false; }
bool Alphanumeric(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}
// Native syntax, not Debian's stricter package-maintainer naming policy:
// https://github.com/guillemj/dpkg/blob/main/lib/dpkg/parsehelp.c
bool Name(const std::string &name, bool package = false) {
    if (name.empty() || name.size() > 256 ||
        name.find_first_not_of(package ? "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-_" :
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-") != std::string::npos) return false;
    return Alphanumeric(name[0]);
}
bool Selector(const std::string &value) {
    const auto colon = value.find(':');
    if (!Name(value.substr(0, colon), true)) return false;
    if (colon == std::string::npos) return true;
    const std::string architecture(value.substr(colon + 1));
    if (architecture.empty() || architecture.size() > 128 || !Alphanumeric(architecture[0])) return false;
    for (char c : architecture) if (!Alphanumeric(c) && c != '-') return false;
    return true;
}
bool Trigger(const std::string &value, bool deferred = false) {
    if (value.empty() || value.size() > 2046) return false;
    if (value[0] != '/') return Name(value);
    // trig_classify_byname rejects these file-trigger forms explicitly:
    // https://github.com/guillemj/dpkg/blob/main/lib/dpkg/triglib.c
    if (value.back() == '/' || value.find("//") != std::string::npos) return false;
    // Native File records can carry non-ASCII path bytes. Unincorp's tokenizer
    // specifically restricts a trigger directive to printable ASCII instead.
    if (deferred) for (unsigned char c : value) if (c <= 32 || c >= 127) return false;
    return true;
}
bool InterestSelector(const std::string &value, std::string *package, bool *await) {
    const auto slash = value.find('/');
    *package = value.substr(0, slash); *await = true;
    if (!Selector(*package)) return false;
    if (slash == std::string::npos) return true;
    const auto option = value.substr(slash + 1);
    if (option == "noawait") { *await = false; return true; }
    return option == "await";
}
bool Lines(const std::string &bytes, std::size_t limit,
           const std::function<bool(const std::string &)> &consume) {
    if (bytes.find('\0') != std::string::npos) return false;
    std::size_t cursor = 0;
    while (cursor < bytes.size()) {
        const auto end = bytes.find('\n', cursor);
        // An unfinished last record cannot be admitted as a settled registry.
        if (end == std::string::npos || end - cursor > limit || !consume(bytes.substr(cursor, end - cursor))) return false;
        cursor = end + 1;
    }
    return true;
}
void Frame(std::string *bytes, const std::string &value) {
    *bytes += std::to_string(value.size()) + ':' + value + ',';
}
std::string Identity(const TriggerRegistryInput &input, const TriggerRegistryState &state) {
    std::string bytes("CYDIA-TRIGGER-REGISTRY-1");
    Frame(&bytes, input.directoryPresent ? "1" : "0");
    // Empty named registries and absent/empty File/Unincorp remain distinct.
    for (const auto &file : input.files) Frame(&bytes, file.first);
    Frame(&bytes, "");
    for (const auto &interest : state.interests) {
        Frame(&bytes, interest.trigger); Frame(&bytes, interest.package); Frame(&bytes, interest.await ? "1" : "0");
    }
    Frame(&bytes, "");
    for (const auto &activation : state.deferred) {
        Frame(&bytes, activation.trigger); Frame(&bytes, activation.noAwait ? "1" : "0");
        for (const auto &awaiter : activation.awaiters) Frame(&bytes, awaiter);
        Frame(&bytes, "");
    }
    Hashes hash(Hashes::SHA256SUM);
    if (!hash.Add(bytes.data(), bytes.size())) return "";
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
}
bool ParseTriggerRegistry(const TriggerRegistryInput &input, TriggerRegistryState *state, std::string *error) {
    if (!state) return Fail(error, "provider_trigger_input_invalid");
    *state = TriggerRegistryState();
    if (error) error->clear();
    if ((!input.directoryPresent && !input.files.empty()) || input.files.size() > MaximumTriggerRegistryFiles)
        return Fail(error, "provider_trigger_input_invalid");
    std::size_t bytes = 0, relations = 0;
    std::map<std::pair<std::string, std::string>, bool> interests;
    struct Activation { std::set<std::string> awaiters; bool noAwait = false; };
    std::map<std::string, Activation> deferred;
    for (const auto &file : input.files) {
        if (file.first.size() > 256 || file.second.size() > MaximumTriggerEvidenceBytes - bytes)
            return Fail(error, "provider_trigger_evidence_limit");
        bytes += file.second.size();
        if (file.first == "Lock") {
            if (!file.second.empty()) return Fail(error, "provider_trigger_lock_invalid");
            continue;
        }
        if (file.first == "Unincorp") {
            if (file.second.size() > MaximumDeferredTriggerBytes) return Fail(error, "provider_trigger_evidence_limit");
            const bool valid = Lines(file.second, 2046, [&](const std::string &line) {
                const auto first = line.find_first_not_of(" \t\r\v\f");
                if (first == std::string::npos || line[first] == '#') return true;
                const auto separator = line.find_first_of(" \t\r\v\f", first);
                if (separator == std::string::npos) return false;
                const std::string trigger(line.substr(first, separator - first));
                if (!Trigger(trigger, true)) return false;
                auto &activation = deferred[trigger];
                std::size_t cursor = separator, count = 0;
                while ((cursor = line.find_first_not_of(" \t\r\v\f", cursor)) != std::string::npos) {
                    const auto end = line.find_first_of(" \t\r\v\f", cursor);
                    const std::string selector(line.substr(cursor, end == std::string::npos ? end : end - cursor));
                    if (++relations > MaximumTriggerRelations) return false;
                    if (selector == "-") activation.noAwait = true;
                    // Unincorp's own tokenizer is stricter than the registry
                    // pkg-spec reader: it accepts lowercase package tokens only.
                    else if (selector.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789:+.-") == std::string::npos &&
                        Selector(selector)) activation.awaiters.insert(selector);
                    else return false;
                    ++count;
                    if (end == std::string::npos) break;
                    cursor = end;
                }
                return count != 0;
            });
            if (!valid) return Fail(error, "provider_trigger_deferred_invalid");
            continue;
        }
        // This is dpkg's fixed atomic deferred-writer scratch name, not an
        // interest registry, even though its spelling also passes name syntax.
        if (file.first == "Unincorp.new") return Fail(error, "provider_trigger_registry_unsupported");
        const bool files = file.first == "File";
        if (!files && !Name(file.first)) return Fail(error, "provider_trigger_registry_unsupported");
        const bool valid = Lines(file.second, 1022, [&](const std::string &line) {
            std::string trigger(file.first), selector(line), package; bool await = true;
            if (files) {
                const auto space = line.find(' ');
                if (space == std::string::npos) return false;
                trigger = line.substr(0, space); selector = line.substr(space + 1);
                if (trigger.empty() || trigger[0] != '/' || !Trigger(trigger)) return false;
            }
            if (++relations > MaximumTriggerRelations || !InterestSelector(selector, &package, &await)) return false;
            const auto inserted = interests.emplace(std::make_pair(trigger, package), await);
            // dpkg rejects duplicate File interests. Identical named interests
            // coalesce, but contradictory await options are not guessed.
            return inserted.second || (!files && inserted.first->second == await);
        });
        if (!valid) return Fail(error, "provider_trigger_interest_invalid");
    }
    TriggerRegistryState result;
    result.directoryPresent = input.directoryPresent; result.lockPresent = input.files.count("Lock") != 0;
    result.fileRegistryPresent = input.files.count("File") != 0; result.deferredPresent = input.files.count("Unincorp") != 0;
    for (const auto &value : interests) {
        TriggerInterest interest; interest.trigger = value.first.first;
        interest.package = value.first.second; interest.await = value.second; result.interests.push_back(interest);
    }
    for (const auto &value : deferred) {
        DeferredTriggerActivation activation; activation.trigger = value.first; activation.noAwait = value.second.noAwait;
        activation.awaiters.assign(value.second.awaiters.begin(), value.second.awaiters.end()); result.deferred.push_back(activation);
    }
    result.canonicalIdentity = Identity(input, result);
    if (result.canonicalIdentity.size() != 64) return Fail(error, "provider_trigger_hash_failed");
    *state = std::move(result); return true;
}
}} // namespace CydiaAPT::Provider
