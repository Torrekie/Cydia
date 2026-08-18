#!/bin/bash

# /usr/bin \

for dir in \
    /Applications \
    /Library/Wallpaper \
    /Library/Ringtones \
    /usr/include \
    /usr/share \
; do
    . "$(dirname "${BASH_SOURCE[0]}")/move.sh" "$@" "${dir}"
done

sync
