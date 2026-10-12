/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ICURuntime.hpp"
#include "Cydia/ProtectedLibraryPath.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <dlfcn.h>
#include <mutex>
#include <sys/stat.h>
#include <vector>

namespace CydiaICU {
namespace {

struct Loaded {
    API api;
    void *common = nullptr;
    void *international = nullptr;
};

int LoadFlags() {
    int flags(RTLD_LOCAL | RTLD_NOW);
#ifdef RTLD_FIRST
    flags |= RTLD_FIRST;
#endif
    return flags;
}

std::string Canonical(const std::string &path) {
    if (path.empty() || path[0] != '/' || path.find('\0') != std::string::npos) return {};
    char *resolved(realpath(path.c_str(), nullptr));
    if (resolved == nullptr) return {};
    std::string result(resolved);
    free(resolved);
    return result;
}

/* A preference or inherited environment must not make Cydia load arbitrary
 * mobile-owned code. Resolve aliases (including /var/jb), then check the
 * library and every ancestor. Apple shared-cache images are handled separately
 * and deliberately do not require a filesystem entry. */
bool ProtectedPath(const std::string &path, bool directory) {
    return !CydiaRuntime::ProtectedLibraryPath(path, directory).empty();
}

template <typename Function>
bool Symbol(void *library, const char *name, const std::string &suffix,
            const std::string &expectedImage, Function *function) {
    void *address(dlsym(library, (std::string(name) + suffix).c_str()));
    if (address == nullptr) return false;
    if (!expectedImage.empty()) {
        Dl_info info = {};
        if (dladdr(address, &info) == 0 || info.dli_fname == nullptr ||
            Canonical(info.dli_fname) != expectedImage) return false;
    }
    *function = reinterpret_cast<Function>(address);
    return true;
}

bool Resolve(Loaded *loaded, const std::string &suffix, bool apple) {
    API &api(loaded->api);
    const std::string commonImage(apple ? "" : Canonical(api.library));
    // Each field below is resolved in its own component, never RTLD_DEFAULT.
    // Matching suffixes plus image provenance prevent an incomplete bootstrap
    // ICU from accidentally borrowing Apple's functions for foreign handles.
    const std::string internationalPath(apple ? "" : api.library.substr(0, api.library.rfind('/') + 1) +
        "libicui18n" + api.library.substr(api.library.rfind('/') + 1 + std::strlen("libicuuc")));
    const std::string internationalImage(apple ? "" : Canonical(internationalPath));
#define CY_ICU_COMMON(field, name) if (!Symbol(loaded->common, #name, suffix, commonImage, &api.field)) return false
#define CY_ICU_I18N(field, name) if (!Symbol(loaded->international, #name, suffix, internationalImage, &api.field)) return false
    CY_ICU_COMMON(getVersion, u_getVersion);
    CY_ICU_COMMON(errorName, u_errorName);
    CY_ICU_COMMON(localeLanguage, uloc_getLanguage);
    CY_ICU_COMMON(localeScript, uloc_getScript);
    CY_ICU_COMMON(localeCountry, uloc_getCountry);
    CY_ICU_COMMON(localeCanonicalize, uloc_canonicalize);
    CY_ICU_COMMON(localeLikelySubtags, uloc_addLikelySubtags);
    CY_ICU_COMMON(localeForLanguageTag, uloc_forLanguageTag);
    CY_ICU_I18N(regexOpen, uregex_openC);
    CY_ICU_I18N(regexClose, uregex_close);
    CY_ICU_I18N(regexGroupCount, uregex_groupCount);
    CY_ICU_I18N(regexGroup, uregex_group);
    CY_ICU_I18N(regexSetText, uregex_setText);
    CY_ICU_I18N(regexMatches, uregex_matches);
    if (apple) {
        CY_ICU_COMMON(fromUTF8, u_strFromUTF8WithSub);
        CY_ICU_COMMON(toUTF8, u_strToUTF8WithSub);
        CY_ICU_COMMON(uppercase, u_toupper);
        CY_ICU_I18N(transliteratorOpen, utrans_openU);
        CY_ICU_I18N(transliterate, utrans_trans);
        CY_ICU_I18N(transliteratorClose, utrans_close);
    }
#undef CY_ICU_COMMON
#undef CY_ICU_I18N
    api.getVersion(api.version);
    if (api.version[0] == 0) return false;
    if (!apple) {
        // Stable since ICU 49. This reads the loaded data, rather than merely
        // checking that a plausible libicudata filename exists on disk.
        void (*dataVersion)(UVersionInfo, UErrorCode *) = nullptr;
        if (api.version[0] < 49 || !Symbol(loaded->common, "u_getDataVersion", suffix, commonImage, &dataVersion)) return false;
        UVersionInfo data = {};
        UErrorCode status(U_ZERO_ERROR);
        dataVersion(data, &status);
        if (U_FAILURE(status) || data[0] != api.version[0] || data[1] != api.version[1]) return false;
        const std::string expected("_" + std::to_string(api.version[0]) +
            (api.kind == ProviderKind::Private ? "_cydia" : ""));
        if (!suffix.empty() && suffix != expected) return false;
    }

    // Exercise the services that depend on packaged data. A successfully loaded
    // library with absent/corrupt resources is not a usable ICU provider.
    UErrorCode status(U_ZERO_ERROR);
    char locale[ULOC_FULLNAME_CAPACITY] = {};
    const int32_t length(api.localeLikelySubtags("zh_Hant", locale, sizeof(locale), &status));
    if (U_FAILURE(status) || length <= 0 || length >= static_cast<int32_t>(sizeof(locale))) return false;
    UParseError parse = {};
    URegularExpression *regex(api.regexOpen("\\p{L}+", 0, &parse, &status));
    if (U_FAILURE(status) || regex == nullptr) {
        if (regex != nullptr) api.regexClose(regex);
        return false;
    }
    const UChar text[] = {0x00e9};
    api.regexSetText(regex, text, 1, &status);
    const bool matches(api.regexMatches(regex, 0, &status));
    api.regexClose(regex);
    if (U_FAILURE(status) || !matches) return false;
    api.symbolSuffix = suffix;
    return true;
}

void Close(Loaded *loaded) {
    if (loaded->international != nullptr && loaded->international != loaded->common) dlclose(loaded->international);
    if (loaded->common != nullptr) dlclose(loaded->common);
    *loaded = Loaded();
}

bool ResolveSuffix(Loaded *loaded, bool apple) {
    // Apple's single system image deliberately exports unrenamed symbols.
    // Split external components require ICU's normal versioned C exports;
    // an unrenamed i18n image cannot prove which common ABI it was built for.
    if (apple && Resolve(loaded, "", true)) return true;
    // ICU's version bytes range from 0 to 255. Lookup is bounded and happens
    // only once per candidate at process startup, including versionless links.
    for (int major(255); major >= 49; --major) {
        const std::string suffix("_" + std::to_string(major) +
            (loaded->api.kind == ProviderKind::Private ? "_cydia" : ""));
        if (Resolve(loaded, suffix, apple)) return true;
    }
    return false;
}

bool CandidateName(const std::string &name, const std::string &stem) {
    if (name == stem + ".dylib") return true;
    if (name.size() <= stem.size() + 7 || name.compare(0, stem.size() + 1, stem + ".") != 0 ||
        name.compare(name.size() - 6, 6, ".dylib") != 0) return false;
    for (size_t index(stem.size() + 1); index != name.size() - 6; ++index)
        if ((name[index] < '0' || name[index] > '9') && name[index] != '.') return false;
    return true;
}

bool LoadDirectory(const std::string &directory, ProviderKind kind, Loaded *loaded) {
    if (!ProtectedPath(directory, true)) return false;
    DIR *stream(opendir(directory.c_str()));
    if (stream == nullptr) return false;
    const std::string stem(kind == ProviderKind::Private ? "libicuuc_cydia" : "libicuuc");
    std::vector<std::string> candidates;
    while (dirent *entry = readdir(stream)) {
        if (CandidateName(entry->d_name, stem)) candidates.push_back(entry->d_name);
        if (candidates.size() > 256) break;
    }
    closedir(stream);
    if (candidates.size() > 256) return false;
    // Prefer the distribution's explicit unversioned link; versioned runtime
    // packages are also usable without installing ICU development symlinks.
    std::sort(candidates.begin(), candidates.end(), [&](const std::string &left, const std::string &right) {
        if (left == stem + ".dylib") return right != left;
        if (right == stem + ".dylib") return false;
        const unsigned long leftMajor(strtoul(left.c_str() + stem.size() + 1, nullptr, 10));
        const unsigned long rightMajor(strtoul(right.c_str() + stem.size() + 1, nullptr, 10));
        return leftMajor != rightMajor ? leftMajor > rightMajor : left > right;
    });
    for (const std::string &name : candidates) {
        const std::string common(directory + "/" + name);
        const std::string international(directory + "/libicui18n" + name.substr(std::strlen("libicuuc")));
        if (!ProtectedPath(common, false) || !ProtectedPath(international, false)) continue;
        Loaded candidate;
        candidate.api.kind = kind;
        candidate.api.library = common;
        candidate.common = dlopen(Canonical(common).c_str(), LoadFlags());
        if (candidate.common == nullptr) continue;
        candidate.international = dlopen(Canonical(international).c_str(), LoadFlags());
        if (candidate.international != nullptr && ResolveSuffix(&candidate, false)) {
            *loaded = candidate;
            return true;
        }
        Close(&candidate);
    }
    return false;
}

const Loaded &Apple() {
    static const Loaded *loaded = []() {
        Loaded *result(new Loaded);
        result->api.kind = ProviderKind::Apple;
        result->api.library = "/usr/lib/libicucore.A.dylib";
        result->common = dlopen(result->api.library.c_str(), LoadFlags());
        result->international = result->common;
        if (result->common == nullptr || !ResolveSuffix(result, true)) Close(result);
        // Do not dlclose a selected provider: static regex destructors and
        // callbacks may run after other C++ static objects are destroyed.
        return result;
    }();
    return *loaded;
}

struct Selection {
    std::mutex mutex;
    const Loaded *provider = nullptr;
};
Selection &State() {
    static Selection *state(new Selection);
    return *state;
}
void Select(Selection *state, const std::string &bootstrap, const std::string &privateDirectory) {
    Loaded candidate;
    if (LoadDirectory(bootstrap, ProviderKind::Bootstrap, &candidate)) state->provider = new Loaded(candidate);
    else if (Apple().api.available()) state->provider = &Apple();
    else if (LoadDirectory(privateDirectory, ProviderKind::Private, &candidate)) state->provider = new Loaded(candidate);
    else state->provider = new Loaded;
}
} // namespace

bool Initialize(const std::string &bootstrapLibraryDirectory, const std::string &privateLibraryDirectory) {
    Selection &state(State());
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.provider != nullptr) return false;
    Select(&state, bootstrapLibraryDirectory, privateLibraryDirectory);
    return true;
}

const API &Services() {
    Selection &state(State());
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.provider == nullptr) Select(&state, "", "");
    return state.provider->api;
}

const API &AppleCollation() { return Apple().api; }
} // namespace CydiaICU
