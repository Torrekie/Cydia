#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
controller="$root/Cydia/HomeGuideController.mm"
python3 "$root/tests/HomeGuideContentTests.py"
for token in UITableViewStyleGrouped UITableViewAutomaticDimension adjustsFontForContentSizeCategory \
    traitCollectionDidChange CydiaColorAppearanceDidChange CydiaColorRoleCellBackground \
    'heightAnchor constraintGreaterThanOrEqualToConstant:44.0' UIAccessibilityTraitButton \
    UIAccessibilityTraitHeader UIAccessibilityTraitStaticText NSStrikethroughStyleAttributeName \
    'HOME_GUIDE_OBSOLETE' 'UIFontMetrics' 'Menlo' 'CydiaExternalURLRouteURL' \
    'pageForURL:context:withReferrer:' 'CydiaUIRouteKindHomeGuide' \
    'NSLinkAttributeName' 'NSTextAttachment' 'shouldInteractWithURL:' \
    'scrollToRowIdentifier:' 'UIFontTextStyleSubheadline' \
    'cell.body.userInteractionEnabled = inlineLinks'; do
    rg -Fq "$token" "$controller" || { echo "[home-guide] missing $token" >&2; exit 1; }
done
if rg -n 'WKWebView|UIWebView|performSelector:|NSTask|system\(|installPackages|runCommand' "$controller"; then
    echo '[home-guide] owned content must be native; commands inert' >&2; exit 1
fi
if ! rg -Uq 'controller = \[\[HomeGuideController alloc\]\s*\n\s*initWithPageIdentifier:' \
    "$root/Cydia/Application+Navigation.mm"; then
    echo '[home-guide] missing native HomeGuideController route allocation' >&2
    exit 1
fi
echo '[home-guide] finite source/content contract PASS; runtime still required'
