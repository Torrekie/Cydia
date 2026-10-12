/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Tests_AptStubs_AptConfiguration_H
#define Tests_AptStubs_AptConfiguration_H

#include <string>
#include <vector>

namespace APT {
namespace Configuration {

std::vector<std::string> getArchitectures(bool cached = true);
struct Compressor {};
std::vector<Compressor> const getCompressors(bool cached = true);
std::vector<std::string> const getCompressionTypes(bool const &cached = true);

} // namespace Configuration
} // namespace APT

#endif // Tests_AptStubs_AptConfiguration_H
