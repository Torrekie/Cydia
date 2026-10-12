$(CYDIA_DEB): $(APP_BINARY) preinst prerm postrm $(POSTINST_BINARY) $(CFVERSION_BINARY) $(FIRMWARE_DISCOVERY_BINARY) $(CYDO_BINARY) $(images) $(apt_catalogs) $(shell find MobileCydia.app Library -type f) cydia.control NOTICE COPYING Cydia/ICU-LICENSE SDURLCache/LICENCE apt64/COPYING apt64/COPYING.GPL libiosexec/LICENSE libiosexec/debian/copyright xxhash/LICENSE vendor/compiler-rt/LICENSE.TXT scripts/write-application-identity.py
	rm -rf $(CYDIA_STAGE)
	mkdir -p $(CYDIA_STAGE_ROOT)/var/lib/cydia
	mkdir -p $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia
	cp -a NOTICE COPYING $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/
	cp -a NOTICE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/copyright
	cp -a Cydia/ICU-LICENSE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/
	cp -a SDURLCache/LICENCE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/SDURLCache-LICENCE
	cp -a apt64/COPYING $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/APT-COPYING
	cp -a apt64/COPYING.GPL $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/APT-COPYING.GPL
	cp -a xxhash/LICENSE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/XXHASH-LICENSE
	cp -a vendor/compiler-rt/LICENSE.TXT $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/COMPILER-RT-LICENSE
	cp -a libiosexec/LICENSE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/LIBIOSEXEC-LICENSE
	cp -a libiosexec/debian/copyright $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/LIBIOSEXEC-COPYRIGHT

	# APT sources, priority pins and global trust belong to the administrator.
	# Historical Cydia payload ownership is released by the maintscripts.

	mkdir -p $(CYDIA_STAGE_ROOT)/usr/libexec
	cp -a Library $(CYDIA_STAGE_ROOT)/usr/libexec/cydia
	# Retired filesystem-stashing helpers have no supported execution path.
	rm -f $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/asuser \
		$(CYDIA_STAGE_ROOT)/usr/libexec/cydia/free.sh $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/move.sh
	cp -a $(CFVERSION_BINARY) $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/cfversion
	cp -a $(FIRMWARE_DISCOVERY_BINARY) $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/firmware-discovery
	cp -a $(CYDO_BINARY) $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/cydo

	mkdir -p $(CYDIA_STAGE_ROOT)/Applications
	cp -a MobileCydia.app $(CYDIA_STAGE_ROOT)/Applications/Cydia.app
	rm -rf $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/*.lproj
	cp -a $(APP_BINARY) $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/Cydia
	cp -a $(APT_LOCALE_DIR) $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/APTLocale

	for meth in bzip2 gzip lzma http https store $(methods); do ln -s Cydia $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/"$${meth}"; done

	cd $(IMAGE_DIR)/MobileCydia.app && find . -name '*.png' -exec cp -af {} $(abspath $(CYDIA_STAGE_ROOT))/Applications/Cydia.app/{} ';'
	@echo "[sign] Cydia.app"
	@$(LDID) -T0 -Sentitlements.xml $(CYDIA_STAGE_ROOT)/Applications/Cydia.app
	@python3 scripts/write-application-identity.py "$(LDID)" \
		"$(CYDIA_STAGE_ROOT)/Applications/Cydia.app/Cydia" "$(CYDIA_STAGE_ROOT)/usr/libexec/cydia/application.identities"

	mkdir -p $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/Sources

	mkdir -p $(CYDIA_STAGE)/DEBIAN
	CYDIA_PACKAGE_EPOCH=$(PACKAGE_EPOCH) ./control.sh cydia.control $(CYDIA_STAGE) $(PACKAGE_ARCH) $(PACKAGE_PREFIX) >$(CYDIA_STAGE)/DEBIAN/control
	@for script in preinst prerm postrm; do \
		cat Library/shared-config-lifecycle.sh "$$script" >$(CYDIA_STAGE)/DEBIAN/"$$script"; \
		chmod 0755 $(CYDIA_STAGE)/DEBIAN/"$$script"; \
	done
	cp -a Library/shared-config-lifecycle.sh $(CYDIA_STAGE)/DEBIAN/cydia-shared-config-lifecycle
	chmod 0755 $(CYDIA_STAGE)/DEBIAN/cydia-shared-config-lifecycle
	@if test -n "$(PACKAGE_PREFIX)"; then \
		for file in $(CYDIA_STAGE)/DEBIAN/preinst $(CYDIA_STAGE)/DEBIAN/prerm $(CYDIA_STAGE)/DEBIAN/postrm \
			$(CYDIA_STAGE)/DEBIAN/cydia-shared-config-lifecycle $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/*; do \
			if test -f "$$file" && head -n 1 "$$file" | grep -q '^#!/bin/'; then \
				sed '1s@#!/bin/@#!$(PACKAGE_PREFIX)/bin/@' "$$file" >"$$file.tmp"; \
				cat "$$file.tmp" >"$$file"; rm "$$file.tmp"; \
			fi; \
		done; \
	fi
	@if test -n "$(PACKAGE_PREFIX)"; then \
		sed 's@ /@ $(PACKAGE_PREFIX)/@g' triggers >$(CYDIA_STAGE)/DEBIAN/triggers; \
	else \
		cp -a triggers $(CYDIA_STAGE)/DEBIAN/triggers; \
	fi
	cp -a $(POSTINST_BINARY) $(CYDIA_STAGE)/DEBIAN/postinst

	@commit_epoch="$$(git log -1 --no-patch --format='%ct' 2>/dev/null || true)"; \
	stamp=""; \
	if test -n "$$commit_epoch"; then \
		stamp="$$(date -u -d "@$$commit_epoch" +"%Y%m%d%H%M.%S" 2>/dev/null || \
			date -u -j -f "%s" +"%Y%m%d%H%M.%S" "$$commit_epoch" 2>/dev/null || true)"; \
	fi; \
	if test -n "$$stamp"; then \
		TZ=UTC find $(CYDIA_STAGE) -exec touch -h -t "$$stamp" {} +; \
	fi

	# Preserve the caller's groups on exec; authorization precedes explicit group elevation.
	chmod 4755 $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/cydo

	mkdir -p $(dir $@)
	$(dpkg) -b $(CYDIA_STAGE) $@
	@echo "$$(wc -c < $@) bytes $@"

$(LPROJ_DEB): $(shell find MobileCydia.app -name '*.strings') cydia-lproj.control
	rm -rf $(LPROJ_STAGE)
	mkdir -p $(LPROJ_STAGE_ROOT)/Applications/Cydia.app

	cp -a MobileCydia.app/*.lproj $(LPROJ_STAGE_ROOT)/Applications/Cydia.app

	mkdir -p $(LPROJ_STAGE)/DEBIAN
	CYDIA_PACKAGE_EPOCH=$(PACKAGE_EPOCH) ./control.sh cydia-lproj.control $(LPROJ_STAGE) $(PACKAGE_ARCH) $(PACKAGE_PREFIX) >$(LPROJ_STAGE)/DEBIAN/control

	mkdir -p $(dir $@)
	$(dpkg) -b $(LPROJ_STAGE) $@
	@echo "$$(wc -c < $@) bytes $@"

package: $(CYDIA_DEB) $(LPROJ_DEB)
