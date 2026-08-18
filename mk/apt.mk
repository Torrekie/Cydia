# Embedded APT provenance and reviewed source manifest.
#
# These values describe the exact baseline committed by the apt64 gitlink.  An
# upstream update must change the gitlink, provenance values, and source groups
# together so that a new APT file cannot silently enter the application through
# a wildcard.

APT_SOURCE_DIR := apt64
APT_SOURCE_COMMIT := e4718f05d049c1a09fb9662cc3db2d4c5122defe
APT_SOURCE_URL := git://git.bingner.com/apt.git
APT_SOURCE_VERSION := 1.8.2
APT_SOURCE_CXX_LEVEL := 11
APT_SOURCE_CXX_STANDARD := c++11
# The inherited git:// source has no recorded signed tag or signer identity.
# Keep that limitation machine-visible until a reviewed upstream import adds a
# real signature-verification gate.
APT_SOURCE_TRUST := legacy-unverified
# APT_PKG_MAJOR/MINOR identify the ABI/SOVERSION; RELEASE is the compatible
# library release component in the version triplet.
APT_ABI_MAJOR := 5
APT_ABI_MINOR := 0
APT_ABI_RELEASE := 2
APT_LICENSE_FILES := COPYING COPYING.GPL
APT_PROVENANCE_STAMP := $(GENERATED_DIR)/apt64/apt-provenance.stamp
# APT headers use an `apt-pkg/...` include root.  Generate that small overlay
# inside BUILD_DIR from the selected source tree instead of relying on the
# repository's legacy convenience symlinks (which could mix revisions).
APT_INCLUDE_DIR := $(GENERATED_DIR)/apt64/include
APT_CONTRIB_INCLUDE_DIR := $(APT_INCLUDE_DIR)/contrib
APT_DEB_INCLUDE_DIR := $(APT_INCLUDE_DIR)/deb
APT_CONTRIB_INCLUDE_TARGET := $(APT_CONTRIB_INCLUDE_DIR)/apt-pkg
APT_DEB_INCLUDE_TARGET := $(APT_DEB_INCLUDE_DIR)/apt-pkg

# `verify-apt-api` can point at a separately fetched stable tag or upstream
# main checkout.  Make never fetches this tree itself.
APT_AUDIT_SOURCE_DIR ?= $(APT_SOURCE_DIR)
APT_AUDIT_CXX_STANDARD ?= $(APT_SOURCE_CXX_STANDARD)

# Translation units that directly or transitively consume libapt-pkg.  Keep
# this list explicit: an APT update must review every Cydia-facing API use,
# even when the source file itself does not include an apt-pkg header.
apt_api_sources := \
    Cydia/AptBackend.cpp \
    Cydia/AptCompatibility.cpp \
    Cydia/AptRuntime.cpp \
    Cydia/ConfirmationController.mm \
    Cydia/Database.mm \
    Cydia/DatabaseStatus.mm \
    Cydia/Package+Metadata.mm \
    Cydia/Package+Operations.mm \
    Cydia/Package.mm \
    Cydia/ProgressController.mm \
    Cydia/ProgressEvent.mm \
    Cydia/Relations.mm \
    Cydia/Source.mm \
    MobileCydia.mm

apt_core_sources := \
    acquire-item.cc \
    acquire-method.cc \
    acquire-worker.cc \
    acquire.cc \
    algorithms.cc \
    aptconfiguration.cc \
    cachefile.cc \
    cachefilter.cc \
    cacheset.cc \
    cdrom.cc \
    clean.cc \
    depcache.cc \
    edsp.cc \
    getservbyport_r.cc \
    indexcopy.cc \
    indexfile.cc \
    init.cc \
    install-progress.cc \
    memrchr.cc \
    metaindex.cc \
    orderlist.cc \
    packagemanager.cc \
    pkgcache.cc \
    pkgcachegen.cc \
    pkgrecords.cc \
    pkgsystem.cc \
    policy.cc \
    prettyprinters.cc \
    rawmemchr.cc \
    sourcelist.cc \
    srcrecords.cc \
    statechanges.cc \
    strchrnul.cc \
    tagfile-compat.cc \
    tagfile.cc \
    update.cc \
    upgrade.cc \
    version.cc \
    versionmatch.cc

apt_deb_sources := \
    debindexfile.cc \
    deblistparser.cc \
    debmetaindex.cc \
    debrecords.cc \
    debsrcrecords.cc \
    debsystem.cc \
    debversion.cc \
    dpkgpm.cc

apt_contrib_sources := \
    cdromutl.cc \
    cmndline.cc \
    configuration.cc \
    crc-16.cc \
    error.cc \
    fileutl.cc \
    gpgv.cc \
    hashes.cc \
    hashsum.cc \
    md5.cc \
    mmap.cc \
    netrc.cc \
    progress.cc \
    proxy.cc \
    sha1.cc \
    sha2_internal.cc \
    strutl.cc

# srvrec.cc has never been part of Cydia's embedded library.  Keep the
# exclusion explicit so an upstream source refresh must review it deliberately.
apt_excluded_contrib_sources := srvrec.cc

methods := copy file rred gpgv
apt_method_sources := store.cc basehttp.cc $(addsuffix .cc,$(methods))
apt_excluded_method_sources := cdrom.cc connect.cc ftp.cc mirror.cc rfc2553emu.cc rsh.cc
apt_http_source := $(APT_SOURCE_DIR)/methods/http.cc

apt_sources := $(addprefix $(APT_SOURCE_DIR)/apt-pkg/,$(apt_core_sources))
apt_sources += $(addprefix $(APT_SOURCE_DIR)/apt-pkg/deb/,$(apt_deb_sources))
apt_sources += $(addprefix $(APT_SOURCE_DIR)/apt-pkg/contrib/,$(apt_contrib_sources))
apt_sources += $(addprefix $(APT_SOURCE_DIR)/methods/,$(apt_method_sources))
