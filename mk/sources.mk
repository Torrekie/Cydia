dirs := Menes CyteKit Cydia SDURLCache

code := $(foreach dir,$(dirs),$(wildcard $(foreach ext,h hpp c cpp m mm,$(dir)/*.$(ext))))
code := $(filter-out SDURLCache/SDURLCacheTests.m,$(code))
code += MobileCydia.mm Version.mm iPhonePrivate.h Cytore.hpp lookup3.c Sources.h Sources.mm DiskUsage.cpp
code += $(apt_http_source)

# The embedded HTTP method has its own process-wide identity values.  Prefix
# them when it is linked into MobileCydia so they do not collide with Cydia's
# request-header state or CyteKit's hardware-machine state.
http_flags := \
    -DMachine_=CydiaHttpMachine_ \
    -DUniqueID_=CydiaHttpUniqueID_ \
    -DFirmware_=CydiaHttpFirmware_ \
    -Dlockdown_connect=CydiaLockdownConnect \
    -Dlockdown_copy_value=CydiaLockdownCopyValue \
    -Dlockdown_disconnect=CydiaLockdownDisconnect

source := $(filter %.m,$(code)) $(filter %.mm,$(code))
source += $(filter %.c,$(code)) $(filter %.cpp,$(code)) $(filter %.cc,$(code))
header := $(filter %.h,$(code)) $(filter %.hpp,$(code)) $(filter %.hh,$(code))
header += $(APT_PROVENANCE_STAMP) $(APT_CONTRIB_INCLUDE_TARGET) $(APT_DEB_INCLUDE_TARGET)

object := $(source)
object := $(object:.c=.o)
object := $(object:.cpp=.o)
object := $(object:.cc=.o)
object := $(object:.m=.o)
object := $(object:.mm=.o)
object := $(object:%=$(OBJECT_DIR)/%)

# Keep APT objects in a stable build namespace even when an update is audited
# from a different source directory.
apt_http_object := $(OBJECT_DIR)/apt64/methods/http.o
apt_compat_object := $(OBJECT_DIR)/Cydia/AptCompatibility.o
object := $(filter-out $(OBJECT_DIR)/$(apt_http_source:.cc=.o),$(object))
object += $(apt_http_object)

libapt64 := $(patsubst $(APT_SOURCE_DIR)/%.cc,$(OBJECT_DIR)/apt64/%.o,$(apt_sources))

tagfile_keys_dir := $(GENERATED_DIR)/apt64/apt-pkg
tagfile_keys_header := $(tagfile_keys_dir)/tagfile-keys.h
tagfile_keys_source := $(tagfile_keys_dir)/tagfile-keys.cc
tagfile_keys_stamp := $(tagfile_keys_dir)/tagfile-keys.stamp
tagfile_keys_object := $(OBJECT_DIR)/apt64/apt-pkg/tagfile-keys.o
libapt64 += $(tagfile_keys_object)

images := $(shell find MobileCydia.app/ -type f -name '*.png')
images := $(images:%=$(IMAGE_DIR)/%)
