/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptRecoveryInitialization_HPP
#define Cydia_AptRecoveryInitialization_HPP
#include "Cydia/AptRuntime.hpp"
namespace CydiaAPT { namespace Internal {
// Internal commit boundary for the process's embedded globals. Only the
// validated captured-configuration reader may call Complete; caches must be
// closed. These functions do not establish protected authority.
bool BeginRecoveryInitialization(std::string *errorCode);
bool CompleteRecoveryInitialization(const Recovery::Snapshot &, std::string *errorCode);
}}
namespace CydiaAPT {
// Fresh acquisition-method processes receive effective options through APT's
// 601 protocol. They must not merge ambient configuration before that message.
bool InitializeRecoveryMethodConfiguration();
}
#endif
