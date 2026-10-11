/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_RuntimeAccessController_H
#define Cydia_RuntimeAccessController_H

#ifdef __cplusplus
#include <sys/types.h>
namespace CydiaRuntime { namespace RuntimeAccess {
struct LockCheck {
    bool passed;
    bool busy;
    int errorNumber;
    pid_t observedOwner;
};
/* The child uses only async-signal-safe descriptor operations. It never
 * launches a helper or inherits the parent's fcntl lock ownership. With
 * releaseInParent the parent closes its descriptor before the child checks. */
LockCheck CheckLockDescriptor(int &descriptor, pid_t owner, bool releaseInParent,
    unsigned timeoutMilliseconds = 2000);
bool ValidSnapshotToken(const char *bytes, unsigned long size);
} }
#endif

#ifdef __OBJC__
#import "CyteKit/ViewController.h"
@class Database;
@interface CydiaRuntimeAccessController : CyteViewController
- (instancetype)initWithDatabase:(Database *)database;
@end
#endif
#endif
