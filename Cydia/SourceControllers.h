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
// Only the explicit native Advanced Settings entry point enables this mode.
- (id) initWithDatabase:(Database *)database advancedAccess:(BOOL)advancedAccess;
- (void) showAddSourcePrompt;
- (void) showAddSourceDefinitionPrompt:(NSString *)definition;
// Compatibility entry points no longer install a built-in repository catalogue.
- (void) showRestoreDefaultSourcePrompt:(NSString *)identifier completion:(void (^)(BOOL added))completion;
- (void) cancelDefaultSourceRestoration;
- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated;
- (NSDictionary *) cydiaNativeCompatibilitySourceSessionDiagnosticWithDelegate:(id)delegate;

@end

#endif//Cydia_SourceControllers_H
