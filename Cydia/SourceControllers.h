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
// Finite Home restoration catalog, not arbitrary URL/distribution input.
- (void) showRestoreDefaultSourcePrompt:(NSString *)identifier completion:(void (^)(BOOL added))completion;
- (void) cancelDefaultSourceRestoration;
- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated;
- (NSDictionary *) cydiaNativeCompatibilitySourceSessionDiagnosticWithDelegate:(id)delegate;

@end

#endif//Cydia_SourceControllers_H
