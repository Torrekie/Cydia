/* Cydia - iPhone UIKit Front-End for Debian APT
 * Private libapt-pkg acquire status adapters.
 * Refurbished compatibility work Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Cydia_DatabaseStatusInternal_HPP
#define Cydia_DatabaseStatusInternal_HPP

#include <Foundation/Foundation.h>

#include <apt-pkg/acquire.h>

#include <memory>

@class Database;

namespace CydiaAPT {
namespace Internal {

class AcquireStatus {
  public:
    virtual ~AcquireStatus();
    virtual pkgAcquireStatus &raw() = 0;
    virtual bool wasCancelled() const = 0;
    virtual void setDelegate(NSObject *delegate);
};

std::unique_ptr<AcquireStatus> CreateProgressStatus();
std::unique_ptr<AcquireStatus> CreateSourceStatus(NSObject *delegate, Database *database);

} // namespace Internal
} // namespace CydiaAPT

#endif // Cydia_DatabaseStatusInternal_HPP
