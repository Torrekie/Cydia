/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptMessages.h"
#include "Cydia/ProtectedLibraryPath.hpp"

#include <dlfcn.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

namespace {
#ifndef CYDIA_APT_MESSAGE_DOMAIN
#define CYDIA_APT_MESSAGE_DOMAIN "cydia-apt"
#endif
const char Domain[] = CYDIA_APT_MESSAGE_DOMAIN;
struct Gettext {
    void *image = NULL;
    char *(*message)(const char *, const char *) = NULL;
    char *(*plural)(const char *, const char *, const char *, unsigned long) = NULL;
    char *(*bind)(const char *, const char *) = NULL;
    char *(*codeset)(const char *, const char *) = NULL;
};
Gettext provider;
std::mutex initialization;
bool configured = false;
std::string catalogDirectory;

template <typename T> T Symbol(void *image, const char *gnu, const char *plain) {
    void *symbol(dlsym(image, gnu));
    return reinterpret_cast<T>(symbol == NULL ? dlsym(image, plain) : symbol);
}

bool Load(const std::string &directory) {
    if (directory.empty() || directory[0] != '/') return false;
    for (const char *leaf : {"libintl.8.dylib", "libintl.dylib"}) {
        const std::string path(CydiaRuntime::ProtectedLibraryPath(directory + "/" + leaf));
        if (path.empty()) continue;
        Gettext candidate;
        int flags = RTLD_NOW | RTLD_LOCAL;
#ifdef RTLD_FIRST
        flags |= RTLD_FIRST;
#endif
        candidate.image = dlopen(path.c_str(), flags);
        if (candidate.image == NULL) continue;
        candidate.message = Symbol<decltype(candidate.message)>(candidate.image, "libintl_dgettext", "dgettext");
        candidate.plural = Symbol<decltype(candidate.plural)>(candidate.image, "libintl_dngettext", "dngettext");
        candidate.bind = Symbol<decltype(candidate.bind)>(candidate.image, "libintl_bindtextdomain", "bindtextdomain");
        candidate.codeset = Symbol<decltype(candidate.codeset)>(candidate.image, "libintl_bind_textdomain_codeset", "bind_textdomain_codeset");
        if (candidate.message && candidate.plural && candidate.bind && candidate.codeset) {
            provider = candidate;
            // Returned strings belong to this provider for the process lifetime.
            return true;
        }
        dlclose(candidate.image);
    }
    return false;
}
}

void CydiaConfigureAPTMessages(const char *library, const char *locales, const char *application) {
    std::lock_guard<std::mutex> lock(initialization);
    if (configured) return;
    configured = true;
    const std::string app(application == NULL ? "" : application);
    catalogDirectory = app.empty() ? "" : app + "/APTLocale";
    if (!Load(library == NULL ? "" : library) && !app.empty()) Load(app + "/Frameworks");
    if (provider.image == NULL) return;
    if (!catalogDirectory.empty()) provider.bind(Domain, catalogDirectory.c_str());
    provider.codeset(Domain, "UTF-8");
    // dpkg's own diagnostics are looked up by APT for its documented progress
    // interpretation. Never bind them to the bundled APT catalogs.
    if (locales != NULL && locales[0] == '/') provider.bind("dpkg", locales);
    provider.codeset("dpkg", "UTF-8");
}

const char *CydiaAPTMessage(const char *message) {
    return CydiaAPTDomainMessage(Domain, message);
}

const char *CydiaAPTDomainMessage(const char *domain, const char *message) {
    if (message == NULL || provider.message == NULL) return message;
    if (domain != NULL && (std::strcmp(domain, "apt") == 0 || std::strcmp(domain, "apt-utils") == 0)) domain = Domain;
    return provider.message(domain == NULL ? Domain : domain, message);
}

const char *CydiaAPTPluralMessage(const char *singular, const char *plural, unsigned long count) {
    return provider.plural == NULL ? (count == 1 ? singular : plural) :
        provider.plural(Domain, singular, plural, count);
}

const char *CydiaAPTTextDomain(const char *) { return Domain; }

const char *CydiaAPTBindTextDomain(const char *domain, const char *directory) {
    // Embedded library and method messages use catalogs from their exact
    // source revision, independently of a bootstrap's Dir::Locale setting.
    if (domain == NULL || std::strcmp(domain, Domain) == 0 ||
        std::strcmp(domain, "apt") == 0 || std::strcmp(domain, "apt-utils") == 0)
        return catalogDirectory.c_str();
    return provider.bind == NULL ? directory : provider.bind(domain, directory);
}

int CydiaAPTMessagesAvailable(void) { return provider.image != NULL; }
