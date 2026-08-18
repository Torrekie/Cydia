dirs := Menes CyteKit Cydia SDURLCache

code := $(foreach dir,$(dirs),$(wildcard $(foreach ext,h hpp c cpp m mm,$(dir)/*.$(ext))))
code := $(filter-out SDURLCache/SDURLCacheTests.m,$(code))
code += MobileCydia.mm Version.mm iPhonePrivate.h Cytore.hpp lookup3.c Sources.h Sources.mm DiskUsage.cpp
code += apt64/methods/http.cc

source := $(filter %.m,$(code)) $(filter %.mm,$(code))
source += $(filter %.c,$(code)) $(filter %.cpp,$(code)) $(filter %.cc,$(code))
header := $(filter %.h,$(code)) $(filter %.hpp,$(code)) $(filter %.hh,$(code))

object := $(source)
object := $(object:.c=.o)
object := $(object:.cpp=.o)
object := $(object:.cc=.o)
object := $(object:.m=.o)
object := $(object:.mm=.o)
object := $(object:%=$(OBJECT_DIR)/%)

methods := copy file rred gpgv

libapt64 :=
libapt64 += $(wildcard apt64/apt-pkg/*.cc)
libapt64 += $(wildcard apt64/apt-pkg/deb/*.cc)
libapt64 += $(wildcard apt64/apt-pkg/contrib/*.cc)
libapt64 += apt64/methods/store.cc
libapt64 += $(patsubst %,apt64/methods/%.cc,$(methods))
libapt64 := $(filter-out %/srvrec.cc,$(libapt64))
libapt64 := $(patsubst %.cc,$(OBJECT_DIR)/%.o,$(libapt64))

tagfile_keys_dir := $(GENERATED_DIR)/apt64/apt-pkg
tagfile_keys_header := $(tagfile_keys_dir)/tagfile-keys.h
tagfile_keys_source := $(tagfile_keys_dir)/tagfile-keys.cc
tagfile_keys_stamp := $(tagfile_keys_dir)/tagfile-keys.stamp
tagfile_keys_object := $(OBJECT_DIR)/apt64/apt-pkg/tagfile-keys.o
libapt64 += $(tagfile_keys_object)

images := $(shell find MobileCydia.app/ -type f -name '*.png')
images := $(images:%=$(IMAGE_DIR)/%)
