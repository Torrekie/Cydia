/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#ifndef CYTEKIT_IOKIT_COMPAT_H
#define CYTEKIT_IOKIT_COMPAT_H

/*
 * The public IOKit library header is present in Apple's SDKs, but is not
 * shipped by theos/sdks.  Keep the normal SDK header when it is available
 * and declare only the small API surface used by CyteObject otherwise.
 */
#if __has_include(<IOKit/IOKitLib.h>)
#include <IOKit/IOKitLib.h>
#else

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_types.h>
#include <stdint.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
typedef uint32_t IOOptionBits;

#ifdef __cplusplus
extern "C" {
#endif

io_registry_entry_t IORegistryEntryFromPath(mach_port_t masterPort,
                                             const char *path);
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry,
                                          CFStringRef key,
                                          CFAllocatorRef allocator,
                                          IOOptionBits options);
kern_return_t IOObjectRelease(io_object_t object);

#ifdef __cplusplus
}
#endif

#endif /* __has_include(<IOKit/IOKitLib.h>) */

#endif /* CYTEKIT_IOKIT_COMPAT_H */
