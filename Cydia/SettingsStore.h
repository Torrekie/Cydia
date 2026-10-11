/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SettingsStore_H
#define Cydia_SettingsStore_H
#import <Foundation/Foundation.h>

/* App preferences are deliberately independent of APT's source documents. */
NSString *CydiaRepositorySecurityPreference(void);
BOOL CydiaSetRepositorySecurityPreference(NSString *value);

#endif
