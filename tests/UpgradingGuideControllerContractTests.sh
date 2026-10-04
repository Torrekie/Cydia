#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail() { echo "[verify-upgrading-guide][FAIL] $*" >&2; exit 1; }
controller="$root/Cydia/UpgradingGuideController.mm"
header="$root/Cydia/UpgradingGuideController.h"
test -f "$controller" || fail "missing controller"
test -f "$header" || fail "missing header"
grep -Fq '@interface UpgradingGuideController : CyteViewController' "$header" || fail "not a native controller"
grep -Fq 'UITableViewStyleGrouped' "$controller" || fail "root is not a grouped native list"
grep -Fq 'initWithPageIdentifier' "$controller" || fail "finite child initializer missing"
grep -Fq 'traitCollectionDidChange' "$controller" || fail "trait-change appearance missing"
grep -Fq 'CydiaColorRoleCellBackground' "$controller" || fail "semantic cell color missing"
grep -Fq 'adjustsFontForContentSizeCategory' "$controller" || fail "Dynamic Type missing"
grep -Fq 'UIAccessibilityTraitButton' "$controller" || fail "row accessibility missing"
grep -Fq 'heightAnchor constraintGreaterThanOrEqualToConstant:44.0' "$controller" || fail "external action target missing"
grep -Fq 'hasLinkDetails' "$controller" || fail "tools description-row layout missing"
grep -Fq 'cydia.home.upgrading.detail.' "$controller" || fail "tools description accessibility identity missing"
grep -Fq 'path.row == 0' "$controller" || fail "tools detail/action rows are not paired"
grep -Fq 'preferredDisplayMode = UISplitViewControllerDisplayModeAllVisible' "$controller" || fail "regular-width guide split missing"
grep -Fq 'minimumPrimaryColumnWidth' "$controller" || fail "guide split width policy missing"
grep -Fq 'hasLinkGroups' "$controller" || fail "news section grouping missing"
grep -Fq 'titleForHeaderInSection' "$controller" || fail "news section headings missing"
python3 "$root/tests/UpgradingGuideContentTests.py"
grep -Fq '@selector(pageForURL:context:withReferrer:)' "$controller" || fail "typed application routing missing"
if grep -Eq 'performSelector:|openExternalURL:' "$controller"; then
    fail "unimplemented or untyped guide resource dispatch"
fi
grep -Fq 'cydia://home/upgrading-jailbreaking' "$controller" || fail "restoration route missing"
if grep -Fq 'WKWebView' "$controller" || grep -Fq 'UIWebView' "$controller"; then fail "guide still embeds web UI"; fi
echo "[verify-upgrading-guide][ ok ] content/assets and source contracts (not runtime UI evidence)"
