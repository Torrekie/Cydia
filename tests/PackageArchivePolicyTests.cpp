/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PackageArchivePolicy.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
#if defined(CYDIA_TEST_PACKAGE_ARCHIVE_READER)
#include "Cydia/PackageArchiveReader.hpp"
#include <apt-pkg/aptconfiguration.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/init.h>
#include <unistd.h>
#endif

using namespace CydiaPackages;
namespace {
const ArchiveIdentity identity = {"sample", "1:2.0-1", "all"};
const ArchiveLayout rootful = {"/", {"/var/jb"}};
const ArchiveLayout rootless = {"/var/jb", {"/opt/distro"}};
std::string Control(const std::string &architecture = "all") {
    return "Package: sample\nVersion: 1:2.0-1\nArchitecture: " + architecture + "\nDescription: Fixture\n continuation\n";
}
void Octal(char *field, std::size_t size, unsigned long long value) {
    std::snprintf(field, size, "%0*llo", static_cast<int>(size - 1), value);
}
std::string Entry(const std::string &name, char type = '0', const std::string &body = "",
                  const std::string &link = "", const std::string &prefix = "") {
    assert(name.size() <= 100 && link.size() <= 100 && prefix.size() <= 155);
    char header[512] = {};
    std::memcpy(header, name.data(), name.size());
    Octal(header + 100, 8, 0644); Octal(header + 108, 8, 0); Octal(header + 116, 8, 0);
    Octal(header + 124, 12, body.size()); Octal(header + 136, 12, 0);
    std::memset(header + 148, ' ', 8); header[156] = type;
    std::memcpy(header + 157, link.data(), link.size());
    std::memcpy(header + 257, "ustar\0", 6); std::memcpy(header + 263, "00", 2);
    std::memcpy(header + 345, prefix.data(), prefix.size());
    unsigned checksum(0); for (unsigned char byte : header) checksum += byte;
    Octal(header + 148, 7, checksum); header[155] = ' ';
    return std::string(header, sizeof(header)) + body + std::string((512 - body.size() % 512) % 512, '\0');
}
std::string Tar(const std::string &entries) { return entries + std::string(1024, '\0'); }
ArchiveRead Reader(const std::string &bytes, std::size_t *offset) {
    return [&bytes, offset](void *output, std::size_t count) {
        if (count > bytes.size() - *offset) return false;
        std::memcpy(output, bytes.data() + *offset, count); *offset += count; return true;
    };
}
ArchivePolicyResult Inspect(const std::string &data, const ArchiveLayout &layout = rootless,
                            const std::string &controlEntries = Entry("./control", '0', Control()),
                            const ArchiveIdentity &expected = identity, const ArchiveLimits &limits = ArchiveLimits()) {
    PackageArchivePolicy policy(expected, layout, limits);
    const std::string controlTar(Tar(controlEntries)), dataTar(Tar(data));
    std::size_t controlOffset(0), dataOffset(0);
    if (policy.ReadControlTar(Reader(controlTar, &controlOffset)))
        policy.ReadDataTar(Reader(dataTar, &dataOffset));
    return policy.Finish();
}
void Expect(const ArchivePolicyResult &result, ArchivePolicyStatus status, const char *reason = NULL) {
    if (result.status != status || (reason != NULL && result.reason != reason)) {
        std::cerr << "unexpected archive policy: " << static_cast<int>(result.status) << ' ' << result.reason
                  << ' ' << result.path << '\n'; std::abort();
    }
}
#if defined(CYDIA_TEST_PACKAGE_ARCHIVE_READER)
std::string ArMember(const std::string &name, const std::string &bytes) {
    char header[61];
    std::snprintf(header, sizeof(header), "%-16s%-12d%-6d%-6d%-8o%-10llu`\n", name.c_str(), 0, 0, 0, 0644,
                  static_cast<unsigned long long>(bytes.size()));
    return std::string(header, 60) + bytes + (bytes.size() % 2 ? "\n" : "");
}
ArchivePolicyResult InspectDeb(const std::string &bytes) {
    char path[] = "/tmp/cydia-archive-policy-XXXXXX";
    const int descriptor(mkstemp(path)); assert(descriptor >= 0);
    assert(write(descriptor, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()));
    assert(close(descriptor) == 0);
    const auto result(InspectPackageArchive(path, identity, rootless));
    assert(unlink(path) == 0); return result;
}
std::string Compress(const std::string &bytes, FileFd::CompressMode mode) {
    FileFd temporary, compressed;
    assert(GetTempFile("cydia-archive-fixture", true, &temporary) != NULL);
    assert(compressed.OpenDescriptor(temporary.Fd(), FileFd::WriteOnly, mode, false));
    assert(compressed.Write(bytes.data(), bytes.size()));
    assert(compressed.Close());
    assert(temporary.Seek(0));
    assert(temporary.Size() <= 4 * 1024 * 1024);
    std::string result(static_cast<std::size_t>(temporary.Size()), '\0');
    assert(temporary.Read(&result[0], result.size()));
    return result;
}
#endif
}

int main() {
    const auto accepted(ArchivePolicyStatus::Accepted), mismatch(ArchivePolicyStatus::LayoutMismatch);
    const auto invalid(ArchivePolicyStatus::Invalid), unverified(ArchivePolicyStatus::Unverified);
    const std::string rooted(Entry("./usr/bin/sample", '0', "data"));
    const std::string prefixed(Entry("./var/jb/usr/bin/sample", '0', "data"));
    Expect(Inspect(rooted, rootful), accepted);
    Expect(Inspect(rooted), mismatch, "unprefixed_bootstrap_destination");
    Expect(Inspect(prefixed), accepted);
    Expect(Inspect(prefixed, rootful), mismatch, "different_installation_prefix");
    const ArchiveLayout custom = {"/opt/distro", {"/var/jb"}};
    Expect(Inspect(Entry("./opt", '5') + Entry("./opt/distro/usr/bin/tool"), custom), accepted);
    Expect(Inspect(prefixed, custom), mismatch, "different_installation_prefix");
    const ArchiveLayout nested = {"/var/jb/custom", {"/var/jb"}};
    Expect(Inspect(Entry("./var/jb/custom/usr/bin/tool"), nested), accepted);
    Expect(Inspect(prefixed, nested), mismatch, "different_installation_prefix");
    Expect(Inspect(Entry("./", '5') + Entry("./var", '5') + Entry("./var/jb", '5') + prefixed), accepted);
    Expect(Inspect(Entry("./var/jb", '5') + Entry("./var/jb", '5') + prefixed), accepted);
    const auto emptyRooted(Inspect(Entry("./usr", '5') + Entry("./usr/bin", '5')));
    Expect(emptyRooted, unverified, "directory_destination_unverified"); assert(emptyRooted.complete);
    Expect(Inspect(Entry("./usr/bin", '5') + rooted), mismatch, "unprefixed_bootstrap_destination");
    const auto emptyForeign(Inspect(Entry("./var/jb", '5'), rootful));
    Expect(emptyForeign, unverified, "directory_destination_unverified"); assert(emptyForeign.complete);
    Expect(Inspect(Entry("./var/jb", '5') + prefixed, rootful), mismatch, "different_installation_prefix");
    Expect(Inspect(Entry("./var/jb", '2', "", "/usr")), invalid, "non_directory_installation_ancestor");
    Expect(Inspect(Entry("./var", '2', "", "/tmp")), invalid, "non_directory_installation_ancestor");
    Expect(Inspect(""), accepted); // Architecture: all metapackage.
    const auto meta(Inspect("")); assert(meta.identityVerified && meta.complete);
    const ArchiveIdentity concrete = {"sample", "1:2.0-1", "iphoneos-arm64"};
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control(concrete.architecture)), concrete), accepted);
    Expect(Inspect(rooted, rootless, Entry("control", '0', Control(concrete.architecture)), concrete), mismatch);
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control("iphoneos-arm"))), ArchivePolicyStatus::IdentityMismatch);
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control() + "Architecture: all\n")), invalid, "duplicate_control_field");
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control()) + Entry("./control", '0', Control())), invalid, "duplicate_control_member");
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control() + "\nPackage: other\n")), invalid, "multiple_control_records");
    const auto scripted(Inspect(prefixed, rootless, Entry("control", '0', Control()) + Entry("postinst", '0', "#!/bin/sh\nexit 0\n")));
    Expect(scripted, unverified, "maintainer_semantics_unverified"); assert(scripted.complete && scripted.identityVerified);
    Expect(Inspect(rooted, rootless, Entry("control", '0', Control()) + Entry("postinst", '0', "unknown")), mismatch);
    Expect(Inspect(Entry("./var/mobile/Library/Theme/file")), accepted);
    Expect(Inspect(Entry("./Library/LaunchDaemons/example.plist")), unverified, "shared_destination_unverified");
    Expect(Inspect(Entry("./System/Library/Audio/example")), unverified);
    Expect(Inspect(Entry("./Library/PreferenceBundles/example.bundle/file")), mismatch);
    Expect(Inspect(Entry("./var/jb/usr/lib/system-link", '2', "", "/usr/lib/libSystem.B.dylib")), accepted);
    Expect(Inspect(Entry("./var/jb/usr/lib/relative-link", '2', "", "../../../../System/Library/example")), accepted);
    Expect(Inspect(Entry("./var/jb/usr/lib/escape", '2', "", "../../../../../outside")), invalid, "unsafe_link_target");
    Expect(Inspect(Entry("./var/jb/usr/bin/tool", '1', "", "./var/jb/usr/bin/source") + Entry("./var/jb/usr/bin/source")), accepted);
    Expect(Inspect(Entry("./var/jb/usr/bin/tool", '1', "", "../outside")), invalid, "unsafe_link_target");
    Expect(Inspect(Entry("./var/jb/usr/bin/tool", '1', "", "missing")), invalid, "invalid_hardlink_target");
    Expect(Inspect(Entry("./var/jb/a", '1', "", "./var/jb/b") + Entry("./var/jb/b", '1', "", "./var/jb/a")), invalid, "hardlink_cycle");
    Expect(Inspect(Entry("./var/jb/link", '2', "", "/var/mobile") + Entry("./var/jb/link/file")), invalid, "non_directory_ancestor");
    Expect(Inspect(Entry("./var/jb/link/file") + Entry("./var/jb/link", '2', "", "/var/mobile")), invalid, "non_directory_ancestor");
    Expect(Inspect(Entry("../outside")), invalid, "unsafe_archive_path");
    Expect(Inspect(Entry("./var/jb/../../usr/bin/outside")), invalid, "unsafe_archive_path");
    Expect(Inspect(Entry("./var/jb/bad\nname")), invalid, "unsafe_archive_path");
    Expect(Inspect(Entry("sample", '0', "data", "", "var/jb/usr/bin")), accepted);
    Expect(Inspect(Entry("sample", '0', "data", "", "usr/bin")), mismatch);
    const std::string longPath("var/jb/usr/share/" + std::string(140, 'a'));
    Expect(Inspect(Entry("././@LongLink", 'L', longPath + std::string(1, '\0')) + Entry("placeholder")), accepted);
    const auto pax(Inspect(Entry("./PaxHeaders/sample", 'x', "metadata") + prefixed));
    Expect(pax, unverified, "unsupported_tar_semantics"); assert(!pax.complete && pax.identityVerified);
    Expect(Inspect(Entry("./var/jb/device", '3')), unverified, "unsupported_tar_semantics");
    ArchiveLimits limits; limits.maxEntries = 1;
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control()), identity, limits), unverified, "inspection_limit");
    limits = ArchiveLimits(); limits.maxStreamBytes = 1024;
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control()), identity, limits), unverified, "inspection_limit");
    limits = ArchiveLimits(); limits.maxMetadataBytes = 16;
    Expect(Inspect(prefixed, rootless, Entry("control", '0', Control()), identity, limits), unverified, "inspection_limit");
    std::string corrupted(prefixed); corrupted[0] ^= 1;
    Expect(Inspect(corrupted), invalid, "invalid_tar_checksum");
    PackageArchivePolicy truncated(identity, rootless); std::size_t offset(0);
    const std::string shortTar("short"); assert(!truncated.ReadControlTar(Reader(shortTar, &offset)));
    Expect(truncated.Finish(), invalid, "truncated_tar");
#if defined(CYDIA_TEST_PACKAGE_ARCHIVE_READER)
    assert(pkgInitConfig(*_config));
    const std::string container("!<arch>\n" + ArMember("debian-binary", "2.0\n"));
    const std::string control(ArMember("control.tar", Tar(Entry("control", '0', Control()))));
    const std::string data(ArMember("data.tar", Tar(prefixed)));
    Expect(InspectDeb(container + control + data), accepted);
    Expect(InspectDeb(container + control + ArMember("data.tar", Tar(rooted))), mismatch);
    Expect(InspectDeb(container + control + control + data), invalid, "duplicate_deb_member");
    Expect(InspectDeb(container + data + control), invalid, "duplicate_or_misordered_data");
    Expect(InspectDeb(container + control + ArMember("data.tar", Tar(Entry("./PaxHeaders/sample", 'x', "metadata")))), unverified);
    const auto extra(InspectDeb(container + control + ArMember("data.tar", Tar(prefixed) + rooted)));
    Expect(extra, unverified, "trailing_tar_data"); assert(!extra.complete && extra.identityVerified);
    // Exercise default and explicitly external codec configurations. Large zero
    // padding exceeds a pipe buffer, so closing at the tar terminator would
    // cause a false SIGPIPE failure for the external variant.
    for (const auto &format : std::vector<std::pair<std::string, FileFd::CompressMode> >{
            {"gzip", FileFd::Gzip}, {"xz", FileFd::Xz}}) {
        const std::string suffix(format.first == "gzip" ? ".gz" : ".xz");
        const std::string compressedControl(Compress(Tar(Entry("control", '0', Control())), format.second));
        const std::string compressedData(Compress(Tar(prefixed) + std::string(1024 * 1024, '\0'), format.second));
        const std::string extraStream(Compress(Tar(rooted), format.second));
        const std::string paddingStream(Compress(std::string(1024, '\0'), format.second));
        const std::string controlMember(ArMember("control.tar" + suffix, compressedControl));
        for (bool external : {false, true}) {
            const std::string key("APT::Compressor::" + format.first + "::Name");
            if (external) _config->Set(key, "archive-fixture-external-" + format.first);
            else _config->Clear(key);
            APT::Configuration::getCompressors(false);
            const auto result(InspectDeb(container + controlMember + ArMember("data.tar" + suffix, compressedData)));
            Expect(result, accepted); assert(result.complete && result.identityVerified);
            const auto padded(InspectDeb(container + controlMember + ArMember("data.tar" + suffix, compressedData + paddingStream)));
            Expect(padded, accepted); assert(padded.complete && padded.identityVerified);
            const auto concatenated(InspectDeb(container + controlMember + ArMember("data.tar" + suffix, compressedData + extraStream)));
            Expect(concatenated, unverified, "trailing_tar_data"); assert(!concatenated.complete && concatenated.identityVerified);
            assert(compressedData.size() > 16);
            Expect(InspectDeb(container + controlMember + ArMember("data.tar" + suffix,
                compressedData.substr(0, compressedData.size() - 12))), invalid);
            Expect(InspectDeb(container + ArMember("control.tar" + suffix,
                compressedControl.substr(0, compressedControl.size() - 12)) + ArMember("data.tar" + suffix, compressedData)), invalid);
            // Neither a valid tar terminator nor a valid compression frame
            // permits unexamined raw bytes at the end of its ar member.
            Expect(InspectDeb(container + controlMember + ArMember("data.tar" + suffix,
                compressedData + "not-a-compression-frame")), invalid);
            Expect(InspectDeb(container + ArMember("control.tar" + suffix,
                compressedControl + "not-a-compression-frame") + ArMember("data.tar" + suffix, compressedData)), invalid);
            _config->Clear(key); APT::Configuration::getCompressors(false);
        }
    }
#endif
    std::cout << "[verify-package-archive-policy][ ok ] identities, layouts, links, tar semantics and bounds\n";
}
