#!/bin/bash
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

# Resolve tools and state from the bootstrap that installed this helper.  An
# explicit launcher override wins; otherwise the installed /var/jb path is the
# rootless signal.  Do not prefix unrelated system or user-data paths.
if [[ ${CYDIA_PACKAGE_LAYOUT:-} == rootless ]]; then
    CYDIA_PREFIX=/var/jb
elif [[ ${CYDIA_PACKAGE_LAYOUT:-} == rootful ]]; then
    CYDIA_PREFIX=
elif [[ ${BASH_SOURCE[0]} == /var/jb/* ]]; then
    CYDIA_PREFIX=/var/jb
else
    CYDIA_PREFIX=
fi

CYDIA_BIN=${CYDIA_PREFIX}/usr/bin
CYDIA_LIBEXEC=${CYDIA_PREFIX}/usr/libexec/cydia
CYDIA_STATE=${CYDIA_PREFIX}/var/lib/cydia
CYDIA_DPKG_STATE=${CYDIA_PREFIX}/var/lib/dpkg
CYDIA_DPKG=${CYDIA_BIN}/dpkg
CYDIA_DPKG_DEB=${CYDIA_BIN}/dpkg-deb
CYDIA_DPKG_QUERY=${CYDIA_BIN}/dpkg-query
CYDIA_APT_STATE=${CYDIA_PREFIX}/var/lib/apt
CYDIA_APT_CONFIG=${CYDIA_PREFIX}/etc/apt

export CYDIA_PREFIX CYDIA_BIN CYDIA_LIBEXEC CYDIA_STATE
export CYDIA_DPKG_STATE CYDIA_DPKG CYDIA_DPKG_DEB CYDIA_DPKG_QUERY
export CYDIA_APT_STATE CYDIA_APT_CONFIG
