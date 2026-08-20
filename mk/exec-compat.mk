# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# Curated static exec compatibility for cydo.
#
# Keep this source manifest intentionally small.  Cydia needs libiosexec's
# execv fallback for iOS script execution, but does not need the dylib, account
# database shims, posix_spawn wrappers, or librecompat's broader libc surface.

EXEC_COMPAT_SOURCE_DIR := libiosexec
EXEC_COMPAT_SOURCE_URL := https://github.com/Remorix/libiosexec.git
EXEC_COMPAT_SOURCE_COMMIT := 9953dfb10a92415301dbb9cf2f79e4a01591c708
EXEC_COMPAT_LICENSE := LICENSE
EXEC_COMPAT_COPYRIGHT := debian/copyright
EXEC_COMPAT_SOURCE_NAMES := execv.c get_new_argv.c utils.c
EXEC_COMPAT_SOURCES := $(addprefix $(EXEC_COMPAT_SOURCE_DIR)/,$(EXEC_COMPAT_SOURCE_NAMES))

EXEC_COMPAT_GENERATED_DIR := $(GENERATED_DIR)/libiosexec
EXEC_COMPAT_OBJECT_DIR := $(OBJECT_DIR)/libiosexec
EXEC_COMPAT_LIBRARY := $(OBJECT_DIR)/libiosexec-exec.a
EXEC_COMPAT_PROVENANCE_STAMP := $(EXEC_COMPAT_GENERATED_DIR)/source.provenance
EXEC_COMPAT_CONFIG_STAMP := $(EXEC_COMPAT_GENERATED_DIR)/build.config
EXEC_COMPAT_PRIVATE_HEADER := $(EXEC_COMPAT_GENERATED_DIR)/libiosexec_private.h
EXEC_COMPAT_PATHS_HEADER := $(EXEC_COMPAT_GENERATED_DIR)/paths.h

EXEC_COMPAT_ROOTFUL_DEFAULT_PATH := /bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin/X11:/usr/games
EXEC_COMPAT_ROOTFUL_STD_PATH := /bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin

ifeq ($(PACKAGE_LAYOUT),rootless)
EXEC_COMPAT_PREFIXED_ROOT := 1
EXEC_COMPAT_SHEBANG_REDIRECT := $(PACKAGE_PREFIX)
EXEC_COMPAT_BSHELL := $(PACKAGE_PREFIX)/bin/sh
EXEC_COMPAT_CSHELL := $(PACKAGE_PREFIX)/bin/csh
EXEC_COMPAT_KSHELL := $(PACKAGE_PREFIX)/bin/ksh
EXEC_COMPAT_SHELLS := $(PACKAGE_PREFIX)/etc/shells
EXEC_COMPAT_PASSWD := $(PACKAGE_PREFIX)/etc/passwd
EXEC_COMPAT_MASTERPASSWD := $(PACKAGE_PREFIX)/etc/master.passwd
EXEC_COMPAT_GROUP := $(PACKAGE_PREFIX)/etc/group
EXEC_COMPAT_MP_DB := $(PACKAGE_PREFIX)/etc/pwd.db
EXEC_COMPAT_SMP_DB := $(PACKAGE_PREFIX)/etc/spwd.db
# Prefer bootstrap BSD utilities in /bin over /usr/bin, followed by sbin and
# local paths.  The unprefixed iOS paths remain available only as fallbacks.
EXEC_COMPAT_DEFAULT_PATH := $(PACKAGE_PREFIX)/bin:$(PACKAGE_PREFIX)/usr/bin:$(PACKAGE_PREFIX)/sbin:$(PACKAGE_PREFIX)/usr/sbin:$(PACKAGE_PREFIX)/usr/local/bin:$(PACKAGE_PREFIX)/usr/local/sbin:$(PACKAGE_PREFIX)/usr/bin/X11:$(PACKAGE_PREFIX)/usr/games:$(EXEC_COMPAT_ROOTFUL_DEFAULT_PATH)
EXEC_COMPAT_STD_PATH := $(PACKAGE_PREFIX)/bin:$(PACKAGE_PREFIX)/usr/bin:$(PACKAGE_PREFIX)/sbin:$(PACKAGE_PREFIX)/usr/sbin:$(PACKAGE_PREFIX)/usr/local/bin:$(PACKAGE_PREFIX)/usr/local/sbin:$(EXEC_COMPAT_ROOTFUL_STD_PATH)
else
EXEC_COMPAT_PREFIXED_ROOT := 0
EXEC_COMPAT_SHEBANG_REDIRECT := /
EXEC_COMPAT_BSHELL := /bin/sh
EXEC_COMPAT_CSHELL := /bin/csh
EXEC_COMPAT_KSHELL := /bin/ksh
EXEC_COMPAT_SHELLS := /etc/shells
EXEC_COMPAT_PASSWD := /etc/passwd
EXEC_COMPAT_MASTERPASSWD := /etc/master.passwd
EXEC_COMPAT_GROUP := /etc/group
EXEC_COMPAT_MP_DB := /etc/pwd.db
EXEC_COMPAT_SMP_DB := /etc/spwd.db
EXEC_COMPAT_DEFAULT_PATH := $(EXEC_COMPAT_ROOTFUL_DEFAULT_PATH)
EXEC_COMPAT_STD_PATH := $(EXEC_COMPAT_ROOTFUL_STD_PATH)
endif

EXEC_COMPAT_INPUTS := \
	$(EXEC_COMPAT_SOURCES) \
	$(EXEC_COMPAT_SOURCE_DIR)/libiosexec.h \
	$(EXEC_COMPAT_SOURCE_DIR)/libiosexec_private.h.in \
	$(EXEC_COMPAT_SOURCE_DIR)/paths.h.in \
	$(EXEC_COMPAT_SOURCE_DIR)/utils.h \
	$(EXEC_COMPAT_SOURCE_DIR)/$(EXEC_COMPAT_LICENSE) \
	$(EXEC_COMPAT_SOURCE_DIR)/$(EXEC_COMPAT_COPYRIGHT)
EXEC_COMPAT_OBJECTS := $(patsubst %.c,$(EXEC_COMPAT_OBJECT_DIR)/%.o,$(EXEC_COMPAT_SOURCE_NAMES))
EXEC_COMPAT_COMPILE_FLAGS := \
	-I$(EXEC_COMPAT_GENERATED_DIR) \
	-I$(EXEC_COMPAT_SOURCE_DIR) \
	-fvisibility=hidden \
	-DLIBIOSEXEC_INTERNAL=1 \
	-DLIBIOSEXEC_PREFIXED_ROOT=$(EXEC_COMPAT_PREFIXED_ROOT)

$(EXEC_COMPAT_PROVENANCE_STAMP): FORCE mk/exec-compat.mk .gitmodules $(EXEC_COMPAT_INPUTS)
	@mkdir -p $(dir $@)
	@actual_commit=$$(git -C $(EXEC_COMPAT_SOURCE_DIR) rev-parse HEAD 2>/dev/null || true); \
		if test "$$actual_commit" != "$(EXEC_COMPAT_SOURCE_COMMIT)"; then \
			echo "libiosexec is $$actual_commit; expected $(EXEC_COMPAT_SOURCE_COMMIT)" >&2; exit 1; \
		fi; \
		tree_state=$$( { \
			git -C $(EXEC_COMPAT_SOURCE_DIR) diff --no-ext-diff --binary HEAD; \
			git -C $(EXEC_COMPAT_SOURCE_DIR) ls-files --others --exclude-standard | \
			while IFS= read -r path; do cksum "$(EXEC_COMPAT_SOURCE_DIR)/$$path"; done; \
		} | cksum | awk '{ print $$1 ":" $$2 }'); \
		tmp="$@.tmp"; \
		{ \
			echo "source-dir=$(EXEC_COMPAT_SOURCE_DIR)"; \
			echo "source-url=$(EXEC_COMPAT_SOURCE_URL)"; \
			echo "commit=$$actual_commit"; \
			echo "tree-state=$$tree_state"; \
			echo "source-files=$(EXEC_COMPAT_SOURCE_NAMES)"; \
			echo "license=$(EXEC_COMPAT_LICENSE)"; \
			echo "copyright=$(EXEC_COMPAT_COPYRIGHT)"; \
		} >"$$tmp"; \
		if test -f "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

$(EXEC_COMPAT_CONFIG_STAMP): FORCE mk/exec-compat.mk mk/paths.mk mk/toolchain.mk makefile
	@mkdir -p $(dir $@)
	@config_state=$$(cksum makefile mk/paths.mk mk/toolchain.mk mk/exec-compat.mk | cksum | awk '{ print $$1 ":" $$2 }'); \
		tmp="$@.tmp"; \
		{ \
			echo "layout=$(PACKAGE_LAYOUT)"; \
			echo "package-prefix=$(PACKAGE_PREFIX)"; \
			echo "prefixed-root=$(EXEC_COMPAT_PREFIXED_ROOT)"; \
			echo "shebang-redirect=$(EXEC_COMPAT_SHEBANG_REDIRECT)"; \
			echo "architecture=$(arch)"; \
			echo "deployment-target=$(DEPLOYMENT_TARGET)"; \
			echo "platform=$(kind)"; \
			echo "compiler=$(gxx)"; \
			echo "sdk=$(sdk)"; \
			echo "default-path=$(EXEC_COMPAT_DEFAULT_PATH)"; \
			echo "standard-path=$(EXEC_COMPAT_STD_PATH)"; \
			echo "config-state=$$config_state"; \
		} >"$$tmp"; \
		if test -f "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

$(EXEC_COMPAT_PRIVATE_HEADER): $(EXEC_COMPAT_SOURCE_DIR)/libiosexec_private.h.in $(EXEC_COMPAT_CONFIG_STAMP)
	@mkdir -p $(dir $@)
	@tmp="$@.tmp"; \
		sed \
			-e 's|@DEFAULT_PATH@|$(EXEC_COMPAT_DEFAULT_PATH)|g' \
			-e 's|@SHEBANG_REDIRECT_PATH@|$(EXEC_COMPAT_SHEBANG_REDIRECT)|g' \
			$< >"$$tmp"; \
		if test -f "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

$(EXEC_COMPAT_PATHS_HEADER): $(EXEC_COMPAT_SOURCE_DIR)/paths.h.in $(EXEC_COMPAT_CONFIG_STAMP)
	@mkdir -p $(dir $@)
	@tmp="$@.tmp"; \
		sed \
			-e 's|@LIBIOSEXEC_BSHELL@|$(EXEC_COMPAT_BSHELL)|g' \
			-e 's|@LIBIOSEXEC_CSHELL@|$(EXEC_COMPAT_CSHELL)|g' \
			-e 's|@LIBIOSEXEC_KSHELL@|$(EXEC_COMPAT_KSHELL)|g' \
			-e 's|@LIBIOSEXEC_SHELLS@|$(EXEC_COMPAT_SHELLS)|g' \
			-e 's|@LIBIOSEXEC_DEFPATH@|$(EXEC_COMPAT_DEFAULT_PATH)|g' \
			-e 's|@LIBIOSEXEC_STDPATH@|$(EXEC_COMPAT_STD_PATH)|g' \
			-e 's|@LIBIOSEXEC_PASSWD@|$(EXEC_COMPAT_PASSWD)|g' \
			-e 's|@LIBIOSEXEC_MASTERPASSWD@|$(EXEC_COMPAT_MASTERPASSWD)|g' \
			-e 's|@LIBIOSEXEC_GROUP@|$(EXEC_COMPAT_GROUP)|g' \
			-e 's|@LIBIOSEXEC_MP_DB@|$(EXEC_COMPAT_MP_DB)|g' \
			-e 's|@LIBIOSEXEC_SMP_DB@|$(EXEC_COMPAT_SMP_DB)|g' \
			$< >"$$tmp"; \
		if test -f "$@" && cmp -s "$$tmp" "$@"; then rm -f "$$tmp"; else mv -f "$$tmp" "$@"; fi

$(EXEC_COMPAT_OBJECT_DIR)/%.o: $(EXEC_COMPAT_SOURCE_DIR)/%.c \
		$(EXEC_COMPAT_SOURCE_DIR)/libiosexec.h $(EXEC_COMPAT_SOURCE_DIR)/utils.h \
		$(EXEC_COMPAT_PRIVATE_HEADER) $(EXEC_COMPAT_PATHS_HEADER) \
		$(EXEC_COMPAT_PROVENANCE_STAMP) $(EXEC_COMPAT_CONFIG_STAMP)
	@mkdir -p $(dir $@)
	@echo "[cycc] $<"
	@$(cycc) -x c $(EXEC_COMPAT_COMPILE_FLAGS) -c -o $@ $<

$(EXEC_COMPAT_LIBRARY): $(EXEC_COMPAT_OBJECTS) $(EXEC_COMPAT_PROVENANCE_STAMP) $(EXEC_COMPAT_CONFIG_STAMP)
	@mkdir -p $(dir $@)
	@echo "[arch] $@"
	@tmp="$@.tmp"; rm -f "$$tmp"; \
		$(CYAR) rcs "$$tmp" $(EXEC_COMPAT_OBJECTS) && mv -f "$$tmp" "$@"
