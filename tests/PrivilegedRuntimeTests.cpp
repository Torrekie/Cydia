/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PrivilegedRuntime.hpp"
#include <cassert>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <unistd.h>

using namespace CydiaRuntime::Privileged;

namespace {
void DpkgOptionPhase() {
    Environment environment;
    environment.dpkgRoot = "/"; environment.dpkgAdmin = "/";
    Error error; std::vector<std::string> bound;
    const std::vector<std::string> canonical{"--root=/", "--admindir=/"};

    // These are native option values, not a new root, hook, or indirect
    // command. A different path is essential: a matching path masked the
    // previous validator's accidental interpretation of opaque values.
    const std::vector<std::string> values{"--path-exclude", "--root=/different", "--path-include=--admindir=/different",
        "--log", "--pre-inv=literal-log-name", "--root=/", "--unpack", "/archive.deb"};
    assert(ValidateDpkgArguments(environment, values, &error));
    assert(BindDpkgArguments(environment, values, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--path-exclude", "--root=/different",
        "--path-include=--admindir=/different", "--log", "--pre-inv=literal-log-name", "--unpack", "/archive.deb"}));
    assert(ValidateDpkgArguments(environment, {"--log", "--status-logger=literal", "--configure", "sample"}, &error));

    for (const auto &tail : std::vector<std::vector<std::string>>{
        {"--unpack", "--", "--root=/different", "--status-logger=literal", "--pre-invoke=literal", "--vendor-option"},
        {"--unpack", "-", "--root=/different", "--adm=/literal"},
        {"--unpack", "/archive.deb", "--root=/different", "--command-fd=literal"},
        {"--unpack", "", "--root=/different"}}) {
        assert(ValidateDpkgArguments(environment, tail, &error));
        assert(BindDpkgArguments(environment, tail, &bound, &error));
        auto expected = canonical; expected.insert(expected.end(), tail.begin(), tail.end());
        assert(bound == expected);
    }

    // Native -D consumes the rest of its cluster, or the next argv token.
    // Therefore the root option after 777 is still in the option phase.
    for (const auto &debug : std::vector<std::vector<std::string>>{
        {"-OD", "777"}, {"-OD777"}, {"-OD=777"}, {"--debug", "777"}, {"--debug=777"}}) {
        auto input = debug; input.insert(input.end(), {"--root=/", "--configure", "sample"});
        assert(ValidateDpkgArguments(environment, input, &error));
        assert(BindDpkgArguments(environment, input, &bound, &error));
        auto expected = canonical; expected.insert(expected.end(), debug.begin(), debug.end());
        expected.insert(expected.end(), {"--configure", "sample"});
        assert(bound == expected);
    }
    assert(BindDpkgArguments(environment, {"-Ra", "--instdir=/", "--configure", "sample"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "-Ra", "--configure", "sample"}));

    // takesvalue=2 supports a continued -value or a separate value, but not
    // the standard =value form. All force operations retain their order.
    assert(BindDpkgArguments(environment, {"--assert", "multi-arch", "--root=/"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--assert", "multi-arch"}));
    assert(BindDpkgArguments(environment, {"--assert-multi-arch", "--root=/"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--assert-multi-arch"}));
    assert(BindDpkgArguments(environment, {"--force", "confold,confdef", "--refuse", "downgrade", "--no-force-confnew",
        "--admindir=/", "--configure", "sample"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--force", "confold,confdef", "--refuse",
        "downgrade", "--no-force-confnew", "--configure", "sample"}));

    auto hooked = environment;
    hooked.trustedDpkgHooks = {"--pre-invoke=printf 'one\ntwo'", "--post-invoke=--root=/different"};
    assert(BindDpkgArguments(hooked, {"--pre-invoke=printf 'one\ntwo'", "--post-invoke", "--root=/different",
        "--instdir=/", "--configure", "sample"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--pre-invoke=printf 'one\ntwo'",
        "--post-invoke", "--root=/different", "--configure", "sample"}));
    assert(!ValidateDpkgArguments(hooked, {"--post-invoke", "--root=/different", "--pre-invoke=printf 'one\ntwo'"}, &error));

    // Refusal never guesses a vendor option's arity, publishes a partial
    // canonical prefix, or mutates aliased input before parsing completes.
    for (const auto &unknown : std::vector<std::vector<std::string>>{
        {"--vendor-output", "--root=/", "--configure", "sample"}, {"--vendor-output=value"},
        {"-Oz", "777", "--root=/"}, {"--force=confold"}, {"--assert=multi-arch"}}) {
        assert(!ValidateDpkgArguments(environment, unknown, &error) && error.code == "unsupported_dpkg_option");
        bound = unknown;
        assert(!BindDpkgArguments(environment, bound, &bound, &error) && bound.empty() && error.code == "unsupported_dpkg_option");
    }
    for (const auto &missing : std::vector<std::vector<std::string>>{
        {"--log"}, {"--assert"}, {"--force"}, {"-OD"}, {"--configure=sample"}}) {
        assert(!ValidateDpkgArguments(environment, missing, &error) && error.code == "invalid_dpkg_argument");
        bound = {"previous output"};
        assert(!BindDpkgArguments(environment, missing, &bound, &error) && bound.empty());
    }
    for (const auto &unsafe : std::vector<std::vector<std::string>>{
        {"--adm=/"}, {"--pre-inv=literal"}, {"--command-fd=0"}, {"--status-logger", "literal"}}) {
        assert(!ValidateDpkgArguments(environment, unsafe, &error) && error.code == "unsafe_dpkg_argument");
        assert(!BindDpkgArguments(environment, unsafe, &bound, &error) && bound.empty());
    }
    assert(!ValidateDpkgArguments(environment, {"--log", std::string("value\0suffix", 12)}, &error));
    assert(!ValidateDpkgArguments(environment, {"--", std::string("file\0suffix", 11)}, &error));
    assert(!ValidateDpkgArguments(environment, std::vector<std::string>(100001, "-a"), &error));
    assert(!BindDpkgArguments(environment, {std::string(8 * 1024 * 1024, 'x')}, &bound, &error) && bound.empty());
    auto oversized = environment; oversized.dpkgRoot.assign(4097, 'x');
    assert(!BindDpkgArguments(oversized, {"--configure", "sample"}, &bound, &error) &&
        bound.empty() && error.code == "invalid_dpkg_argument");
}
}

int main() {
    Error error;
    Request reviewed;
    reviewed.expected = {"/etc/apt/review.conf", "/", "/var/lib/dpkg", "/usr/bin/dpkg",
        "/usr/bin/dpkg-query", "/usr/bin/dpkg-deb", "/etc/apt/sources.list", "/etc/apt/sources.list.d"};
    reviewed.payload = std::string("exact\0bytes\nwith,:", 17);
    const std::string wire = SerializeRequest(reviewed);
    Request decoded;
    assert(ParseRequest(wire, &decoded, &error));
    assert(decoded.expected.dpkgAdmin == reviewed.expected.dpkgAdmin);
    assert(decoded.expected.sourceParts == reviewed.expected.sourceParts);
    assert(decoded.payload == reviewed.payload);
    assert(!ParseRequest(wire + "0:,", &decoded, &error));
    assert(!ParseRequest("CYDIA-PRIVILEGED-2\n" + wire.substr(19), &decoded, &error));
    assert(!ParseRequest(wire.substr(0, wire.size() - 1), &decoded, &error));
    reviewed.expected.dpkg = std::string("/usr/bin/dpkg\0hidden", 20);
    assert(!ParseRequest(SerializeRequest(reviewed), &decoded, &error));

    std::vector<std::string> fields;
    assert(ParseFields(SerializeFields({"dpkg", "/usr/bin/dpkg"}), 2, &fields, &error));
    assert(fields[0] == "dpkg" && fields[1] == "/usr/bin/dpkg");
    assert(!ParseFields("01:a,", 1, &fields, &error));
    assert(!ParseFields("999999999999999999999999999:a,", 1, &fields, &error));
    assert(!ParseFields("1:a;", 1, &fields, &error));
    assert(!ParseFields("0:,0:,", 1, &fields, &error));
    assert(!ParseFields(std::string(8 * 1024 * 1024 + 1, 'x'), 1, &fields, &error));

    int descriptors[2]; assert(pipe(descriptors) == 0);
    reviewed.expected.dpkg = "/usr/bin/dpkg";
    const std::string pipeWire = SerializeRequest(reviewed);
    assert(write(descriptors[1], pipeWire.data(), pipeWire.size()) == static_cast<ssize_t>(pipeWire.size()));
    close(descriptors[1]);
    assert(ReadRequest(descriptors[0], &decoded, &error)); close(descriptors[0]);
    assert(decoded.payload == reviewed.payload);

    Environment environment;
    environment.dpkgRoot = "/"; environment.dpkgAdmin = "/";
    assert(ValidateDpkgArguments(environment, {"--root=/", "--admindir", "/", "--status-fd", "8", "--configure", "-a"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--root=/tmp"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--admindir"}, &error));
    std::vector<std::string> bound;
    const std::vector<std::string> canonical{"--root=/", "--admindir=/", "--force-confold", "--configure", "sample"};
    assert(BindDpkgArguments(environment, {"--admindir=/", "--force-confold", "--root", "/", "--instdir=/", "--configure", "sample"}, &bound, &error));
    assert(bound == canonical); // No late root reset survives, other order preserved.
    bound = {"--admindir", "/", "--force-confold", "--root=/", "--configure", "sample"};
    assert(BindDpkgArguments(environment, bound, &bound, &error) && bound == canonical);
    assert(!BindDpkgArguments(environment, {"--root=/tmp"}, &bound, &error) && bound.empty());
    assert(!BindDpkgArguments(environment, {"--admindir"}, &bound, &error) && bound.empty());
    auto hooked = environment; hooked.trustedDpkgHooks = {"--pre-invoke=--root=/"};
    assert(BindDpkgArguments(hooked, {"--pre-invoke", "--root=/", "--configure", "sample"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--pre-invoke", "--root=/", "--configure", "sample"}));

    assert(BindDpkgArguments(environment, {"--log", "--root=/", "--unpack", "--", "--root=/"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--log", "--root=/", "--unpack", "--", "--root=/"}));
    assert(BindDpkgArguments(environment, {"--unpack", "/archive.deb", "--root=/"}, &bound, &error));
    assert((bound == std::vector<std::string>{"--root=/", "--admindir=/", "--unpack", "/archive.deb", "--root=/"}));
    auto missingRoot = environment; missingRoot.dpkgRoot.clear();
    assert(!BindDpkgArguments(missingRoot, {"--configure", "sample"}, &bound, &error) && bound.empty());
    assert(!ValidateDpkgArguments(environment, {"--pre-invoke=/bin/sh"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--post-invoke", "command"}, &error));
    environment.trustedDpkgHooks = {"--pre-invoke=protected command", "--post-invoke=protected cleanup"};
    assert(ValidateDpkgArguments(environment, {"--pre-invoke", "protected command", "--post-invoke=protected cleanup", "--configure", "-a"}, &error));
    assert(ValidateDpkgArguments(environment, {"--configure", "-a"}, &error)); // Standalone dpkg is distinct from an APT options list.
    assert(!ValidateDpkgArguments(environment, {"--pre-invoke=protected command", "--post-invoke=other command"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--pre-invoke=protected command", "--pre-invoke=protected command", "--post-invoke=protected cleanup"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--post-invoke=protected cleanup", "--pre-invoke=protected command"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--pre-invoke=protected command"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--pre-inv=protected command"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--command-fd=0"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--status-logger=command"}, &error));
    assert(!ValidateDpkgArguments(environment, {"--adm=/tmp"}, &error));
    assert(!ValidateDpkgArguments(environment, {std::string("arg\0suffix", 10)}, &error));
    DpkgOptionPhase();

    assert(ValidateRootOwnedPath("/", true, false, &error));
    assert(ValidateRootOwnedPath("/bin/sh", false, true, &error));
    assert(!ValidateRootOwnedPath("/dev/null", false, false, &error));
    assert(!ValidateRootOwnedPath("/tmp", true, false, &error));
    assert(!ValidateRootOwnedPath("relative", false, false, &error));
    assert(OpenFrontendLock("/", "arbitrary", &error) == -1);

    Evidence original;
    assert(CaptureEvidence("/etc/hosts", false, false, &original, &error));
    assert(RecheckEvidence({original}, &error));
    Evidence stale(original); stale.bytes += "changed";
    assert(!RecheckEvidence({stale}, &error) && error.code == "stale_environment");
    stale = original; ++stale.identity.st_ino;
    assert(!RecheckEvidence({stale}, &error) && error.code == "stale_environment");
    std::cout << "Privileged request, protected path and configuration preimage checks passed\n";
}
