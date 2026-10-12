/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryMachO.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <TargetConditionals.h>
#endif
namespace {
namespace M = CydiaAPT::Recovery::MachO;
void Require(bool value, const char *description) {
    if (value) return;
    std::fprintf(stderr, "[recovery-macho] %s\n", description); std::exit(1);
}
void Set(std::string &bytes, std::size_t at, uint32_t value, bool big = false) {
    Require(at <= bytes.size() && bytes.size()-at >= 4, "fixture word in range");
    for (unsigned i = 0; i < 4; ++i) bytes[at+i] = value >> (8 * (big ? 3-i : i));
}
std::string Command(uint32_t kind, std::size_t size) {
    std::string bytes(size, '\0'); Set(bytes, 0, kind); Set(bytes, 4, size); return bytes;
}
std::string StringCommand(uint32_t kind, const std::string &name, unsigned header = 12) {
    auto bytes = Command(kind, (header+name.size()+1+7) & ~std::size_t(7));
    Set(bytes, 8, header); bytes.replace(header, name.size(), name); return bytes;
}
std::string Dylib(uint32_t kind, const std::string &name, uint32_t current = 0x20000, uint32_t compatibility = 0x10000) {
    auto bytes = StringCommand(kind, name, 24); Set(bytes, 16, current); Set(bytes, 20, compatibility); return bytes;
}
std::string Platform(uint32_t kind = 2, uint32_t minimum = 0xc0000) {
    auto bytes = Command(0x32, 24); Set(bytes, 8, kind); Set(bytes, 12, minimum); return bytes;
}
std::string Image(std::vector<std::string> commands, uint32_t cpu = 0x100000c, uint32_t subtype = 0, uint32_t type = 2) {
    auto segment = Command(0x19, 72); segment.replace(8, 6, "__TEXT"); Set(segment, 60, 5);
    commands.insert(commands.begin(), segment);
    if (type == 2) commands.push_back(Command(0x80000028u, 24));
    std::string bytes(32, '\0'); Set(bytes, 0, 0xfeedfacf); Set(bytes, 4, cpu); Set(bytes, 8, subtype);
    Set(bytes, 12, type); Set(bytes, 16, commands.size()); Set(bytes, 24, 0x80);
    for (const auto &command : commands) bytes += command;
    Set(bytes, 20, bytes.size()-32);
    if (type == 2) Set(bytes, bytes.size()-16, bytes.size());
    bytes += std::string(4, '\0'); Set(bytes, 32+48, bytes.size()); Set(bytes, 32+32, bytes.size()); return bytes;
}
std::string Executable(uint32_t cpu = 0x100000c, uint32_t subtype = 0) {
    return Image({StringCommand(0xe, "/usr/lib/dyld"), Platform(),
        StringCommand(0x8000001c, "@executable_path/../lib"), Dylib(0xc, "@rpath/libapt.dylib"),
        Dylib(0x80000018, "/usr/lib/libz.1.dylib")}, cpu, subtype);
}
std::string Fat(const std::vector<std::string> &images, const std::vector<uint32_t> &subtypes, bool wide = false) {
    const auto stride = wide ? 32u : 20u; std::string bytes(8 + stride*images.size(), '\0');
    Set(bytes, 0, wide ? 0xcafebabf : 0xcafebabe, true); Set(bytes, 4, images.size(), true);
    for (std::size_t n = 0; n < images.size(); ++n) {
        const auto entry = 8 + n*stride, offset = bytes.size(); bytes += images[n];
        Set(bytes, entry, 0x100000c, true); Set(bytes, entry+4, subtypes[n], true);
        if (wide) { Set(bytes, entry+12, offset, true); Set(bytes, entry+20, images[n].size(), true); }
        else { Set(bytes, entry+8, offset, true); Set(bytes, entry+12, images[n].size(), true); }
    }
    return bytes;
}
void Reject(const std::string &bytes, const M::Target &target, const char *description) {
    M::Image output; std::string error;
    Require(!M::Inspect(bytes.data(), bytes.size(), target, &output, &error) && !error.empty(), description);
}
}
int main(int argc, char **argv) {
    const M::Target arm64{0x100000c, 0, 2, 0x100000}, arm64e{0x100000c, 2, 2, 0x100000};
    M::Image result; std::string error;
    const auto valid = Executable();
    Require(M::Inspect(valid.data(), valid.size(), arm64, &result, &error), "valid thin arm64 image");
    Require(error.empty() && result.dependencies.size() == 2 && result.dependencies[0].compatibilityVersion == 0x10000 &&
        result.dependencies[1].weak && result.rpaths == std::vector<std::string>{"@executable_path/../lib"} && result.dynamicLoader == "/usr/lib/dyld", "exact loader metadata retained");
    const auto dylib = Image({Dylib(0xd, "@rpath/libapt.dylib"), Platform()}, 0x100000c, 0, 6);
    Require(M::Inspect(dylib.data(), dylib.size(), arm64, &result, &error) && result.currentVersion == 0x20000 && result.type == 6, "dylib identity and versions");
    for (bool wide : {false, true}) {
        const auto fat = Fat({valid, Executable(0x100000c, 2)}, {0, 2}, wide);
        Require(M::Inspect(fat.data(), fat.size(), arm64e, &result, &error) && result.subtype == 2, "fat best subtype selected");
        Require(M::Inspect(fat.data(), fat.size(), arm64, &result, &error) && result.subtype == 0, "fat baseline selected");
        std::string broken = fat; Set(broken, wide ? 20 : 16, 1, true); Reject(broken, arm64, "fat offset cannot enter headers");
        broken = fat; Set(broken, wide ? 28 : 20, 0xffffffffu, true); Reject(broken, arm64, "fat slice cannot escape file");
    }
    const auto baseline = Fat({valid}, {0});
    Require(M::Inspect(baseline.data(), baseline.size(), arm64e, &result, &error) && result.subtype == 0, "extended CPU accepts baseline slice");
    Reject(Fat({valid, valid}, {0, 0}), arm64, "duplicate compatible slices rejected");
    Reject(Fat({valid}, {2}), arm64e, "fat header must agree with thin subtype");
    Reject(Executable(0x1000007, 3), arm64, "wrong CPU rejected");
    Reject(Executable(0x100000c, 0x80000002u), arm64e, "unsupported CPU ABI capability rejected");
    for (std::size_t n = 0; n < valid.size(); ++n) Reject(valid.substr(0, n), arm64, "every truncation rejected");
    auto broken = valid; Set(broken, 16, 4097); Reject(broken, arm64, "load command count bounded");
    broken = valid; Set(broken, 36, 0xfffffff8u); Reject(broken, arm64, "load command size bounded");
    broken = valid; Set(broken, 32+72+8, 8); Reject(broken, arm64, "string offset cannot enter command fields");
    broken = valid; Set(broken, 24, 0); Reject(broken, arm64, "flat namespace is unsupported");
    Reject(Image({StringCommand(0xe, "/usr/lib/dyld"), Platform(1)}), arm64, "macOS binary is not iOS binary");
    Reject(Image({StringCommand(0xe, "/usr/lib/dyld"), Platform(2, 0x110000)}), arm64, "future minimum OS rejected");
    Reject(Image({StringCommand(0xe, "/usr/lib/dyld"), Platform(), Platform()}), arm64, "ambiguous platform metadata rejected");
    Reject(Image({StringCommand(0xe, "/private/dyld"), Platform()}), arm64, "custom dynamic loader rejected");
    Reject(Image({StringCommand(0xe, "/usr/lib/dyld"), Platform(), StringCommand(0x27, "DYLD_INSERT_LIBRARIES=/bad")}), arm64, "embedded dyld environment rejected");
    Reject(Image({StringCommand(0xe, "/usr/lib/dyld"), Platform(), Command(0x80007777u, 8)}), arm64, "unknown required loader feature rejected");
    Require(!M::IsMachO("#!/bin/sh\n", 10), "scripts are not Mach-O");
#if defined(__APPLE__)
    // Read-only check against a real current-target built artifact. No loading
    // or child execution occurs; root may also pass a worker artifact path.
    const auto *header = _dyld_get_image_header(0);
    M::Target host{uint32_t(header->cputype), uint32_t(header->cpusubtype),
#if TARGET_OS_SIMULATOR
        7,
#elif TARGET_OS_IPHONE
        2,
#else
        1,
#endif
        0xffffffffu};
    std::ifstream input(argc > 1 ? argv[1] : argv[0], std::ios::binary);
    std::string artifact((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    Require(!artifact.empty() && M::Inspect(artifact.data(), artifact.size(), host, &result, &error), "current built artifact has valid target loader metadata");
#else
    (void)argc; (void)argv;
#endif
    std::puts("Recovery Mach-O parser tests passed");
}
