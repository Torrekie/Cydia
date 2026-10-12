/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryMachO.hpp"
#include <algorithm>
#include <cstring>
#include <set>
#include <utility>

namespace CydiaAPT { namespace Recovery { namespace MachO {
namespace {
constexpr std::size_t MaxFile = 128 * 1024 * 1024, MaxCommands = 1024 * 1024;
struct Reader {
    const unsigned char *p; std::size_t size; bool big;
    Reader(const unsigned char *data, std::size_t length, bool bigEndian = false) : p(data), size(length), big(bigEndian) {}
    uint32_t U32(std::size_t i) const {
        return big ? (uint32_t(p[i]) << 24 | uint32_t(p[i+1]) << 16 | uint32_t(p[i+2]) << 8 | p[i+3]) :
            (uint32_t(p[i+3]) << 24 | uint32_t(p[i+2]) << 16 | uint32_t(p[i+1]) << 8 | p[i]);
    }
    uint64_t U64(std::size_t i) const { return big ? uint64_t(U32(i)) << 32 | U32(i+4) : uint64_t(U32(i+4)) << 32 | U32(i); }
    bool String(std::size_t command, uint32_t offset, uint32_t length, uint32_t minimum, std::string *out) const {
        if (offset < minimum || offset >= length || length - offset > 4096) return false;
        const char *first = reinterpret_cast<const char *>(p + command + offset);
        const char *end = static_cast<const char *>(std::memchr(first, 0, length - offset));
        if (!end || end == first) return false;
        out->assign(first, end);
        return std::none_of(out->begin(), out->end(), [](unsigned char c) { return c < 32 || c == 127; });
    }
};
bool Fail(std::string *error, const char *value) { if (error) *error = value; return false; }
int Rank(uint32_t cpu, uint32_t subtype, const Target &target) {
    if (cpu != target.cpu || (subtype & 0xff000000u & ~target.subtype)) return -1;
    if (subtype == target.subtype) return 2;
    // A baseline arm64 or x86_64 slice runs on the corresponding extended CPU.
    if ((cpu == 0x100000cu && subtype == 0) || (cpu == 0x1000007u && subtype == 3)) return 1;
    return -1;
}
bool Thin(Reader r, const Target &target, Image *output, std::string *error) {
    if (r.size < 28) return Fail(error, "machoTruncated");
    const uint32_t magic = r.U32(0);
    const bool wide = magic == 0xfeedfacfu || magic == 0xcffaedfeu;
    if (magic != 0xfeedfaceu && magic != 0xfeedfacfu && magic != 0xcefaedfeu && magic != 0xcffaedfeu)
        return Fail(error, "componentFormatUnsupported");
    r.big = magic == 0xcefaedfeu || magic == 0xcffaedfeu;
    const std::size_t header = wide ? 32 : 28;
    if (r.size < header) return Fail(error, "machoTruncated");
    Image image; image.cpu = r.U32(4); image.subtype = r.U32(8); image.type = r.U32(12);
    if (Rank(image.cpu, image.subtype, target) < 0) return Fail(error, "componentArchitectureUnsupported");
    if (image.type != 2 && image.type != 6 && image.type != 8) return Fail(error, "componentTypeUnsupported");
    // Recovery depends on two-level namespace binding, not process-wide symbol
    // interposition or DYLD_* directives embedded in a supplied image.
    if ((r.U32(24) & 0x80u) == 0) return Fail(error, "flatNamespaceUnsupported");
    const uint32_t count = r.U32(16), commands = r.U32(20);
    if (count > 4096 || commands > MaxCommands || commands > r.size - header || count > commands / 8)
        return Fail(error, "machoLoadCommandsInvalid");
    std::size_t cursor = header; bool platform = false, identifier = false, textSegment = false, entryPoint = false;
    uint64_t entryOffset = 0, textEnd = 0;
    for (uint32_t n = 0; n != count; ++n) {
        if (cursor + 8 > header + commands) return Fail(error, "machoLoadCommandsInvalid");
        const uint32_t command = r.U32(cursor), length = r.U32(cursor+4);
        if (length < 8 || length % (wide ? 8 : 4) || length > header + commands - cursor)
            return Fail(error, "machoLoadCommandsInvalid");
        if (command == 1 || command == 0x19) {
            const bool segment64 = command == 0x19;
            const uint32_t minimum = segment64 ? 72 : 56, sectionSize = segment64 ? 80 : 68;
            if (segment64 != wide || length < minimum) return Fail(error, "machoSegmentInvalid");
            const uint32_t sections = r.U32(cursor + (segment64 ? 64 : 48));
            const uint64_t fileOffset = segment64 ? r.U64(cursor+40) : r.U32(cursor+32), fileSize = segment64 ? r.U64(cursor+48) : r.U32(cursor+36);
            const uint64_t memorySize = segment64 ? r.U64(cursor+32) : r.U32(cursor+28);
            if (sections > (length-minimum)/sectionSize || length != minimum + sections*sectionSize || fileOffset > r.size || fileSize > r.size-fileOffset || fileSize > memorySize)
                return Fail(error, "machoSegmentInvalid");
            for (uint32_t s = 0; s < sections; ++s) {
                const std::size_t section = cursor + minimum + s*sectionSize;
                const auto sectionType = r.U32(section+(segment64 ? 64 : 56)) & 0xffu;
                const auto offset = r.U32(section+(segment64 ? 48 : 40));
                const uint64_t size = segment64 ? r.U64(section+40) : r.U32(section+36);
                if (r.U32(section+(segment64 ? 52 : 44)) > 31 ||
                    (sectionType != 1 && sectionType != 0xc && sectionType != 0x12 &&
                        (offset < fileOffset || offset > fileOffset+fileSize || size > fileOffset+fileSize-offset)))
                    return Fail(error, "machoSectionInvalid");
            }
            const uint32_t protection = r.U32(cursor+(segment64 ? 60 : 44));
            if (std::memcmp(r.p+cursor+8, "__TEXT\0", 7) == 0) {
                if (textSegment || fileOffset != 0 || fileSize < header+commands || !(protection & 4)) return Fail(error, "machoSegmentInvalid");
                textSegment = true; textEnd = fileSize;
            }
        } else if (command == 0x80000028u) {
            if (entryPoint || length != 24) return Fail(error, "machoEntryPointInvalid");
            entryPoint = true; entryOffset = r.U64(cursor+8);
        } else if (command == 4 || command == 5) {
            // Current recovery payloads use LC_MAIN; unmodeled thread-state
            // entry points cannot establish executable loadability here.
            return Fail(error, "machoEntryPointUnsupported");
        } else if (command == 0xc || command == 0x80000018u || command == 0x8000001fu || command == 0x80000023u || command == 0x20 || command == 0xd) {
            Dependency dependency;
            if (length < 24 || !r.String(cursor, r.U32(cursor+8), length, 24, &dependency.name)) return Fail(error, "machoDependencyInvalid");
            dependency.compatibilityVersion = r.U32(cursor+20); dependency.weak = command == 0x80000018u;
            if (command == 0xd) {
                if (identifier) return Fail(error, "machoIdentityInvalid");
                identifier = true; image.identifier = dependency.name;
                image.currentVersion = r.U32(cursor+16); image.compatibilityVersion = dependency.compatibilityVersion;
            } else image.dependencies.push_back(std::move(dependency));
        } else if (command == 0x8000001cu || command == 0xe) {
            std::string name;
            if (length < 12 || !r.String(cursor, r.U32(cursor+8), length, 12, &name)) return Fail(error, "machoLoaderPathInvalid");
            if (command == 0xe) {
                if (!image.dynamicLoader.empty() || name != "/usr/lib/dyld") return Fail(error, "dynamicLoaderUnsupported");
                image.dynamicLoader = name;
            } else image.rpaths.push_back(std::move(name));
        } else if (command == 0x32 || command == 0x24 || command == 0x25 || command == 0x2f || command == 0x30) {
            if (platform || length < (command == 0x32 ? 24u : 16u)) return Fail(error, "machoPlatformInvalid");
            platform = true;
            image.platform = command == 0x32 ? r.U32(cursor+8) : command == 0x24 ? 1 : command == 0x25 ? 2 : command == 0x2f ? 3 : 4;
            image.minimumOS = r.U32(cursor + (command == 0x32 ? 12 : 8));
            if (command == 0x32 && r.U32(cursor+20) > (length - 24) / 8) return Fail(error, "machoPlatformInvalid");
        } else if (command == 0x21 || command == 0x2c) {
            if (length < 20 || r.U32(cursor+16) != 0) return Fail(error, "encryptedComponentUnsupported");
        } else if (command == 2) {
            if (length != 24) return Fail(error, "machoLinkEditInvalid");
            const auto symbols = r.U32(cursor+8), count = r.U32(cursor+12), strings = r.U32(cursor+16), stringSize = r.U32(cursor+20);
            if (symbols > r.size || count > (r.size-symbols)/(wide ? 16 : 12) || strings > r.size || stringSize > r.size-strings)
                return Fail(error, "machoLinkEditInvalid");
        } else if (command == 0x22 || command == 0x80000022u) {
            if (length != 48) return Fail(error, "machoLinkEditInvalid");
            for (unsigned at = 8; at < 48; at += 8)
                if (r.U32(cursor+at) > r.size || r.U32(cursor+at+4) > r.size-r.U32(cursor+at)) return Fail(error, "machoLinkEditInvalid");
        } else if (command == 0x1d || command == 0x1e || command == 0x26 || command == 0x29 || command == 0x2b || command == 0x2e) {
            if (length != 16 || r.U32(cursor+8) > r.size || r.U32(cursor+12) > r.size-r.U32(cursor+8)) return Fail(error, "machoLinkEditInvalid");
        } else if (command == 0x80000033u || command == 0x80000034u) {
            if (length != 16 || r.U32(cursor+8) > r.size || r.U32(cursor+12) > r.size-r.U32(cursor+8)) return Fail(error, "machoLinkEditInvalid");
            if ((target.platform == 2 && target.operatingSystem < 0xe0000) || (target.platform == 1 && target.operatingSystem < 0xb0000))
                return Fail(error, "machoRequiredCommandUnsupported");
        } else if (command == 0x27 || command == 0x80000035u || command == 0x80000036u) {
            return Fail(error, "dynamicLoaderPolicyUnsupported");
        } else if ((command & 0x80000000u) && command != 0x80000022u && command != 0x80000028u && command != 0x80000033u && command != 0x80000034u) {
            return Fail(error, "machoRequiredCommandUnsupported");
        }
        cursor += length;
    }
    if (cursor != header + commands || !platform || image.platform != target.platform || !image.minimumOS || !target.operatingSystem || image.minimumOS > target.operatingSystem)
        return Fail(error, "componentPlatformUnsupported");
    if (!textSegment || (image.type == 2 && (!entryPoint || entryOffset < header+commands || entryOffset >= textEnd))) return Fail(error, "machoEntryPointInvalid");
    if ((image.type == 6 && !identifier) || (image.type == 2 && image.dynamicLoader.empty())) return Fail(error, "machoIdentityInvalid");
    *output = std::move(image); if (error) error->clear(); return true;
}
}
bool IsMachO(const void *bytes, std::size_t size) {
    if (!bytes || size < 4) return false;
    Reader r{static_cast<const unsigned char *>(bytes), size};
    const auto magic = r.U32(0);
    return magic == 0xfeedfaceu || magic == 0xfeedfacfu || magic == 0xcefaedfeu || magic == 0xcffaedfeu ||
        magic == 0xcafebabeu || magic == 0xbebafecau || magic == 0xcafebabfu || magic == 0xbfbafecau;
}
bool Inspect(const void *bytes, std::size_t size, const Target &target, Image *output, std::string *error) {
    if (output) *output = Image();
    if (!bytes || !output || size < 4 || size > MaxFile || !target.cpu || !target.platform) return Fail(error, "machoInputInvalid");
    Reader r{static_cast<const unsigned char *>(bytes), size};
    const auto magic = r.U32(0);
    const bool fat = magic == 0xcafebabeu || magic == 0xbebafecau || magic == 0xcafebabfu || magic == 0xbfbafecau;
    if (!fat) return Thin(r, target, output, error);
    if (size < 8) return Fail(error, "machoTruncated");
    r.big = magic == 0xbebafecau || magic == 0xbfbafecau;
    const bool wide = magic == 0xcafebabfu || magic == 0xbfbafecau;
    const uint32_t count = r.U32(4), stride = wide ? 32 : 20;
    if (!count || count > 64 || count > (size - 8) / stride) return Fail(error, "machoFatInvalid");
    int best = -1; std::size_t offset = 0, length = 0; uint32_t cpu = 0, subtype = 0;
    std::vector<std::pair<uint64_t, uint64_t>> ranges;
    for (uint32_t n = 0; n != count; ++n) {
        const std::size_t entry = 8 + n * stride;
        const uint64_t start = wide ? r.U64(entry+8) : r.U32(entry+8), span = wide ? r.U64(entry+16) : r.U32(entry+12);
        const uint32_t align = r.U32(entry + (wide ? 24 : 16));
        if (!span || start < 8 + count * stride || start > size || span > size - start || align > 31 || (start & ((uint64_t(1) << align) - 1)))
            return Fail(error, "machoFatInvalid");
        for (const auto &range : ranges) if (start < range.second && start + span > range.first) return Fail(error, "machoFatInvalid");
        ranges.emplace_back(start, start+span);
        const int rank = Rank(r.U32(entry), r.U32(entry+4), target);
        if (rank >= 0 && rank == best) return Fail(error, "machoFatAmbiguous");
        if (rank > best) { best = rank; offset = start; length = span; cpu = r.U32(entry); subtype = r.U32(entry+4); }
    }
    if (best < 0) return Fail(error, "componentArchitectureUnsupported");
    if (!Thin({r.p + offset, length}, target, output, error)) return false;
    if (output->cpu != cpu || output->subtype != subtype) { *output = Image(); return Fail(error, "machoFatInvalid"); }
    return true;
}
}}}
