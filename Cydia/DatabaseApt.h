/* Cydia - iPhone UIKit Front-End for Debian APT
 * Private APT view used by the database model and package controllers.
 *
 * Keep this mutable-handle compatibility surface out of Database.h.  The
 * eventual DTO backend can replace these raw handles without making every
 * ordinary database client depend on them.
 */

#ifndef Cydia_DatabaseApt_H
#define Cydia_DatabaseApt_H

#include "Cydia/Database.h"

#include <apt-pkg/acquire.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>

@interface Database (APTCompatibility)
- (pkgCacheFile &) cache;
- (pkgDepCache::Policy *) policy;
- (pkgRecords *) records;
- (pkgProblemResolver *) resolver;
- (pkgAcquire &) fetcher;
- (pkgSourceList &) list;
- (Source *) getSource:(pkgCache::PkgFileIterator)file;
@end

#endif //Cydia_DatabaseApt_H
