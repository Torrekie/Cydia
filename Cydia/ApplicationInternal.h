/* Internal state shared by the Cydia application implementation categories. */

#ifndef Cydia_ApplicationInternal_H
#define Cydia_ApplicationInternal_H

#include "CyteKit/UCPlatform.h"
#include "Menes/ObjectHandle.h"

#include <Foundation/Foundation.h>
#include <sys/types.h>

extern NSString *Error_;
extern NSString *Warning_;
extern BOOL Ignored_;
extern _H<NSDate> Backgrounded_;

void SaveConfig(NSObject *lock);
pid_t launch_get_job_pid(const char *job);
void CydiaSetMenuButtonIntercepted(bool intercepted);
void UpdateExternalStatus(uint64_t status);

#endif//Cydia_ApplicationInternal_H
