/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2013  Jay Freeman (saurik)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#ifndef Sources_H
#define Sources_H

#include <Foundation/Foundation.h>

/* Writes only the maintainer-declared Cydia source file.  The private cache
 * path is staging state, never an APT source location. */
bool CydiaWriteSources();
void CydiaSetManagedSourceListPath(NSString *path);
NSString *CydiaManagedSourceListPath();
/* Returns true only when the declared leaf remains below the effective APT
 * sourceparts directory and its parent is physically available.  UI mutation
 * controls use this readiness check; CydiaWriteSources still reports an
 * invalid declaration as a failure rather than silently succeeding. */
bool CydiaCanEditManagedSources();
/* Returns true when a maintainer declaration is present.  This is only a
 * configuration-presence predicate; callers that expose mutation controls
 * must use CydiaCanEditManagedSources() so an invalid or unavailable parent
 * cannot leave a dead editing path visible. */
bool CydiaHasManagedSourceListPath();
/* Returns true only when the stable source key is present inside the
 * maintainer-declared Cydia ownership block.  A matching Sources_ preference
 * record alone is not sufficient: old preferences can outlive the package or
 * source file that originally created them. */
bool CydiaManagedSourceKeyIsOwned(NSString *key);
/* Remove an app-owned source record and remember the deletion for the next
 * marker rewrite.  Callers must use this instead of mutating Sources_
 * directly so a relaunch cannot resurrect the removed line. */
void CydiaRemoveSource(NSString *key);
void CydiaAddSource(NSDictionary *source);
void CydiaAddSource(NSString *href, NSString *distribution, NSArray *sections = nil);

extern NSString *Cache_;
NSString *Cache(const char *file);

/* Private staging filename; it is never referenced by APT's source parser. */
#define SOURCES_STAGING Cache("cydia-managed.list")

#endif//Sources_H
