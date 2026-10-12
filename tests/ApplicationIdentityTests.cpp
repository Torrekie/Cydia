/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ApplicationIdentity.hpp"
#include "Cydia/ApplicationSession.hpp"
#include <cstdlib>
#include <iostream>
#include <iterator>

using namespace CydiaRuntime::Privileged;
static void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[application-identity] FAIL: " << message << '\n'; std::exit(1);
}
int main(int argc, char **argv) {
    if (argc == 2 && (std::string(argv[1]) == "--canonicalize" ||
                      std::string(argv[1]) == "--canonicalize-kernel")) {
        const std::string bytes((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>());
        std::vector<std::string> directories;
        const bool kernel = std::string(argv[1]) == "--canonicalize-kernel";
        if (!(kernel ? CanonicalKernelApplicationSigningBlob(bytes, &directories) :
                       CanonicalApplicationSigningBlob(bytes, &directories))) return 65;
        const char digits[] = "0123456789abcdef";
        for (const auto &directory : directories) {
            for (unsigned char byte : directory) std::cout << digits[byte >> 4] << digits[byte & 15];
            std::cout << '\n';
        }
        return 0;
    }
    const std::string first("0123456789abcdef0123456789abcdef01234567\n");
    const std::string second("ffffffffffffffffffffffffffffffffffffffff\n");
    const std::string header("CYDIA-APPLICATION-IDENTITY-1\n");
    std::set<ApplicationCodeHash> hashes;
    Require(ParseApplicationCodeHashes(header + first + second + first, &hashes) && hashes.size() == 2,
        "accept distinct signed architecture/hash variants and deduplicate");
    Require(hashes.begin()->at(0) == 0x01 && hashes.begin()->at(1) == 0x23 && hashes.begin()->at(19) == 0x67,
        "decode exact canonical signing identity bytes");
    auto allowed(hashes);
    Require(ApplicationCodeHashesAllowed(allowed, hashes), "allow matching executable directories");
    ApplicationCodeHash foreign = {}; hashes.insert(foreign);
    Require(!ApplicationCodeHashesAllowed(allowed, hashes), "reject an unpinned executable directory despite a matching decoy");
    Require(!ApplicationCodeHashesAllowed(allowed, {}), "reject empty kernel signing identity");
    for (const auto &bad : {std::string(), first.substr(0, 40), first + "\n", first + "path=/Applications/Cydia.app\n",
                           std::string(40, 'z') + "\n", std::string(40, 'F') + "\n", std::string(4097, '0')})
        Require(!ParseApplicationCodeHashes(header + bad, &hashes), "reject malformed, truncated or oversized identity manifests");
    Require(!ParseApplicationCodeHashes(first, &hashes), "reject legacy raw hashes without a canonical format marker");
    ApplicationSession session;
    session.process = {"123", "100.25", "200.75", first.substr(0, 40)}; session.admin = "/bootstrap/dpkg";
    ApplicationSession parsed;
    Require(ParseApplicationSession(SerializeApplicationSession(session), &parsed) &&
        parsed.process == session.process && parsed.admin == session.admin && parsed.graceDeadline == 0,
        "preserve exact outgoing process and administrator identity");
    auto alternate(session);
    alternate.process.hash += second.substr(0, 40);
    Require(ParseApplicationSession(SerializeApplicationSession(alternate), &parsed) &&
        parsed.process == alternate.process && ApplicationSessionAllows(parsed, alternate.process, 9000000, true),
        "continue the same application with primary and alternate signing directories");
    Require(!ApplicationSessionAllows(parsed, session.process, 9000000, true),
        "one matching directory cannot substitute for the exact running directory set");
    for (const auto &badHash : {first.substr(0, 40) + first.substr(0, 40),
                               second.substr(0, 40) + first.substr(0, 40), std::string(39, '0'),
                               std::string(64, '0'), std::string(40, 'F'), std::string(40, 'z'),
                               std::string(7 * 40, '0')}) {
        auto invalid(alternate); invalid.process.hash = badHash;
        Require(!ParseApplicationSession(SerializeApplicationSession(invalid), &parsed),
            "reject duplicate, reordered, malformed and excessive signing directories");
    }
    for (const auto &badNumber : {std::string(), std::string("1"), std::string("0123"),
                                 std::string("-123"), std::string("2147483648"), std::string("123x")}) {
        auto invalid(session); invalid.process.pid = badNumber;
        Require(!ParseApplicationSession(SerializeApplicationSession(invalid), &parsed),
            "reject an invalid application PID");
    }
    for (const auto &badTime : {std::string("100"), std::string("100.1000000"), std::string("100.-1"),
                               std::string("0100.25"), std::string("100.025"), std::string("0.25"),
                               std::string("100.25.1"), std::string("9223372036854775808.0")}) {
        for (bool boot : {false, true}) {
            auto invalid(session); (boot ? invalid.process.boot : invalid.process.start) = badTime;
            Require(!ParseApplicationSession(SerializeApplicationSession(invalid), &parsed),
                "reject malformed boot and process start generation times");
        }
    }
    Require(ParseApplicationSession(SerializeApplicationSession(session), &parsed), "restore single-directory fixture");
    Require(ApplicationSessionAllows(parsed, session.process, 9000000, true) &&
        !ApplicationSessionAllows(parsed, session.process, 9000000, false),
        "long transaction authorization requires this process's actual frontend lock");
    parsed.graceDeadline = 9001000;
    Require(ApplicationSessionAllows(parsed, session.process, 9000000, false) &&
        !ApplicationSessionAllows(parsed, session.process, 9001000, true),
        "finite finalization grace cannot be extended by reacquiring a lock");
    auto other(session.process);
    for (auto field : {&other.pid, &other.boot, &other.start, &other.hash}) {
        const std::string before(*field); *field += "0";
        Require(!ApplicationSessionAllows(parsed, other, 9000000, true), "deny PID reuse, boot changes and different code/processes");
        *field = before;
    }
    Require(!ParseApplicationSession(SerializeFields({"123", "100.0", "200.0", first.substr(0,40), "/bootstrap/dpkg", "18446744073709551616"}), &parsed),
        "reject overflowing continuation deadlines");
    std::cout << "[application-identity] PASS: package manifest and bounded upgrade continuation\n";
}
