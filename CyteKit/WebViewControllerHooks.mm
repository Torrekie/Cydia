#include <UIKit/UIKit.h>

#include "Substrate.hpp"

MSClassHook(WAKWindow)

static CGSize $WAKWindow$screenSize(WAKWindow *self, SEL _cmd) {
    CGSize size([[UIScreen mainScreen] bounds].size);
    /*if ([$WAKWindow respondsToSelector:@selector(hasLandscapeOrientation)])
        if ([$WAKWindow hasLandscapeOrientation])
            std::swap(size.width, size.height);*/
    return size;
}

static struct WAKWindow$screenSize { WAKWindow$screenSize() {
    if ($WAKWindow != NULL)
        if (Method method = class_getInstanceMethod($WAKWindow, @selector(screenSize)))
            method_setImplementation(method, (IMP) &$WAKWindow$screenSize);
} } WAKWindow$screenSize;;

MSClassHook(NSUserDefaults)

MSHook(id, NSUserDefaults$objectForKey$, NSUserDefaults *self, SEL _cmd, NSString *key) {
    if ([key respondsToSelector:@selector(isEqualToString:)] && [key isEqualToString:@"WebKitLocalStorageDatabasePathPreferenceKey"])
        return [NSString stringWithFormat:@"%@/%@/%@", NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject, NSBundle.mainBundle.bundleIdentifier, @"LocalStorage"];
    return _NSUserDefaults$objectForKey$(self, _cmd, key);
}

CYHook(NSUserDefaults, objectForKey$, objectForKey:)
