/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_ExtendedState_HPP
#define Cydia_ExtendedState_HPP
#include <string>
#include <vector>
namespace CydiaRuntime {
struct AutoStateDelta {
    std::string package, architecture;
    bool automatic;
};
/* Lossless merge of only committed package auto flags. Old unqualified
 * records apply to all configured architectures, as in APT's reader. When
 * one architecture changes, expand that record explicitly so its siblings
 * retain their previous flags and unknown fields. */
bool MergeExtendedState(const std::string &original, const std::string &installedStatus,
    const std::string &nativeArchitecture, const std::vector<std::string> &architectures,
    const std::vector<AutoStateDelta> &deltas, std::string *updated);
bool ValidPackageName(const std::string &name);
bool ValidArchitectureName(const std::string &name);
}
#endif
