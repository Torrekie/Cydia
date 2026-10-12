/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_FetchDiagnostics_H
#define Cydia_FetchDiagnostics_H
#include "Cydia/AptCompatibility.hpp"
#import <Foundation/Foundation.h>

/* Localizes typed acquisition/preflight outcomes; raw paths remain verbatim. */
NSString *CydiaFetchDiagnosticMessage(const CydiaAPT::FetchFailureData &diagnostic);
/* Localizes only explicitly Cydia-owned diagnostics; upstream text is preserved. */
NSString *CydiaAPTDiagnosticMessage(const CydiaAPT::ErrorData &diagnostic);
#endif
