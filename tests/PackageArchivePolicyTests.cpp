/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PackageArchivePolicy.hpp"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <map>
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
                  const std::string &link = "", const std::string &prefix = "",
                  unsigned mode = 0644, unsigned uid = 0, unsigned gid = 0) {
    assert(name.size() <= 100 && link.size() <= 100 && prefix.size() <= 155);
    char header[512] = {};
    std::memcpy(header, name.data(), name.size());
    Octal(header + 100, 8, mode); Octal(header + 108, 8, uid); Octal(header + 116, 8, gid);
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
std::string TarNumber(std::string entry, std::size_t offset, const std::string &bytes) {
    assert(offset + bytes.size() <= 512 && entry.size() >= 512);
    entry.replace(offset, bytes.size(), bytes);
    std::memset(&entry[148], ' ', 8);
    unsigned checksum = 0;
    for (std::size_t i = 0; i < 512; ++i) checksum += static_cast<unsigned char>(entry[i]);
    Octal(&entry[148], 7, checksum); entry[155] = ' '; return entry;
}
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
struct PayloadFixture {
    ArchivePolicyResult archive;
    ArchivePayloadInspection payload;
    std::map<std::string, ArchivePayloadFileMetadata> files;
    std::map<std::string, std::string> bodies;
};
PayloadFixture InspectPayload(const std::string &data, const std::vector<std::string> &paths,
    const ArchiveLimits &limits = ArchiveLimits(), const ArchivePayloadConsumer &custom = ArchivePayloadConsumer()) {
    PayloadFixture result;
    PackageArchivePolicy policy(identity, rootless, limits);
    const std::string controlTar(Tar(Entry("control", '0', Control()))), dataTar(Tar(data));
    std::size_t controlOffset = 0, dataOffset = 0;
    const ArchivePayloadConsumer consume([&](const ArchivePayloadFileMetadata &file, const ArchiveRead &read) {
        result.files[file.path] = file;
        std::uint64_t remaining(file.size);
        while (remaining != 0) {
            char bytes[7]; const std::size_t size = static_cast<std::size_t>(std::min<std::uint64_t>(remaining, sizeof(bytes)));
            if (!read(bytes, size)) return false;
            result.bodies[file.path].append(bytes, size); remaining -= size;
        }
        return true;
    });
    if (policy.ReadControlTar(Reader(controlTar, &controlOffset)))
        policy.ReadDataTar(Reader(dataTar, &dataOffset), paths, custom ? custom : consume);
    result.archive = policy.Finish(); result.payload = policy.PayloadInspection();
    return result;
}
ArchiveControlMetadata InspectControl(const std::string &controlEntries,
    const std::string &data = "", const ArchiveLimits &limits = ArchiveLimits()) {
    PackageArchivePolicy policy(identity, rootless, limits);
    const std::string controlTar(Tar(controlEntries)), dataTar(Tar(data));
    std::size_t controlOffset = 0, dataOffset = 0;
    assert(!policy.ControlMetadata().complete);
    if (policy.ReadControlTar(Reader(controlTar, &controlOffset))) {
        assert(!policy.ControlMetadata().complete);
        policy.ReadDataTar(Reader(dataTar, &dataOffset));
    }
    policy.Finish(); return policy.ControlMetadata();
}
struct InventoryFixture {
    ArchivePolicyResult archive;
    ArchiveDataInventory inventory;
};
InventoryFixture InspectInventory(const std::string &data, const ArchiveLimits &limits = ArchiveLimits(),
    const std::string &controlEntries = Entry("control", '0', Control())) {
    InventoryFixture result;
    PackageArchivePolicy policy(identity, rootless, limits);
    const std::string controlTar(Tar(controlEntries)), dataTar(Tar(data));
    std::size_t controlOffset = 0, dataOffset = 0;
    assert(!policy.DataInventory().complete && policy.DataInventory().entries.empty());
    if (policy.ReadControlTar(Reader(controlTar, &controlOffset)))
        policy.ReadDataTarWithInventory(Reader(dataTar, &dataOffset));
    assert(!policy.DataInventory().complete && policy.DataInventory().entries.empty());
    result.archive = policy.Finish(); result.inventory = policy.DataInventory();
    return result;
}
void ExpectNoInventory(const ArchiveDataInventory &inventory, const char *reason = nullptr) {
    assert(!inventory.complete && inventory.entries.empty() && inventory.identity.package.empty() &&
        inventory.identity.version.empty() && inventory.identity.architecture.empty());
    if (reason != nullptr) assert(inventory.reason == reason);
}
void DataInventoryTests() {
    const std::string file = "var/jb/usr/share/sample";
    const std::string members = Entry("./", '5') + Entry("/", '5') + Entry("///././var/jb/usr/", '0') +
        Entry("share", '5', "", "", "var/jb/usr") + Entry("sample", '\0', "payload", "", "var/jb/usr/share") +
        Entry("//./var/jb/usr/share/alias", '1', "", "///././" + file) +
        Entry("./var/jb/usr/share/link", '2', "", "../share/sample") + Entry("var/jb/usr/share/", '5');
    const auto result = InspectInventory(members);
    assert(result.archive.complete && result.archive.identityVerified && result.inventory.complete);
    assert(result.inventory.identity.package == identity.package && result.inventory.identity.version == identity.version &&
        result.inventory.identity.architecture == identity.architecture);
    const auto &entries = result.inventory.entries;
    assert(entries.size() == 8 && entries[0].name == "/." && entries[1].name == "/");
    assert(entries[2].name == "/var/jb/usr" && entries[2].type == '5' && entries[2].headerType == '0');
    assert(entries[3].name == "/var/jb/usr/share" && entries[3].type == '5' && entries[3].headerType == '5');
    assert(entries[4].name == '/' + file && entries[4].type == '0' && entries[4].headerType == '0' && entries[4].link.empty());
    assert(entries[5].type == '1' && entries[5].link == "///././" + file && entries[5].hardlinkTarget == '/' + file);
    assert(entries[6].type == '2' && entries[6].link == "../share/sample" && entries[6].hardlinkTarget.empty());
    assert(entries[7].name == entries[3].name && entries[7].type == '5'); // Ordered duplicate directory, not a set.
    for (std::size_t i = 0; i < entries.size(); ++i) assert(entries[i].ordinal == i + 1);
    // Native interpretation is opt-in; existing generic layout behavior stays
    // unchanged for a legacy regular member ending in a directory slash.
    const auto ordinary = Inspect(Entry("var/jb/usr/", '0') + Entry(file));
    assert(!ordinary.complete && ordinary.reason == "non_directory_ancestor");
    const auto empty = InspectInventory("");
    assert(empty.inventory.complete && empty.inventory.entries.empty() && empty.inventory.reason.empty());
    PackageArchivePolicy unrequested(identity, rootless);
    const std::string control = Tar(Entry("control", '0', Control())), data = Tar("");
    std::size_t controlOffset = 0, dataOffset = 0;
    assert(unrequested.ReadControlTar(Reader(control, &controlOffset)) && unrequested.ReadDataTar(Reader(data, &dataOffset)));
    assert(unrequested.Finish().complete);
    ExpectNoInventory(unrequested.DataInventory(), "data_inventory_incomplete");

    for (const auto &name : {"var/jb/usr//share/file", "var/jb/usr/./share/file", "var/jb/usr/share/.", "var/jb/usr/share//"}) {
        const std::string member = Entry(name, '5');
        assert(Inspect(member).complete);
        const auto refused = InspectInventory(Entry(file) + member);
        assert(refused.archive.complete);
        ExpectNoInventory(refused.inventory, "data_inventory_ambiguous_name");
    }
    for (const auto &target : {"var/jb/usr//share/sample", "var/jb/usr/./share/sample", "var/jb/usr/share/sample/"}) {
        const auto refused = InspectInventory(Entry(file) + Entry("var/jb/alias", '1', "", target));
        assert(refused.archive.complete);
        ExpectNoInventory(refused.inventory, "data_inventory_ambiguous_hardlink");
    }
    // GNU extensions affect the next member but consume no member ordinal.
    const std::string longName = "var/jb/usr/share/" + std::string(140, 'a');
    const auto gnu = InspectInventory(Entry("././@LongLink", 'L', longName + std::string(1, '\0')) + Entry("placeholder") +
        Entry("././@LongLink", 'K', "./" + longName + std::string(1, '\0')) + Entry("var/jb/alias", '1'));
    assert(gnu.inventory.complete && gnu.inventory.entries.size() == 2);
    assert(gnu.inventory.entries[0].name == '/' + longName && gnu.inventory.entries[0].ordinal == 1);
    assert(gnu.inventory.entries[1].link == "./" + longName && gnu.inventory.entries[1].hardlinkTarget == '/' + longName &&
        gnu.inventory.entries[1].ordinal == 2);
    const auto scripted = InspectInventory(Entry(file), ArchiveLimits(), Entry("control", '0', Control()) + Entry("postinst"));
    assert(scripted.archive.status == ArchivePolicyStatus::Unverified && scripted.inventory.complete);
    for (const auto &bad : {Entry(file) + Entry(file), Entry(file) + Entry("PaxHeaders/file", 'x', "metadata"),
            Entry(file) + Entry("var/jb/device", '3'), Entry(file) + Entry("var/jb/alias", '1', "", "missing"),
            Entry(file) + Entry("var/jb/dir/", '0', "unexpected data"),
            Entry("var/jb/dir", '5') + Entry("var/jb/dir", '5', "", "unexpected")}) {
        ExpectNoInventory(InspectInventory(bad).inventory);
    }
    std::string corrupted = Entry("var/jb/late"); corrupted[0] ^= 1;
    ExpectNoInventory(InspectInventory(Entry(file) + corrupted).inventory, "invalid_tar_checksum");
    ExpectNoInventory(InspectInventory(Entry(file), ArchiveLimits(), Entry("control", '0', Control("amd64"))).inventory,
        "archive_identity_mismatch");
    ArchiveLimits limits; limits.maxEntries = 2;
    ExpectNoInventory(InspectInventory(Entry(file) + Entry("var/jb/late"), limits).inventory, "inspection_limit");
    limits = ArchiveLimits(); limits.maxMetadataBytes = 128;
    ExpectNoInventory(InspectInventory(Entry(file) + Entry("var/jb/late"), limits).inventory, "inspection_limit");
    limits = ArchiveLimits(); limits.maxPathBytes = file.size();
    ExpectNoInventory(InspectInventory(Entry(file), limits).inventory, "inspection_limit"); // Added native leading slash.
    limits = ArchiveLimits(); limits.maxStreamBytes = 2048;
    ExpectNoInventory(InspectInventory(Entry(file), limits).inventory, "inspection_limit");
    PackageArchivePolicy truncated(identity, rootless);
    controlOffset = dataOffset = 0; const std::string shortData = Entry(file) + std::string(512, '\0');
    assert(truncated.ReadControlTar(Reader(control, &controlOffset)));
    assert(!truncated.ReadDataTarWithInventory(Reader(shortData, &dataOffset)));
    truncated.Finish(); ExpectNoInventory(truncated.DataInventory(), "truncated_tar");
}
void ControlMetadataTests() {
    std::map<std::string, std::string> canonical, equivalent; std::string error;
    assert(CanonicalPackageEffectControlFields({{"depends", "perl:any(>=5.0),\n locales | alternative"},
        {"pre-depends", "dpkg:native"}, {"multi-arch", "foreign"}}, &canonical, &error));
    assert(CanonicalPackageEffectControlFields({{"depends", "perl:any ( >= 5.0 ) , locales|alternative"},
        {"pre-depends", "dpkg:native"}, {"multi-arch", "foreign"}, {"essential", "no"}, {"protected", "no"}}, &equivalent, &error));
    assert(canonical == equivalent && canonical.at("depends") == "perl:any (>= 5.0), locales | alternative");
    assert(canonical.at("essential") == "no" && canonical.at("protected") == "no" && canonical.at("provides").empty());
    for (const std::string malformed : {"foo bar", "foo:", "foo (>= 1 2)", "foo,", "foo [amd64]", "foo (>< 1)", "foo | | bar"}) {
        canonical["stale"] = "value";
        assert(!CanonicalPackageEffectControlFields({{"depends", malformed}}, &canonical, &error) && canonical.empty());
    }
    assert(!CanonicalPackageEffectControlFields({{"essential", "sometimes"}}, &canonical, &error) && canonical.empty());
    const std::string body = Control() + "Depends: perl:any(>=5.0),\n locales | alternative\nMulti-Arch: foreign\nProtected: yes\n";
    const std::string triggers = "# package declarations\ninterest-noawait /usr/share/icons\nactivate-noawait icon-cache\n";
    const auto metadata = InspectControl(Entry("control", '0', body) + Entry("triggers", '0', triggers));
    assert(metadata.complete && metadata.identity.package == identity.package && metadata.identity.version == identity.version &&
        metadata.identity.architecture == "all" && metadata.controls.at("protected") == "yes" && metadata.triggersPresent && metadata.triggers == triggers);
    const auto absent = InspectControl(Entry("control", '0', Control()));
    const auto empty = InspectControl(Entry("control", '0', Control()) + Entry("triggers"));
    assert(absent.complete && !absent.triggersPresent && absent.triggers.empty());
    assert(empty.complete && empty.triggersPresent && empty.triggers.empty());
    assert(!absent.prerm.present && !absent.postinst.present && absent.prerm.bytes.empty() && absent.postinst.bytes.empty());
    const std::string prerm = "#!/bin/sh\nexit 0\n", postinst("binary\0bytes", 12);
    const auto scripts = InspectControl(Entry("control", '0', Control()) +
        Entry("prerm", '0', prerm, "", "", 0755, 12, 34) +
        Entry("postinst", '0', postinst, "", "", 04755, 56, 78));
    assert(scripts.complete && scripts.prerm.present && scripts.postinst.present);
    assert(scripts.prerm.bytes == prerm && scripts.prerm.mode == 0755 && scripts.prerm.uid == 12 && scripts.prerm.gid == 34);
    assert(scripts.postinst.bytes == postinst && scripts.postinst.mode == 04755 && scripts.postinst.uid == 56 && scripts.postinst.gid == 78);
    const auto emptyScript = InspectControl(Entry("control", '0', Control()) + Entry("postinst", '0', "", "", "", 0755));
    assert(emptyScript.complete && emptyScript.postinst.present && emptyScript.postinst.bytes.empty() && emptyScript.postinst.mode == 0755);
    for (const auto &member : {Entry("prerm", '2', "", "postinst"),
            Entry("postinst", '0', prerm) + Entry("./postinst", '0', prerm)}) {
        const auto refused = InspectControl(Entry("control", '0', Control()) + member);
        assert(!refused.complete && !refused.prerm.present && !refused.postinst.present && refused.controls.empty());
    }
    std::string oversizedOwner(8, '\0'); oversizedOwner[0] = static_cast<char>(0x80); oversizedOwner[3] = 1;
    for (const auto &member : {Entry("prerm", '0', prerm, "", "", 0100755),
            TarNumber(Entry("postinst", '0', prerm), 108, "invalid!"),
            TarNumber(Entry("postinst", '0', prerm), 116, oversizedOwner)}) {
        const auto refused = InspectControl(Entry("control", '0', Control()) + member);
        assert(!refused.complete && refused.reason == "control_script_metadata_unverified" &&
            !refused.prerm.present && !refused.postinst.present && refused.controls.empty());
        // Additional evidence refusal does not change existing layout inspection.
        const auto layout = Inspect("", rootless, Entry("control", '0', Control()) + member);
        assert(layout.complete && layout.identityVerified && layout.status == ArchivePolicyStatus::Unverified);
    }
    for (const auto &entries : std::vector<std::string>{Entry("control", '0', body) + Entry("triggers") + Entry("./triggers"),
        Entry("control", '0', body) + Entry("triggers", '2', "", "control"), Entry("control", '0', Control("amd64")),
        Entry("control", '0', Control() + "Depends: foo bar\n")}) {
        const auto invalid = InspectControl(entries);
        assert(!invalid.complete && invalid.controls.empty() && invalid.triggers.empty() && !invalid.triggersPresent);
    }
    ArchiveLimits small; small.maxMetadataBytes = 128;
    const auto bounded = InspectControl(Entry("control", '0', Control()) + Entry("triggers", '0', std::string(129, 'x')), "", small);
    assert(!bounded.complete && bounded.controls.empty() && bounded.triggers.empty());
    const auto boundedScript = InspectControl(Entry("control", '0', Control()) + Entry("prerm", '0', std::string(129, 'x')), "", small);
    assert(!boundedScript.complete && !boundedScript.prerm.present && boundedScript.prerm.bytes.empty());
    const auto late = InspectControl(Entry("control", '0', body) + Entry("triggers", '0', triggers), Entry("bad", 'x', "metadata"));
    assert(!late.complete && late.controls.empty() && late.triggers.empty());
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
ArchivePayloadEvidence InspectPayloadDeb(const std::string &bytes, const std::vector<std::string> &paths,
    const ArchiveIdentity &expected = identity, const ArchiveLimits &limits = ArchiveLimits(),
    const std::function<bool()> &cancelled = std::function<bool()>()) {
    char path[] = "/tmp/cydia-archive-payload-XXXXXX";
    const int descriptor(mkstemp(path)); assert(descriptor >= 0);
    assert(write(descriptor, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()));
    assert(close(descriptor) == 0);
    const auto result(InspectPackageArchivePayloadWithDecoders(path, expected, rootless, paths, {}, limits, cancelled));
    assert(unlink(path) == 0); return result;
}
ArchiveControlEvidence InspectControlDeb(const std::string &bytes) {
    char path[] = "/tmp/cydia-archive-control-XXXXXX";
    const int descriptor(mkstemp(path)); assert(descriptor >= 0);
    assert(write(descriptor, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()));
    assert(close(descriptor) == 0);
    const auto result(InspectPackageArchiveControlWithDecoders(path, identity, rootless, {}));
    assert(unlink(path) == 0); return result;
}
ArchiveDataInventoryEvidence InspectInventoryDeb(const std::string &bytes,
    const ArchiveLimits &limits = ArchiveLimits(), const std::function<bool()> &cancelled = std::function<bool()>(),
    bool replacePath = false) {
    char path[] = "/tmp/cydia-archive-inventory-XXXXXX";
    const int descriptor(mkstemp(path)); assert(descriptor >= 0);
    assert(write(descriptor, bytes.data(), bytes.size()) == static_cast<ssize_t>(bytes.size()));
    assert(close(descriptor) == 0);
    bool replaced = false;
    const auto check = [&]() {
        // The first cancellation check is after opening the archive. Replace
        // the named file while its original descriptor remains readable.
        if (replacePath && !replaced) {
            assert(unlink(path) == 0);
            FILE *file = std::fopen(path, "wb"); assert(file != nullptr);
            assert(std::fwrite(bytes.data(), 1, bytes.size(), file) == bytes.size());
            assert(std::fclose(file) == 0); replaced = true;
        }
        return cancelled && cancelled();
    };
    const auto result(InspectPackageArchiveDataInventoryWithDecoders(path, identity, rootless, {}, limits, check));
    assert(!replacePath || replaced);
    assert(unlink(path) == 0); return result;
}
void ExpectNoPayload(const ArchivePayloadEvidence &result, const char *reason = nullptr) {
    assert(!result.payload.complete && result.files.empty());
    if (reason != nullptr && result.payload.reason != reason) {
        std::cerr << "unexpected payload evidence refusal: " << result.payload.reason << '\n'; std::abort();
    }
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
    ControlMetadataTests();
    DataInventoryTests();
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
    const ArchiveLayout enclosing = {"/var", {"/var/jb"}};
    Expect(Inspect(Entry("./var/usr/bin/tool"), enclosing), accepted);
    Expect(Inspect(prefixed, enclosing), mismatch, "different_installation_prefix");
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

    const std::string component("/var/jb/usr/bin/sample"), emptyComponent("/var/jb/usr/lib/empty");
    const std::string componentData(Entry("." + component, '0', "replacement bytes", "", "", 04755, 12, 34) +
        Entry("." + emptyComponent, '0', "", "", "", 0600, 56, 78));
    const auto payload(InspectPayload(componentData, {component, emptyComponent}));
    Expect(payload.archive, accepted); assert(payload.payload.complete && payload.files.size() == 2);
    assert(payload.files.at(component).path == component && payload.files.at(component).size == 17);
    assert(payload.files.at(component).mode == 04755 && payload.files.at(component).uid == 12 && payload.files.at(component).gid == 34);
    assert(payload.bodies.at(component) == "replacement bytes" && payload.files.at(emptyComponent).size == 0);
    assert(payload.files.at(emptyComponent).mode == 0600 && payload.files.at(emptyComponent).uid == 56 && payload.files.at(emptyComponent).gid == 78);
    for (const auto &paths : std::vector<std::vector<std::string>>{
            {}, {"var/jb/usr/bin/sample"}, {"/var/jb/usr/bin/./sample"}, {"/var/jb/usr/bin/sample/"},
            {"/var/jb/usr/bin//sample"}, {"/var/jb/usr/bin/../sample"}, {"/"}, {component, component}}) {
        const auto refused(InspectPayload(componentData, paths));
        Expect(refused.archive, accepted); assert(!refused.payload.complete && !refused.payload.reason.empty());
    }
    ArchiveLimits payloadLimits; payloadLimits.maxPayloadFiles = 1;
    assert(InspectPayload(componentData, {component, emptyComponent}, payloadLimits).payload.reason == "invalid_payload_request_count");
    const auto missingPayload(InspectPayload(prefixed, {component, emptyComponent}));
    Expect(missingPayload.archive, accepted);
    assert(!missingPayload.payload.complete && missingPayload.payload.reason == "payload_file_missing" && missingPayload.payload.path == emptyComponent);
    for (char type : {'1', '2'}) {
        const auto linked(InspectPayload(Entry("." + component, type, "", "." + emptyComponent) +
            Entry("." + emptyComponent, '0', "data"), {component}));
        Expect(linked.archive, accepted); assert(!linked.payload.complete && linked.payload.reason == "payload_not_regular");
    }
    const auto ancestor(InspectPayload(Entry("./var/jb/usr/bin", '2', "", "/bin"), {component}));
    Expect(ancestor.archive, accepted); assert(!ancestor.payload.complete && ancestor.payload.reason == "payload_link_ancestor");
    const std::string alias(Entry("./var/jb/usr/bin/alias", '1', "", "." + component));
    for (const std::string &items : {prefixed + alias, alias + prefixed}) {
        const auto linked(InspectPayload(items, {component}));
        Expect(linked.archive, accepted); assert(!linked.payload.complete && linked.payload.reason == "payload_hardlink_alias");
    }
    const auto chained(InspectPayload(Entry("./var/jb/usr/bin/a", '1', "", "./var/jb/usr/bin/alias") + alias + prefixed, {component}));
    assert(!chained.payload.complete && chained.payload.reason == "payload_hardlink_alias");
    const auto unrelated(InspectPayload(componentData + Entry("./var/jb/unrelated", '2', "", "/usr/lib/libSystem.B.dylib"), {component}));
    Expect(unrelated.archive, accepted); assert(unrelated.payload.complete);
    const auto badMode(InspectPayload(Entry("." + component, '0', "data", "", "", 0100755), {component}));
    Expect(badMode.archive, accepted); assert(!badMode.payload.complete && badMode.payload.reason == "payload_metadata_unverified");
    // Reject malformed numeric ownership and values not representable by the
    // target uid/gid types, while ordinary layout inspection remains unchanged.
    std::string oversizedOwner(8, '\0'); oversizedOwner[0] = static_cast<char>(0x80); oversizedOwner[3] = 1;
    for (std::size_t field : {std::size_t(108), std::size_t(116)}) {
        for (const std::string &value : {std::string("invalid!"), oversizedOwner}) {
            const auto badOwner(InspectPayload(TarNumber(prefixed, field, value), {component}));
            Expect(badOwner.archive, accepted);
            assert(!badOwner.payload.complete && badOwner.payload.reason == "payload_metadata_unverified");
        }
    }
    for (int behavior : {0, 1, 2}) {
        const auto refused(InspectPayload(prefixed, {component}, ArchiveLimits(),
            [behavior](const ArchivePayloadFileMetadata &file, const ArchiveRead &read) {
                char bytes[32];
                if (behavior == 0) { assert(read(bytes, 1)); return false; }
                if (behavior == 1) { assert(read(bytes, 1)); return true; }
                assert(!read(bytes, static_cast<std::size_t>(file.size + 1))); return true;
            }));
        Expect(refused.archive, accepted); assert(!refused.payload.complete && refused.payload.reason == "payload_consumer_failed");
    }
    const auto lateDuplicate(InspectPayload(prefixed + prefixed, {component}));
    Expect(lateDuplicate.archive, invalid, "duplicate_archive_path"); assert(!lateDuplicate.payload.complete);
    const auto lateUnsupported(InspectPayload(prefixed + Entry("./PaxHeaders/sample", 'x', "metadata"), {component}));
    Expect(lateUnsupported.archive, unverified, "unsupported_tar_semantics"); assert(!lateUnsupported.payload.complete);
#if defined(CYDIA_TEST_PACKAGE_ARCHIVE_READER)
    assert(pkgInitConfig(*_config));
    const std::string container("!<arch>\n" + ArMember("debian-binary", "2.0\n"));
    const std::string control(ArMember("control.tar", Tar(Entry("control", '0', Control()))));
    const std::string data(ArMember("data.tar", Tar(prefixed)));
    Expect(InspectDeb(container + control + data), accepted);
    const std::string inventoryMembers = Entry("./", '5') + Entry("/", '5') + Entry("./var/jb/usr/", '0') +
        prefixed + Entry("./var/jb/usr/bin/alias", '1', "", "./var/jb/usr/bin/sample") +
        Entry("./var/jb/usr/bin/link", '2', "", "sample");
    const std::string inventoryDeb = container + control + ArMember("data.tar", Tar(inventoryMembers));
    const auto nativeInventory = InspectInventoryDeb(inventoryDeb);
    assert(nativeInventory.archive.complete && nativeInventory.inventory.complete && nativeInventory.inventory.entries.size() == 6);
    assert(nativeInventory.inventory.entries[0].name == "/." && nativeInventory.inventory.entries[1].name == "/" &&
        nativeInventory.inventory.entries[2].type == '5' && nativeInventory.inventory.entries[2].headerType == '0' &&
        nativeInventory.inventory.entries[4].hardlinkTarget == "/var/jb/usr/bin/sample");
    const auto emptyInventory = InspectInventoryDeb(container + control + ArMember("data.tar", Tar("")));
    assert(emptyInventory.inventory.complete && emptyInventory.inventory.entries.empty());
    const std::string inventoryGzip = Compress(Tar(inventoryMembers), FileFd::Gzip);
    const auto compressedInventory = InspectInventoryDeb(container + control + ArMember("data.tar.gz", inventoryGzip));
    assert(compressedInventory.inventory.complete && compressedInventory.inventory.entries.size() == nativeInventory.inventory.entries.size());
    for (const auto &broken : std::vector<std::string>{
            container + control + ArMember("data.tar.gz", inventoryGzip + "garbage"),
            container + control + ArMember("data.tar.gz", inventoryGzip.substr(0, inventoryGzip.size() - 12)),
            container + control + ArMember("data.tar.gz", inventoryGzip + Compress(Tar(prefixed), FileFd::Gzip)),
            container + control + ArMember("data.tar", Tar(inventoryMembers) + prefixed),
            container + control + ArMember("data.tar", Tar(inventoryMembers + prefixed)),
            container + control + ArMember("data.tar", Tar(inventoryMembers + Entry("var/jb/PaxHeaders", 'x', "metadata"))),
            container + ArMember("control.tar", Tar(Entry("control", '0', Control("amd64")))) + data})
        ExpectNoInventory(InspectInventoryDeb(broken).inventory);
    ExpectNoInventory(InspectInventoryDeb(inventoryDeb, ArchiveLimits(), [] { return true; }).inventory, "inspection_cancelled");
    ExpectNoInventory(InspectInventoryDeb(inventoryDeb, ArchiveLimits(), {}, true).inventory, "archive_changed");
    ArchiveLimits inventoryLimit; inventoryLimit.maxEntries = 3;
    ExpectNoInventory(InspectInventoryDeb(inventoryDeb, inventoryLimit).inventory, "inspection_limit");
    const auto ambiguousInventory = InspectInventoryDeb(container + control + ArMember("data.tar", Tar(Entry("var/jb/usr//bin/sample"))));
    assert(ambiguousInventory.archive.complete);
    ExpectNoInventory(ambiguousInventory.inventory, "data_inventory_ambiguous_name");
    const std::string declarations = "interest-noawait /usr/share/icons\n";
    const std::string effectScript = "#!/bin/sh\nexit 0\n";
    const std::string effectTar = Tar(Entry("control", '0', Control() + "Depends: perl:any (>= 5)\n") + Entry("triggers", '0', declarations) +
        Entry("prerm", '0', effectScript, "", "", 0755) + Entry("postinst", '0', "", "", "", 0755));
    const auto controlEvidence = InspectControlDeb(container + ArMember("control.tar.gz", Compress(effectTar, FileFd::Gzip)) + data);
    assert(controlEvidence.archive.complete && controlEvidence.control.complete && controlEvidence.control.triggers == declarations);
    assert(controlEvidence.control.prerm.present && controlEvidence.control.prerm.bytes == effectScript && controlEvidence.control.prerm.mode == 0755);
    assert(controlEvidence.control.postinst.present && controlEvidence.control.postinst.bytes.empty() && controlEvidence.control.postinst.mode == 0755);
    for (const auto &broken : std::vector<std::string>{
            container + ArMember("control.tar.gz", Compress(effectTar, FileFd::Gzip) + "garbage") + data,
            container + ArMember("control.tar", effectTar) + ArMember("data.tar", Tar(prefixed) + rooted)}) {
        const auto refused = InspectControlDeb(broken);
        assert(!refused.control.complete && refused.control.controls.empty() && refused.control.triggers.empty());
        assert(!refused.control.prerm.present && !refused.control.postinst.present);
    }
    const std::string evidenceData(Entry("." + component, '0', "abc", "", "", 04755, 12, 34) +
        Entry("." + emptyComponent, '0', "", "", "", 0600, 56, 78));
    const std::string evidenceDeb(container + control + ArMember("data.tar", Tar(evidenceData)));
    const auto evidence(InspectPayloadDeb(evidenceDeb, {component, emptyComponent}));
    Expect(evidence.archive, accepted); assert(evidence.payload.complete && evidence.files.size() == 2);
    const auto &replacement(evidence.files.at(component));
    assert(replacement.metadata.path == component && replacement.metadata.size == 3 && replacement.metadata.mode == 04755);
    assert(replacement.metadata.uid == 12 && replacement.metadata.gid == 34);
    assert(replacement.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert(evidence.files.at(emptyComponent).sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    ExpectNoPayload(InspectPayloadDeb(evidenceDeb, {component, "/var/jb/missing"}), "payload_file_missing");
    ExpectNoPayload(InspectPayloadDeb(evidenceDeb, {component, component}), "invalid_payload_request_path");
    ExpectNoPayload(InspectPayloadDeb(evidenceDeb, {component}, concrete), "archive_identity_mismatch");
    ExpectNoPayload(InspectPayloadDeb(container + control + ArMember("data.tar", Tar(rooted)), {component}), "unprefixed_bootstrap_destination");
    ExpectNoPayload(InspectPayloadDeb(container + control + ArMember("data.tar", Tar(prefixed + alias)), {component}), "payload_hardlink_alias");
    ExpectNoPayload(InspectPayloadDeb(container + control + ArMember("data.tar", Tar(Entry("." + component, '2', "", "/usr/bin/false"))), {component}), "payload_not_regular");
    ExpectNoPayload(InspectPayloadDeb(container + control + ArMember("data.tar", Tar(prefixed) + rooted), {component}), "trailing_tar_data");
    ExpectNoPayload(InspectPayloadDeb(container + control + ArMember("data.tar", Tar(prefixed + prefixed)), {component}), "duplicate_archive_path");
    ExpectNoPayload(InspectPayloadDeb(evidenceDeb, {component}, identity, ArchiveLimits(), [] { return true; }), "inspection_cancelled");
    ArchiveLimits shortEvidence; shortEvidence.maxStreamBytes = evidenceDeb.size() - 1;
    ExpectNoPayload(InspectPayloadDeb(evidenceDeb, {component}, identity, shortEvidence), "inspection_limit");
    const std::string scriptedControl(ArMember("control.tar", Tar(Entry("control", '0', Control()) + Entry("postinst", '0', "#!/bin/sh\nexit 0\n"))));
    const auto scriptedEvidence(InspectPayloadDeb(container + scriptedControl + ArMember("data.tar", Tar(evidenceData)), {component}));
    Expect(scriptedEvidence.archive, unverified, "maintainer_semantics_unverified"); assert(scriptedEvidence.payload.complete);
    // The new API always uses its explicit decoder set. gzip is internal;
    // neither APT compressor settings nor an arbitrary PATH helper is needed.
    const std::string gzipEvidence(Compress(Tar(evidenceData), FileFd::Gzip));
    const auto compressedEvidence(InspectPayloadDeb(container + control + ArMember("data.tar.gz", gzipEvidence), {component, emptyComponent}));
    assert(compressedEvidence.payload.complete && compressedEvidence.files.at(component).sha256 == replacement.sha256);
    ExpectNoPayload(InspectPayloadDeb(container + control + ArMember("data.tar.gz", gzipEvidence + "trailing"), {component}), "archive_decode_failed");
    assert(gzipEvidence.size() > 12);
    ExpectNoPayload(InspectPayloadDeb(container + control + ArMember("data.tar.gz", gzipEvidence.substr(0, gzipEvidence.size() - 12)), {component}));
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
