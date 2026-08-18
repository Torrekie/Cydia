all: $(APP_BINARY)

clean:
	@case "$(BUILD_DIR)" in \
		""|/|.|..|/*|./*|../*|*/.|*/..|*/./*|*/../*|*/) \
			echo "refusing unsafe BUILD_DIR: $(BUILD_DIR)" >&2; exit 2;; \
	esac
	rm -rf -- "$(BUILD_DIR)"

$(APT_CONTRIB_INCLUDE_TARGET): FORCE
	@mkdir -p $(dir $@)
	@desired="$(abspath $(APT_SOURCE_DIR)/apt-pkg/contrib)"; \
		if test -L "$@" && test "$$(readlink "$@")" = "$$desired"; then exit 0; fi; \
		tmp="$@.tmp"; \
		if test -L "$$tmp"; then unlink "$$tmp"; elif test -e "$$tmp"; then \
			echo "refusing to replace non-link $$tmp" >&2; exit 2; fi; \
		ln -s "$$desired" "$$tmp" && \
		if test -L "$@"; then unlink "$@"; elif test -e "$@"; then \
			echo "refusing to replace non-link $@" >&2; exit 2; fi && \
		mv "$$tmp" "$@"

$(APT_DEB_INCLUDE_TARGET): FORCE
	@mkdir -p $(dir $@)
	@desired="$(abspath $(APT_SOURCE_DIR)/apt-pkg/deb)"; \
		if test -L "$@" && test "$$(readlink "$@")" = "$$desired"; then exit 0; fi; \
		tmp="$@.tmp"; \
		if test -L "$$tmp"; then unlink "$$tmp"; elif test -e "$$tmp"; then \
			echo "refusing to replace non-link $$tmp" >&2; exit 2; fi; \
		ln -s "$$desired" "$$tmp" && \
		if test -L "$@"; then unlink "$@"; elif test -e "$@"; then \
			echo "refusing to replace non-link $@" >&2; exit 2; fi && \
		mv "$$tmp" "$@"

$(OBJECT_DIR)/apt64/apt-pkg/tagfile.o: $(tagfile_keys_header)
$(OBJECT_DIR)/apt64/apt-pkg/deb/deblistparser.o: $(tagfile_keys_header)
$(tagfile_keys_object): $(tagfile_keys_source) $(tagfile_keys_header)

$(APT_PROVENANCE_STAMP): FORCE mk/apt.mk mk/rules.mk mk/sources.mk mk/toolchain.mk .gitmodules apt.h apt-extra/*.h \
	$(APT_CONTRIB_INCLUDE_TARGET) $(APT_DEB_INCLUDE_TARGET) | verify-apt
	@mkdir -p $(dir $@)
	@tmp="$@.tmp"; \
	tree_state=$$( { \
		git -C $(APT_SOURCE_DIR) diff --no-ext-diff --binary HEAD; \
		git -C $(APT_SOURCE_DIR) ls-files --others --exclude-standard | \
		while IFS= read -r path; do cksum "$(APT_SOURCE_DIR)/$$path"; done; \
	} | cksum | awk '{ print $$1 ":" $$2 }'); \
	config_state=$$(cksum mk/apt.mk mk/rules.mk mk/sources.mk mk/toolchain.mk \
		.gitmodules apt.h apt-extra/*.h | cksum | awk '{ print $$1 ":" $$2 }'); \
	toolchain_state=$$(printf '%s\n' \
		"compiler=$(gxx)" "sdk=$(sdk)" "mac-sdk=$(mac)" \
		"icu-include=$(ICU_INCLUDE_DIR)" "kind=$(kind)" | \
		cksum | awk '{ print $$1 ":" $$2 }'); \
	{ \
		echo "source-dir=$(APT_SOURCE_DIR)"; \
		echo "commit=$$(git -C $(APT_SOURCE_DIR) rev-parse HEAD 2>/dev/null || echo missing)"; \
		echo "tree-state=$$tree_state"; \
		echo "config-state=$$config_state"; \
		echo "toolchain-state=$$toolchain_state"; \
		echo "source-url=$(APT_SOURCE_URL)"; \
		echo "version=$(APT_SOURCE_VERSION)"; \
		echo "cxx-level=$(APT_SOURCE_CXX_LEVEL)"; \
		echo "cxx-standard=$(APT_SOURCE_CXX_STANDARD)"; \
		echo "trust=$(APT_SOURCE_TRUST)"; \
		echo "abi=$(APT_ABI_MAJOR).$(APT_ABI_MINOR).$(APT_ABI_RELEASE)"; \
		echo "arch=$(arch)"; \
		echo "deployment-target=$(DEPLOYMENT_TARGET)"; \
		echo "contrib-include=$(APT_CONTRIB_INCLUDE_DIR)"; \
		echo "deb-include=$(APT_DEB_INCLUDE_DIR)"; \
		echo "sources=$(apt_sources)"; \
	} >"$$tmp"; \
	if test -f "$@" && cmp -s "$$tmp" "$@"; \
	then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

$(tagfile_keys_stamp): $(APT_PROVENANCE_STAMP) \
	$(APT_SOURCE_DIR)/apt-pkg/tagfile-keys.list $(APT_SOURCE_DIR)/triehash/triehash.pl
	@mkdir -p $(tagfile_keys_dir)
	@echo "[trie] $(tagfile_keys_header)"
	@$(APT_SOURCE_DIR)/triehash/triehash.pl \
            --ignore-case \
            --header $(tagfile_keys_header) \
            --code $(tagfile_keys_source) \
            --enum-class \
            --enum-name pkgTagSection::Key \
            --function-name pkgTagHash \
            --include "<apt-pkg/tagfile.h>" \
            $(APT_SOURCE_DIR)/apt-pkg/tagfile-keys.list
	@perl -pi -e 's@typedef char static_assert64@//typedef char static_assert64@' $(tagfile_keys_source)
	@touch $@

$(tagfile_keys_header) $(tagfile_keys_source): $(tagfile_keys_stamp)
	@test -f $@

$(tagfile_keys_object): $(tagfile_keys_source) $(header) apt.h apt-extra/*.h
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(apt64) $(apt_plus) -c -o $@ $(tagfile_keys_source) -Dmain=main_$(basename $(notdir $@))

$(OBJECT_DIR)/apt64/%.o: $(APT_SOURCE_DIR)/%.cc $(header) apt.h apt-extra/*.h
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(apt64) $(apt_plus) -c -o $@ $< -Dmain=main_$(basename $(notdir $@))

$(apt_http_object): $(apt_http_source) $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) $(apt_plus) -c -o $@ $< $(flag) $(http_flags) -Wno-format -include apt.h -Dmain=main_http

$(apt_compat_object): Cydia/AptCompatibility.cpp $(header) apt.h apt-extra/*.h
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(apt64) $(apt_plus) -c -o $@ $<

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
	@$(cycc) $(objc_arc) -c -o $@ $< $(flag)

$(OBJECT_DIR)/%.o: %.cpp $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) $(plus) -c -o $@ $< $(flag)

$(OBJECT_DIR)/%.o: %.mm $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) $(plus) $(objc_arc) -c -o $@ $< $(flag)

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

$(APT_LIBRARY): $(APT_PROVENANCE_STAMP) $(libapt64)
	@mkdir -p $(dir $@)
	@echo "[arch] $@"
	@tmp="$@.tmp"; rm -f "$$tmp"; \
		ar -rc "$$tmp" $(filter %.o,$^) && mv -f "$$tmp" "$@"

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
	$(cycc) $(objc_arc) -o $@ $(filter %.mm,$^) $(flag) $(link) -framework CoreFoundation
	@ldid -T0 -Sgenent.xml $@

$(SETNSFPN_BINARY): setnsfpn.cpp
	@mkdir -p $(dir $@)
	$(cycc) -o $@ $(filter %.cpp,$^) $(flag) $(link)
	@ldid -T0 -Sgenent.xml $@

$(CYDO_BINARY): cydo.cpp Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	$(cycc) $(plus) -o $@ $(filter %.cpp,$^) $(flag) $(link) -Wno-deprecated-writable-strings
	@ldid -T0 -Sgenent.xml $@

$(POSTINST_BINARY): postinst.mm CyteKit/stringWith.mm CyteKit/stringWith.h CyteKit/UCPlatform.h Cydia/DpkgRunner.cpp Cydia/DpkgRunner.h Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	$(cycc) $(plus) $(objc_arc) -o $@ $(filter %.mm %.cpp,$^) $(flag) $(link) -framework CoreFoundation -framework Foundation -framework UIKit
	@ldid -T0 -Sgenent.xml $@

MobileCydia: $(APP_BINARY)
postinst: $(POSTINST_BINARY)
cfversion: $(CFVERSION_BINARY)
setnsfpn: $(SETNSFPN_BINARY)
cydo: $(CYDO_BINARY)

FORCE:
