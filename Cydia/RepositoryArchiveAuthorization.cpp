/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RepositoryArchiveAuthorization.hpp"
#include <mutex>
#include <utility>
namespace CydiaRuntime {
namespace {
std::mutex HandlerMutex;
RepositoryArchiveAuthorizationHandler Handler;
thread_local const RepositoryArchiveAuthorizationHandler *ScopedHandler = nullptr;
}
void SetRepositoryArchiveAuthorizationHandler(RepositoryArchiveAuthorizationHandler handler) {
    std::lock_guard<std::mutex> lock(HandlerMutex); Handler = std::move(handler);
}
ScopedRepositoryArchiveAuthorizationHandler::ScopedRepositoryArchiveAuthorizationHandler(RepositoryArchiveAuthorizationHandler handler) :
    handler_(std::move(handler)), previous_(ScopedHandler) { ScopedHandler = &handler_; }
ScopedRepositoryArchiveAuthorizationHandler::~ScopedRepositoryArchiveAuthorizationHandler() { ScopedHandler = previous_; }
RepositoryArchiveAuthorizationResult AuthorizeRepositoryArchive(
    const RepositoryArchiveAuthorizationRequest &request, const std::function<bool()> &cancelled) {
    RepositoryArchiveAuthorizationHandler handler;
    if (ScopedHandler) handler = *ScopedHandler;
    else { std::lock_guard<std::mutex> lock(HandlerMutex); handler = Handler; }
    if (handler) return handler(request, cancelled);
    RepositoryArchiveAuthorizationResult result;
    result.status = RepositoryArchiveAuthorizationStatus::Unsupported;
    return result;
}
}
