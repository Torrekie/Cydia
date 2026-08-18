.DELETE_ON_ERROR:
.SECONDARY:

include mk/paths.mk
include mk/toolchain.mk
include mk/sources.mk
include mk/rules.mk
include mk/package.mk

.PHONY: all clean package MobileCydia postinst cfversion setnsfpn cydo FORCE
