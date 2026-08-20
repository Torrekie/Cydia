# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# Make-backed modernization checks.  These targets are intentionally separate
# from `all` and `package`: existing build and packaging behavior is unchanged.

VERIFY_SCRIPT := scripts/verify-modernization.sh
APPEARANCE_VERIFY_SCRIPT := scripts/verify-appearance-simulator.sh
APT_VERIFY_SCRIPT := scripts/verify-apt-provenance.sh
APT_API_VERIFY_SCRIPT := scripts/verify-apt-api.sh
EXEC_COMPAT_VERIFY_SCRIPT := scripts/verify-exec-compat.sh
VERIFY_MAX_SOURCE_LINES ?= 1200
PACKAGE_PATHS_TEST := $(BUILD_DIR)/tests/PackageDatabasePathsTests
APT_RUNTIME_TEST := $(BUILD_DIR)/tests/AptRuntimeTests
DPKG_RUNNER_TEST := $(BUILD_DIR)/tests/DpkgRunnerTests
DPKG_STATUS_TEST := $(BUILD_DIR)/tests/DpkgStatusParserTests
EXEC_COMPAT_PARSER_TEST := $(BUILD_DIR)/tests/ExecCompatParserTests
REGEX_ARC_TEST := $(BUILD_DIR)/tests/RegExArcTests
PACKAGE_IDENTITY_TEST := $(BUILD_DIR)/tests/PackageIdentityTests
MULTIARCH_FIXTURE_TEST := $(BUILD_DIR)/tests/MultiArchFixtureTests
ifeq ($(HOST_OS),Linux)
host_cxx ?= $(or $(HOST_CXX),c++)
host_cc ?= $(or $(HOST_CC),cc)
host_cxx_flags :=
host_cc_flags :=
else
host_cxx ?= $(shell xcrun --sdk macosx -f clang++)
host_cc ?= $(shell xcrun --sdk macosx -f clang)
host_cxx_flags := -isysroot $(mac)
host_cc_flags := -isysroot $(mac)
endif

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

# Candidate set for the APT-consumer inventory.  The inventory script checks
# that every raw APT token in app-owned C++/Objective-C++ is represented by the
# reviewed `apt_api_sources` manifest above.
apt_api_candidates := $(filter-out apt64/% SDURLCache/%,$(filter %.mm %.cpp %.cc,$(code)))

.PHONY: verify verify-static verify-config verify-ownership verify-size verify-compile
.PHONY: verify-package-paths verify-package-identity verify-apt-runtime verify-dpkg-runner verify-dpkg-status verify-bootstrap-helpers
.PHONY: verify-regex-arc
.PHONY: verify-multiarch-fixture
.PHONY: verify-exec-compat verify-exec-compat-provenance verify-exec-compat-archive
.PHONY: verify-exec-compat-parser verify-exec-compat-binary
.PHONY: verify-appearance-simulator
.PHONY: verify-apt verify-apt-provenance verify-apt-sources verify-apt-config verify-apt-api verify-apt-api-inventory verify-apt-compile

verify: verify-apt verify-apt-api verify-apt-compile verify-package-paths verify-package-identity verify-multiarch-fixture verify-apt-runtime verify-dpkg-runner verify-dpkg-status verify-bootstrap-helpers verify-regex-arc verify-exec-compat verify-static verify-compile

$(PACKAGE_PATHS_TEST): tests/PackageDatabasePathsTests.cpp Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/PackageDatabasePathsTests.cpp Cydia/PackageDatabasePaths.cpp -o $@

verify-package-paths: $(PACKAGE_PATHS_TEST)
	@$<

$(PACKAGE_IDENTITY_TEST): tests/PackageIdentityTests.cpp Cydia/PackageIdentity.cpp Cydia/AptCompatibility.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/PackageIdentityTests.cpp Cydia/PackageIdentity.cpp -o $@

verify-package-identity: $(PACKAGE_IDENTITY_TEST)
	@$<

$(MULTIARCH_FIXTURE_TEST): tests/MultiArchFixtureTests.cpp \
		tests/fixtures/multiarch/Packages tests/fixtures/multiarch/progress-status \
		Cydia/PackageIdentity.cpp Cydia/AptCompatibility.hpp \
		Cydia/DpkgStatusParser.cpp Cydia/DpkgStatusParser.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/MultiArchFixtureTests.cpp Cydia/PackageIdentity.cpp \
		Cydia/DpkgStatusParser.cpp -o $@

verify-multiarch-fixture: $(MULTIARCH_FIXTURE_TEST)
	@$<

$(APT_RUNTIME_TEST): tests/AptRuntimeTests.cpp Cydia/AptRuntime.cpp Cydia/AptRuntime.hpp \
		Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp \
		tests/apt-stubs/apt-pkg/configuration.h tests/apt-stubs/apt-pkg/init.h \
		tests/apt-stubs/apt-pkg/pkgsystem.h
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -Itests/apt-stubs -I. \
		tests/AptRuntimeTests.cpp Cydia/AptRuntime.cpp Cydia/PackageDatabasePaths.cpp -o $@

verify-apt-runtime: $(APT_RUNTIME_TEST)
	@$<

$(DPKG_RUNNER_TEST): tests/DpkgRunnerTests.cpp Cydia/DpkgRunner.cpp Cydia/DpkgRunner.h Cydia/PackageDatabasePaths.cpp Cydia/PackageDatabasePaths.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/DpkgRunnerTests.cpp Cydia/DpkgRunner.cpp Cydia/PackageDatabasePaths.cpp -o $@

verify-dpkg-runner: $(DPKG_RUNNER_TEST)
	@$<

$(DPKG_STATUS_TEST): tests/DpkgStatusParserTests.cpp Cydia/DpkgStatusParser.cpp Cydia/DpkgStatusParser.hpp
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=c++11 -Wall -Wextra -I. \
		tests/DpkgStatusParserTests.cpp Cydia/DpkgStatusParser.cpp -o $@

verify-dpkg-status: $(DPKG_STATUS_TEST)
	@$<

verify-bootstrap-helpers:
	@tests/BootstrapHelpersTests.sh

ifeq ($(HOST_OS),Darwin)
$(REGEX_ARC_TEST): tests/RegExArcTests.mm CyteKit/RegEx.hpp CyteKit/stringWith.h CyteKit/stringWith.mm
	@mkdir -p $(dir $@)
	@$(host_cxx) $(host_cxx_flags) -std=gnu++11 -fobjc-arc -Wall -Wextra -I. \
		tests/RegExArcTests.mm CyteKit/stringWith.mm -framework Foundation -licucore -o $@

verify-regex-arc: $(REGEX_ARC_TEST)
	@$<
else
verify-regex-arc:
	@echo "[verify] RegEx ARC runtime test requires a Darwin host; iOS compile coverage remains enabled"
endif

$(EXEC_COMPAT_PARSER_TEST): tests/ExecCompatParserTests.c \
		$(EXEC_COMPAT_SOURCE_DIR)/get_new_argv.c \
		$(EXEC_COMPAT_SOURCE_DIR)/libiosexec.h $(EXEC_COMPAT_SOURCE_DIR)/utils.h \
		$(EXEC_COMPAT_PRIVATE_HEADER) $(EXEC_COMPAT_PATHS_HEADER) \
		tests/exec-compat-stubs/sys/paths.h
	@mkdir -p $(dir $@)
	@$(host_cc) $(host_cc_flags) -std=gnu11 -Wall -Wextra \
		-Itests/exec-compat-stubs -I$(EXEC_COMPAT_GENERATED_DIR) \
		-I$(EXEC_COMPAT_SOURCE_DIR) \
		-DLIBIOSEXEC_INTERNAL=1 \
		-DLIBIOSEXEC_PREFIXED_ROOT=$(EXEC_COMPAT_PREFIXED_ROOT) \
		tests/ExecCompatParserTests.c $(EXEC_COMPAT_SOURCE_DIR)/get_new_argv.c -o $@

verify-exec-compat: verify-exec-compat-provenance verify-exec-compat-archive \
	verify-exec-compat-parser verify-exec-compat-binary

verify-exec-compat-provenance: $(EXEC_COMPAT_VERIFY_SCRIPT) \
		$(EXEC_COMPAT_PROVENANCE_STAMP) $(EXEC_COMPAT_CONFIG_STAMP)
	@$(EXEC_COMPAT_VERIFY_SCRIPT) provenance \
		"$(EXEC_COMPAT_SOURCE_DIR)" "$(EXEC_COMPAT_SOURCE_COMMIT)" \
		"$(EXEC_COMPAT_SOURCE_URL)" "$(EXEC_COMPAT_SOURCE_NAMES)" \
		"$(EXEC_COMPAT_LICENSE)" "$(EXEC_COMPAT_COPYRIGHT)" \
		"$(EXEC_COMPAT_PROVENANCE_STAMP)" "$(EXEC_COMPAT_CONFIG_STAMP)" \
		"$(PACKAGE_LAYOUT)" \
		"$(PACKAGE_PREFIX)" "$(EXEC_COMPAT_SHEBANG_REDIRECT)" \
		"$(EXEC_COMPAT_DEFAULT_PATH)" "$(EXEC_COMPAT_STD_PATH)"

verify-exec-compat-archive: $(EXEC_COMPAT_VERIFY_SCRIPT) $(EXEC_COMPAT_LIBRARY)
	@$(EXEC_COMPAT_VERIFY_SCRIPT) archive "$(CYAR)" "$(EXEC_COMPAT_LIBRARY)"

verify-exec-compat-parser: $(EXEC_COMPAT_PARSER_TEST) Library/firmware.sh
	@$(EXEC_COMPAT_PARSER_TEST) Library/firmware.sh "$(if $(filter 1,$(EXEC_COMPAT_PREFIXED_ROOT)),$(PACKAGE_PREFIX),)/bin/bash"

verify-exec-compat-binary: $(EXEC_COMPAT_VERIFY_SCRIPT) $(CYDO_BINARY)
	@test -n "$(CYNM)" || { echo "CYNM is required" >&2; exit 2; }
	@test -n "$(CYOTOOL)" || { echo "CYOTOOL is required" >&2; exit 2; }
	@$(EXEC_COMPAT_VERIFY_SCRIPT) binary "$(CYNM)" "$(CYOTOOL)" "$(CYDO_BINARY)"

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

verify-apt-api-inventory: $(APT_API_VERIFY_SCRIPT) $(apt_api_sources)
	@$(APT_API_VERIFY_SCRIPT) inventory "$(apt_api_sources)" $(apt_api_candidates)

verify-apt-api: verify-apt-api-inventory $(APT_API_VERIFY_SCRIPT) $(apt_api_sources)
	@$(APT_API_VERIFY_SCRIPT) "$(APT_AUDIT_SOURCE_DIR)" "$(gxx)" "$(sdk)" \
		"$(kind)" "$(arch)" "$(DEPLOYMENT_TARGET)" \
		"$(APT_AUDIT_CXX_STANDARD)" "$(GENERATED_DIR)" "$(ICU_INCLUDE_DIR)" \
		$(apt_api_sources)

verify-apt-compile: $(APT_LIBRARY) $(apt_http_object) $(apt_compat_object)
	@echo "[verify-apt] embedded APT archive, HTTP method, and compatibility API compile graph is up to date"

verify-apt-provenance: $(APT_VERIFY_SCRIPT) mk/apt.mk .gitmodules \
	$(APT_CONTRIB_INCLUDE_TARGET) $(APT_DEB_INCLUDE_TARGET)
	@$(APT_VERIFY_SCRIPT) provenance \
		"$(APT_SOURCE_DIR)" "$(APT_SOURCE_COMMIT)" "$(APT_SOURCE_URL)" \
		"$(APT_SOURCE_VERSION)" "$(APT_SOURCE_CXX_LEVEL)" \
		"$(APT_SOURCE_TRUST)" \
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
		"makefile mk/apt.mk mk/toolchain.mk mk/exec-compat.mk mk/rules.mk mk/verify.mk"

verify-ownership: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) ownership $(verify_ownership_files)

verify-size: $(VERIFY_SCRIPT)
	@$(VERIFY_SCRIPT) size "$(VERIFY_MAX_SOURCE_LINES)" $(verify_size_sources)

# Compile every supported Objective-C object and both direct helper binaries,
# but do not perform the application/package link.  This is the fast, Make-only
# migration proof used between source-splitting commits.
verify-compile: $(verify_objc_objects) $(POSTINST_BINARY) $(CFVERSION_BINARY)
	@echo "[verify] Objective-C/Objective-C++ compile graph is up to date"

# Runtime UI verification is intentionally opt-in because it installs a probe
# app and changes simulator appearance. The script restores appearance and
# removes its uniquely identified app when it exits.
verify-appearance-simulator: $(APPEARANCE_VERIFY_SCRIPT)
	@test -n "$(SIMULATOR_UDID)" || { \
		echo "SIMULATOR_UDID is required" >&2; exit 2; \
	}
	@$(APPEARANCE_VERIFY_SCRIPT) "$(SIMULATOR_UDID)" \
		"$(IOS12_SIMULATOR_UDID)" "$(MAKE)" "$(BUILD_DIR)/appearance-simulator"
