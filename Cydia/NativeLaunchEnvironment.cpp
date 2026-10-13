/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/NativeLaunchEnvironment.hpp"
#include <algorithm>
#include <array>
#include <cstring>

extern char **environ;

namespace CydiaRuntime {
struct NativeLaunchEnvironment::Storage { std::vector<std::string> entries; };
namespace {
using Environment = NativeLaunchEnvironment;
using Error = Environment::Error;
struct Entry {
    const char *data = nullptr;
    std::size_t size = 0, name = 0;
};
using Entries = std::array<Entry, MaximumNativeEnvironmentEntries>;
bool Fail(Environment *output, Error *error, Error reason) {
    if (output) *output = Environment();
    if (error) *error = reason;
    return false;
}
bool Charge(std::size_t size, std::size_t *total, Error *error) {
    if (size > MaximumNativeEnvironmentEntryBytes) { *error = Error::EntryTooLarge; return false; }
    if (size + 1 > MaximumNativeEnvironmentBytes - *total) { *error = Error::TotalTooLarge; return false; }
    *total += size + 1; return true;
}
bool FirstNameByte(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}
bool Name(const Entry &entry) {
    if (!entry.name || !FirstNameByte(static_cast<unsigned char>(entry.data[0]))) return false;
    for (std::size_t i = 1; i < entry.name; ++i) {
        const auto c = static_cast<unsigned char>(entry.data[i]);
        if (!FirstNameByte(c) && !(c >= '0' && c <= '9')) return false;
    }
    return true;
}
bool Shape(Entry *entry, bool value, Error *error) {
    if (std::memchr(entry->data, '\0', entry->size)) { *error = Error::EmbeddedNul; return false; }
    entry->name = entry->size;
    if (value) {
        const auto equal = static_cast<const char *>(std::memchr(entry->data, '=', entry->size));
        if (!equal) { *error = Error::MissingEquals; return false; }
        entry->name = static_cast<std::size_t>(equal - entry->data);
    }
    if (!Name(*entry)) { *error = Error::InvalidName; return false; }
    return true;
}
int Compare(const Entry &a, const Entry &b) {
    const auto n = std::min(a.name, b.name);
    const int compared = std::memcmp(a.data, b.data, n);
    if (compared) return compared;
    return a.name == b.name ? 0 : a.name < b.name ? -1 : 1;
}
bool Canonical(Entries *entries, std::size_t count, Error *error) {
    std::sort(entries->begin(), entries->begin() + count,
        [](const Entry &a, const Entry &b) { return Compare(a, b) < 0; });
    for (std::size_t i = 1; i < count; ++i)
        if (!Compare((*entries)[i - 1], (*entries)[i])) { *error = Error::DuplicateName; return false; }
    return true;
}
bool VectorEntries(const std::vector<std::string> &source, bool value, Entries *entries,
    std::size_t *total, Error *error) {
    // All length/count/aggregate checks precede string copies or allocations.
    if (source.size() > MaximumNativeEnvironmentEntries) { *error = Error::TooManyEntries; return false; }
    for (const auto &entry : source) if (!Charge(entry.size(), total, error)) return false;
    for (std::size_t i = 0; i < source.size(); ++i) {
        (*entries)[i].data = source[i].data(); (*entries)[i].size = source[i].size();
        if (!Shape(&(*entries)[i], value, error)) return false;
    }
    return Canonical(entries, source.size(), error);
}
std::vector<std::string> Copy(const Entries &entries, std::size_t count) {
    std::vector<std::string> result; result.reserve(count);
    for (std::size_t i = 0; i < count; ++i) result.emplace_back(entries[i].data, entries[i].size);
    return result;
}
bool Contains(const Entries &entries, std::size_t count, const Entry &needle) {
    const auto found = std::lower_bound(entries.begin(), entries.begin() + count, needle,
        [](const Entry &a, const Entry &b) { return Compare(a, b) < 0; });
    return found != entries.begin() + count && !Compare(*found, needle);
}
}
bool NativeLaunchEnvironment::initialized() const { return bool(storage_); }
const std::vector<std::string> &NativeLaunchEnvironment::entries() const {
    static const std::vector<std::string> empty;
    return storage_ ? storage_->entries : empty;
}
bool NativeLaunchEnvironment::Envp::initialized() const { return bool(storage_); }
char *const *NativeLaunchEnvironment::Envp::data() const { return storage_ ? pointers_.data() : nullptr; }
bool NativeLaunchEnvironment::FromEntries(const std::vector<std::string> &input, NativeLaunchEnvironment *output, Error *error) {
    if (!output) return Fail(output, error, Error::InvalidOutput);
    Error reason = Error::None; std::size_t total = 0; Entries parsed;
    if (!VectorEntries(input, true, &parsed, &total, &reason)) return Fail(output, error, reason);
    std::shared_ptr<Storage> storage(new Storage()); storage->entries = Copy(parsed, input.size());
    output->storage_ = std::move(storage);
    if (error) *error = Error::None;
    return true;
}
bool NativeLaunchEnvironment::CaptureProcess(NativeLaunchEnvironment *output, Error *error) {
    if (!output) return Fail(output, error, Error::InvalidOutput);
    char *const *source = environ; std::size_t count = 0, total = 0; Entries parsed; Error reason = Error::None;
    // environ is a trusted, caller-stabilized null-terminated pointer array.
    // Reading one pointer beyond the supported count detects excess entries.
    while (source && source[count]) {
        if (count == MaximumNativeEnvironmentEntries) return Fail(output, error, Error::TooManyEntries);
        const auto size = strnlen(source[count], MaximumNativeEnvironmentEntryBytes + 1);
        if (!Charge(size, &total, &reason)) return Fail(output, error, reason);
        parsed[count].data = source[count]; parsed[count].size = size; ++count;
    }
    for (std::size_t i = 0; i < count; ++i)
        if (!Shape(&parsed[i], true, &reason)) return Fail(output, error, reason);
    if (!Canonical(&parsed, count, &reason)) return Fail(output, error, reason);
    std::shared_ptr<Storage> storage(new Storage()); storage->entries = Copy(parsed, count);
    output->storage_ = std::move(storage);
    if (error) *error = Error::None;
    return true;
}
bool NativeLaunchEnvironment::Overlay(const std::vector<std::string> &setEntries,
    const std::vector<std::string> &unsetNames, NativeLaunchEnvironment *output, Error *error) const {
    if (!output) return Fail(output, error, Error::InvalidOutput);
    const auto original = storage_; // output may alias this snapshot.
    if (!original) return Fail(output, error, Error::NotInitialized);
    if (setEntries.size() > MaximumNativeEnvironmentEntries ||
        unsetNames.size() > MaximumNativeEnvironmentEntries - setEntries.size()) return Fail(output, error, Error::TooManyEntries);
    Error reason = Error::None; std::size_t total = 0; Entries replacements, removals, result;
    if (!VectorEntries(setEntries, true, &replacements, &total, &reason) ||
        !VectorEntries(unsetNames, false, &removals, &total, &reason)) return Fail(output, error, reason);
    for (std::size_t i = 0; i < setEntries.size(); ++i)
        if (Contains(removals, unsetNames.size(), replacements[i])) return Fail(output, error, Error::ConflictingOverlay);
    std::size_t count = 0; total = 0;
    for (const auto &old : original->entries) {
        Entry entry; entry.data = old.data(); entry.size = old.size(); entry.name = old.find('=');
        if (Contains(replacements, setEntries.size(), entry) || Contains(removals, unsetNames.size(), entry)) continue;
        if (!Charge(entry.size, &total, &reason)) return Fail(output, error, reason);
        result[count++] = entry;
    }
    for (std::size_t i = 0; i < setEntries.size(); ++i) {
        if (count == MaximumNativeEnvironmentEntries) return Fail(output, error, Error::TooManyEntries);
        if (!Charge(replacements[i].size, &total, &reason)) return Fail(output, error, reason);
        result[count++] = replacements[i];
    }
    if (!Canonical(&result, count, &reason)) return Fail(output, error, reason);
    std::shared_ptr<Storage> storage(new Storage()); storage->entries = Copy(result, count);
    output->storage_ = std::move(storage);
    if (error) *error = Error::None;
    return true;
}
bool NativeLaunchEnvironment::BuildEnvp(Envp *output, Error *error) const {
    if (!output) { if (error) *error = Error::InvalidOutput; return false; }
    if (!storage_) { *output = Envp(); if (error) *error = Error::NotInitialized; return false; }
    Envp result; result.storage_ = storage_; result.pointers_.reserve(storage_->entries.size() + 1);
    for (const auto &entry : storage_->entries) result.pointers_.push_back(const_cast<char *>(entry.c_str()));
    result.pointers_.push_back(nullptr); *output = std::move(result);
    if (error) *error = Error::None;
    return true;
}
}
