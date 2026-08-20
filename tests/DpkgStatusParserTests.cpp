/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "Cydia/DpkgStatusParser.hpp"

#include <cstdlib>
#include <iostream>

namespace {

void Expect(bool condition, const char *message) {
    if (condition)
        return;
    std::cerr << "[verify-dpkg-status][FAIL] " << message << std::endl;
    std::exit(1);
}

void ExpectRecord(const std::string &line, const char *type, const char *package,
                  double percent, const char *message) {
    CydiaRuntime::Dpkg::PackageManagerProgressRecord record;
    Expect(CydiaRuntime::Dpkg::ParsePackageManagerProgress(line, &record),
           "parse valid progress record");
    Expect(record.type == type, "preserve record type");
    Expect(record.package == package, "preserve package identity");
    Expect(record.percent == percent, "parse percent field");
    Expect(record.message == message, "preserve message including colons");
}

} // namespace

int main() {
    ExpectRecord("pmstatus:apt:25:Preparing apt", "pmstatus", "apt", 25,
                 "Preparing apt");
    ExpectRecord("pmstatus:bash-builtins:iphoneos-arm64:50:Installing",
                 "pmstatus", "bash-builtins:iphoneos-arm64", 50, "Installing");
    ExpectRecord("pmerror:runtime:any:12.5:failed: detail", "pmerror",
                 "runtime:any", 12.5, "failed: detail");
    ExpectRecord("pmconffile:dpkg-exec:100:/etc/example", "pmconffile",
                 "dpkg-exec", 100, "/etc/example");

    CydiaRuntime::Dpkg::PackageManagerProgressRecord record;
    Expect(!CydiaRuntime::Dpkg::ParsePackageManagerProgress("pmstatus:pkg:oops", &record),
           "reject missing numeric percent");
    Expect(!CydiaRuntime::Dpkg::ParsePackageManagerProgress("pmstatus::50:empty", &record),
           "reject empty package identity");
    Expect(!CydiaRuntime::Dpkg::ParsePackageManagerProgress("pmstatus:pkg:101:range", &record),
           "reject out-of-range percent");
    Expect(!CydiaRuntime::Dpkg::ParsePackageManagerProgress("pmstatus:pkg:50:ok", NULL),
           "reject null output");

    std::cout << "[verify-dpkg-status][ ok ] architecture-qualified progress records" << std::endl;
    return 0;
}
