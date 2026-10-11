/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/ApplicationIdentity.hpp"
#include "Cydia/ApplicationSession.hpp"
#include <cstdlib>
#include <iostream>

using namespace CydiaRuntime::Privileged;
static void Require(bool value, const char *message) {
    if (value) return;
    std::cerr << "[application-identity] FAIL: " << message << '\n'; std::exit(1);
}
int main() {
    const std::string first("0123456789abcdef0123456789abcdef01234567\n");
    const std::string second("ffffffffffffffffffffffffffffffffffffffff\n");
    std::set<ApplicationCodeHash> hashes;
    Require(ParseApplicationCodeHashes(first + second + first, &hashes) && hashes.size() == 2,
        "accept distinct signed architecture/hash variants and deduplicate");
    Require(hashes.begin()->at(0) == 0x01 && hashes.begin()->at(1) == 0x23 && hashes.begin()->at(19) == 0x67,
        "decode exact kernel code hash bytes");
    for (const auto &bad : {std::string(), first.substr(0, 40), first + "\n", first + "path=/Applications/Cydia.app\n",
                           std::string(40, 'z') + "\n", std::string(40, 'F') + "\n", std::string(4097, '0')})
        Require(!ParseApplicationCodeHashes(bad, &hashes), "reject malformed, truncated or oversized identity manifests");
    ApplicationSession session;
    session.process = {"123", "100.25", "200.75", first.substr(0, 40)}; session.admin = "/bootstrap/dpkg";
    ApplicationSession parsed;
    Require(ParseApplicationSession(SerializeApplicationSession(session), &parsed) &&
        parsed.process == session.process && parsed.admin == session.admin && parsed.graceDeadline == 0,
        "preserve exact outgoing process and administrator identity");
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
    Require(!ParseApplicationSession(SerializeFields({"123", "100", "200", first.substr(0,40), "/bootstrap/dpkg", "18446744073709551616"}), &parsed),
        "reject overflowing continuation deadlines");
    std::cout << "[application-identity] PASS: package manifest and bounded upgrade continuation\n";
}
