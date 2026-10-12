/* Parent archive proof tests use only disposable source/index/archive files.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderArchiveEvidence.hpp"
#include <apt-pkg/hashes.h>
#include <apt-pkg/strutl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>
#include <zlib.h>

namespace {
namespace P = CydiaAPT::Provider;
void Require(bool value, const char *message) {
    if (!value) { std::cerr << "[apt-provider-archive-evidence] " << message << '\n'; std::abort(); }
}
std::string SHA256(const std::string &bytes) {
    Hashes hash(Hashes::SHA256SUM);
    Require(hash.Add(bytes.data(), bytes.size()), "hash fixture");
    return hash.GetHashString(Hashes::SHA256SUM).HashValue();
}
void Write(const std::string &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file.write(bytes.data(), bytes.size()); Require(file.good(), "write fixture");
}
void Octal(char *field, std::size_t size, unsigned long long value) {
    std::snprintf(field, size, "%0*llo", static_cast<int>(size - 1), value);
}
std::string Tar(const std::string &control, const std::string &name = "control") {
    char header[512] = {};
    Require(name.size() <= 100, "fixture tar name");
    std::memcpy(header, name.data(), name.size());
    Octal(header + 100, 8, 0644); Octal(header + 108, 8, 0); Octal(header + 116, 8, 0);
    Octal(header + 124, 12, control.size()); Octal(header + 136, 12, 0);
    std::memset(header + 148, ' ', 8); header[156] = '0';
    std::memcpy(header + 257, "ustar\0", 6); std::memcpy(header + 263, "00", 2);
    unsigned checksum = 0; for (unsigned char c : header) checksum += c;
    Octal(header + 148, 7, checksum); header[155] = ' ';
    return std::string(header, sizeof(header)) + control + std::string((512 - control.size() % 512) % 512 + 1024, '\0');
}
std::string Ar(const std::string &name, const std::string &bytes) {
    char header[61];
    std::snprintf(header, sizeof(header), "%-16s%-12d%-6d%-6d%-8o%-10llu`\n", name.c_str(), 0, 0, 0, 0644,
        static_cast<unsigned long long>(bytes.size()));
    return std::string(header, 60) + bytes + (bytes.size() % 2 ? "\n" : "");
}
std::string Deb(const std::string &architecture = "all") {
    return "!<arch>\n" + Ar("debian-binary", "2.0\n") +
        Ar("control.tar", Tar("Package: sample\nVersion: 1\nArchitecture: " + architecture + "\nDescription: fixture\n")) +
        Ar("data.tar", std::string(1024, '\0'));
}
std::string Gzip(const std::string &bytes) {
    z_stream stream = {};
    Require(deflateInit2(&stream, 6, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK, "gzip init");
    std::string result(compressBound(bytes.size()) + 128, '\0');
    stream.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(bytes.data())); stream.avail_in = bytes.size();
    stream.next_out = reinterpret_cast<Bytef *>(&result[0]); stream.avail_out = result.size();
    Require(deflate(&stream, Z_FINISH) == Z_STREAM_END, "gzip fixture");
    result.resize(stream.total_out); Require(deflateEnd(&stream) == Z_OK, "gzip finish"); return result;
}
struct Fixture {
    std::string directory, record, indexBytes, deb;
    CydiaAPT::RuntimeDescriptor runtime;
    P::ReviewedTransaction review;
    Fixture(bool compressed = false) {
        char pattern[] = "/tmp/cydia-provider-proof-XXXXXX";
        char *created = mkdtemp(pattern); Require(created != nullptr, "fixture directory");
        directory = created; std::filesystem::create_directory(directory + "/lists");
        runtime.sourceListPath = directory + "/sources.list"; runtime.listsDirectory = directory + "/lists";
        runtime.architecture = "amd64"; runtime.registeredArchitectures = {"amd64"}; runtime.acquisitionArchitectures = {"amd64"};
        runtime.binding.providerIdentifier = review.binding.providerIdentifier = "fixture-provider";
        runtime.binding.session = review.binding.session = std::string(64, 'a');
        runtime.binding.configurationIdentity = review.binding.configurationIdentity = "fixture-config";
        runtime.binding.policyIdentity = review.binding.policyIdentity = "fixture-policy";
        Write(runtime.sourceListPath, "deb https://example.invalid/ ./\n");
        P::ArchiveManifest archive;
        archive.identifier = "sample"; archive.package = {"sample", "1", "all"};
        archive.sourceDefinitionPath = runtime.sourceListPath;
        archive.sourceURI = "https://example.invalid/"; archive.sourceIndexURI = "https://example.invalid/./Packages";
        archive.sourceIndexPath = runtime.listsDirectory + '/' + URItoFileName(archive.sourceIndexURI) + (compressed ? ".gz" : "");
        archive.filename = "pool/sample.deb"; archive.path = directory + "/sample.deb";
        deb = Deb(); archive.size = deb.size(); archive.hashes = {{"SHA256", SHA256(deb)}};
        archive.layout = {"/", {"/var/jb"}};
        record = "Package: sample\nVersion: 1\nArchitecture: all\nFilename: " + archive.filename +
            "\nSize: " + std::to_string(archive.size) + "\nSHA256: " + archive.hashes["SHA256"] + "\n\n";
        indexBytes = compressed ? Gzip(record) : record;
        archive.recordSize = record.size(); archive.sourceIndexIdentity = "SHA256:" + SHA256(indexBytes);
        Write(archive.sourceIndexPath, indexBytes); Write(archive.path, deb); review.execution.archives.push_back(archive);
    }
    ~Fixture() { std::filesystem::remove_all(directory); }
    std::shared_ptr<P::ArchiveEvidenceSnapshot> Capture(std::string *error, const std::function<bool()> &cancelled = {}) {
        return P::ArchiveEvidenceSnapshot::Capture(runtime, review, "/usr/bin:/bin", cancelled, error);
    }
};
void SetControls(Fixture &fixture, const std::string &indexFields, const std::string &archiveFields,
    bool triggersPresent = true, const std::string &triggers = "interest-noawait /usr/share/icons\n") {
    auto &archive = fixture.review.execution.archives.front();
    std::string controlTar = Tar("Package: sample\nVersion: 1\nArchitecture: all\n" + archiveFields);
    if (triggersPresent) {
        std::string triggerTar = Tar(triggers, "triggers");
        controlTar.resize(controlTar.size() - 1024); controlTar += triggerTar;
    }
    fixture.deb = "!<arch>\n" + Ar("debian-binary", "2.0\n") + Ar("control.tar", controlTar) + Ar("data.tar", std::string(1024, '\0'));
    archive.size = fixture.deb.size(); archive.hashes = {{"SHA256", SHA256(fixture.deb)}};
    fixture.record = "Package: sample\nVersion: 1\nArchitecture: all\nFilename: " + archive.filename +
        "\nSize: " + std::to_string(archive.size) + "\nSHA256: " + archive.hashes["SHA256"] + "\n" + indexFields + "\n";
    archive.recordSize = fixture.record.size(); archive.sourceIndexIdentity = "SHA256:" + SHA256(fixture.record);
    Write(archive.sourceIndexPath, fixture.record); Write(archive.path, fixture.deb);
}
void ControlProof() {
    Fixture fixture; std::string error;
    SetControls(fixture, "Depends: perl:any (>= 5),\n locales | other\nMulti-Arch: foreign\n",
        "Depends: perl:any(>=5),locales|other\nMulti-Arch: foreign\nEssential: no\n");
    auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
    std::map<std::string, std::string> controls;
    auto archive = fixture.review.execution.archives.front();
    Require(snapshot->ControlFields(archive, &controls, {}, &error) && controls["depends"] == "perl:any (>= 5), locales | other" &&
        controls["essential"] == "no", "retained index canonical control fields");
    std::vector<P::VerifiedArchiveControlEvidence> proof;
    Require(snapshot->VerifyControl({archive}, &proof, {}, &error) && proof.size() == 1 &&
        proof[0].archive.archive.identifier == archive.identifier && !proof[0].archive.fileIdentity.empty() &&
        proof[0].control.complete && proof[0].control.identity.architecture == "all" && proof[0].control.triggersPresent &&
        proof[0].control.triggers == "interest-noawait /usr/share/icons\n", "independent index/archive control match");
    auto forged = archive; forged.package.version = "2";
    Require(!snapshot->ControlFields(forged, &controls, {}, &error) && controls.empty(), "worker identity cannot solicit record control proof");
    Write(archive.sourceIndexPath, fixture.record + "\n");
    Require(!snapshot->ControlFields(archive, &controls, {}, &error) && controls.empty(), "changed retained index cannot publish control authority");
    for (const auto &mismatch : std::vector<std::pair<std::string, std::string>>{
            {"Depends: perl (= 1)\n", "Depends: perl (= 2)\n"},
            {"Protected: yes\n", ""}, {"Multi-Arch: same\n", "Multi-Arch: foreign\n"}}) {
        Fixture bad; SetControls(bad, mismatch.first, mismatch.second);
        auto capture = bad.Capture(&error); Require(capture != nullptr, error.c_str());
        Require(!capture->VerifyControl(bad.review.execution.archives, &proof, {}, &error) && proof.empty() &&
            error == "provider_archive_control_index_mismatch", "different archive control cannot inherit index authority");
    }
    Fixture absent; SetControls(absent, "", "", false);
    auto empty = absent.Capture(&error); Require(empty != nullptr, error.c_str());
    Require(empty->VerifyControl(absent.review.execution.archives, &proof, {}, &error) && !proof[0].control.triggersPresent,
        "absence of trigger declarations is proved from archive, not Packages metadata");
    Require(!empty->VerifyControl(absent.review.execution.archives, &proof, [] { return true; }, &error) && proof.empty(),
        "cancelled control proof has no partial publication");
}
void ValidAndChanged(bool compressed) {
    Fixture fixture(compressed); std::string error;
    auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
    std::vector<P::VerifiedArchiveEvidence> evidence;
    Require(snapshot->Verify(fixture.review.execution.archives, &evidence, {}, &error), error.c_str());
    Require(evidence.size() == 1 && evidence[0].inspection.identityVerified && evidence[0].inspection.complete,
        "archive verification evidence missing");
    auto forged = fixture.review.execution.archives;
    forged[0].filename = "pool/other.deb";
    Require(!snapshot->Verify(forged, &evidence, {}, &error) && evidence.empty(), "changed reviewed manifest accepted");
    Write(fixture.review.execution.archives[0].path, Deb("amd64"));
    Require(!snapshot->Verify(fixture.review.execution.archives, &evidence, {}, &error), "changed archive accepted");
}
void SourceAndIndexBinding() {
    for (int variant = 0; variant < 8; ++variant) {
        Fixture fixture; auto &archive = fixture.review.execution.archives.front(); std::string error;
        switch (variant) {
            case 0: archive.sourceURI = "https://other.invalid/"; break;
            case 1: archive.sourceDefinitionOrdinal = 1; break;
            case 2: archive.sourceIndexIdentity = "SHA256:" + std::string(64, '0'); break;
            case 3: archive.recordOffset = 1; --archive.recordSize; break;
            case 4: archive.package.version = "2"; break;
            case 5: archive.hashes["SHA256"] = std::string(64, '0'); break;
            case 6: archive.recordSize = 1024 * 1024 + 1; break;
            case 7: Write(fixture.runtime.sourceListPath, "# deb https://example.invalid/ ./\n"); break;
        }
        Require(!fixture.Capture(&error), "unproved index record accepted");
    }
    Fixture fixture; std::string error; auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
    Write(fixture.runtime.sourceListPath, "deb https://different.invalid/ ./\n");
    std::vector<P::VerifiedArchiveEvidence> evidence;
    Require(!snapshot->Verify(fixture.review.execution.archives, &evidence, {}, &error), "source change after review accepted");
    Fixture changed; auto other = changed.Capture(&error); Require(other != nullptr, error.c_str());
    Write(changed.review.execution.archives[0].sourceIndexPath, changed.record + "\n");
    Require(!other->Verify(changed.review.execution.archives, &evidence, {}, &error), "index change after review accepted");
    Fixture cancelled;
    Require(!cancelled.Capture(&error, [] { return true; }) && error == "provider_cancelled", "capture cancellation ignored");
}
void AuthorizationBeforeDownload() {
    Fixture fixture;
    auto &archive = fixture.review.execution.archives.front();
    fixture.record.insert(fixture.record.size() - 1, "Tag: role::enduser, cydia::commercial\n");
    archive.recordSize = fixture.record.size(); archive.sourceIndexIdentity = "SHA256:" + SHA256(fixture.record);
    Write(archive.sourceIndexPath, fixture.record);
    std::string error; auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
    Require(unlink(archive.path.c_str()) == 0, "remove undownloaded archive fixture");
    CydiaRuntime::RepositoryArchiveAuthorizationRequest request; bool commercial(false);
    Require(snapshot->AuthorizationRequest(archive, &request, &commercial, {}, &error) && commercial &&
        request.sourceURL == archive.sourceURI && request.package == "sample" && request.version == "1" && request.architecture == "all",
        "grant identity must derive from verified record without needing the archive");
    auto forged = archive; forged.package.architecture = "amd64";
    Require(!snapshot->AuthorizationRequest(forged, &request, &commercial, {}, &error) && request.package.empty(),
        "unreviewed identity cannot solicit account authorization");
    Require(!snapshot->AuthorizationRequest(archive, &request, &commercial, [] { return true; }, &error) && request.package.empty(),
        "cancelled authorization proof leaves no identity");
    Write(archive.sourceIndexPath, fixture.record + "\n");
    Require(!snapshot->AuthorizationRequest(archive, &request, &commercial, {}, &error) && request.package.empty(),
        "changed source index cannot solicit account authorization");
    Fixture ordinary; auto publicSource = ordinary.Capture(&error); Require(publicSource != nullptr, error.c_str());
    Require(publicSource->AuthorizationRequest(ordinary.review.execution.archives.front(), &request, &commercial, {}, &error) && !commercial,
        "ordinary package does not become commercial from a worker claim");
}
void SeparateAllArchitectureIndex() {
    Fixture fixture;
    auto &archive = fixture.review.execution.archives.front();
    Write(fixture.runtime.sourceListPath, "deb [arch=amd64] https://example.invalid/ stable main\n");
    archive.sourceIndexURI = "https://example.invalid/dists/stable/main/binary-all/Packages";
    archive.sourceIndexPath = fixture.runtime.listsDirectory + '/' + URItoFileName(archive.sourceIndexURI);
    Write(archive.sourceIndexPath, fixture.indexBytes);
    std::string error;
    Require(fixture.Capture(&error) != nullptr, "implicit binary-all source association rejected");
    Write(fixture.runtime.sourceListPath, "deb [arch=amd64 arch-=all] https://example.invalid/ stable main\n");
    Require(!fixture.Capture(&error), "explicitly disabled binary-all source association accepted");
}
} // namespace

int main() {
    ControlProof(); ValidAndChanged(false); ValidAndChanged(true); SourceAndIndexBinding(); SeparateAllArchitectureIndex(); AuthorizationBeforeDownload();
    std::cout << "[apt-provider-archive-evidence] PASS\n";
}
