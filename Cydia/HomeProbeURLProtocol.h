/* Cydia Refurbished native Home simulator URL recorder.
 * Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_HomeProbeURLProtocol_H
#define Cydia_HomeProbeURLProtocol_H

#include <TargetConditionals.h>
#include <Foundation/Foundation.h>

#if TARGET_OS_SIMULATOR && defined(CYDIA_HOME_SIMULATOR_PROBE)

@interface CydiaHomeProbeURLProtocol : NSURLProtocol
@end

void HomeProbeProtocolReset(void);
NSDictionary *HomeProbeProtocolSnapshot(void);

#endif

#endif // Cydia_HomeProbeURLProtocol_H
