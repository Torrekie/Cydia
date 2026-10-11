/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RuntimeSnapshotInputs_HPP
#define Cydia_RuntimeSnapshotInputs_HPP
#include "Cydia/PrivilegedRuntime.hpp"
namespace CydiaRuntime { namespace Privileged {
enum class SnapshotScope { PackageState, RepositoryTrust };
/* This internal seam lets host fixtures supply evidence from isolated files.
 * The privileged entrypoints always use the protected CaptureEvidence reader. */
typedef bool (*SnapshotCapture)(const std::string &, bool, bool, Evidence *, Error *);
bool CaptureSnapshotInputs(const Environment &environment, SnapshotScope scope,
                          std::vector<Evidence> *inputs, Error *error,
                          SnapshotCapture capture = CaptureEvidence);
std::string SerializeSnapshotEvidence(const Evidence &evidence);
} }
#endif
