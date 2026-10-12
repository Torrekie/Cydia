/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SettingsStore_H
#define Cydia_SettingsStore_H
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* App preferences are deliberately independent of APT's source documents. */
/* Nil means no valid explicit choice was saved. These readers never persist
 * defaults, so a saved Warning remains distinguishable from absence. */
NSString * _Nullable CydiaExplicitRepositorySecurityPreference(void);
NSString *CydiaEffectiveRepositorySecurityPreference(BOOL selectedExternalProviderReady);
/* Compatibility accessor for startup before external-provider activation. */
NSString *CydiaRepositorySecurityPreference(void);
BOOL CydiaSetRepositorySecurityPreference(NSString *value);

/* Automatic is the unsaved default. Only the runtime coordinator persists a
 * choice after accepting the corresponding transition. */
NSString *CydiaRuntimeProviderPreference(void);
BOOL CydiaSetRuntimeProviderPreference(NSString *value);

NS_ASSUME_NONNULL_END

#endif
