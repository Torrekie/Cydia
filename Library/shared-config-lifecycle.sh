#!/bin/bash
# Preserve administrator-controlled APT files when historical Cydia payload
# ownership is retired. This library is embedded in the removal scripts so
# purge remains safe after dpkg removes the package's other control files.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

cydia_shared_error() {
    printf 'cydia shared configuration: %s\n' "$*" >&2
    return 1
}

cydia_shared_absolute() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *$'\n'*|*$'\r'*|*'//'*|*/../*|*/./*|*/..|*/.) return 1 ;;
    esac
}

cydia_shared_logical() {
    local path="$1"
    case "$path" in ./*) path="${path#./}" ;; esac
    case "$path" in /*) ;; *) path="/$path" ;; esac
    cydia_shared_absolute "$path" || return 1
    printf '%s\n' "$path"
}

cydia_shared_candidate() {
    case "$1" in
        /etc/apt/sources.list.d/cydia.list|*/etc/apt/sources.list.d/cydia.list|\
        /etc/apt/preferences.d/cydia|*/etc/apt/preferences.d/cydia|\
        /etc/apt/trusted.gpg.d/*.gpg|*/etc/apt/trusted.gpg.d/*.gpg) return 0 ;;
    esac
    return 1
}

cydia_shared_safe_owned() {
    local path="$1" type="$2" attributes owner mode
    [[ ! -L "$path" ]] || return 1
    if [[ "$type" == directory ]]; then
        [[ -d "$path" ]] || return 1
    else
        [[ -f "$path" ]] || return 1
    fi
    attributes=$(stat -c '%u %a' "$path" 2>/dev/null) ||
        attributes=$(stat -f '%u %Lp' "$path" 2>/dev/null) || return 1
    read -r owner mode <<< "$attributes"
    [[ "$owner" == "$CYDIA_SHARED_UID" && "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

cydia_shared_initialize() {
    CYDIA_SHARED_QUERY=$(command -v dpkg-query) ||
        { cydia_shared_error 'dpkg-query is unavailable'; return 1; }
    CYDIA_SHARED_DIVERT=$(command -v dpkg-divert) ||
        { cydia_shared_error 'dpkg-divert is unavailable'; return 1; }
    cydia_shared_absolute "$CYDIA_SHARED_QUERY" &&
        cydia_shared_absolute "$CYDIA_SHARED_DIVERT" || return 1
    CYDIA_SHARED_UID=$(id -u) || return 1
    CYDIA_SHARED_ROOT="${DPKG_ROOT:-/}"
    CYDIA_SHARED_ROOT="${CYDIA_SHARED_ROOT%/}"
    [[ -n "$CYDIA_SHARED_ROOT" ]] || CYDIA_SHARED_ROOT=/
    cydia_shared_absolute "$CYDIA_SHARED_ROOT" ||
        { cydia_shared_error 'invalid dpkg installation root'; return 1; }

    CYDIA_SHARED_ADMIN="${DPKG_ADMINDIR:-}"
    if [[ -z "$CYDIA_SHARED_ADMIN" ]]; then
        local list
        list=$("$CYDIA_SHARED_QUERY" --control-path cydia postinst 2>/dev/null) ||
            { cydia_shared_error 'dpkg did not provide its administrative directory'; return 1; }
        case "$list" in */info/cydia.postinst) CYDIA_SHARED_ADMIN="${list%/info/cydia.postinst}" ;;
            *) cydia_shared_error 'unexpected dpkg control-file location'; return 1 ;; esac
    fi
    cydia_shared_absolute "$CYDIA_SHARED_ADMIN" || return 1
    CYDIA_SHARED_ADMIN=$(CDPATH= cd -P -- "$CYDIA_SHARED_ADMIN" && pwd -P) || return 1
    CYDIA_SHARED_JOURNAL="$CYDIA_SHARED_ADMIN/cydia-shared-config-handoff"
    CYDIA_SHARED_LIST="$CYDIA_SHARED_ADMIN/info/cydia.list"
}

cydia_shared_file_list() {
    if [[ ! -e "$CYDIA_SHARED_LIST" && ! -L "$CYDIA_SHARED_LIST" ]]; then
        return 0
    fi
    cydia_shared_safe_owned "$CYDIA_SHARED_LIST" file ||
        { cydia_shared_error 'unsafe Cydia payload ownership metadata'; return 1; }
    # The fixed package ID and dpkg's active administrative directory identify
    # its payload list. --control-path deliberately omits dpkg-generated list
    # metadata, so it cannot prove this ownership on our behalf.
    [[ -s "$CYDIA_SHARED_LIST" ]] || return 0
    printf '%s\n' "$CYDIA_SHARED_LIST"
}

cydia_shared_listed() {
    local list="$1" path="$2" line normalized
    [[ -n "$list" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        normalized=$(cydia_shared_logical "$line") || continue
        [[ "$normalized" != "$path" ]] || return 0
    done < "$list"
    return 1
}

cydia_shared_diversion() {
    "$CYDIA_SHARED_DIVERT" --admindir "$CYDIA_SHARED_ADMIN" \
        --instdir "$CYDIA_SHARED_ROOT" "$@"
}

cydia_shared_journal_ready() {
    if [[ ! -e "$CYDIA_SHARED_JOURNAL" && ! -L "$CYDIA_SHARED_JOURNAL" ]]; then
        (umask 077; mkdir "$CYDIA_SHARED_JOURNAL") || return 1
    fi
    cydia_shared_safe_owned "$CYDIA_SHARED_JOURNAL" directory ||
        { cydia_shared_error 'unsafe shared-configuration journal'; return 1; }
}

cydia_shared_read_record() {
    local record="$1" line key value seen='|' version package
    cydia_shared_safe_owned "$record" file ||
        { cydia_shared_error 'unsafe handoff record'; return 1; }
    CYDIA_SHARED_RECORD_PATH= CYDIA_SHARED_RECORD_DIVERT=
    CYDIA_SHARED_RECORD_VERSION= CYDIA_SHARED_RECORD_KIND=
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}"; value="${line#*=}"
        case "$seen" in *"|$key|"*) return 1 ;; esac
        seen="$seen$key|"
        case "$key" in
            version) version="$value" ;; package) package="$value" ;;
            old_version) CYDIA_SHARED_RECORD_VERSION="$value" ;;
            path) CYDIA_SHARED_RECORD_PATH="$value" ;;
            divert) CYDIA_SHARED_RECORD_DIVERT="$value" ;;
            kind) CYDIA_SHARED_RECORD_KIND="$value" ;;
            *) return 1 ;;
        esac
    done < "$record"
    [[ "$version" == 1 && "$package" == cydia &&
        -n "$CYDIA_SHARED_RECORD_VERSION" ]] || return 1
    case "$CYDIA_SHARED_RECORD_KIND" in ordinary|conffile) ;; *) return 1 ;; esac
    cydia_shared_absolute "$CYDIA_SHARED_RECORD_PATH" &&
        cydia_shared_candidate "$CYDIA_SHARED_RECORD_PATH" &&
        cydia_shared_absolute "$CYDIA_SHARED_RECORD_DIVERT" || return 1
    case "$CYDIA_SHARED_RECORD_DIVERT" in
        "$CYDIA_SHARED_RECORD_PATH".cydia-handoff.*.distrib) ;;
        *) return 1 ;;
    esac
}

cydia_shared_existing_record() {
    local wanted="$1" record found=
    [[ -d "$CYDIA_SHARED_JOURNAL" ]] || return 1
    cydia_shared_safe_owned "$CYDIA_SHARED_JOURNAL" directory || return 2
    for record in "$CYDIA_SHARED_JOURNAL"/*.record; do
        [[ -e "$record" || -L "$record" ]] || continue
        cydia_shared_read_record "$record" || return 2
        if [[ "$CYDIA_SHARED_RECORD_PATH" == "$wanted" ]]; then
            [[ -z "$found" ]] || return 2
            found="$record"
        fi
    done
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

cydia_shared_kind() {
    local wanted="$1" conffiles line
    conffiles=$("$CYDIA_SHARED_QUERY" --admindir "$CYDIA_SHARED_ADMIN" \
        --show --showformat='${Conffiles}\n' cydia 2>/dev/null) || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+(.+)[[:space:]][0-9a-fA-F]{32}([[:space:]]+obsolete)?$ ]]; then
            [[ "${BASH_REMATCH[1]}" != "$wanted" ]] || { printf 'conffile\n'; return 0; }
        fi
    done <<< "$conffiles"
    printf 'ordinary\n'
}

cydia_shared_prepare_path() {
    local path="$1" old_version="$2" record result owner target temporary token kind physical
    physical="${CYDIA_SHARED_ROOT%/}$path"
    [[ -f "$physical" || -L "$physical" ]] || return 0
    record=$(cydia_shared_existing_record "$path"); result=$?
    (( result < 2 )) || { cydia_shared_error 'ambiguous or unsafe handoff records'; return 1; }
    owner=$(cydia_shared_diversion --listpackage "$path") || return 1
    target=$(cydia_shared_diversion --truename "$path") || return 1
    if [[ -n "$record" ]]; then
        cydia_shared_read_record "$record" || return 1
        [[ "$CYDIA_SHARED_RECORD_VERSION" == "$old_version" ||
           "$CYDIA_SHARED_RECORD_KIND" == conffile ]] ||
            { cydia_shared_error "ownership version changed for $path"; return 1; }
        if [[ -n "$owner" ]]; then
            [[ "$owner" == LOCAL && "$target" == "$CYDIA_SHARED_RECORD_DIVERT" ]] ||
                { cydia_shared_error "foreign diversion for $path"; return 1; }
            return 0
        fi
    else
        [[ -z "$owner" && "$target" == "$path" ]] ||
            { cydia_shared_error "foreign diversion for $path"; return 1; }
        cydia_shared_journal_ready || return 1
        temporary=$(umask 077; mktemp "$CYDIA_SHARED_JOURNAL/record.XXXXXXXX") || return 1
        token="${temporary##*/}"
        target="$path.cydia-handoff.$token.distrib"
        [[ ! -e "${CYDIA_SHARED_ROOT%/}$target" && ! -L "${CYDIA_SHARED_ROOT%/}$target" ]] ||
            { rm -f "$temporary"; return 1; }
        kind=$(cydia_shared_kind "$path") || { rm -f "$temporary"; return 1; }
        if ! printf 'version=1\npackage=cydia\nold_version=%s\npath=%s\ndivert=%s\nkind=%s\n' \
                "$old_version" "$path" "$target" "$kind" > "$temporary"; then
            rm -f "$temporary"; return 1
        fi
        record="$temporary.record"
        ln "$temporary" "$record" || { rm -f "$temporary"; return 1; }
        rm -f "$temporary" || return 1
        sync || return 1
        cydia_shared_read_record "$record" || return 1
    fi
    [[ "$target" == "$path" || "$target" == "$CYDIA_SHARED_RECORD_DIVERT" ]] || return 1
    [[ ! -e "${CYDIA_SHARED_ROOT%/}$CYDIA_SHARED_RECORD_DIVERT" &&
       ! -L "${CYDIA_SHARED_ROOT%/}$CYDIA_SHARED_RECORD_DIVERT" ]] ||
        { cydia_shared_error "unexpected diverted payload for $path"; return 1; }
    cydia_shared_diversion --local --no-rename --divert "$CYDIA_SHARED_RECORD_DIVERT" --add "$path"
}

cydia_shared_release_record() {
    local record="$1" owner target
    cydia_shared_read_record "$record" || return 1
    owner=$(cydia_shared_diversion --listpackage "$CYDIA_SHARED_RECORD_PATH") || return 1
    target=$(cydia_shared_diversion --truename "$CYDIA_SHARED_RECORD_PATH") || return 1
    if [[ -n "$owner" ]]; then
        [[ "$owner" == LOCAL && "$target" == "$CYDIA_SHARED_RECORD_DIVERT" ]] ||
            { cydia_shared_error "diversion changed for $CYDIA_SHARED_RECORD_PATH"; return 1; }
        [[ ! -e "${CYDIA_SHARED_ROOT%/}$target" && ! -L "${CYDIA_SHARED_ROOT%/}$target" ]] ||
            { cydia_shared_error "unexpected diverted payload for $CYDIA_SHARED_RECORD_PATH"; return 1; }
        cydia_shared_diversion --local --no-rename --divert "$target" \
            --remove "$CYDIA_SHARED_RECORD_PATH" || return 1
    else
        [[ "$target" == "$CYDIA_SHARED_RECORD_PATH" ]] || return 1
    fi
    rm "$record"
}

cydia_shared_finish() {
    local phase="$1" list record
    [[ -e "$CYDIA_SHARED_JOURNAL" || -L "$CYDIA_SHARED_JOURNAL" ]] || return 0
    cydia_shared_safe_owned "$CYDIA_SHARED_JOURNAL" directory ||
        { cydia_shared_error 'unsafe shared-configuration journal'; return 1; }
    list=$(cydia_shared_file_list) || return 1
    for record in "$CYDIA_SHARED_JOURNAL"/*.record; do
        [[ -e "$record" || -L "$record" ]] || continue
        cydia_shared_read_record "$record" || return 1
        if [[ "$phase" != abort && "$phase" != purge ]] &&
                cydia_shared_listed "$list" "$CYDIA_SHARED_RECORD_PATH"; then
            if [[ "$phase" == configure && "$CYDIA_SHARED_RECORD_KIND" == ordinary ]]; then
                cydia_shared_error "the new package still owns shared configuration $CYDIA_SHARED_RECORD_PATH"
                return 1
            fi
            continue
        fi
        cydia_shared_release_record "$record" || return 1
    done
    # Unknown journal entries are never recursively deleted.
    rmdir "$CYDIA_SHARED_JOURNAL" 2>/dev/null || true
    sync
}

cydia_shared_prepare() {
    local list old_version line path
    list=$(cydia_shared_file_list) || return 1
    [[ -n "$list" ]] || return 0
    old_version=$("$CYDIA_SHARED_QUERY" --admindir "$CYDIA_SHARED_ADMIN" \
        --show --showformat='${Version}' cydia 2>/dev/null) || return 1
    [[ -n "$old_version" && "$old_version" != *$'\n'* && "$old_version" != *$'\r'* ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        path=$(cydia_shared_logical "$line") || continue
        cydia_shared_candidate "$path" || continue
        cydia_shared_prepare_path "$path" "$old_version" || return 1
    done < "$list"
}

cydia_shared_config_lifecycle() {
    local script="$1" phase="${2:-}"
    case "$script:$phase" in
        preinst:install|preinst:upgrade|postinst:configure|prerm:remove|\
        postrm:remove|postrm:purge|postrm:abort-install|postrm:abort-upgrade) ;;
        *) return 0 ;;
    esac
    cydia_shared_initialize || return 1
    case "$script:$phase" in
        preinst:*) cydia_shared_finish retry && cydia_shared_prepare ;;
        postinst:configure) cydia_shared_finish configure ;;
        prerm:remove) cydia_shared_prepare ;;
        postrm:remove) cydia_shared_finish remove ;;
        postrm:purge) cydia_shared_finish purge ;;
        postrm:abort-*) cydia_shared_finish abort ;;
    esac
}

if [[ "${1:-}" == --cydia-shared-config-lifecycle ]]; then
    shift
    cydia_shared_config_lifecycle "$@"
    exit $?
fi
