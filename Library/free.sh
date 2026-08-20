#!/bin/bash

# /usr/bin \

case ${BASH_SOURCE[0]} in
    */*) cydia_free_dir=${BASH_SOURCE[0]%/*} ;;
    *) cydia_free_dir=. ;;
esac

for dir in \
    /Applications \
    /Library/Wallpaper \
    /Library/Ringtones \
    /usr/include \
    /usr/share \
; do
    . "${cydia_free_dir}/move.sh" "$@" "${dir}"
done

unset cydia_free_dir

sync
