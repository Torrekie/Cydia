/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptNativeBackend_HPP
#define Cydia_AptNativeBackend_HPP
#include "Cydia/AptBackendImplementation.hpp"
#include "Cydia/AptRecoveryPackageManager.hpp"

class pkgAcquireStatus;

namespace CydiaAPT { namespace Internal {

// Only the app supplies this resolver. Resolve each call independently: a
// source refresh can use a different status object from archive acquisition.
using NativeAcquireStatusResolver =
    std::function<pkgAcquireStatus &(CydiaAPT::AcquireStatus &)>;

class NativeBackend : public BackendImplementation {
public:
    // A worker has a native status object and must not fabricate the app's
    // AcquireStatus bridge merely to refresh its private package indexes.
    virtual UpdateResultData updateListsNative(int pulseInterval) = 0;
    virtual RecoveryCaptureResult captureRecoveryReview(const RuntimeDescriptor &runtime,
        const Provider::Binding &binding, const CydiaPackages::ArchiveLayout &layout,
        const std::function<bool()> &cancelled = {}) = 0;
};

// The status and any objects captured by resolver must outlive the backend.
// Without a resolver, all acquisition uses the supplied native status. This
// factory does not initialize APT, select a runtime or change execution/locking
// authority. In particular, worker dispatch must still broker shared mutations.
std::unique_ptr<NativeBackend> CreateNativeBackend(pkgAcquireStatus &status,
    NativeAcquireStatusResolver resolver = NativeAcquireStatusResolver());

}} // namespace CydiaAPT::Internal
#endif
