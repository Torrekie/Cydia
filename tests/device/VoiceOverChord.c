/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Test-only helper, never linked into Cydia. Dispatch acknowledgement is NOT
 * VoiceOver focus evidence. Join the candidate's observed focus notifications.
 */

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

typedef CFTypeRef (*CreateClient)(CFAllocatorRef);
typedef CFTypeRef (*CreateKey)(CFAllocatorRef, uint64_t, uint16_t, uint16_t, Boolean, uint32_t);
typedef void (*DispatchKey)(CFTypeRef, CFTypeRef);
typedef CFStringRef (*CopyFrontmost)(void);
typedef int (*ProcessPath)(int, void *, uint32_t);

static volatile sig_atomic_t interrupted;
static void Interrupt(int signal) { (void)signal; interrupted = 1; }

static bool Device(char *model, size_t size) {
    if (sysctlbyname("hw.machine", model, &size, NULL, 0) != 0)
        return false;
    return strcmp(model, "iPad13,4") == 0 || strcmp(model, "iPhone13,1") == 0;
}

static bool Guard(pid_t pid, ProcessPath processPath, CopyFrontmost copyFrontmost) {
    char path[4096] = {0};
    if (processPath(pid, path, sizeof(path)) <= 0 ||
        (strcmp(path, "/Applications/Cydia.app/Cydia") != 0 &&
         strcmp(path, "/var/jb/Applications/Cydia.app/Cydia") != 0))
        return false;
    CFStringRef front = copyFrontmost();
    bool result = front != NULL && CFEqual(front, CFSTR("com.saurik.Cydia"));
    if (front != NULL)
        CFRelease(front);
    return result;
}

static bool Send(CFTypeRef client, CreateKey create, DispatchKey dispatch,
                 uint16_t usage, bool down) {
    CFTypeRef event = create(kCFAllocatorDefault, mach_absolute_time(), 0x07, usage, down, 0);
    if (event == NULL)
        return false;
    dispatch(client, event);
    CFRelease(event);
    printf("hid_usage=%u down=%u\n", usage, down);
    usleep(20000);
    return true;
}

int main(int argc, char **argv) {
    if (argc != 4 || strcmp(argv[1], "--pid") != 0 ||
        (strcmp(argv[3], "next") != 0 && strcmp(argv[3], "previous") != 0)) {
        fprintf(stderr, "usage: VoiceOverChord --pid EXACT_CYDIA_PID next|previous\n");
        return 2;
    }
    char *end = NULL;
    errno = 0;
    long parsed = strtol(argv[2], &end, 10);
    if (errno != 0 || *end != '\0' || parsed <= 1 || parsed > INT32_MAX)
        return 2;
    pid_t pid = (pid_t)parsed;
    char model[128] = {0};
    if (geteuid() != 0 || !Device(model, sizeof(model))) {
        fprintf(stderr, "refused: authorized logical test device/root required\n");
        return 3;
    }
    void *hid = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    if (hid == NULL || sbs == NULL) {
        fprintf(stderr, "refused: device input/foreground frameworks unavailable\n");
        return 3;
    }
    CreateClient createClient = (CreateClient)dlsym(hid, "IOHIDEventSystemClientCreate");
    CreateKey createKey = (CreateKey)dlsym(hid, "IOHIDEventCreateKeyboardEvent");
    DispatchKey dispatch = (DispatchKey)dlsym(hid, "IOHIDEventSystemClientDispatchEvent");
    CopyFrontmost copyFrontmost = (CopyFrontmost)dlsym(sbs, "SBSCopyFrontmostApplicationDisplayIdentifier");
    ProcessPath processPath = (ProcessPath)dlsym(RTLD_DEFAULT, "proc_pidpath");
    if (createClient == NULL || createKey == NULL || dispatch == NULL ||
        copyFrontmost == NULL || processPath == NULL || !Guard(pid, processPath, copyFrontmost)) {
        fprintf(stderr, "refused: exact PID/foreground or required symbols unavailable\n");
        return 3;
    }
    CFTypeRef client = createClient(kCFAllocatorDefault);
    if (client == NULL)
        return 3;
    signal(SIGINT, Interrupt);
    signal(SIGTERM, Interrupt);
    signal(SIGHUP, Interrupt);
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("device=%s pid=%d command=VO-%s\n", model, pid, argv[3]);
    uint16_t arrow = strcmp(argv[3], "next") == 0 ? 0x4f : 0x50;
    /* Left Control + left Option, then exactly one arrow. No activate/confirm
     * key exists. Recheck foreground before every key-down, always release. */
    uint16_t keys[] = {0xe0, 0xe2, arrow};
    size_t pressed = 0;
    bool ok = true;
    for (size_t i = 0; i < 3; ++i) {
        if (interrupted || !Guard(pid, processPath, copyFrontmost) ||
            !Send(client, createKey, dispatch, keys[i], true)) {
            ok = false;
            break;
        }
        ++pressed;
    }
    while (pressed != 0)
        if (!Send(client, createKey, dispatch, keys[--pressed], false))
            ok = false;
    CFRelease(client);
    puts(ok && !interrupted ? "CHORD_DISPATCHED_FOCUS_UNVERIFIED" : "CHORD_INTERRUPTED_OR_FAILED");
    return ok && !interrupted ? 0 : 1;
}
