#!/bin/bash
sed_expression='s@\(\x0C\x00\x00\x00\x4C\x00\x00\x00\x18\x00\x00\x00\x02\x00\x00\x00\)\x00...\(\x00\x00\x01\x00/System/Library/Frameworks/UIKit.framework/UIKit\x00\x00\x00\x00\)@\1\x00\x00\xF6\x0C\2@g'
if sed_bin=$(command -v gsed); then
    LANG=C exec "$sed_bin" -i -e "$sed_expression" "$1"
fi

# macOS sed does not implement GNU sed's hexadecimal escapes. Perl is present
# on the supported build hosts and provides the same byte-preserving rewrite.
if perl_bin=$(command -v perl); then
    LANG=C exec "$perl_bin" -0pi -e 's@(\x0C\x00\x00\x00\x4C\x00\x00\x00\x18\x00\x00\x00\x02\x00\x00\x00)\x00...(\x00\x00\x01\x00/System/Library/Frameworks/UIKit.framework/UIKit\x00\x00\x00\x00)@${1}\x00\x00\xF6\x0C${2}@g' "$1"
fi

echo "uikit.sh: GNU sed or Perl is required" >&2
exit 127
