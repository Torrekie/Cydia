/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_DatabaseSnapshots_H
#define Cydia_DatabaseSnapshots_H
#import <Foundation/Foundation.h>
#include <string>
// Call only under Database serialization, using the selected helper authority.
NSString *CurrentListsSnapshot();
std::string CurrentTrustContext();
NSString *CurrentTransactionSnapshot();
#endif
