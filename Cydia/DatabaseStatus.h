/* Cydia - iPhone UIKit Front-End for Debian APT
 * Cydia-owned acquire status façade.
 */

#ifndef Cydia_DatabaseStatus_H
#define Cydia_DatabaseStatus_H

#include "Cydia/AptAcquireStatusBridge.hpp"

#include <Foundation/Foundation.h>

#include <memory>

@class Database;
@protocol FetchDelegate;
@protocol ProgressDelegate;

namespace CydiaAPT {

class AptBackend;

namespace Internal {
class AcquireStatus;
}

class AcquireStatus {
  private:
    std::unique_ptr<Internal::AcquireStatus> implementation_;

    friend class AptBackend;
    friend void *Internal::NativeAcquireStatus(AcquireStatus &status);

  protected:
    Internal::AcquireStatus &implementation();
    explicit AcquireStatus(std::unique_ptr<Internal::AcquireStatus> implementation);

  public:
    virtual ~AcquireStatus();
    bool wasCancelled() const;
};

class ProgressStatus : public AcquireStatus {
  public:
    ProgressStatus();
    void setDelegate(NSObject<ProgressDelegate> *delegate);
};

class SourceStatus : public AcquireStatus {
  public:
    SourceStatus(NSObject<FetchDelegate> *delegate, Database *database);
};

} // namespace CydiaAPT

#endif // Cydia_DatabaseStatus_H
