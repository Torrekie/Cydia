# Make-backed modernization checks.  These targets are intentionally separate
# from `all` and `package`: existing build and packaging behavior is unchanged.

VERIFY_SCRIPT := scripts/verify-modernization.sh
APT_VERIFY_SCRIPT := scripts/verify-apt-provenance.sh
VERIFY_MAX_SOURCE_LINES ?= 1200

verify_objc_sources := $(filter %.m %.mm,$(source))
verify_objc_objects := $(patsubst %.m,$(OBJECT_DIR)/%.o,$(filter %.m,$(verify_objc_sources)))
verify_objc_objects += $(patsubst %.mm,$(OBJECT_DIR)/%.o,$(filter %.mm,$(verify_objc_sources)))

# Ownership checks cover the supported Objective-C implementation and header
# set, including helper binaries.  Tests are already excluded by sources.mk.
verify_ownership_files := $(filter %.m %.mm %.h %.hpp,$(code))
verify_ownership_files += postinst.mm cfversion.mm

# The line-size gate is for app-owned source only.  apt64 is vendored upstream
# code, and SDURLCache is a vendored third-party implementation; neither is a
# realistic part of the Cydia module split.  They remain in the ARC compile
# gate above.
verify_size_sources := $(filter-out apt64/% SDURLCache/%,$(filter %.m %.mm %.c %.cc %.cpp,$(code)))
verify_size_sources += postinst.mm cfversion.mm

.PHONY: verify verify-static verify-config verify-ownership verify-size verify-compile
.PHONY: verify-apt verify-apt-provenance verify-apt-sources verify-apt-config verify-apt-compile

verify: verify-apt verify-apt-compile verify-static verify-compile

verify-apt: verify-apt-provenance verify-apt-sources verify-apt-config

verify-apt-config:
	@package_version=$$(printf '#include <config.h>\n' | \
		$(apt64) -dM -E -x c++ - 2>/dev/null | \
		awk '$$2 == "PACKAGE_VERSION" { print $$3; exit }'); \
	version=$$(printf '#include <config.h>\n' | \
		$(apt64) -dM -E -x c++ - 2>/dev/null | \
		awk '$$2 == "VERSION" { print $$3; exit }'); \
	if test "$$package_version" != '"$(APT_SOURCE_VERSION)"'; then \
		echo "[verify-apt][FAIL] PACKAGE_VERSION is $$package_version" >&2; exit 1; \
	fi; \
	if test "$$version" != '"$(APT_SOURCE_VERSION)"'; then \
		echo "[verify-apt][FAIL] VERSION is $$version" >&2; exit 1; \
	fi; \
	echo "[verify-apt][ ok ] compiler reports APT version $(APT_SOURCE_VERSION)"

verify-apt-compile: $(APT_LIBRARY) $(apt_http_object)
	@echo "[verify-apt] embedded APT archive and HTTP method compile graph is up to date"

verify-apt-provenance: $(APT_VERIFY_SCRIPT) mk/apt.mk .gitmodules \
	$(APT_CONTRIB_INCLUDE_TARGET) $(APT_DEB_INCLUDE_TARGET)
	@$(APT_VERIFY_SCRIPT) provenance \
		"$(APT_SOURCE_DIR)" "$(APT_SOURCE_COMMIT)" "$(APT_SOURCE_URL)" \
		"$(APT_SOURCE_VERSION)" "$(APT_SOURCE_TRUST)" \
		"$(APT_ABI_MAJOR)" "$(APT_ABI_MINOR)" "$(APT_ABI_RELEASE)" \
		"$(APT_LICENSE_FILES)" \
		"$(APT_CONTRIB_INCLUDE_TARGET)" "$(APT_DEB_INCLUDE_TARGET)"

verify-apt-sources: $(APT_VERIFY_SCRIPT) mk/apt.mk
	@$(APT_VERIFY_SCRIPT) sources "$(APT_SOURCE_DIR)" \
		"$(apt_core_sources)" "$(apt_deb_sources)" \
		"$(apt_contrib_sources)" "$(apt_method_sources)" \
		"$(apt_excluded_contrib_sources)" "$(notdir $(apt_http_source))" \
		"$(apt_excluded_method_sources)"

verify-static: $(VERIFY_SCRIPT)
	@status=0; \
	$(MAKE) --no-print-directory verify-config || status=1; \
	$(MAKE) --no-print-directory verify-ownership || status=1; \
	$(MAKE) --no-print-directory verify-size || status=1; \
	exit $$status

# This target is useful while the source split is in progress: it checks the
# effective Make configuration and command graph without requiring a complete
# application link or a finished line-size gate.
verify-config: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) config "$(DEPLOYMENT_TARGET)" "$(arch)" "$(objc_arc)" "$(MAKE)" \
		"$(OBJECT_DIR)" "$(POSTINST_BINARY)" "$(CFVERSION_BINARY)" \
		"makefile mk/apt.mk mk/toolchain.mk mk/rules.mk mk/verify.mk"

verify-ownership: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) ownership $(verify_ownership_files)

verify-size: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) size "$(VERIFY_MAX_SOURCE_LINES)" $(verify_size_sources)

# Compile every supported Objective-C object and both direct helper binaries,
# but do not perform the application/package link.  This is the fast, Make-only
# migration proof used between source-splitting commits.
verify-compile: $(verify_objc_objects) $(POSTINST_BINARY) $(CFVERSION_BINARY)
	@echo "[verify] Objective-C/Objective-C++ compile graph is up to date"
