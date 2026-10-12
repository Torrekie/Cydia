#!/bin/sh
# Cydia native FAQ list/detail and iOS 12 appearance contract.
# Copyright (C) 2026 Torrekie
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
header="$root/Cydia/FAQController.h"
controller="$root/Cydia/FAQController.mm"
renderer="$root/Cydia/HomeGuideController.mm"
document="$root/MobileCydia.app/FAQGuide.json"
home="$root/Cydia/HomeController.mm"
route_context="$root/Cydia/UIRouteContext.mm"
route_header="$root/Cydia/UIRouteContext.h"
navigation="$root/Cydia/Application+Navigation.mm"

fail() {
    echo "[verify-faq-controller][FAIL] $*" >&2
    exit 1
}

for file in "$header" "$controller" "$renderer" "$document" "$home" "$route_context" "$route_header" "$navigation"; do
    test -f "$file" || fail "missing FAQ source: $file"
done

grep -Fq '@interface FAQController : HomeGuideController' "$header" ||
    fail "FAQ controller does not reuse the native rich guide"
grep -Fq 'UITableViewStyleGrouped' "$renderer" ||
    fail "FAQ root is not a grouped UIKit table"
grep -Fq 'numberOfSectionsInTableView' "$renderer" ||
    fail "FAQ table data source does not declare its section count"
grep -Fq 'UITextView' "$renderer" ||
    fail "FAQ detail is missing its native readable text surface"
grep -Fq 'initWithQuestionIdentifier' "$header" ||
    fail "FAQ child route initializer is missing"
grep -Fq 'cydia://home/faq' "$controller" ||
    fail "FAQ navigation URL is missing"
grep -Fq 'traitCollectionDidChange' "$renderer" ||
    fail "FAQ does not react to trait changes"
grep -Fq 'CydiaColorAppearanceDidChange' "$renderer" ||
    fail "FAQ does not compare appearance traits"
for role in CydiaColorRoleGroupedBackground CydiaColorRoleCellBackground \
        CydiaColorRoleLabel CydiaColorRoleSecondaryLabel CydiaColorRoleSeparator \
        CydiaColorRoleAccent; do
    grep -Fq "$role" "$renderer" || fail "FAQ appearance role missing: $role"
done
grep -Fq 'traitCollection:self.traitCollection' "$renderer" ||
    fail "FAQ does not resolve colors from its owning trait collection"
grep -Fq 'adjustsFontForContentSizeCategory = YES' "$renderer" ||
    fail "FAQ text does not support Dynamic Type"
grep -Fq 'UIAccessibilityTraitStaticText' "$renderer" ||
    fail "FAQ answer is missing a static-text accessibility trait"
grep -Fq 'UIAccessibilityTraitButton' "$renderer" ||
    fail "FAQ questions are missing button accessibility traits"
for identifier in what-is-cydia refresh-sources install-remove \
        package-unavailable other-frontends recover-safely; do
    grep -Fq "\"$identifier\"" "$document" ||
        fail "FAQ finite model is missing: $identifier"
done
grep -Fq 'scrollToRowIdentifier:target[@"anchor"]' "$controller" ||
    fail "FAQ child no longer restores its original question anchor"
grep -Fq 'NSLinkAttributeName' "$renderer" ||
    fail "FAQ answer inline links are not native attributed links"
python3 - "$document" "$root/MobileCydia.app" <<'PY'
import json,pathlib,re,sys
document=json.load(open(sys.argv[1]))
assert document['schema']==1
pages=document['pages']; aliases=document['aliases']
# The native renderer resolves title_key in Localizable.strings. Reuse the
# historical FAQ heading rather than an undefined key with an English fallback.
title_key=pages['root']['title_key']
assert title_key=='FREQUENTLY_ASKED_QUESTIONS'
bundles=sorted(pathlib.Path(sys.argv[2]).glob('*.lproj'))
assert len(bundles)==21
pattern=re.compile(r'^\s*"'+re.escape(title_key)+r'"\s*=\s*("(?:[^"\\]|\\.)*")\s*;',re.M)
for bundle in bundles:
    match=pattern.search((bundle/'Localizable.strings').read_text(encoding='utf-8-sig'))
    assert match, (bundle.name, 'FAQ title key missing')
    value=json.loads(match.group(1))
    assert value and value!=title_key, (bundle.name, 'FAQ title untranslated')
    if bundle.name!='en.lproj':
        assert value!=pages['root']['title'], (bundle.name, 'English FAQ title fallback')
root=pages['root']['sections']
assert [section['title'] for section in root]==[
    'Getting Started','Fixing Problems','Using Repositories (Sources)',
    'Developing for Jailbroken iOS','Learning More']
assert [len(section['rows']) for section in root]==[6,4,5,1,2]
for section in root:
    for row in section['rows']:
        assert row['kind']=='link' and row['destination']
        if row['destination'].startswith('cydia://home/faq/'):
            assert row['destination'].rsplit('/',1)[-1] in aliases
assert {key:len(pages[key]['sections']) for key in ['software','fixing','repositories','safemode']}=={
    'software':6,'fixing':4,'repositories':5,'safemode':6}
for alias in aliases.values():
    assert alias['anchor'] in [row['id'] for section in pages[alias['page']]['sections'] for row in section['rows']]
for page in pages.values():
    for section in page['sections']:
        for row in section['rows']:
            assert row['text']==''.join(run['text'] for run in row['runs'])
            for run in row['runs']:
                assert not run.get('link','').startswith(('https://cydia.saurik.com/faq/','http://cydia.saurik.com/faq/'))
assert any(run.get('link')=='cydia://home/faq/safemode-help'
    for section in pages['fixing']['sections'] for row in section['rows'] for run in row['runs'])
assert any(run.get('bold') and 'cannot locate package' in run['text']
    for section in pages['fixing']['sections'] for row in section['rows'] for run in row['runs'])
assert pages['safemode']['sections'][0]['rows'][0].get('warning') is True
PY
grep -Fq 'CydiaUIRouteKindFAQ' "$route_header" ||
    fail "FAQ route kind is missing"
grep -Fq 'CydiaUIRouteKindFAQ' "$route_context" ||
    fail "FAQ route parser is missing"
grep -Fq '#include "Cydia/FAQController.h"' "$navigation" ||
    fail "application navigation does not import FAQ controller"
grep -Fq 'initWithQuestionIdentifier' "$navigation" ||
    fail "application navigation does not create FAQ child pages"
grep -Fq 'cydia://home/faq' "$home" ||
    fail "Home does not retain the native FAQ route"
if grep -Fq 'https://cydia.saurik.com/questions.html' "$home"; then
    fail "Home FAQ action still opens the historical external questions page"
fi
if grep -Eq 'CydiaWebViewController|UI_/|dispatchEvent|applicationCache' \
        "$header" "$controller"; then
    fail "FAQ controller retains a remote web UI dependency"
fi

echo "[verify-faq-controller][ ok ] finite native FAQ list/detail, typed route, AX, and iOS12 color contract"
