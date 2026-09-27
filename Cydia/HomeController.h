/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_HomeController_H
#define Cydia_HomeController_H

#include "CyteKit/ViewController.h"
#include "Cydia/HomeViewModel.h"

#include <SystemConfiguration/SystemConfiguration.h>

@class Database;

@interface HomeController : CyteViewController {
    CFRunLoopRef runloop_;
    SCNetworkReachabilityRef reachability_;
}

- (instancetype) initWithDatabase:(Database *)database;
- (void) aboutButtonClicked;
- (void) refreshButtonClicked;

#if defined(CYDIA_HOME_SIMULATOR_PROBE)
- (instancetype) initWithViewModel:(CydiaHomeViewModel *)viewModel;
- (void) setProbeReachabilityKnown:(BOOL)known reachable:(BOOL)reachable;
- (CydiaHomeViewModel *) probeViewModel;
#endif

@end

#endif//Cydia_HomeController_H
