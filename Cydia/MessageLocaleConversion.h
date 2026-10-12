/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_MessageLocaleConversion_H
#define Cydia_MessageLocaleConversion_H
#import <Foundation/Foundation.h>

// Convert the selected bundle localization, without changing the process locale.
// Unsupported identifiers return an empty array; the caller owns global fallback.
NSArray<NSString *> *CydiaGettextLanguages(NSString *appleIdentifier);
// POSIX names omit the codeset so the environment layer can add UTF-8 before @.
NSArray<NSString *> *CydiaPOSIXMessageLocales(NSString *appleIdentifier);

#endif
