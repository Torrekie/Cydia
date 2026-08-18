# Make-backed modernization checks.  These targets are intentionally separate
# from `all` and `package`: existing build and packaging behavior is unchanged.

VERIFY_SCRIPT := scripts/verify-modernization.sh
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

verify: verify-static verify-compile

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
		"makefile mk/toolchain.mk mk/rules.mk mk/verify.mk"

verify-ownership: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) ownership $(verify_ownership_files)

verify-size: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) size "$(VERIFY_MAX_SOURCE_LINES)" $(verify_size_sources)

# Compile every supported Objective-C object and both direct helper binaries,
# but do not perform the application/package link.  This is the fast, Make-only
# migration proof used between source-splitting commits.
verify-compile: $(verify_objc_objects) $(POSTINST_BINARY) $(CFVERSION_BINARY)
	@echo "[verify] Objective-C/Objective-C++ compile graph is up to date"
