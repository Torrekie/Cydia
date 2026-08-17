.DELETE_ON_ERROR:
.SECONDARY:

dpkg := fakeroot dpkg-deb -Zlzma
version := $(shell ./version.sh)
DEPLOYMENT_TARGET ?= 12.0
BUILD_DIR ?= build

OBJECT_DIR := $(BUILD_DIR)/objects
GENERATED_DIR := $(BUILD_DIR)/generated
IMAGE_DIR := $(BUILD_DIR)/images
BIN_DIR := $(BUILD_DIR)/bin
ARCHIVE_DIR := $(BUILD_DIR)/archive
PACKAGE_DIR := $(BUILD_DIR)/packages
STAGE_DIR := $(BUILD_DIR)/stage

APP_BINARY := $(BIN_DIR)/MobileCydia
POSTINST_BINARY := $(BIN_DIR)/postinst
CYDO_BINARY := $(BIN_DIR)/cydo
SETNSFPN_BINARY := $(BIN_DIR)/setnsfpn
CFVERSION_BINARY := $(BIN_DIR)/cfversion
APT_LIBRARY := $(OBJECT_DIR)/libapt64.a
VERSION_HEADER := $(GENERATED_DIR)/Version.h
CYDIA_STAGE := $(STAGE_DIR)/cydia
LPROJ_STAGE := $(STAGE_DIR)/cydia-lproj
CYDIA_DEB := $(PACKAGE_DIR)/cydia_$(version)_iphoneos-arm.deb
LPROJ_DEB := $(PACKAGE_DIR)/cydia-lproj_$(version)_iphoneos-arm.deb

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

dirs := Menes CyteKit Cydia SDURLCache

code := $(foreach dir,$(dirs),$(wildcard $(foreach ext,h hpp c cpp m mm,$(dir)/*.$(ext))))
code := $(filter-out SDURLCache/SDURLCacheTests.m,$(code))
code += MobileCydia.mm Version.mm iPhonePrivate.h Cytore.hpp lookup3.c Sources.h Sources.mm DiskUsage.cpp

code += apt64/methods/http.cc

source := $(filter %.m,$(code)) $(filter %.mm,$(code))
source += $(filter %.c,$(code)) $(filter %.cpp,$(code)) $(filter %.cc,$(code))
header := $(filter %.h,$(code)) $(filter %.hpp,$(code)) $(filter %.hh,$(code))

object := $(source)
object := $(object:.c=.o)
object := $(object:.cpp=.o)
object := $(object:.cc=.o)
object := $(object:.m=.o)
object := $(object:.mm=.o)
object := $(object:%=$(OBJECT_DIR)/%)

methods := copy file rred gpgv

libapt64 := 
libapt64 += $(wildcard apt64/apt-pkg/*.cc)
libapt64 += $(wildcard apt64/apt-pkg/deb/*.cc)
libapt64 += $(wildcard apt64/apt-pkg/contrib/*.cc)
libapt64 += apt64/methods/store.cc
libapt64 += $(patsubst %,apt64/methods/%.cc,$(methods))
libapt64 := $(filter-out %/srvrec.cc,$(libapt64))
libapt64 := $(patsubst %.cc,$(OBJECT_DIR)/%.o,$(libapt64))

tagfile_keys_dir := $(GENERATED_DIR)/apt64/apt-pkg
tagfile_keys_header := $(tagfile_keys_dir)/tagfile-keys.h
tagfile_keys_source := $(tagfile_keys_dir)/tagfile-keys.cc
tagfile_keys_stamp := $(tagfile_keys_dir)/tagfile-keys.stamp
tagfile_keys_object := $(OBJECT_DIR)/apt64/apt-pkg/tagfile-keys.o
libapt64 += $(tagfile_keys_object)

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

images := $(shell find MobileCydia.app/ -type f -name '*.png')
images := $(images:%=$(IMAGE_DIR)/%)

all: $(APP_BINARY)

clean:
	@case "$(BUILD_DIR)" in ""|/|.|..) echo "refusing unsafe BUILD_DIR: $(BUILD_DIR)" >&2; exit 2;; esac
	rm -rf -- "$(BUILD_DIR)"

$(OBJECT_DIR)/apt64/apt-pkg/tagfile.o: $(tagfile_keys_header)
$(OBJECT_DIR)/apt64/apt-pkg/deb/deblistparser.o: $(tagfile_keys_header)
$(tagfile_keys_object): $(tagfile_keys_source) $(tagfile_keys_header)

$(tagfile_keys_stamp): apt64/apt-pkg/tagfile-keys.list apt64/triehash/triehash.pl
	@mkdir -p $(tagfile_keys_dir)
	@echo "[trie] $(tagfile_keys_header)"
	@apt64/triehash/triehash.pl \
            --ignore-case \
            --header $(tagfile_keys_header) \
            --code $(tagfile_keys_source) \
            --enum-class \
            --enum-name pkgTagSection::Key \
            --function-name pkgTagHash \
            --include "<apt-pkg/tagfile.h>" \
            apt64/apt-pkg/tagfile-keys.list
	@perl -pi -e 's@typedef char static_assert64@//typedef char static_assert64@' $(tagfile_keys_source)
	@touch $@

$(tagfile_keys_header) $(tagfile_keys_source): $(tagfile_keys_stamp)
	@test -f $@

$(tagfile_keys_object): $(tagfile_keys_source) $(header) apt.h apt-extra/*.h
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(apt64) $(plus) -c -o $@ $(tagfile_keys_source) -Dmain=main_$(basename $(notdir $@))

$(OBJECT_DIR)/apt64/%.o: apt64/%.cc $(header) apt.h apt-extra/*.h
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(apt64) $(plus) -c -o $@ $< -Dmain=main_$(basename $(notdir $@))

$(OBJECT_DIR)/%.o: %.cc $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) $(plus) -c -o $@ $< $(flag) -Wno-format -include apt.h -Dmain=main_$(basename $(notdir $@))

$(OBJECT_DIR)/%.o: %.c $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) -c -o $@ -x c $< $(flag)

$(OBJECT_DIR)/%.o: %.m $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) -c -o $@ $< $(flag)

$(OBJECT_DIR)/%.o: %.cpp $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) $(plus) -c -o $@ $< $(flag)

$(OBJECT_DIR)/%.o: %.mm $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) $(plus) -c -o $@ $< $(flag)

$(OBJECT_DIR)/Version.o: $(VERSION_HEADER)

$(VERSION_HEADER): FORCE
	@./version.sh --header $@ >/dev/null

$(IMAGE_DIR)/%.png: %.png
	@mkdir -p $(dir $@)
	@echo "[pngc] $<"
	@./pngcrush.sh $< $@
	@touch $@

sysroot: sysroot.sh
	@echo "Your ./sysroot/ is either missing or out of date. Please read compiling.txt for help." 1>&2
	@echo 1>&2
	@exit 1

$(APT_LIBRARY): $(libapt64)
	@mkdir -p $(dir $@)
	@echo "[arch] $@"
	@ar -rc $@ $^

$(APP_BINARY): $(object) entitlements.xml $(lapt)
	@mkdir -p $(dir $@) $(ARCHIVE_DIR)
	@echo "[link] $@"
	@$(cycc) -o $@ $(filter %.o,$^) $(link) $(libs) $(uikit)
	@cp -a $@ $(ARCHIVE_DIR)/$(notdir $@)-$(version)_$(shell date +%s)
	@echo "[strp] $@"
	@grep '~' <<<"$(version)" >/dev/null && echo "skipping..." || strip $@
	@echo "[uikt] $@"
	@./uikit.sh $@
	@install_name_tool -add_rpath /System/Library/Frameworks $@
	@install_name_tool -add_rpath /System/Library/PrivateFrameworks $@
	@install_name_tool -change /System/Library/Frameworks/WebKit.framework/WebKit @rpath/WebKit.framework/WebKit $@
	@install_name_tool -change /System/Library/PrivateFrameworks/WebKit.framework/WebKit @rpath/WebKit.framework/WebKit $@

$(CFVERSION_BINARY): cfversion.mm
	@mkdir -p $(dir $@)
	$(cycc) -o $@ $(filter %.mm,$^) $(flag) $(link) -framework CoreFoundation
	@ldid -T0 -Sgenent.xml $@

$(SETNSFPN_BINARY): setnsfpn.cpp
	@mkdir -p $(dir $@)
	$(cycc) -o $@ $(filter %.cpp,$^) $(flag) $(link)
	@ldid -T0 -Sgenent.xml $@

$(CYDO_BINARY): cydo.cpp
	@mkdir -p $(dir $@)
	$(cycc) $(plus) -o $@ $(filter %.cpp,$^) $(flag) $(link) -Wno-deprecated-writable-strings
	@ldid -T0 -Sgenent.xml $@

$(POSTINST_BINARY): postinst.mm CyteKit/stringWith.mm CyteKit/stringWith.h CyteKit/UCPlatform.h
	@mkdir -p $(dir $@)
	$(cycc) $(plus) -o $@ $(filter %.mm,$^) $(flag) $(link) -framework CoreFoundation -framework Foundation -framework UIKit
	@ldid -T0 -Sgenent.xml $@

$(CYDIA_DEB): $(APP_BINARY) preinst $(POSTINST_BINARY) $(CFVERSION_BINARY) $(SETNSFPN_BINARY) $(CYDO_BINARY) $(images) $(shell find MobileCydia.app) cydia.control cydia.preferences Library/firmware.sh Library/move.sh Library/startup
	fakeroot rm -rf $(CYDIA_STAGE)
	mkdir -p $(CYDIA_STAGE)/var/lib/cydia
	
	mkdir -p $(CYDIA_STAGE)/etc/apt
	mkdir $(CYDIA_STAGE)/etc/apt/apt.conf.d
	mkdir $(CYDIA_STAGE)/etc/apt/preferences.d
	cp -a cydia.preferences $(CYDIA_STAGE)/etc/apt/preferences.d/cydia
	cp -a Trusted.gpg $(CYDIA_STAGE)/etc/apt/trusted.gpg.d
	cp -a Sources.list $(CYDIA_STAGE)/etc/apt/sources.list.d
	
	mkdir -p $(CYDIA_STAGE)/usr/libexec
	cp -a Library $(CYDIA_STAGE)/usr/libexec/cydia
	cp -a sysroot/usr/bin/du $(CYDIA_STAGE)/usr/libexec/cydia
	cp -a $(CFVERSION_BINARY) $(CYDIA_STAGE)/usr/libexec/cydia/cfversion
	cp -a $(SETNSFPN_BINARY) $(CYDIA_STAGE)/usr/libexec/cydia/setnsfpn
	
	cp -a $(CYDO_BINARY) $(CYDIA_STAGE)/usr/libexec/cydia/cydo
	
	mkdir -p $(CYDIA_STAGE)/Library
	cp -a LaunchDaemons $(CYDIA_STAGE)/Library/LaunchDaemons
	
	mkdir -p $(CYDIA_STAGE)/Applications
	cp -a MobileCydia.app $(CYDIA_STAGE)/Applications/Cydia.app
	rm -rf $(CYDIA_STAGE)/Applications/Cydia.app/*.lproj
	cp -a $(APP_BINARY) $(CYDIA_STAGE)/Applications/Cydia.app/Cydia
	
	for meth in bzip2 gzip lzma http https store $(methods); do ln -s Cydia $(CYDIA_STAGE)/Applications/Cydia.app/"$${meth}"; done
	
	cd $(IMAGE_DIR)/MobileCydia.app && find . -name '*.png' -exec cp -af {} $(abspath $(CYDIA_STAGE))/Applications/Cydia.app/{} ';'
	@echo "[sign] Cydia.app"
	@ldid -T0 -Sentitlements.xml $(CYDIA_STAGE)/Applications/Cydia.app
	
	mkdir -p $(CYDIA_STAGE)/Applications/Cydia.app/Sources
	ln -s /usr/share/bigboss/icons/bigboss.png $(CYDIA_STAGE)/Applications/Cydia.app/Sources/apt.bigboss.us.com.png
	ln -s /usr/share/bigboss/icons/planetiphones.png $(CYDIA_STAGE)/Applications/Cydia.app/Sections/"Planet-iPhones Mods.png"
	
	mkdir -p $(CYDIA_STAGE)/DEBIAN
	./control.sh cydia.control $(CYDIA_STAGE) >$(CYDIA_STAGE)/DEBIAN/control
	cp -a preinst triggers $(CYDIA_STAGE)/DEBIAN/
	cp -a $(POSTINST_BINARY) $(CYDIA_STAGE)/DEBIAN/postinst
	
	find $(CYDIA_STAGE) -exec touch -t "$$(date -j -f "%s" +"%Y%m%d%H%M.%S" "$$(git show --format='format:%ct' | head -n 1)")" {} ';'
	
	fakeroot chown -R 0 $(CYDIA_STAGE)
	fakeroot chgrp -R 0 $(CYDIA_STAGE)
	fakeroot chmod 6755 $(CYDIA_STAGE)/usr/libexec/cydia/cydo
	
	mkdir -p $(dir $@)
	$(dpkg) -b $(CYDIA_STAGE) $@
	@echo "$$(stat -f "%z" $@) $$(stat -f "%Y" $@)"

$(LPROJ_DEB): $(shell find MobileCydia.app -name '*.strings') cydia-lproj.control
	fakeroot rm -rf $(LPROJ_STAGE)
	mkdir -p $(LPROJ_STAGE)/Applications/Cydia.app
	
	cp -a MobileCydia.app/*.lproj $(LPROJ_STAGE)/Applications/Cydia.app
	
	mkdir -p $(LPROJ_STAGE)/DEBIAN
	./control.sh cydia-lproj.control $(LPROJ_STAGE) >$(LPROJ_STAGE)/DEBIAN/control
	
	fakeroot chown -R 0 $(LPROJ_STAGE)
	fakeroot chgrp -R 0 $(LPROJ_STAGE)
	
	mkdir -p $(dir $@)
	$(dpkg) -b $(LPROJ_STAGE) $@
	@echo "$$(stat -f "%z" $@) $$(stat -f "%Y" $@)"
	
MobileCydia: $(APP_BINARY)
postinst: $(POSTINST_BINARY)
cfversion: $(CFVERSION_BINARY)
setnsfpn: $(SETNSFPN_BINARY)
cydo: $(CYDO_BINARY)
package: $(CYDIA_DEB) $(LPROJ_DEB)

FORCE:

.PHONY: all clean package MobileCydia postinst cfversion setnsfpn cydo FORCE
