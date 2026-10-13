/* Explicit native child environments; no policy or authority assertions.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_NativeLaunchEnvironment_HPP
#define Cydia_NativeLaunchEnvironment_HPP
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace CydiaRuntime {
constexpr std::size_t MaximumNativeEnvironmentEntries = 256;
constexpr std::size_t MaximumNativeEnvironmentEntryBytes = 64 * 1024;
// Includes each entry's terminating NUL, matching the eventual envp strings.
constexpr std::size_t MaximumNativeEnvironmentBytes = 1024 * 1024;

class NativeLaunchEnvironment {
    struct Storage;
    std::shared_ptr<const Storage> storage_;
public:
    enum class Error {
        None, InvalidOutput, NotInitialized, TooManyEntries, EntryTooLarge,
        TotalTooLarge, MissingEquals, EmbeddedNul, InvalidName,
        DuplicateName, ConflictingOverlay
    };
    class Envp {
        friend class NativeLaunchEnvironment;
        std::shared_ptr<const Storage> storage_;
        std::vector<char *> pointers_;
    public:
        // Default/moved-from views are invalid. A valid empty environment has
        // nonnull data() with data()[0] == nullptr, never ambient inheritance.
        bool initialized() const;
        // POSIX launch APIs require char pointers but must not modify them.
        // This view retains the immutable backing strings independently of
        // the source snapshot. Pointers remain valid while this view lives;
        // assignment/destruction of the view invalidates its pointer array.
        char *const *data() const;
    };

    // Default snapshots are deliberately invalid, distinct from FromEntries({}).
    bool initialized() const;
    // Canonical order is bytewise variable NAME order. Names use the portable
    // ASCII [A-Za-z_][A-Za-z0-9_]* grammar. Values are opaque non-NUL bytes;
    // an empty value is preserved and does not mean the name is absent.
    const std::vector<std::string> &entries() const;
    static bool FromEntries(const std::vector<std::string> &, NativeLaunchEnvironment *, Error * = nullptr);
    // Call only on trusted process environ after helper sanitization, with
    // caller-controlled exclusion of writers for the duration of capture.
    // This is a bounded read, NOT synchronization against arbitrary setenv/
    // unsetenv/putenv writers or mutable putenv buffers. No environment changes
    // or executable selection are made, and no authority is established.
    static bool CaptureProcess(NativeLaunchEnvironment *, Error * = nullptr);
    // Return a new snapshot. Existing names may be replaced or explicitly
    // removed; removing an absent name is valid. Duplicate edits and a name in
    // both sets refuse. Edit count/bytes and final result are independently
    // bounded. output may alias this snapshot. Failure leaves output invalid.
    bool Overlay(const std::vector<std::string> &setEntries, const std::vector<std::string> &unsetNames,
        NativeLaunchEnvironment *, Error * = nullptr) const;
    // Failure leaves the view invalid. A successful view owns its backing
    // snapshot and survives copies, source destruction and source reassignment.
    bool BuildEnvp(Envp *, Error * = nullptr) const;
};
}
#endif
