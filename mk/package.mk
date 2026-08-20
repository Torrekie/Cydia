$(CYDIA_DEB): $(APP_BINARY) preinst $(POSTINST_BINARY) $(CFVERSION_BINARY) $(SETNSFPN_BINARY) $(CYDO_BINARY) $(images) $(shell find MobileCydia.app Library LaunchDaemons -type f) cydia.control cydia.preferences NOTICE COPYING Cydia/ICU-LICENSE SDURLCache/LICENCE apt64/COPYING apt64/COPYING.GPL libiosexec/LICENSE libiosexec/debian/copyright
	rm -rf $(CYDIA_STAGE)
	mkdir -p $(CYDIA_STAGE_ROOT)/var/lib/cydia
	mkdir -p $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia
	cp -a NOTICE COPYING $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/
	cp -a NOTICE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/copyright
	cp -a Cydia/ICU-LICENSE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/
	cp -a SDURLCache/LICENCE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/SDURLCache-LICENCE
	cp -a apt64/COPYING $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/APT-COPYING
	cp -a apt64/COPYING.GPL $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/APT-COPYING.GPL
	cp -a libiosexec/LICENSE $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/LIBIOSEXEC-LICENSE
	cp -a libiosexec/debian/copyright $(CYDIA_STAGE_ROOT)/usr/share/doc/cydia/LIBIOSEXEC-COPYRIGHT

	mkdir -p $(CYDIA_STAGE_ROOT)/etc/apt/apt.conf.d
	mkdir -p $(CYDIA_STAGE_ROOT)/etc/apt/preferences.d
	mkdir -p $(CYDIA_STAGE_ROOT)/etc/apt/trusted.gpg.d
	mkdir -p $(CYDIA_STAGE_ROOT)/etc/apt/sources.list.d
	cp -a cydia.preferences $(CYDIA_STAGE_ROOT)/etc/apt/preferences.d/cydia
	cp -a Trusted.gpg/. $(CYDIA_STAGE_ROOT)/etc/apt/trusted.gpg.d/
	cp -a Sources.list/. $(CYDIA_STAGE_ROOT)/etc/apt/sources.list.d/

	mkdir -p $(CYDIA_STAGE_ROOT)/usr/libexec
	cp -a Library $(CYDIA_STAGE_ROOT)/usr/libexec/cydia
	cp -a $(CFVERSION_BINARY) $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/cfversion
	cp -a $(SETNSFPN_BINARY) $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/setnsfpn
	cp -a $(CYDO_BINARY) $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/cydo

	mkdir -p $(CYDIA_STAGE_ROOT)/Library
	cp -a LaunchDaemons $(CYDIA_STAGE_ROOT)/Library/LaunchDaemons
	@if test -n "$(PACKAGE_PREFIX)"; then \
		file=$(CYDIA_STAGE_ROOT)/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist; \
		sed \
			-e 's@/bin/bash@$(PACKAGE_PREFIX)/bin/bash@g' \
			-e 's@/usr/libexec/cydia@$(PACKAGE_PREFIX)/usr/libexec/cydia@g' \
			"$$file" >"$$file.tmp"; \
		mv -f "$$file.tmp" "$$file"; \
	fi

	mkdir -p $(CYDIA_STAGE_ROOT)/Applications
	cp -a MobileCydia.app $(CYDIA_STAGE_ROOT)/Applications/Cydia.app
	rm -rf $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/*.lproj
	cp -a $(APP_BINARY) $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/Cydia

	for meth in bzip2 gzip lzma http https store $(methods); do ln -s Cydia $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/"$${meth}"; done

	cd $(IMAGE_DIR)/MobileCydia.app && find . -name '*.png' -exec cp -af {} $(abspath $(CYDIA_STAGE_ROOT))/Applications/Cydia.app/{} ';'
	@echo "[sign] Cydia.app"
	@$(LDID) -T0 -Sentitlements.xml $(CYDIA_STAGE_ROOT)/Applications/Cydia.app

	mkdir -p $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/Sources
	ln -s $(PACKAGE_PREFIX)/usr/share/bigboss/icons/bigboss.png $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/Sources/apt.bigboss.us.com.png
	ln -s $(PACKAGE_PREFIX)/usr/share/bigboss/icons/planetiphones.png $(CYDIA_STAGE_ROOT)/Applications/Cydia.app/Sections/"Planet-iPhones Mods.png"

	mkdir -p $(CYDIA_STAGE)/DEBIAN
	CYDIA_PACKAGE_EPOCH=$(PACKAGE_EPOCH) ./control.sh cydia.control $(CYDIA_STAGE) $(PACKAGE_ARCH) $(PACKAGE_PREFIX) >$(CYDIA_STAGE)/DEBIAN/control
	cp -a preinst $(CYDIA_STAGE)/DEBIAN/
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

	chmod 6755 $(CYDIA_STAGE_ROOT)/usr/libexec/cydia/cydo

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
