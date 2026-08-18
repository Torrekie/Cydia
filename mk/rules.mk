all: $(APP_BINARY)

clean:
	@case "$(BUILD_DIR)" in \
		""|/|.|..|/*|./*|../*|*/.|*/..|*/./*|*/../*|*/) \
			echo "refusing unsafe BUILD_DIR: $(BUILD_DIR)" >&2; exit 2;; \
	esac
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

MobileCydia: $(APP_BINARY)
postinst: $(POSTINST_BINARY)
cfversion: $(CFVERSION_BINARY)
setnsfpn: $(SETNSFPN_BINARY)
cydo: $(CYDO_BINARY)

FORCE:
