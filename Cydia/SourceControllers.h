/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 */

#ifndef Cydia_SourceControllers_H
#define Cydia_SourceControllers_H

#include "CyteKit/ViewController.h"

@class Database;

@interface SourcesController : CyteViewController

- (id) initWithDatabase:(Database *)database;
- (void) showAddSourcePrompt;
- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated;

@end

#endif//Cydia_SourceControllers_H
