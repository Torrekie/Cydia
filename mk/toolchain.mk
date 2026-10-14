flag :=
plus :=
link :=
libs :=
lapt :=
objc_arc := -fobjc-arc

ifeq ($(doIA),yes)
kind := iphonesimulator
arch := x86_64
flag += -DCYDIA_APPEARANCE_SIMULATOR_PROBE=1
ifeq ($(doHomeProbe),yes)
flag += -DCYDIA_HOME_SIMULATOR_PROBE=1
endif
ifeq ($(doExternalURLProbe),yes)
flag += -DCYDIA_EXTERNAL_URL_SIMULATOR_PROBE=1
endif
ifeq ($(doErrorViewProbe),yes)
flag += -DCYDIA_ERROR_VIEW_SIMULATOR_PROBE=1
endif
else
kind := iphoneos
arch := arm64
endif

HOST_OS ?= $(shell uname -s)

ifeq ($(HOST_OS),Linux)
THEOS ?= $(CURDIR)/.theos
LINUX_TOOLCHAIN ?= $(THEOS)/toolchain/linux/iphone
IOS_SDK ?= $(firstword $(wildcard $(THEOS)/sdks/iPhoneOS*.sdk))

gxx ?= $(LINUX_TOOLCHAIN)/bin/clang++
sdk ?= $(IOS_SDK)
# App sources only need target SDK headers. Host-side verification programs use
# the native compiler and deliberately do not inherit this sysroot.
mac ?= $(sdk)

CYAR ?= $(LINUX_TOOLCHAIN)/bin/llvm-ar
CYSTRIP ?= $(LINUX_TOOLCHAIN)/bin/strip
LDID ?= $(LINUX_TOOLCHAIN)/bin/ldid
CYNM ?= $(firstword $(wildcard $(LINUX_TOOLCHAIN)/bin/llvm-nm $(LINUX_TOOLCHAIN)/bin/nm))
CYOTOOL ?= $(firstword $(wildcard $(LINUX_TOOLCHAIN)/bin/llvm-otool $(LINUX_TOOLCHAIN)/bin/otool))
INSTALL_NAME_TOOL ?= $(firstword $(wildcard \
    $(LINUX_TOOLCHAIN)/bin/llvm-install-name-tool \
    $(LINUX_TOOLCHAIN)/bin/install_name_tool))

ifeq ($(strip $(sdk)),)
$(error IOS_SDK must name an extracted iPhoneOS SDK when building on Linux)
endif
else
gxx ?= $(shell xcrun --sdk $(kind) -f g++)
sdk ?= $(shell xcodebuild -sdk $(kind) -version Path)
mac ?= $(shell xcodebuild -sdk macosx -version Path)

CYAR ?= ar
CYSTRIP ?= strip
LDID ?= ldid
CYNM ?= $(shell xcrun --sdk $(kind) -f nm)
CYOTOOL ?= $(shell xcrun --sdk $(kind) -f otool)
INSTALL_NAME_TOOL ?= install_name_tool
endif

cycc := $(gxx)

cycc += -isysroot $(sdk)
cycc += -idirafter $(mac)/usr/include
private_frameworks_dir := $(sdk)/System/Library/PrivateFrameworks
ifneq ($(wildcard $(private_frameworks_dir)),)
cycc += -F$(private_frameworks_dir)
endif

ifeq ($(doIA),yes)
simulator_private_frameworks_dir := $(sdk)/../../../../iPhoneOS.platform/Developer/Library/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks
ifneq ($(wildcard $(simulator_private_frameworks_dir)),)
cycc += -Xarch_x86_64 -F$(simulator_private_frameworks_dir)
endif
endif

cycc += -include system.h
cycc += -fmessage-length=0
cycc += -gfull -O2
cycc += -fvisibility=hidden

link += -Wl,-dead_strip
link += -Wl,-no_dead_strip_inits_and_terms

iapt :=
iapt += -I$(APT_SOURCE_DIR)
iapt += -I$(APT_CONTRIB_INCLUDE_DIR)
iapt += -I$(APT_DEB_INCLUDE_DIR)
iapt += -Iapt-extra
iapt += -I$(XXHASH_SOURCE_DIR)
iapt += -I$(GENERATED_DIR)/apt64

ifeq ($(HOST_OS),Linux)
flag += $(iapt)
else
flag += $(patsubst %,-Xarch_$(arch) %,$(iapt))
endif
flag += -I.
flag += -I$(sdk)/usr/include/libxml2
flag += -I$(GENERATED_DIR)
flag += -isystem sysroot/usr/include

# Apple removed unicode/utrans.h from newer SDKs while retaining the ICU C
# ABI.  Prefer the locally supplied iPhoneOS 14.5 SDK headers when present;
# callers can override ICU_INCLUDE_DIR for another Apple SDK checkout.
ifeq ($(HOST_OS),Linux)
ICU_SDK ?= $(sdk)
else
ICU_SDK ?= $(HOME)/iPhoneOS14.5.sdk
endif
ICU_INCLUDE_DIR ?= $(if $(wildcard $(ICU_SDK)/usr/include/unicode/utypes.h),$(ICU_SDK)/usr/include,$(mac)/usr/include)
ifeq ($(wildcard $(ICU_INCLUDE_DIR)/unicode/utypes.h),)
$(error ICU_INCLUDE_DIR must point to Apple OSS/iPhoneOS ICU headers: $(ICU_INCLUDE_DIR))
endif
flag += -idirafter $(ICU_INCLUDE_DIR)

flag += -Wall
flag += -Wno-dangling-else
flag += -Wno-objc-protocol-method-implementation
flag += -Wno-logical-op-parentheses
flag += -Wno-shift-op-parentheses
flag += -Wno-unknown-pragmas
flag += -Wno-unknown-warning-option

plus += -fobjc-call-cxx-cdtors
plus += -fvisibility-inlines-hidden
plus += -include apt.h

link += -multiply_defined suppress

libs += -framework CoreFoundation
libs += -framework CoreGraphics
libs += -framework Foundation
# GraphicsServices is a private, dynamically-resolved API in this source. It
# was present in older SDK layouts but is absent from current public SDKs; do
# not make a modern SDK link fail merely because that optional framework is
# not shipped.
graphics_services_framework := $(firstword $(wildcard \
    $(sdk)/System/Library/PrivateFrameworks/GraphicsServices.framework \
    $(sdk)/System/Library/Frameworks/GraphicsServices.framework))
ifneq ($(graphics_services_framework),)
ifneq ($(doIA),yes)
libs += -framework GraphicsServices
endif
endif
libs += -framework IOKit
libs += -framework QuartzCore
libs += -framework SafariServices
springboard_services_framework := $(firstword $(wildcard \
    $(sdk)/System/Library/PrivateFrameworks/SpringBoardServices.framework \
    $(sdk)/System/Library/Frameworks/SpringBoardServices.framework))
ifneq ($(springboard_services_framework),)
ifneq ($(doIA),yes)
libs += -framework SpringBoardServices
endif
endif
libs += -framework SystemConfiguration
libs += -framework CFNetwork
libs += -framework Security
libs += -framework AuthenticationServices
libs += -framework LocalAuthentication
libs += -framework WebKit
ifeq ($(HOST_OS),Linux)
libs += -Wl,-force_load,$(APT_LIBRARY)
else
libs += -Xarch_$(arch) -Wl,-force_load,$(APT_LIBRARY)
endif
lapt += $(APT_LIBRARY)
libs += -licucore
libs += -lxml2

ifeq ($(HOST_OS),Linux)
# The pinned cross compiler omits the Darwin availability runtime used by
# @available. Link the copied Apple compiler-rt archive; see its provenance.
compiler_rt_ios_library := vendor/compiler-rt/libclang_rt.ios.a
libs += $(compiler_rt_ios_library)
endif

uikit :=
uikit += -framework UIKit

link += -Wl,-liconv
ifeq ($(HOST_OS),Linux)
link += -Wl,-lz
else
link += -Xarch_$(arch) -Wl,-lz
endif

flag += -DAPT_PKG_EXPOSE_STRING_VIEW
flag += -Dsighandler_t=sig_t

target :=
ifeq ($(HOST_OS),Linux)
target += -target $(arch)-apple-ios$(DEPLOYMENT_TARGET)
else
target += -arch $(arch)
target += -m$(kind)-version-min=$(DEPLOYMENT_TARGET)
endif

apt64 := $(cycc) $(target) $(flag)
apt64 += -include apt.h
apt64 += -DAPT_COMPILING_APT
apt64 += -DXXH_INLINE_ALL
apt64 += -D'VERSION="$(APT_SOURCE_VERSION)"'
apt64 += -D'PACKAGE_VERSION="$(APT_SOURCE_VERSION)"'
apt64 += -Wno-deprecated-register
apt64 += -Wno-c++11-narrowing
apt64 += -Wno-unused-private-field
apt64 += -Wno-unused-variable
apt64 += -DNDEBUG

cycc += $(target)
plus += -std=c++11
apt_plus := $(filter-out -std=%,$(plus)) -std=$(APT_SOURCE_CXX_STANDARD) -DAPT_COMPILING_APT -Wno-c++11-narrowing
