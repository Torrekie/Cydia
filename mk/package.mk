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

package: $(CYDIA_DEB) $(LPROJ_DEB)
