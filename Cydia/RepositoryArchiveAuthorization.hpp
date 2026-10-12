/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RepositoryArchiveAuthorization_HPP
#define Cydia_RepositoryArchiveAuthorization_HPP
#include <functional>
#include <string>
namespace CydiaRuntime {
enum class RepositoryArchiveAuthorizationStatus {
    NotRequired, Authorized, AuthenticationRequired, Unavailable,
    Unsupported, Failed, Cancelled
};
struct RepositoryArchiveAuthorizationRequest {
    std::string sourceURL, package, version, architecture;
};
struct RepositoryArchiveAuthorizationResult {
    RepositoryArchiveAuthorizationStatus status = RepositoryArchiveAuthorizationStatus::Failed;
    /* Sensitive: valid only for the exact request. Never display or log. */
    std::string transportURL;
    std::string message;
};
using RepositoryArchiveAuthorizationHandler = std::function<RepositoryArchiveAuthorizationResult(
    const RepositoryArchiveAuthorizationRequest &, const std::function<bool()> &)>;
void SetRepositoryArchiveAuthorizationHandler(RepositoryArchiveAuthorizationHandler handler);
void ConfigureRepositoryArchiveAuthorization();

/* Call only off the main thread. The account UI owns consent and sign-in.
 * This function never starts authentication or purchases. A successful grant
 * still requires the caller's exact archive/hash/layout validation. */
RepositoryArchiveAuthorizationResult AuthorizeRepositoryArchive(
    const RepositoryArchiveAuthorizationRequest &request,
    const std::function<bool()> &cancelled = {});
}
#endif
