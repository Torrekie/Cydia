/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_DatabaseConfigurationInternal_H
#define Cydia_DatabaseConfigurationInternal_H

#include "Cydia/Database.h"
#include <string>

@interface Database (ConfigurationInternal)
- (void) initializeConfigurationPrompts;
- (void) _processDpkgStatusLine:(const std::string &)line;
@end

#endif
