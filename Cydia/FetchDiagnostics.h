/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_FetchDiagnostics_H
#define Cydia_FetchDiagnostics_H
#include "Cydia/AptCompatibility.hpp"
#import <Foundation/Foundation.h>

/* Localizes typed acquisition/preflight outcomes; raw paths remain verbatim. */
NSString *CydiaFetchDiagnosticMessage(const CydiaAPT::FetchFailureData &diagnostic);

/* Presentation only: recognizes complete messages from the embedded APT and
 * its acquire methods. Unknown diagnostics and technical arguments are kept.
 * A bundle may be supplied to use a specific localization. */
NSString *CydiaAPTDiagnosticMessage(NSString *message, NSBundle *bundle = nil);
#endif
