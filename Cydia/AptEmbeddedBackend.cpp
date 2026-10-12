/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptNativeBackend.hpp"
#include "Cydia/AptBackendInternal.hpp"
#include "Cydia/AptAcquireStatusBridge.hpp"

namespace CydiaAPT {
AptBackend::AptBackend(AcquireStatus &status) : implementation_(Internal::CreateNativeBackend(
    *static_cast<pkgAcquireStatus *>(Internal::NativeAcquireStatus(status)),
    [](AcquireStatus &current) -> pkgAcquireStatus & {
        return *static_cast<pkgAcquireStatus *>(Internal::NativeAcquireStatus(current));
    })) {}

void AptBackend::KeepFileDescriptor(int descriptor) { Internal::AptBackend::KeepFileDescriptor(descriptor); }
} // namespace CydiaAPT
