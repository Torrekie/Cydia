/* Cydia - iPhone UIKit Front-End for Debian APT
 * Pure C++ bridge to the private acquire status adapter.
 */

#ifndef Cydia_AptAcquireStatusBridge_HPP
#define Cydia_AptAcquireStatusBridge_HPP

namespace CydiaAPT {

class AcquireStatus;

namespace Internal {
void *NativeAcquireStatus(AcquireStatus &status);
}

} // namespace CydiaAPT

#endif // Cydia_AptAcquireStatusBridge_HPP
