/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Tests_AptStubs_Init_H
#define Tests_AptStubs_Init_H

class Configuration;
class pkgSystem;

bool pkgInitConfig(Configuration &configuration);
bool pkgInitSystem(Configuration &configuration, pkgSystem *&system);

#endif // Tests_AptStubs_Init_H
