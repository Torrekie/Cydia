/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "apt-extra/apti18n.h"
#include "Cydia/ProtectedLibraryPath.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

namespace {
void Require(bool condition, const char *message) {
    if (condition) return;
    std::fprintf(stderr, "[verify-apt-messages] %s\n", message);
    std::exit(1);
}
}

int main() {
    Require(CydiaRuntime::ProtectedLibraryPath("relative/libintl.dylib").empty() &&
        CydiaRuntime::ProtectedLibraryPath(std::string("/usr/lib\0hidden", 15), true).empty(),
        "library discovery rejects relative and embedded-NUL paths");
    char temporary[] = "/tmp/cydia-library-alias.XXXXXX";
    Require(mkdtemp(temporary) != nullptr, "create alias fixture");
    const std::string alias(std::string(temporary) + "/system");
    Require(symlink("/usr/lib", alias.c_str()) == 0, "create mutable alias");
    Require(CydiaRuntime::ProtectedLibraryPath(alias, true).empty(),
        "a mutable alias cannot authorize an otherwise protected system directory");
    unlink(alias.c_str()); rmdir(temporary);
    const char *message("Failed to fetch %s  %s");
    Require(CydiaAPTMessage(message) == message, "messages remain usable before optional gettext initialization");
    Require(CydiaAPTMessage(nullptr) == nullptr, "a missing message remains missing");
    CydiaConfigureAPTMessages("/nonexistent-cydia-gettext", "/nonexistent-cydia-locales", "");
    Require(!CydiaAPTMessagesAvailable(), "a missing library is reported instead of claiming localization support");
    Require(_(message) == message, "missing gettext preserves the original upstream message and format placeholders");
    Require(std::strcmp(P_("one index", "many indexes", 1), "one index") == 0 &&
        std::strcmp(P_("one index", "many indexes", 0), "many indexes") == 0 &&
        std::strcmp(P_("one index", "many indexes", 2), "many indexes") == 0,
        "missing gettext follows the upstream English plural fallback");
    Require(dgettext("dpkg", message) == message, "missing dpkg catalogs do not translate through an unrelated domain");
    const char *domain(textdomain(nullptr));
    Require(domain != nullptr && std::strncmp(domain, "cydia-apt-", 10) == 0 &&
        std::strcmp(textdomain("apt"), domain) == 0,
        "embedded APT retains its own source-version domain");
    Require(std::strcmp(bindtextdomain("apt", "/unrelated-distribution-catalogs"), "") == 0,
        "APT configuration cannot redirect its private domain to mismatched distribution catalogs");
    std::puts("[verify-apt-messages] passed");
    return 0;
}
