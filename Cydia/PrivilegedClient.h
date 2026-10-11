/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PrivilegedClient_H
#define Cydia_PrivilegedClient_H

#include "Cydia/PrivilegedRuntime.hpp"
#include <cstddef>
#include <string>

namespace CydiaRuntime {
namespace PrivilegedClient {

struct Result {
    int launchError;
    int exitCode;
    int termSignal;
    bool outputLimitExceeded;
    std::string output;
    std::string error;
    bool succeeded() const;
};

/* The helper independently resolves protected configuration. This descriptor
 * is the frontend's expectation, never privileged path authority. */
Privileged::ExpectedEnvironment CurrentExpectedEnvironment();
Privileged::Request RuntimeRequest(const std::string &payload);
Result Run(const std::string &helperPath, const std::string &command,
           const Privileged::Request &request,
           std::size_t captureLimit = 8 * 1024 * 1024,
           unsigned timeoutMilliseconds = 0);
Result RunNativeCommand(const std::string &command, const std::string &payload,
                       std::size_t captureLimit = 8 * 1024 * 1024,
                       unsigned timeoutMilliseconds = 0);

/* Returns a safely opened descriptor, without taking a lock. The frontend
 * must acquire its own fcntl lock; APT's GetLock callback does this normally. */
int OpenLock(const std::string &helperPath, const Privileged::Request &request,
             const std::string &purpose, Privileged::Error *error,
             unsigned timeoutMilliseconds = 0);
/* Register only outside an active operation under Database serialization.
 * Unrelated APT archive/list locks retain their ordinary open behavior. */
void ConfigureLockBridge(const std::string &helperPath,
                         const Privileged::ExpectedEnvironment &expected);
/* Scoped diagnostics may temporarily bound the existing bridge without
 * replacing its expected environment. Returns the previous timeout. */
unsigned SetLockBridgeTimeoutMilliseconds(unsigned timeoutMilliseconds);
void ClearLockBridge();

} // namespace PrivilegedClient
} // namespace CydiaRuntime
#endif
