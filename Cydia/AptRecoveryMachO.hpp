/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryMachO_HPP
#define Cydia_AptRecoveryMachO_HPP
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace CydiaAPT { namespace Recovery { namespace MachO {
// Wire-format constants keep the reader testable without Darwin headers.
struct Target {
    uint32_t cpu, subtype, platform, operatingSystem;
    Target(uint32_t cpuValue = 0, uint32_t subtypeValue = 0, uint32_t platformValue = 0, uint32_t operatingSystemValue = 0) :
        cpu(cpuValue), subtype(subtypeValue), platform(platformValue), operatingSystem(operatingSystemValue) {}
};
struct Dependency {
    std::string name;
    uint32_t compatibilityVersion;
    bool weak;
    Dependency(const std::string &value = std::string(), uint32_t version = 0, bool optional = false) :
        name(value), compatibilityVersion(version), weak(optional) {}
};
struct Image {
    uint32_t cpu = 0, subtype = 0, type = 0, platform = 0, minimumOS = 0;
    uint32_t currentVersion = 0, compatibilityVersion = 0;
    std::string identifier, dynamicLoader;
    std::vector<std::string> rpaths;
    std::vector<Dependency> dependencies;
};
// Does not map, load or execute code. Checks the selected slice and the complete
// bounded load-command area, including offsets in fat and thin headers.
bool Inspect(const void *bytes, std::size_t size, const Target &, Image *, std::string *error);
bool IsMachO(const void *bytes, std::size_t size);
}}}
#endif
