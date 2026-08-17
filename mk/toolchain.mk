flag :=
plus :=
link :=
libs :=
lapt :=

ifeq ($(doIA),yes)
kind := iphonesimulator
arch := x86_64
else
kind := iphoneos
arch := arm64
endif

gxx := $(shell xcrun --sdk $(kind) -f g++)
cycc := $(gxx)

sdk := $(shell xcodebuild -sdk $(kind) -version Path)
mac := $(shell xcodebuild -sdk macosx -version Path)

cycc += -isysroot $(sdk)
cycc += -idirafter $(mac)/usr/include
cycc += -F$(sdk)/System/Library/PrivateFrameworks

ifeq ($(doIA),yes)
cycc += -Xarch_x86_64 -F$(sdk)/../../../../iPhoneOS.platform/Developer/Library/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks
endif

cycc += -include system.h
cycc += -fmessage-length=0
cycc += -gfull -O2
cycc += -fvisibility=hidden

link += -Wl,-dead_strip
link += -Wl,-no_dead_strip_inits_and_terms

iapt :=
iapt += -Iapt64
iapt += -Iapt64-contrib
iapt += -Iapt64-deb
iapt += -Iapt-extra
iapt += -I$(GENERATED_DIR)/apt64

flag += $(patsubst %,-Xarch_$(arch) %,$(iapt))
flag += -I.
flag += -I$(GENERATED_DIR)
flag += -isystem sysroot/usr/include
flag += -idirafter icu/icuSources/common
flag += -idirafter icu/icuSources/i18n

# Apple removed unicode/utrans.h from newer SDKs while retaining the ICU C
# ABI.  Prefer the locally supplied iPhoneOS 14.5 SDK headers when present;
# callers can override ICU_INCLUDE_DIR for another Apple SDK checkout.
ICU_SDK ?= $(HOME)/iPhoneOS14.5.sdk
ICU_INCLUDE_DIR ?= $(if $(wildcard $(ICU_SDK)/usr/include/unicode/utypes.h),$(ICU_SDK)/usr/include,$(mac)/usr/include)
ifneq ($(wildcard $(ICU_INCLUDE_DIR)/unicode/utypes.h),)
flag += -idirafter $(ICU_INCLUDE_DIR)
endif

flag += -Wall
flag += -Wno-dangling-else
flag += -Wno-deprecated-declarations
flag += -Wno-objc-protocol-method-implementation
flag += -Wno-logical-op-parentheses
flag += -Wno-shift-op-parentheses
flag += -Wno-unknown-pragmas
flag += -Wno-unknown-warning-option

plus += -fobjc-call-cxx-cdtors
plus += -fvisibility-inlines-hidden

link += -multiply_defined suppress

libs += -framework CoreFoundation
libs += -framework CoreGraphics
libs += -framework Foundation
libs += -framework GraphicsServices
libs += -framework IOKit
libs += -framework QuartzCore
libs += -framework SpringBoardServices
libs += -framework SystemConfiguration
libs += -framework CFNetwork
libs += -llockdown
libs += -framework WebKit
libs += -Xarch_$(arch) -Wl,-force_load,$(APT_LIBRARY)
lapt += $(APT_LIBRARY)
libs += -licucore

uikit :=
uikit += -framework UIKit

link += -Wl,-liconv
link += -Xarch_$(arch) -Wl,-lz

flag += -DAPT_PKG_EXPOSE_STRING_VIEW
flag += -Dsighandler_t=sig_t

target :=
target += -arch $(arch)
target += -m$(kind)-version-min=$(DEPLOYMENT_TARGET)

apt64 := $(cycc) $(target) $(flag)
apt64 += -include apt.h
apt64 += -Wno-deprecated-register
apt64 += -Wno-unused-private-field
apt64 += -Wno-unused-variable
apt64 += -DNDEBUG

eapt := -include apt.h
apt64 += $(eapt)
eapt += -D'VERSION="0.7.25.3"'
eapt += -Wno-format
eapt += -Wno-logical-op-parentheses
iapt += $(eapt)

cycc += $(target)
plus += -std=c++11
