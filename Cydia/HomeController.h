/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_HomeController_H
#define Cydia_HomeController_H

#include "Cydia/CydiaWebViewController.h"

#include <SystemConfiguration/SystemConfiguration.h>

@interface HomeController : CydiaWebViewController {
    CFRunLoopRef runloop_;
    SCNetworkReachabilityRef reachability_;
}

@end

#endif//Cydia_HomeController_H
