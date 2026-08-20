/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_LockdownServices_H
#define Cydia_LockdownServices_H

#include <CoreFoundation/CoreFoundation.h>

extern "C" {
void *CydiaLockdownConnect(void);
CFStringRef CydiaLockdownCopyValue(void *lockdown, void *null, CFStringRef key);
void CydiaLockdownDisconnect(void *lockdown);
}

#endif//Cydia_LockdownServices_H
