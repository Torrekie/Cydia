/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_MessageLocale_H
#define Cydia_MessageLocale_H
#import <Foundation/Foundation.h>

/* Catalog names and POSIX locale candidates come from the Apple language
 * converter. Candidates omit the codeset (for example fr_FR or sr_RS@latin).
 * The optional availability block allows capability checks without changing
 * the process locale; nil uses the platform's newlocale implementation. */
NSDictionary<NSString *, NSString *> *CydiaMessageLocaleEnvironment(
    NSArray<NSString *> *catalogLanguages, NSArray<NSString *> *localeCandidates,
    BOOL (^available)(NSString *locale));

/* Call once during application startup, before APT or worker threads. Child
 * tools inherit the environment and use their own gettext catalogs. */
BOOL CydiaConfigureMessageLocale(NSArray<NSString *> *catalogLanguages,
    NSArray<NSString *> *localeCandidates);
#endif
