/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryDependencyInspector.hpp"
#include "Cydia/AptRecoveryMachO.hpp"
#include "Cydia/ProtectedLibraryPath.hpp"
#include <apt-pkg/hashes.h>
#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <set>
#include <sstream>
#include <unistd.h>
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#endif

namespace CydiaAPT { namespace Recovery {
namespace {
namespace P = CydiaRuntime::Privileged;
std::string Hash(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM);
    if (!hash.Add(bytes.data(), bytes.size())) return {};
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
bool SameFile(const struct stat &a, const struct stat &b) {
    if (a.st_dev != b.st_dev || a.st_ino != b.st_ino || a.st_size != b.st_size || a.st_mode != b.st_mode || a.st_uid != b.st_uid || a.st_gid != b.st_gid) return false;
#if defined(__APPLE__)
    return a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
#else
    return a.st_mtim.tv_sec == b.st_mtim.tv_sec && a.st_mtim.tv_nsec == b.st_mtim.tv_nsec &&
        a.st_ctim.tv_sec == b.st_ctim.tv_sec && a.st_ctim.tv_nsec == b.st_ctim.tv_nsec;
#endif
}
std::string Lower(std::string s) { for (char &c : s) if (c >= 'A' && c <= 'Z') c += 'a' - 'A'; return s; }
bool Prefix(const std::string &s, const std::string &prefix) { return s.compare(0, prefix.size(), prefix) == 0; }
std::string Parent(const std::string &s) {
    const auto slash(s.rfind('/'));
    return slash == 0 ? "/" : s.substr(0, slash);
}
std::string Normalize(const std::string &s) {
    if (s.empty() || s[0] != '/' || s.size() > 4096 || std::any_of(s.begin(), s.end(), [](unsigned char c) { return c < 32 || c == 127; })) return {};
    std::vector<std::string> parts; std::istringstream input(s); std::string part;
    while (std::getline(input, part, '/')) {
        if (part.empty() || part == ".") continue;
        if (part == "..") { if (parts.empty()) return {}; parts.pop_back(); }
        else parts.push_back(part);
    }
    std::string value; for (const auto &p : parts) value += '/' + p;
    return value.empty() ? "/" : value;
}
struct Config {
    std::vector<std::pair<std::string, std::string>> entries;
    std::string Get(const std::string &key, const std::string &fallback = {}) const {
        for (const auto &entry : entries) if (entry.first == key) return entry.second;
        return fallback;
    }
    // Authority.configuration is the linked libapt's flattened Dump(), not an
    // arbitrary apt.conf file. Reject directives, sections, duplicate scalar
    // values, quotes/newlines and unsupported tag escapes instead of reparsing
    // them differently from the worker. Empty vector tags can repeat.
    bool Read(const std::string &bytes) {
        if (bytes.size() > 1024 * 1024) return false;
        std::istringstream input(bytes); std::string line; std::set<std::string> scalars;
        while (std::getline(input, line)) {
            if (line.empty()) continue;
            const auto split = line.find(" \"");
            if (split == std::string::npos || line.size() < split+4 || line.compare(line.size()-2, 2, "\";") != 0 || entries.size() >= 16384) return false;
            const std::string key = Lower(line.substr(0, split)), value = line.substr(split+2, line.size()-split-4);
            if (key.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-._:") != std::string::npos ||
                value.find('"') != std::string::npos || value.find('\0') != std::string::npos) return false;
            if (!key.empty() && key.back() != ':' && !scalars.insert(key).second) return false;
            if (!key.empty()) entries.emplace_back(key, value);
        }
        return !entries.empty();
    }
};
#if defined(__APPLE__)
std::string SystemValue(const char *key) {
    char bytes[256] = {}; std::size_t size = sizeof(bytes);
    if (sysctlbyname(key, bytes, &size, nullptr, 0) || size == 0 || size > sizeof(bytes) || bytes[size-1]) return {};
    return bytes;
}
uint32_t Version(const std::string &value) {
    unsigned components[3] = {}; std::size_t index = 0;
    if (value.empty()) return 0;
    for (unsigned char c : value) {
        if (c == '.' && index < 2) { ++index; continue; }
        if (c < '0' || c > '9' || components[index] > 6553) return 0;
        components[index] = components[index] * 10 + c - '0';
    }
    if (components[0] > 65535 || components[1] > 255 || components[2] > 255) return 0;
    return components[0] << 16 | components[1] << 8 | components[2];
}
uint32_t OperatingSystem() {
    const auto version = Version(SystemValue("kern.osproductversion"));
    if (version) return version;
    // Older iOS has no kern.osproductversion. Read the platform's own bounded
    // property list, rather than confusing Darwin kernel and iOS versions.
    const std::string path = CydiaRuntime::ProtectedLibraryPath("/System/Library/CoreServices/SystemVersion.plist");
    if (path.empty()) return 0;
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC); if (fd < 0) return 0;
    struct stat st; std::string bytes;
    if (!fstat(fd, &st) && st.st_size > 0 && st.st_size <= 65536) {
        bytes.resize(st.st_size); std::size_t at = 0;
        while (at < bytes.size()) { const auto n = read(fd, &bytes[at], bytes.size()-at); if (n < 0 && errno == EINTR) continue; if (n <= 0) break; at += n; }
        if (at != bytes.size()) bytes.clear();
    }
    close(fd); if (bytes.empty()) return 0;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(bytes.data()), bytes.size());
    if (!data) return 0;
    CFPropertyListRef plist = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, nullptr, nullptr); CFRelease(data);
    uint32_t result = 0;
    if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFTypeRef value = CFDictionaryGetValue(static_cast<CFDictionaryRef>(plist), CFSTR("ProductVersion")); char text[64];
        if (value && CFGetTypeID(value) == CFStringGetTypeID() && CFStringGetCString(static_cast<CFStringRef>(value), text, sizeof(text), kCFStringEncodingUTF8)) result = Version(text);
    }
    if (plist) CFRelease(plist); return result;
}
#endif
struct Inspector {
    const Authority &authority; const std::function<bool()> &cancelled;
    DependencyProof proof; MachO::Target target; Config config;
    struct Input { Component component; MachO::Image image; std::string canonical; bool binary = false, script = false, discovered = false; };
    std::map<std::string, Input> inputs;
    std::map<std::string, std::string> aliases;
    std::set<std::string> unresolved, dependencies, visited;
    std::vector<std::string> loaderFields;
    std::size_t totalBytes = 0;
    Inspector(const Authority &value, const std::function<bool()> &stop) : authority(value), cancelled(stop) {}
#if defined(CYDIA_RECOVERY_DEPENDENCY_TESTING)
    bool fixture = false;
#endif
    bool Stopped() { if (cancelled && cancelled()) { unresolved.insert("dependencyInspectionCancelled"); return true; } return false; }
    void Missing(const std::string &field) { if (unresolved.size() < 100) unresolved.insert(field); }
    bool Platform(const std::string &path) {
#if defined(__APPLE__)
        // Membership in the active cache, not /usr/lib spelling, establishes a
        // platform image. On older systems, only a currently mapped image with
        // MH_DYLIB_IN_CACHE supplies the equivalent evidence.
        using Contains = bool (*)(const char *);
        static const auto contains = reinterpret_cast<Contains>(dlsym(RTLD_DEFAULT, "_dyld_shared_cache_contains_path"));
        if (contains && contains(path.c_str())) return true;
        for (uint32_t n = 0; n < _dyld_image_count(); ++n) {
            const auto *header = _dyld_get_image_header(n); const char *name = _dyld_get_image_name(n);
            if (header && name && (header->flags & 0x80000000u) && path == name) return true;
        }
#else
        (void)path;
#endif
        return false;
    }
    bool CurrentTarget() {
#if defined(__APPLE__)
        const auto *header = _dyld_get_image_header(0);
        if (!header) return false;
        target.cpu = header->cputype; target.subtype = header->cpusubtype;
#if TARGET_OS_SIMULATOR
        target.platform = 7;
#elif TARGET_OS_IPHONE
        target.platform = 2;
#else
        target.platform = 1;
#endif
        target.operatingSystem = OperatingSystem();
        const auto build = SystemValue("kern.osversion");
        if (!target.operatingSystem || build.empty()) return false;
        loaderFields = {"CYDIA-RECOVERY-LOADER-1", build, std::to_string(target.cpu), std::to_string(target.subtype), std::to_string(target.platform), std::to_string(target.operatingSystem)};
        // Bind UUIDs of the mapped cache's images. This does not dlopen a new
        // image, and keeps cache changes distinct from OS version text alone.
        for (uint32_t n = 0; n < _dyld_image_count(); ++n) {
            const auto *h = _dyld_get_image_header(n); const char *name = _dyld_get_image_name(n);
            if (!h || !name || !(h->flags & 0x80000000u) || h->sizeofcmds > 1024*1024 || h->ncmds > 4096) continue;
            const unsigned char *p = reinterpret_cast<const unsigned char *>(h) + (h->magic == 0xfeedfacfu ? 32 : 28);
            std::size_t remaining = h->sizeofcmds;
            for (uint32_t c = 0; c < h->ncmds && remaining >= sizeof(load_command); ++c) {
                load_command command; std::memcpy(&command, p, sizeof(command));
                if (command.cmdsize < 8 || command.cmdsize > remaining) break;
                if (command.cmd == LC_UUID && command.cmdsize >= 24) loaderFields.push_back(std::string(name) + ':' + Hash(std::string(reinterpret_cast<const char *>(p+8), 16)));
                p += command.cmdsize; remaining -= command.cmdsize;
            }
        }
        return true;
#else
        return false;
#endif
    }
    bool Read(Component component, bool discovered = false) {
        if (Stopped()) return false;
        P::Error error;
        const auto canonical = CydiaRuntime::ProtectedLibraryPath(component.path);
        if (canonical.empty() || !P::ValidateRootOwnedPath(component.path, false, component.executable, &error)) { Missing("componentProtectionInvalid"); return false; }
        const int fd = open(canonical.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        struct stat before{}, after{}, current{}; std::string bytes;
        bool okay = fd >= 0 && !fstat(fd, &before) && S_ISREG(before.st_mode) && before.st_size >= 0 && before.st_size <= 128*1024*1024;
        if (okay) { totalBytes += before.st_size; okay = totalBytes <= 512*1024*1024; }
        if (okay) {
            bytes.resize(before.st_size); std::size_t at = 0;
            while (at < bytes.size() && !Stopped()) {
                const auto n = read(fd, &bytes[at], std::min<std::size_t>(32768, bytes.size()-at));
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break; at += n;
            }
            okay = at == bytes.size() && !fstat(fd, &after) && !stat(component.path.c_str(), &current) && SameFile(before, after) && SameFile(before, current);
        }
        if (fd >= 0) close(fd);
        const auto digest = okay ? Hash(bytes) : std::string();
        if (!okay || digest.empty() || (!discovered && digest != component.sha256) || CydiaRuntime::ProtectedLibraryPath(component.path) != canonical) { Missing("componentChanged"); return false; }
        if (discovered) component.sha256 = digest;
        Input input; input.component = component; input.canonical = canonical; input.discovered = discovered;
        input.script = Prefix(bytes, "#!"); input.binary = MachO::IsMachO(bytes.data(), bytes.size());
        if (input.binary) {
            std::string reason;
            if (!MachO::Inspect(bytes.data(), bytes.size(), target, &input.image, &reason)) { Missing(reason); return false; }
        } else if (component.executable) Missing(input.script ? "scriptCommandClosureUnsupported" : "componentFormatUnsupported");
        if (inputs.count(component.path)) { Missing("componentInventoryInvalid"); return false; }
        const auto prior = aliases.find(canonical);
        if (prior != aliases.end() && inputs.at(prior->second).component.sha256 != component.sha256) { Missing("componentInventoryInvalid"); return false; }
        aliases[canonical] = component.path; inputs.emplace(component.path, std::move(input));
        if (discovered) {
            proof.discoveredComponents.push_back(component);
            loaderFields.push_back(P::SerializeFields({"externalDependency", component.path, component.sha256}));
        }
        return true;
    }
    Input *Find(const std::string &path) {
        auto found = inputs.find(path); if (found != inputs.end()) return &found->second;
        const auto canonical = CydiaRuntime::ProtectedLibraryPath(path);
        const auto alias = aliases.find(canonical); return alias == aliases.end() ? nullptr : &inputs.at(alias->second);
    }
    std::string Expand(const std::string &path, const std::string &loader, const std::string &executable) {
        if (path == "@loader_path") return Normalize(Parent(loader));
        if (path == "@executable_path") return Normalize(Parent(executable));
        if (Prefix(path, "@loader_path/")) return Normalize(Parent(loader) + path.substr(12));
        if (Prefix(path, "@executable_path/")) return Normalize(Parent(executable) + path.substr(16));
        return Normalize(path);
    }
    bool Closure(Input &input, const std::string &executable, std::vector<std::string> inherited, bool external = false, unsigned depth = 0) {
        if (Stopped()) return false;
        if (depth > 64 || visited.size() >= 4096) { Missing("dependencyGraphTooLarge"); return false; }
        if (!input.binary) { Missing(input.script ? "scriptCommandClosureUnsupported" : "componentFormatUnsupported"); return false; }
        std::vector<std::string> search;
        for (const auto &rpath : input.image.rpaths) {
            const auto path = Expand(rpath, input.canonical, executable);
            if (path.empty()) { Missing("dynamicLoaderSearchUnsupported"); return false; }
            search.push_back(path);
        }
        for (const auto &path : inherited) if (std::find(search.begin(), search.end(), path) == search.end()) search.push_back(path);
        if (search.size() > 256) { Missing("dependencyGraphTooLarge"); return false; }
        const auto key = P::SerializeFields({input.canonical, executable, P::SerializeFields(search), external ? "external" : "private"});
        if (!visited.insert(key).second) return true;
        for (const auto &dependency : input.image.dependencies) {
            std::vector<std::string> candidates;
            if (Prefix(dependency.name, "@rpath/")) for (const auto &path : search) candidates.push_back(Normalize(path + dependency.name.substr(6)));
            else candidates.push_back(Expand(dependency.name, input.canonical, executable));
            bool resolved = false;
            for (const auto &path : candidates) {
                if (path.empty()) { Missing("dynamicLoaderSearchUnsupported"); return false; }
                if (Platform(path)) { loaderFields.push_back(path + ':' + std::to_string(dependency.compatibilityVersion)); resolved = true; break; }
                struct stat st;
#if defined(CYDIA_RECOVERY_DEPENDENCY_TESTING)
                if (fixture) { if (!inputs.count(path)) continue; }
                else
#endif
                if (lstat(path.c_str(), &st) != 0 && errno == ENOENT) continue;
                // Do not skip a present, undeclared earlier rpath candidate to
                // manufacture a different resolution from the real loader.
                Input *child = Find(path);
                if (!child && external && proof.discoveredComponents.size() < 256 && inputs.size() < 768) {
                    Component component; component.path = path;
                    if (!Read(component, true)) return false;
                    child = Find(path);
                }
                if (!child) { Missing("dependencyInventoryIncomplete"); return false; }
                if (child->discovered && !external) { Missing("privateDependencyInventoryIncomplete"); return false; }
                if (!child->binary || child->image.type != 6 || child->image.currentVersion < dependency.compatibilityVersion) { Missing("dependencyABIUnsupported"); return false; }
                dependencies.insert(child->component.path);
                loaderFields.push_back(P::SerializeFields({"dependency", input.component.path, dependency.name, child->component.path}));
                if (!Closure(*child, executable, search, external, depth+1)) return false;
                resolved = true; break;
            }
            // Weak imports are still part of the declared payload contract;
            // absence does not establish that the program handles it safely.
            if (!resolved) { Missing("dependencyUnavailable"); return false; }
        }
        return true;
    }
    bool Command(const std::string &path, const char *field, bool external = false) {
        const auto normalized = Normalize(path);
        if (normalized.empty()) { Missing(field); return false; }
        Input *input = Find(normalized);
        if (!input) { Missing(field); return false; }
        if (input->discovered && !external) { Missing("privateDependencyInventoryIncomplete"); return false; }
        struct stat st;
        if (stat(path.c_str(), &st) || !(st.st_mode & 0111) || !input->binary || input->image.type != 2) {
            Missing(input->script ? "scriptCommandClosureUnsupported" : "configuredCommandFormatUnsupported"); return false;
        }
        dependencies.insert(input->component.path);
        return Closure(*input, input->canonical, {}, external);
    }
    void OptionalMessages() {
        // This is the worker's explicit dlopen interface in AptMessages.cpp.
        // Missing gettext remains optional; a present candidate must belong to
        // the declared private closure rather than enter through ambient paths.
        const auto app = CydiaRuntime::PackageDatabasePaths::Current().CydiaApplicationDirectory();
        for (const char *leaf : {"libintl.8.dylib", "libintl.dylib"}) {
            const auto path = app + "/Frameworks/" + leaf;
            if (CydiaRuntime::ProtectedLibraryPath(path).empty()) continue;
            Input *input = Find(path);
            if (!input || input->discovered) { Missing("privateGettextInventoryIncomplete"); continue; }
            if (!input->binary || input->image.type != 6) { Missing("privateGettextFormatUnsupported"); continue; }
            dependencies.insert(input->component.path); Closure(*input, authority.executable, {});
        }
    }
    void Commands() {
        if (!config.Read(authority.configuration)) { Missing("configuredCommandPolicyInvalid"); return; }
        if (config.Get("apt::solver", "internal") != "internal") Missing("externalSolverUnsupported");
        if (config.Get("apt::planner", "internal") != "internal") Missing("externalPlannerUnsupported");
        if (config.Get("apt::compressor::.::name", ".") != ".") Missing("compressorInterfaceUnsupported");
        const std::set<std::string> ordinaryBins{"methods", "dpkg", "dpkg-query", "dpkg-deb", "apt-key", "apt-config", "gpg", "gpgv", "gzip", "bzip2", "xz", "lzma", "lz4", "zstd", "uncompressed", "solvers", "planners"};
        const std::set<std::string> methods{"http", "https", "copy", "file", "gpgv", "rred", "store"};
        for (const auto &entry : inputs) if (entry.second.component.executable && Prefix(entry.first, authority.runtime.methodsDirectory + '/')) {
            const auto name = entry.first.substr(authority.runtime.methodsDirectory.size()+1);
            if (!methods.count(name)) Missing("acquisitionMethodInterfaceUnsupported");
        }
        for (const auto &entry : config.entries) {
            const auto &key = entry.first, &value = entry.second;
            if (value.empty()) continue;
            if (key.find("pre-invoke") != std::string::npos || key.find("post-invoke") != std::string::npos || key.find("pre-install-pkgs") != std::string::npos ||
                key.find("auth-failure") != std::string::npos || key.find("proxy-auto-detect") != std::string::npos || key.find("proxyautodetect") != std::string::npos ||
                (Prefix(key, "acquire::cdrom::") && key != "acquire::cdrom::mount") ||
                Prefix(key, "acquire::rsh::") || Prefix(key, "acquire::ssh::") || key == "methods::mirror::problemreporting") Missing("configuredCommandInterfaceUnsupported");
            // pkgInitConfig supplies this passive mount-point path even when
            // no cdrom source is enabled. Per-mount Mount/UMount entries are
            // shell commands and remain unsupported above.
            // Binary-specific configuration is reapplied by subprocesses. Its
            // effects are not represented by this single clean authority dump.
            if (Prefix(key, "binary::")) Missing("binaryConfigurationUnsupported");
            if (Prefix(key, "dir::bin::methods::")) {
                if (!methods.count(key.substr(std::strlen("dir::bin::methods::")))) Missing("acquisitionMethodInterfaceUnsupported");
                Command(value[0] == '/' ? value : authority.runtime.methodsDirectory + '/' + value, "acquisitionMethodUnavailable");
            }
            else if (Prefix(key, "dir::bin::")) {
                std::string leaf = key.substr(10); while (!leaf.empty() && leaf.back() == ':') leaf.pop_back();
                if (!ordinaryBins.count(leaf)) Missing("configuredCommandInterfaceUnsupported");
            }
            if (Prefix(key, "apt::key::") && key != "apt::key::gpgcommand" && key != "apt::key::gpgvcommand" && key != "apt::key::archivekeyring" && key != "apt::key::removedkeys") Missing("keyCommandPolicyUnsupported");
            if (Prefix(key, "apt::compressor::")) {
                const auto rest = key.substr(17);
                const auto end = rest.find("::");
                const auto name = rest.substr(0, end);
                if (name != "gzip" && name != "bzip2" && name != "xz" && name != "lzma" && name != "lz4" && name != "zstd" && name != ".") Missing("compressorInterfaceUnsupported");
            }
        }
        Command(config.Get("dir::bin::apt-key"), "privateAptKeyUnavailable");
        Command(config.Get("dir::bin::apt-config"), "privateAptConfigUnavailable");
        Command(config.Get("apt::key::gpgcommand", config.Get("dir::bin::gpg")), "privateGpgUnavailable");
        Command(config.Get("apt::key::gpgvcommand", config.Get("dir::bin::gpgv")), "privateGpgvUnavailable");
        for (const char *name : {"gzip", "bzip2", "xz", "lzma", "lz4", "zstd"}) {
            const std::string prefix = std::string("apt::compressor::") + name + "::";
            if (config.Get(prefix + "name", name) != name) { Missing("compressorInterfaceUnsupported"); continue; }
            // Cydia's private APT uses its linked gzip reader. Binary is not
            // consulted for that Name by FileFd; no external gzip is required.
            if (std::strcmp(name, "gzip") == 0) continue;
            std::string command = config.Get(prefix + "binary", name);
            const auto path = config.Get(std::string("dir::bin::") + name);
            // An explicitly absent probe path disables this external format.
            // Without a captured choice, runtime defaults are not a closure.
            if (path.empty()) { Missing("compressionPolicyIncomplete"); continue; }
            struct stat st;
            if (lstat(path.c_str(), &st) && errno == ENOENT) {
                if (Normalize(path) != path || CydiaRuntime::ProtectedLibraryPath(Parent(path), true).empty()) Missing("compressionPolicyUnsupported");
                else loaderFields.push_back("disabledCompression:" + std::string(name) + ':' + path);
                continue;
            }
            if (command.empty() || command == "false") { Missing("compressionPolicyUnsupported"); continue; }
            if (command.front() != '/') {
                if (command.find('/') != std::string::npos) { Missing("compressionPolicyUnsupported"); continue; }
                std::istringstream directories(authority.acquisitionSearchPath); std::string directory, resolved;
                while (std::getline(directories, directory, ':')) {
                    const auto candidate = Normalize(directory + '/' + command);
                    if (!candidate.empty() && access(candidate.c_str(), X_OK) == 0) { resolved = candidate; break; }
                }
                command = resolved;
            }
            Command(command, "privateCompressorUnavailable");
        }
        // The selected distribution's dpkg is intentionally an external
        // requirement. It is never replaced with a private recovery dpkg.
        for (const auto &path : {authority.runtime.dpkgExecutablePath, authority.runtime.dpkgQueryExecutablePath, authority.runtime.dpkgDebExecutablePath, authority.runtime.privilegedHelperPath}) Command(path, "selectedDpkgUnavailable", true);
    }
    DependencyProof Run(const std::string &inventory) {
        proof.inventoryIdentity = inventory;
        if (!CurrentTarget()) Missing("targetLoaderUnavailable");
        else {
            if (authority.components.empty() || authority.components.size() > 512) Missing("componentInventoryInvalid");
            else for (const auto &component : authority.components) { if (Stopped()) break; Read(component); }
            std::set<std::string> externalRoots;
            for (const auto &path : {authority.runtime.dpkgExecutablePath, authority.runtime.dpkgQueryExecutablePath, authority.runtime.dpkgDebExecutablePath, authority.runtime.privilegedHelperPath})
                if (Input *input = Find(path)) externalRoots.insert(input->canonical);
            for (auto &entry : inputs) if (entry.second.binary && !entry.second.discovered) Closure(entry.second,
                entry.second.image.type == 2 ? entry.second.canonical : authority.executable, {}, externalRoots.count(entry.second.canonical) != 0);
            Commands();
            OptionalMessages();
        }
        loaderFields.push_back(inventory);
        std::sort(loaderFields.begin(), loaderFields.end()); loaderFields.erase(std::unique(loaderFields.begin(), loaderFields.end()), loaderFields.end());
        proof.loaderIdentity = Hash(P::SerializeFields(loaderFields));
        proof.nonPlatformDependencies.assign(dependencies.begin(), dependencies.end());
        proof.unresolvedFields.assign(unresolved.begin(), unresolved.end()); return proof;
    }
};
}
DependencyProof InspectInstalledDependencies(const Authority &authority, const std::string &inventory,
    const std::function<bool()> &cancelled) {
    Inspector inspector{authority, cancelled}; return inspector.Run(inventory);
}
#if defined(CYDIA_RECOVERY_DEPENDENCY_TESTING)
DependencyProof InspectConfiguredCommandsForTesting(const std::string &configuration) {
    Authority authority; authority.configuration = configuration;
    const std::function<bool()> cancelled;
    Inspector inspector(authority, cancelled); inspector.Commands();
    inspector.proof.unresolvedFields.assign(inspector.unresolved.begin(), inspector.unresolved.end());
    return inspector.proof;
}
DependencyProof InspectDependencyGraphForTesting(const std::map<std::string, MachO::Image> &images,
    const std::vector<std::string> &roots, const std::function<bool()> &cancelled) {
    Authority authority; Inspector inspector(authority, cancelled); inspector.fixture = true;
    for (const auto &entry : images) {
        Inspector::Input input; input.component.path = input.canonical = entry.first;
        input.component.sha256.assign(64, 'a'); input.image = entry.second; input.binary = true;
        inspector.inputs.emplace(entry.first, std::move(input));
    }
    for (const auto &root : roots) {
        auto found = inspector.inputs.find(root);
        if (found == inspector.inputs.end()) inspector.Missing("rootMissing");
        else inspector.Closure(found->second, root, {});
    }
    inspector.proof.nonPlatformDependencies.assign(inspector.dependencies.begin(), inspector.dependencies.end());
    inspector.proof.unresolvedFields.assign(inspector.unresolved.begin(), inspector.unresolved.end());
    return inspector.proof;
}
#endif
}}
