dpkg := dpkg-deb --root-owner-group -Zxz
version := $(shell ./version.sh)
DEPLOYMENT_TARGET ?= 12.0
BUILD_DIR ?= build
PACKAGE_LAYOUT ?= rootful

ifeq ($(PACKAGE_LAYOUT),rootless)
PACKAGE_PREFIX := /var/jb
PACKAGE_ARCH := iphoneos-arm64
else ifeq ($(PACKAGE_LAYOUT),rootful)
PACKAGE_PREFIX :=
PACKAGE_ARCH := iphoneos-arm
else
$(error unsupported PACKAGE_LAYOUT '$(PACKAGE_LAYOUT)'; expected rootful or rootless)
endif

OBJECT_DIR := $(BUILD_DIR)/objects
GENERATED_DIR := $(BUILD_DIR)/generated
IMAGE_DIR := $(BUILD_DIR)/images
BIN_DIR := $(BUILD_DIR)/bin
ARCHIVE_DIR := $(BUILD_DIR)/archive
PACKAGE_DIR := $(BUILD_DIR)/packages
STAGE_DIR := $(BUILD_DIR)/stage

APP_BINARY := $(BIN_DIR)/MobileCydia
POSTINST_BINARY := $(BIN_DIR)/postinst
CYDO_BINARY := $(BIN_DIR)/cydo
SETNSFPN_BINARY := $(BIN_DIR)/setnsfpn
CFVERSION_BINARY := $(BIN_DIR)/cfversion
APT_LIBRARY := $(OBJECT_DIR)/libapt64.a
VERSION_HEADER := $(GENERATED_DIR)/Version.h
CYDIA_STAGE := $(STAGE_DIR)/cydia
LPROJ_STAGE := $(STAGE_DIR)/cydia-lproj
CYDIA_STAGE_ROOT := $(CYDIA_STAGE)$(PACKAGE_PREFIX)
LPROJ_STAGE_ROOT := $(LPROJ_STAGE)$(PACKAGE_PREFIX)
CYDIA_DEB = $(PACKAGE_DIR)/cydia_$(version)_$(PACKAGE_ARCH).deb
LPROJ_DEB = $(PACKAGE_DIR)/cydia-lproj_$(version)_$(PACKAGE_ARCH).deb
