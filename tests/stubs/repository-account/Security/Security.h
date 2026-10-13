#pragma once
#import <Security/SecBase.h>
#import <Security/SecTrust.h>
#import <CoreFoundation/CoreFoundation.h>
#define kSecClass CFSTR("class")
#define kSecClassGenericPassword CFSTR("generic-password")
#define kSecAttrService CFSTR("service")
#define kSecAttrAccount CFSTR("account")
#define kSecReturnData CFSTR("return-data")
#define kSecMatchLimit CFSTR("match-limit")
#define kSecMatchLimitOne CFSTR("one")
#define kSecValueData CFSTR("data")
#define kSecAttrAccessible CFSTR("accessible")
#define kSecAttrAccessibleWhenUnlockedThisDeviceOnly CFSTR("unlocked-device-only")
#define SecItemCopyMatching CydiaTestSecItemCopyMatching
#define SecItemUpdate CydiaTestSecItemUpdate
#define SecItemAdd CydiaTestSecItemAdd
#define SecItemDelete CydiaTestSecItemDelete
OSStatus CydiaTestSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result);
OSStatus CydiaTestSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes);
OSStatus CydiaTestSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result);
OSStatus CydiaTestSecItemDelete(CFDictionaryRef query);
