/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_PrivateServices_H
#define Cydia_PrivateServices_H

#include <Foundation/Foundation.h>
#include <mach/mach.h>

/*
 * SpringBoardServices is private and is not shipped by current public SDKs.
 * Keep the ABI boundary in one place and resolve these entry points at
 * runtime, so the app remains linkable with either an older jailbreak SDK or
 * a current Apple SDK.
 */
mach_port_t CydiaSpringBoardServerPort(void);
int CydiaBundlePathForDisplayIdentifier(mach_port_t port, const char *identifier, char *path);
NSArray *CydiaCopyApplicationDisplayIdentifiers(bool active, bool debuggable);
NSString *CydiaCopyLocalizedApplicationName(NSString *identifier);
NSString *CydiaCopyIconImagePath(NSString *identifier);
bool CydiaReboot(uint64_t flags);

#endif//Cydia_PrivateServices_H
