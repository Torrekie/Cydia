all: $(APP_BINARY)

$(APT_LOCALE_DIR)/%/LC_MESSAGES/$(APT_MESSAGE_DOMAIN).mo: $(APT_SOURCE_DIR)/po/%.po
	@mkdir -p $(dir $@)
	@$(MSGFMT) --check --output-file=$@.tmp $< && mv $@.tmp $@

$(apt_messages_object): Cydia/AptMessages.cpp Cydia/AptMessages.h
	@mkdir -p $(dir $@)
	@$(cycc) $(plus) -c -o $@ $< $(flag) -DCYDIA_APT_MESSAGE_DOMAIN='"$(APT_MESSAGE_DOMAIN)"'

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

$(APT_PROVENANCE_STAMP): FORCE mk/apt.mk mk/rules.mk mk/sources.mk mk/toolchain.mk mk/exec-compat.mk .gitmodules apt.h apt-extra/*.h apt-extra/gnutls/*.h $(APT_TRIEHASH) \
	$(APT_CONTRIB_INCLUDE_TARGET) $(APT_DEB_INCLUDE_TARGET) | verify-apt
	@mkdir -p $(dir $@)
	@tmp="$@.tmp"; \
	tree_state=$$( { \
		git -C $(APT_SOURCE_DIR) diff --no-ext-diff --binary HEAD; \
		git -C $(APT_SOURCE_DIR) ls-files --others --exclude-standard | \
		while IFS= read -r path; do cksum "$(APT_SOURCE_DIR)/$$path"; done; \
	} | cksum | awk '{ print $$1 ":" $$2 }'); \
	config_state=$$(cksum mk/apt.mk mk/rules.mk mk/sources.mk mk/toolchain.mk mk/exec-compat.mk \
		.gitmodules apt.h apt-extra/*.h apt-extra/gnutls/*.h $(APT_TRIEHASH) | cksum | awk '{ print $$1 ":" $$2 }'); \
	xxhash_commit=$$(git -C $(XXHASH_SOURCE_DIR) rev-parse HEAD 2>/dev/null || echo missing); \
	toolchain_state=$$(printf '%s\n' \
		"compiler=$(gxx)" "sdk=$(sdk)" "mac-sdk=$(mac)" \
		"icu-include=$(ICU_INCLUDE_DIR)" "kind=$(kind)" | \
		cksum | awk '{ print $$1 ":" $$2 }'); \
	{ \
		echo "source-dir=$(APT_SOURCE_DIR)"; \
		echo "commit=$$(git -C $(APT_SOURCE_DIR) rev-parse HEAD 2>/dev/null || echo missing)"; \
		echo "base-commit=$(APT_SOURCE_BASE_COMMIT)"; \
		echo "tree-state=$$tree_state"; \
		echo "config-state=$$config_state"; \
		echo "toolchain-state=$$toolchain_state"; \
		echo "source-url=$(APT_SOURCE_URL)"; \
		echo "version=$(APT_SOURCE_VERSION)"; \
		echo "xxhash-source-dir=$(XXHASH_SOURCE_DIR)"; \
		echo "xxhash-commit=$$xxhash_commit"; \
		echo "xxhash-source-url=$(XXHASH_SOURCE_URL)"; \
		echo "xxhash-version=$(XXHASH_SOURCE_VERSION)"; \
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

$(tagfile_keys_clean_list): $(APT_SOURCE_DIR)/apt-pkg/tagfile-keys.list
	@mkdir -p $(dir $@)
	@tmp="$@.tmp"; grep -v '^#' "$<" >"$$tmp" && mv -f "$$tmp" "$@"

$(tagfile_keys_stamp): $(APT_PROVENANCE_STAMP) \
	$(tagfile_keys_clean_list) $(APT_TRIEHASH)
	@mkdir -p $(tagfile_keys_dir)
	@echo "[trie] $(tagfile_keys_header)"
	@$(APT_TRIEHASH) \
            --ignore-case \
            --header $(tagfile_keys_header) \
            --code $(tagfile_keys_source) \
            --enum-class \
            --enum-name pkgTagSection::Key \
            --function-name pkgTagHash \
            --include "<apt-pkg/tagfile.h>" \
		$(tagfile_keys_clean_list)
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
	@$(apt64) $(apt_plus) $(APT_EXEC_COMPAT_FLAGS) -c -o $@ $< -Dmain=main_$(basename $(notdir $@))

$(apt_http_object): $(apt_http_source) $(header)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) $(apt_plus) -c -o $@ $< $(flag) $(http_flags) -Wno-format -include apt.h -Dmain=main_http

$(apt_compat_object): Cydia/AptCompatibility.cpp $(header) apt.h apt-extra/*.h
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(apt64) $(apt_plus) -c -o $@ $<

$(OBJECT_DIR)/Cydia/AptRuntime.o: Cydia/AptRuntime.cpp Cydia/AptRuntime.hpp $(header) apt.h apt-extra/*.h
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(apt64) $(plus) -c -o $@ $< $(flag)

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
		$(CYAR) -rc "$$tmp" $(filter %.o,$^) && mv -f "$$tmp" "$@"

$(APP_BINARY): $(object) entitlements.xml $(lapt) $(EXEC_COMPAT_LIBRARY) $(EXEC_COMPAT_VERIFY_SCRIPT) $(compiler_rt_ios_library) $(BUILD_PROVENANCE_SCRIPT)
	@mkdir -p $(dir $@) $(ARCHIVE_DIR)
	@echo "[link] $@"
	@$(cycc) -o $@ $(filter %.o,$^) $(link) $(libs) $(EXEC_COMPAT_LIBRARY) $(uikit)
	@$(EXEC_COMPAT_VERIFY_SCRIPT) binary "$(CYNM)" "$(CYOTOOL)" "$@" app-unstripped
	@cp -a $@ $(ARCHIVE_DIR)/$(notdir $@)-$(version)_$(shell date +%s)
	@echo "[strp] $@"
	@printf '%s\n' "$(version)" | grep -q '~' && echo "skipping..." || $(CYSTRIP) $@
	@echo "[uikt] $@"
	@./uikit.sh $@
	@$(BUILD_PROVENANCE_SCRIPT) record "$(CURDIR)" "$@" "$(VERSION_HEADER)" "$(APP_BINARY_PROVENANCE)"

$(CFVERSION_BINARY): cfversion.mm
	@mkdir -p $(dir $@)
	$(cycc) $(objc_arc) -o $@ $(filter %.mm,$^) $(flag) $(link) -framework CoreFoundation
	@$(LDID) -T0 -Sgenent.xml $@

$(FIRMWARE_DISCOVERY_BINARY): firmware-discovery.mm
	@mkdir -p $(dir $@)
	$(cycc) $(plus) $(objc_arc) -o $@ $(filter %.mm,$^) $(flag) $(link) -framework CoreFoundation -framework Foundation
	@$(LDID) -T0 -Sgenent.xml $@

$(SETNSFPN_BINARY): setnsfpn.cpp
	@mkdir -p $(dir $@)
	$(cycc) -o $@ $(filter %.cpp,$^) $(flag) $(link)
	@$(LDID) -T0 -Sgenent.xml $@

$(CYDO_BINARY): cydo.cpp Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp \
		Cydia/AptProviderBrokerPrivileged.cpp Cydia/AptProviderBrokerValues.cpp \
		Cydia/AptProviderSelection.cpp Cydia/AptProviderSelectionValues.cpp Cydia/AptProviderClient.cpp \
		Cydia/AptProviderLaunch.cpp Cydia/AptRecoverySnapshot.cpp \
		Cydia/AptRecoveryAuthority.cpp Cydia/AptRecoveryInstalledAuthority.cpp \
		Cydia/AptRecoveryDependencyInspector.cpp Cydia/AptRecoveryMachO.cpp \
		Cydia/AptProviderComponentCapture.cpp Cydia/AptProviderComponentSuccession.cpp \
		Cydia/AptProviderTransactionChannel.cpp Cydia/AptProviderTransactionRequest.cpp \
		Cydia/AptProviderTransactionResult.cpp \
		Cydia/AptProviderTransactionRequestDigest.cpp \
		Cydia/AptProviderTransactionFiles.cpp Cydia/AptProviderTransactionLease.cpp \
		Cydia/AptProviderTransactionOwner.cpp Cydia/AptProviderTransactionService.cpp \
		Cydia/AptProviderNativeDpkgAuthority.cpp Cydia/AptProviderReview.cpp Cydia/AptProviderArchiveEvidence.cpp \
		Cydia/AptProviderTriggerEffects.cpp Cydia/AptProviderTriggerMetadata.cpp \
		Cydia/AptProviderInstalledScripts.cpp Cydia/AptProviderBinaryRelationships.cpp \
		Cydia/AptProviderDeconfigurationEffects.cpp \
		Cydia/AptProviderNativeVersionComparison.cpp \
		Cydia/AptProviderTriggerCapture.cpp Cydia/AptProviderTriggerApproval.cpp \
		Cydia/AptProviderTriggerEvidence.cpp Cydia/AptProviderTriggerEvidenceProtected.cpp \
		Cydia/AptProviderProtocol.cpp Cydia/AptProviderValues.cpp Cydia/AptRuntimeDescriptor.cpp \
		Cydia/AptProviderDpkgState.cpp Cydia/AptProviderDpkgStateCapture.cpp Cydia/PackageIdentity.cpp \
		Cydia/PackageArchivePolicy.cpp Cydia/PackageArchiveReader.cpp Cydia/AptProviderArchiveDecoders.cpp \
		Cydia/RepositorySecurityPolicy.cpp \
		Cydia/PrivilegedRuntime.cpp Cydia/PrivilegedConfig.cpp Cydia/PrivilegedRuntime.hpp Cydia/ApplicationIdentity.hpp Cydia/ApplicationSession.hpp \
		Cydia/SourceDocument.cpp Cydia/SourceDocumentStore.cpp Cydia/SourceDocumentCommit.cpp \
		Cydia/SourceDocument.hpp Cydia/SourceDocumentStore.hpp Cydia/SourceDocumentCommit.hpp \
        Cydia/SharedStateFile.hpp Cydia/ReadOnlySourceAlias.hpp Cydia/SourceReaderGroups.hpp Cydia/DpkgAdminAccess.hpp \
		Cydia/ExtendedState.cpp Cydia/ExtendedState.hpp Cydia/RuntimeState.cpp Cydia/RuntimeState.hpp \
		Cydia/RuntimeSnapshotInputs.cpp Cydia/RuntimeSnapshotInputs.hpp \
		Cydia/AptProviderTriggerEvidenceCapture.cpp Cydia/AptProviderTriggerEvidence.hpp \
		Cydia/KeyringImport.cpp Cydia/KeyringImportPrivileged.cpp Cydia/KeyringImport.hpp \
		Cydia/KeyringVerifier.cpp Cydia/KeyringVerifier.hpp \
		Cydia/RecoveryPlan.cpp Cydia/RecoveryPlan.hpp Cydia/RecoveryPrivileged.cpp Cydia/RecoveryPrivileged.hpp \
		Cydia/DpkgRunner.cpp Cydia/DpkgRunner.h \
		$(EXEC_COMPAT_LIBRARY) $(APT_LIBRARY)
	@mkdir -p $(dir $@)
	$(cycc) $(plus) -o $@ $(filter %.cpp,$^) $(EXEC_COMPAT_LIBRARY) $(APT_LIBRARY) $(flag) $(link) -Wno-deprecated-writable-strings -framework CoreFoundation -licucore
	@$(LDID) -T0 -Sgenent.xml $@

$(POSTINST_BINARY): postinst.mm Cydia/FirmwareMarkerPermissions.hpp Cydia/PrivateStateDirectory.hpp Cydia/PrivateMetadataMigration.hpp Cydia/SharedConfigHandoff.hpp Cydia/LegacySourceHandoff.cpp Cydia/LegacySourceHandoff.hpp Cydia/LegacyCydiaSourceAlias.cpp Cydia/LegacyCydiaSourceAlias.hpp Cydia/DpkgRunner.cpp Cydia/DpkgRunner.h Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp Cydia/InstalledRuntimePolicy.hpp Cydia/DpkgAdminAccess.hpp Cydia/SharedStateFile.hpp
	@mkdir -p $(dir $@)
	$(cycc) $(plus) $(objc_arc) -DCYDIA_POSTINST_ROOTLESS=$(if $(filter rootless,$(PACKAGE_LAYOUT)),1,0) -o $@ $(filter %.mm %.cpp,$^) $(flag) $(link)
	@$(LDID) -T0 -Sgenent.xml $@

MobileCydia: $(APP_BINARY)
postinst: $(POSTINST_BINARY)
cfversion: $(CFVERSION_BINARY)
setnsfpn: $(SETNSFPN_BINARY)
cydo: $(CYDO_BINARY)

FORCE:
