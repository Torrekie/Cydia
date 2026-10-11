/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/PrivilegedRuntime.hpp"
#include <cassert>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <unistd.h>

using namespace CydiaRuntime::Privileged;

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
