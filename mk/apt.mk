# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# Embedded APT provenance and reviewed source manifest.
#
# These values describe the exact baseline committed by the apt64 gitlink.  An
# upstream update must change the gitlink, provenance values, and source groups
# together so that a new APT file cannot silently enter the application through
# a wildcard.

APT_SOURCE_DIR := apt64
APT_SOURCE_COMMIT := 0c7c5febb3308fc194b79fe1d2a054c80a321a77
APT_SOURCE_BASE_COMMIT := ed053de346d92c1a4218a7b80a20158f3535fe2a
APT_SOURCE_URL := https://salsa.debian.org/apt-team/apt.git
APT_SOURCE_VERSION := 2.7.9
APT_SOURCE_CXX_LEVEL := 17
APT_SOURCE_CXX_STANDARD := c++17
# The inherited upstream source has no recorded signed tag or signer identity;
# APT_SOURCE_COMMIT is the local Cydia compatibility commit above that exact
# 2.7.9 base.
# scripts/checkout-apt-source.sh regenerates it from the tracked mail patches
# in apt-extra/apt-2.7.9-cydia.patch, preserving the exact gitlink.
# Keep that limitation machine-visible until a reviewed upstream import adds a
# real signature-verification gate.
APT_SOURCE_TRUST := legacy-unverified
# APT 2.7.9 uses XXH3 for cache hashing.  iPhoneOS does not ship libxxhash,
# so use the pinned header-only implementation below and keep its exact source
# commit in the build provenance.
XXHASH_SOURCE_DIR := xxhash
XXHASH_SOURCE_COMMIT := bbb27a5efb85b92a0486cf361a8635715a53f6ba
XXHASH_SOURCE_URL := https://github.com/Cyan4973/xxHash.git
XXHASH_SOURCE_VERSION := 0.8.2
# APT_PKG_MAJOR/MINOR identify the ABI/SOVERSION; RELEASE is the compatible
# library release component in the version triplet.
APT_ABI_MAJOR := 6
APT_ABI_MINOR := 0
APT_ABI_RELEASE := 0
APT_LICENSE_FILES := COPYING COPYING.GPL
# These catalogs match the embedded source, independent of bootstrap locales.
# Upstream excludes Hebrew at its translator's request (po/CMakeLists.txt).
MSGFMT ?= msgfmt
APT_MESSAGE_DOMAIN := cydia-apt-$(APT_SOURCE_VERSION)
APT_LOCALE_DIR := $(GENERATED_DIR)/apt-locale
apt_catalog_languages := $(filter-out he,$(notdir $(basename $(wildcard $(APT_SOURCE_DIR)/po/*.po))))
apt_catalogs := $(foreach language,$(apt_catalog_languages),$(APT_LOCALE_DIR)/$(language)/LC_MESSAGES/$(APT_MESSAGE_DOMAIN).mo)
APT_PROVENANCE_STAMP := $(GENERATED_DIR)/apt64/apt-provenance.stamp
APT_TRIEHASH := scripts/apt-triehash.pl
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
    Cydia/AptProviderServer.cpp \
    Cydia/AptProviderServerTransport.cpp \
    Cydia/AptProviderArchiveAuthorization.cpp \
    Cydia/AptNativeBackend.cpp \
    Cydia/AptBackendRecovery.cpp \
    Cydia/AptRecoveryAuthority.cpp \
    Cydia/AptRecoveryDependencyInspector.cpp \
    Cydia/AptRecoveryInitialization.cpp \
    Cydia/AptRecoveryInstalledAuthority.cpp \
    Cydia/AptRecoverySnapshot.cpp \
    Cydia/AptRecoveryTrust.cpp \
    Cydia/AptRecoveryWorker.cpp \
    Cydia/AptRecoveryPackageManager.cpp \
    Cydia/AptWorkerAcquireStatus.cpp \
    Cydia/AptProviderSelectionValues.cpp \
    Cydia/AptProviderBrokerValues.cpp \
    Cydia/AptProviderBroker.cpp \
    Cydia/TransactionReview.mm \
    Cydia/DatabaseSnapshots.mm \
    Cydia/Database+RuntimeProviders.mm \
    Cydia/AptProviderSelection.cpp \
    Cydia/AptProviderBrokerPrivileged.cpp \
    Cydia/AptProviderArchiveEvidence.cpp \
    Cydia/APTSrvCompat.cpp \
    Cydia/AdvancedSettingsController.mm \
    Cydia/AptBackend.cpp \
    Cydia/AptBackendFacade.cpp \
    Cydia/AptBackendOperations.cpp \
    Cydia/AptEmbeddedBackend.cpp \
    Cydia/AptRemoteBackend.cpp \
    Cydia/AptAuthorizedArchives.cpp \
    Cydia/AptCompatibility.cpp \
    Cydia/AptProviderClient.cpp \
    Cydia/AptProviderLaunch.cpp \
    Cydia/AptProviderDpkgState.cpp \
    Cydia/AptProviderDpkgStateCapture.cpp \
    Cydia/AptProviderProtocol.cpp \
    Cydia/AptProviderReview.cpp \
    Cydia/AptProviderComponentSuccession.cpp \
    Cydia/AptProviderTransactionLease.cpp \
    Cydia/AptProviderTriggerEvidenceCapture.cpp \
    Cydia/AptProviderTriggerEvidence.cpp \
    Cydia/AptProviderTriggerEvidenceProtected.cpp \
    Cydia/RuntimeSnapshotInputs.cpp \
    Cydia/AptProviderSession.cpp \
    Cydia/AptRuntime.cpp \
    Cydia/SourceAddController+Discovery.mm \
    Cydia/SourceAddController.mm \
    Cydia/SourceAddSession.mm \
    Cydia/SourceDiscoveryTransport.mm \
    Cydia/SourcePreflight.cpp \
    Cydia/SourceKeyDiscovery.mm \
    Cydia/AptVersionPolicy.cpp \
    Cydia/PackageArchiveReader.cpp \
    Cydia/BootstrapAccessController.mm \
    Cydia/CapabilityController.mm \
    Cydia/KeyringImportController.mm \
    Cydia/PrivilegedConfig.cpp \
    Cydia/PrivilegedClient.mm \
    Cydia/RuntimeAccessController.mm \
    Cydia/RuntimeState.cpp \
    Cydia/SettingsStore.mm \
    Cydia/ConfirmationController.mm \
    Cydia/ConfirmationControllerProbe.mm \
    Cydia/ConfirmationViewModel.mm \
    Cydia/Database.mm \
    Cydia/Database+SourceOperations.mm \
    Cydia/DatabaseStatus.mm \
    Cydia/FetchDiagnostics.mm \
    Cydia/Package+Metadata.mm \
    Cydia/Package+Operations.mm \
    Cydia/Package.mm \
    Cydia/PackageControllers.mm \
    Cydia/PackageUnavailableController.mm \
    Cydia/PackageUnavailableProbe.mm \
    Cydia/ProgressController.mm \
    Cydia/ProgressEvent.mm \
    Cydia/Relations.mm \
    Cydia/Source.mm \
    Sources.mm \
    MobileCydia.mm

apt_core_sources := \
    acquire-item.cc \
    acquire-method.cc \
    acquire-worker.cc \
    acquire.cc \
    algorithms.cc \
    aptconfiguration.cc \
    cachefile.cc \
    cachefilter-patterns.cc \
    cachefilter.cc \
    cacheset.cc \
    cdrom.cc \
    clean.cc \
    depcache.cc \
    dirstream.cc \
    edsp.cc \
    indexcopy.cc \
    indexfile.cc \
    init.cc \
    install-progress.cc \
    metaindex.cc \
    orderlist.cc \
    packagemanager.cc \
    pkgcache.cc \
    pkgcachegen.cc \
    pkgrecords.cc \
    pkgsystem.cc \
    policy.cc \
    prettyprinters.cc \
    sourcelist.cc \
    srcrecords.cc \
    statechanges.cc \
    tagfile.cc \
    update.cc \
    upgrade.cc \
    version.cc \
    versionmatch.cc

apt_deb_sources := \
    debfile.cc \
    debindexfile.cc \
    deblistparser.cc \
    debmetaindex.cc \
    debrecords.cc \
    debsrcrecords.cc \
    debsystem.cc \
    debversion.cc \
    dpkgpm.cc

apt_contrib_sources := \
    arfile.cc \
    cdromutl.cc \
    cmndline.cc \
    configuration.cc \
    error.cc \
    extracttar.cc \
    fileutl.cc \
    gpgv.cc \
    hashes.cc \
    mmap.cc \
    netrc.cc \
    progress.cc \
    proxy.cc \
    strutl.cc

# APT's rred method uses the small command-line parser from apt-private.  Keep
# that parser in the embedded archive; the remaining apt-private commands are
# intentionally not part of Cydia.
apt_excluded_contrib_sources := srvrec.cc
apt_private_sources := apt-private/private-cmndline.cc apt-private/private-main.cc

methods := copy file rred gpgv
apt_method_sources := store.cc basehttp.cc connect.cc $(addsuffix .cc,$(methods))
apt_excluded_method_sources := cdrom.cc ftp.cc mirror.cc rfc2553emu.cc rsh.cc
apt_http_source := $(APT_SOURCE_DIR)/methods/http.cc

apt_sources := $(addprefix $(APT_SOURCE_DIR)/apt-pkg/,$(apt_core_sources))
apt_sources += $(addprefix $(APT_SOURCE_DIR)/apt-pkg/deb/,$(apt_deb_sources))
apt_sources += $(addprefix $(APT_SOURCE_DIR)/apt-pkg/contrib/,$(apt_contrib_sources))
apt_sources += $(addprefix $(APT_SOURCE_DIR)/methods/,$(apt_method_sources))
apt_sources += $(addprefix $(APT_SOURCE_DIR)/,$(apt_private_sources))
