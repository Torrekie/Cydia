/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptRecoveryInitialization.hpp"
#include "Cydia/AptRecoverySnapshot.hpp"
#include <apt-pkg/configuration.h>
#include <cstdio>
#include <cstdlib>

namespace CydiaAPT {
bool InitializeRecoveryMethodConfiguration() {
    if (unsetenv("APT_CONFIG") != 0 || !_config) return false;
    _config->Clear();
    _config->Set("Dir::Etc::parts", "/dev/null");
    _config->Set("Dir::Etc::main", "/dev/null");
    SetConfigurationReadValidator([](const std::string &path, bool directory, void *) {
        return !directory && path == "/dev/null";
    }, nullptr);
    return true;
}
bool InitializeRecoverySnapshot(const Recovery::Snapshot &snapshot, std::string *errorCode) {
    if (!Internal::BeginRecoveryInitialization(errorCode)) return false;
    const auto fail = [&](const char *code) {
        if (errorCode) *errorCode = code;
        return false;
    };
    if (!Recovery::ValidateSnapshot(snapshot)) return fail("recovery_snapshot_invalid");
    // Upstream grammar preserves escaping and vector entries. Read exactly one
    // unlinked private file and reject all includes, including self-includes.
    // pkgInitConfig would reread ambient policy and must never be used here.
    std::unique_ptr<FILE, int (*)(FILE *)> file(std::tmpfile(), std::fclose);
    if (!file || std::fwrite(snapshot.configuration.data(), 1,
            snapshot.configuration.size(), file.get()) != snapshot.configuration.size() ||
        std::fflush(file.get()) != 0 || std::fseek(file.get(), 0, SEEK_SET) != 0)
        return fail("recovery_configuration_unavailable");
    struct ReadScope {
        std::string path;
        bool opened = false;
        static bool Read(const std::string &path, bool directory, void *context) {
            ReadScope &self(*static_cast<ReadScope *>(context));
            if (directory || self.opened || path != self.path) return false;
            self.opened = true; return true;
        }
        explicit ReadScope(int fd) : path("/dev/fd/" + std::to_string(fd)) {
            SetConfigurationReadValidator(&Read, this);
        }
        ~ReadScope() { SetConfigurationReadValidator(nullptr, nullptr); }
    };
    _config->Clear();
    {
        ReadScope scope(fileno(file.get()));
        if (!ReadConfigFile(*_config, scope.path)) return fail("recovery_configuration_invalid");
    }
    file.reset();
    return Internal::CompleteRecoveryInitialization(snapshot, errorCode);
}
}
