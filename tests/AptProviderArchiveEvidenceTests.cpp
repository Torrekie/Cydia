/* Parent archive proof tests use only disposable source/index/archive files.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptProviderArchiveEvidence.hpp"
#include <apt-pkg/hashes.h>
#include <apt-pkg/strutl.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/stat.h>
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
void AddIndexRecord(Fixture &fixture, bool separateIndex = false) {
    auto second = fixture.review.execution.archives.front();
    second.identifier = "another"; second.package.package = "another";
    second.filename = "pool/another.deb"; second.path = fixture.directory + "/not-downloaded.deb";
    std::string record = "Package: another\nVersion: 1\nArchitecture: all\nFilename: " + second.filename +
        "\nSize: " + std::to_string(second.size) + "\nSHA256: " + second.hashes["SHA256"] + "\nDepends: sample\n\n";
    if (separateIndex) {
        Write(fixture.runtime.sourceListPath, "deb https://example.invalid/ ./\ndeb https://second.invalid/ ./\n");
        second.sourceDefinitionOrdinal = 1; second.sourceURI = "https://second.invalid/";
        second.sourceIndexURI = "https://second.invalid/./Packages";
        second.sourceIndexPath = fixture.runtime.listsDirectory + '/' + URItoFileName(second.sourceIndexURI);
        second.recordOffset = 0; second.sourceIndexIdentity = "SHA256:" + SHA256(record);
        Write(second.sourceIndexPath, record);
    } else {
        second.recordOffset = fixture.record.size(); fixture.indexBytes = fixture.record + record;
        second.sourceIndexIdentity = "SHA256:" + SHA256(fixture.indexBytes);
        fixture.review.execution.archives.front().sourceIndexIdentity = second.sourceIndexIdentity;
        Write(second.sourceIndexPath, fixture.indexBytes);
    }
    second.recordSize = record.size(); fixture.review.execution.archives.push_back(std::move(second));
}
void BatchControlBeforeDownload(bool separateIndex) {
    Fixture fixture; AddIndexRecord(fixture, separateIndex);
    Require(unlink(fixture.review.execution.archives.front().path.c_str()) == 0, "remove archive before capturing index controls");
    std::string error; auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
    std::vector<P::VerifiedIndexControlEvidence> evidence;
    Require(snapshot->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error) && evidence.size() == 2 &&
        evidence[0].archive.identifier == "sample" && evidence[1].archive.identifier == "another" &&
        evidence[0].controls.at("multi-arch") == "no" && evidence[1].controls.at("depends") == "sample" &&
        evidence[0].evidenceIdentity.size() == 64 && evidence[1].evidenceIdentity.size() == 64 &&
        evidence[0].evidenceIdentity != evidence[1].evidenceIdentity,
        "complete ordered batch proof needs no downloaded archives");
    const auto original = evidence;
    auto reversed = fixture.review.execution.archives; std::reverse(reversed.begin(), reversed.end());
    Require(snapshot->ControlEvidence(reversed, &evidence, {}, &error) &&
        evidence[0].evidenceIdentity == original[1].evidenceIdentity && evidence[1].evidenceIdentity == original[0].evidenceIdentity,
        "per-record provenance must not depend on request order");
    Require(snapshot->ControlEvidence({reversed.front()}, &evidence, {}, &error) && evidence.size() == 1 &&
        evidence.front().evidenceIdentity == original[1].evidenceIdentity, "subset preserves complete record identity");
    auto fresh = fixture.Capture(&error); Require(fresh != nullptr, error.c_str());
    Require(fresh->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error) &&
        evidence[0].evidenceIdentity == original[0].evidenceIdentity, "unchanged recapture has deterministic identity");
    for (int kind = 0; kind < 4; ++kind) {
        auto invalid = fixture.review.execution.archives;
        if (kind == 0) invalid.push_back(invalid.front());
        if (kind == 1) invalid.back().identifier = "unreviewed";
        if (kind == 2) invalid.back().path += ".other";
        if (kind == 3) ++invalid.back().recordOffset;
        evidence = original;
        Require(!snapshot->ControlEvidence(invalid, &evidence, {}, &error) && evidence.empty() &&
            error == "provider_archive_not_reviewed", "invalid batch publishes no partial proof");
    }
    evidence = original;
    Require(!snapshot->ControlEvidence(fixture.review.execution.archives, &evidence, [] { return true; }, &error) &&
        evidence.empty() && error == "provider_cancelled", "cancelled batch clears previous evidence");
    unsigned callbacks = 0;
    Require(!snapshot->ControlEvidence(fixture.review.execution.archives, &evidence, [&] { return ++callbacks == 5; }, &error) &&
        evidence.empty() && error == "provider_cancelled", "cancellation after admission remains atomic");
    Require(snapshot->ControlEvidence({}, &evidence, {}, &error) && evidence.empty(), "empty exact set is a valid empty proof");
    Require(!snapshot->ControlEvidence({}, nullptr, {}, &error), "null output rejected");
}
void BatchControlProvenance() {
    for (int changed = 0; changed < 3; ++changed) {
        Fixture fixture; AddIndexRecord(fixture, true); std::string error;
        auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
        std::vector<P::VerifiedIndexControlEvidence> evidence;
        Require(snapshot->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error), error.c_str());
        if (changed == 0) Write(fixture.runtime.sourceListPath, "# changed\ndeb https://example.invalid/ ./\ndeb https://second.invalid/ ./\n");
        if (changed == 1) Write(fixture.review.execution.archives.back().sourceIndexPath, "changed");
        if (changed == 2) {
            struct stat metadata;
            const auto &path = fixture.review.execution.archives.front().sourceIndexPath;
            Require(stat(path.c_str(), &metadata) == 0 && chmod(path.c_str(), (metadata.st_mode & 07777) ^ 0100) == 0,
                "change index metadata");
        }
        Require(!snapshot->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error) && evidence.empty(),
            "source/index content or file metadata mutation invalidates entire batch");
    }
    Fixture fixture; std::string error; auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
    std::vector<P::VerifiedIndexControlEvidence> evidence;
    Require(snapshot->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error), error.c_str());
    const auto original = evidence.front().evidenceIdentity;
    // Changing a manifest field that does not affect index association still
    // changes the identity; the old snapshot may not accept the new claim.
    fixture.review.execution.archives.front().path += ".reviewed-destination";
    auto different = fixture.Capture(&error); Require(different != nullptr, error.c_str());
    Require(different->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error) &&
        evidence.front().evidenceIdentity != original, "full manifest, including destination, is identity-bound");
    const auto changedManifest = evidence.front().evidenceIdentity;
    Write(fixture.runtime.sourceListPath, "# same configured repository\ndeb https://example.invalid/ ./\n");
    different = fixture.Capture(&error); Require(different != nullptr, error.c_str());
    Require(different->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error) &&
        evidence.front().evidenceIdentity != changedManifest, "retained source bytes/metadata are identity-bound");
    const auto changedSources = evidence.front().evidenceIdentity;
    SetControls(fixture, "Depends: sample-helper\n", "Depends: sample-helper\n");
    different = fixture.Capture(&error); Require(different != nullptr, error.c_str());
    Require(different->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error) &&
        evidence.front().controls.at("depends") == "sample-helper" && evidence.front().evidenceIdentity != changedSources,
        "canonical controls and retained index contents are identity-bound");
    const auto changedControls = evidence.front().evidenceIdentity;
    const auto &indexPath = fixture.review.execution.archives.front().sourceIndexPath;
    Require(unlink(indexPath.c_str()) == 0, "replace index inode retaining identical contents");
    Write(indexPath, fixture.record);
    auto replaced = fixture.Capture(&error); Require(replaced != nullptr, error.c_str());
    Require(replaced->ControlEvidence(fixture.review.execution.archives, &evidence, {}, &error) &&
        evidence.front().evidenceIdentity != changedControls, "retained index inode identity is bound even with identical contents");
    bool modified = false;
    Require(!replaced->ControlEvidence(fixture.review.execution.archives, &evidence, [&] {
        if (!modified) { modified = true; Write(fixture.runtime.sourceListPath, "# changed during capture\n"); }
        return false;
    }, &error) && evidence.empty(), "source changes during a batch cannot publish proof");
    Fixture late; AddIndexRecord(late, true);
    auto retained = late.Capture(&error); Require(retained != nullptr, error.c_str());
    // Use the existing cancellation boundary as an interleaving seam. First
    // locate the final boundary without assuming a particular chunk count,
    // then mutate an already-hashed index immediately before publication.
    std::size_t boundaries = 0, current = 0;
    Require(retained->ControlEvidence(late.review.execution.archives, &evidence, [&] { ++boundaries; return false; }, &error) &&
        boundaries > 0, "observe complete batch cancellation boundaries");
    Require(!retained->ControlEvidence(late.review.execution.archives, &evidence, [&] {
        if (++current == boundaries) Write(late.review.execution.archives.front().sourceIndexPath, late.record + "\n");
        return false;
    }, &error) && current == boundaries && evidence.empty(), "late mutation of an earlier index prevents partial publication");
}
void BatchControlBounds() {
    Fixture fixture; std::string error; auto snapshot = fixture.Capture(&error); Require(snapshot != nullptr, error.c_str());
    std::vector<P::VerifiedIndexControlEvidence> evidence(1);
    std::vector<P::ArchiveManifest> excessive(P::MaximumIndexControlRecords + 1, fixture.review.execution.archives.front());
    Require(!snapshot->ControlEvidence(excessive, &evidence, {}, &error) && evidence.empty() && error == "provider_index_control_limit",
        "record count limit applies before duplicate processing");
    Fixture large;
    auto archive = large.review.execution.archives.front();
    archive.path = "/" + std::string(P::MaximumIndexControlBytes / 2 - 1, 'x');
    large.review.execution.archives = {archive}; archive.identifier = "another-destination";
    large.review.execution.archives.push_back(std::move(archive));
    auto captured = large.Capture(&error); Require(captured != nullptr, error.c_str());
    Require(!captured->ControlEvidence(large.review.execution.archives, &evidence, {}, &error) && evidence.empty() &&
        error == "provider_index_control_limit", "aggregate encoded byte limit has no partial output");
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
    BatchControlBeforeDownload(false); BatchControlBeforeDownload(true); BatchControlProvenance(); BatchControlBounds();
    std::cout << "[apt-provider-archive-evidence] PASS\n";
}
