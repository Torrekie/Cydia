/* Cydia - iPhone UIKit Front-End for Debian APT
 * Compatibility wrapper Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef CYDIA_REBOOT_COMPAT_H
#define CYDIA_REBOOT_COMPAT_H

#if __has_include(<sys/reboot.h>)
#include <sys/reboot.h>
#else
/* The private CydiaReboot bridge only needs the flag value when cross-built
 * on Linux; the device implementation resolves the reboot entry point. */
#define RB_AUTOBOOT 0
#endif

#endif /* CYDIA_REBOOT_COMPAT_H */
