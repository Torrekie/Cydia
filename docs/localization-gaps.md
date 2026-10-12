# Localization gaps and migration coverage

The comparison uses the September 2023 revision
`ca95f5c16e0b47b0396bc781f22157845e3e513b` and the 21 shipped locales:
`ar`, `de`, `el`, `en`, `es`, `fr`, `he`, `it`, `ja`, `ko`, `nl`, `pl`,
`pt`, `pt-PT`, `ru`, `sv`, `th`, `tr`, `vi`, `zh-Hans`, `zh-Hant`.
The baseline remains intact. Reviewed repairs to 25 locale/key pairs are
recorded separately in `tests/fixtures/ui/native-localization-repairs.json`;
all other original entries still match it. `DPKG_LOCKED` remains unchanged.

## Additions made after 2023

The nine native catalogs contain 272 added keys: 237 in Settings, Sources,
Actions, Recovery, RuntimeAccess, BootstrapAccess, InfoPlist and PackageSupport,
and 35 added to Localizable. Of these, 257 are authored UI additions
and 15 are imported Home/package-support labels. All 5,440 non-English entries
are present. The review found no remaining whole-string English fallback in
these added entries. The separate Home catalog retains recorded source
coverage independently of the native label improvements.

Coverage alone missed three presentation problems, now repaired:

| Surface | Problem | Repair |
| --- | --- | --- |
| FAQ navigation title | `FAQ_TITLE` had no translation entry. | Resolve the existing `FREQUENTLY_ASKED_QUESTIONS` key in all 21 locales. |
| Upgrading navigation title | Generated `UPGRADING_root_title` had no entry. | Resolve the existing `HOME_UPGRADING_HELP` key for the root page. |
| Capability preview/apply failures | Localized alerts appended English helper output. | Keep the localized summary in the alert; retain execution output on the localized Technical Details page, including after a failed preview or automatic refresh. |

Two Greek key-import explanations now refer to the actual translated
Advanced Settings heading. Chinese distribution-source wording remains
发行源 / 發行源, distinct from ordinary software sources.

Seven added locale/key pairs correctly share an English spelling:
German/Dutch **Details**, German/Dutch/Swedish **Status**, Spanish **Error**,
and French **destination**. These are reviewed translations, not gaps.

PackageSupport also uses the correct shared words **Support** in Swedish and
**Console** in French, Italian, Dutch and Brazilian Portuguese.

## Current interface repairs

The current Home labels have 48 reviewed improvements across 20 non-English
locales, including extension discovery, iPad headings, Japanese welcome/byline/
credits and Greek developer/credits terminology. `HomeLocalizationCatalog.json`
records native overrides separately; importing source labels preserves them.

The active original-table repairs cover Japanese package origins, German and
Vietnamese queue badges, Greek Sources, and a clearer APT cache error in all
21 locales. Of the 25 repaired entries, ten supply a previously absent key
and fifteen replace an existing value. The reserved `DPKG_LOCKED` identifier
and its existing behavior remain unchanged.

Package support and the console-package notice now use eight keys in the new
PackageSupport table, with full 21-locale coverage. Existing support addresses,
commercial conditions and routes are retained. Home subpage translations,
including FAQ, Storage, Extensions and operational guides, remain deferred;
the console notice belongs to package details rather than the Home menu.

## Remaining inherited gaps

These inventories list the text, key or content location, and affected locales.
They separate preserved content from the migration repairs.

| Inventory | What it lists |
| --- | --- |
| [Home English fallbacks](localization-gaps/home-fallbacks.csv) | Japanese `HOME_NEW`, an unused native Home key; all active Home labels are covered. The ten inherited iPad recommendation summaries still need content review. |
| [Missing original keys](localization-gaps/legacy-missing-keys.csv) | 34 original keys missing in each of ten partial locales, 340 locale/key pairs; these keys have no current native UI consumer. |
| [Original unresolved key](localization-gaps/inherited-unresolved-keys.csv) | `DPKG_LOCKED` has no entry even in English; the key itself is shown in all 21 locales. The lookup already existed before 2024. |
| [Original English-valued entries](localization-gaps/legacy-english-values.csv) | Remaining English-equivalent catalog entries, including dormant labels, shared words, brands, formatting and uncertain wording. Active package-origin, queue and Greek Sources gaps are repaired. |
| [Inherited guide and explanatory text](localization-gaps/inherited-prose.csv) | 171 remaining Home-guide/explanatory fields and old attributions; localized package-support/console content has been removed from this gap inventory. |

The prose inventory's `lookup_or_content_id` is an actual lookup key when
one exists, otherwise a content identifier; its `source` column points to the
rendered field. Duplicate styling fragments, pure commands, URLs and proper-name
labels are excluded. Counts are per resource or rendered field and are not
additive across inventories: the same phrase can appear in multiple resources.

The recorded source Home labels originally had these six English fallbacks.
Native overrides now translate the five active labels; `HOME_NEW` remains unused:

| Text | Affected locales |
| --- | --- |
| Find Extensions for Applications | All 20 non-English locales |
| Extensions Useful on iPad | `ar`, `he`, `ja`, `ko`, `pl`, `pt`, `pt-PT`, `ru`, `th`, `tr`, `vi` |
| Products Designed for iPad | Same eleven locales |
| by %@ | `ja` |
| New | `ja` |
| Welcome to Cydia™ | `ja` |

The ten original partial locales are `he`, `ja`, `ko`, `pl`, `pt`, `pt-PT`,
`ru`, `th`, `tr`, and `vi`. Their missing keys already predate 2024;
some missing keys are brands or acronyms rather than untranslated prose.
The CSV includes them because absence of a locale entry is a separate coverage
issue from whether the displayed spelling needs to change.

The recorded Greek source labels contain **Credits / Ευχαριστούμε**,
**Χρήσιμες πηγές για developers**, and **Μόνο Developers**. Native Home now
uses fully translated wording. The source record remains separate from the
original Localizable table and from deferred guide bodies.

Original `Sections.strings` tables remain unchanged. The unused English
`Sections_.strings` template is not a rendered English localization catalog
and is excluded from the gap counts.

## Limits and verification

The pre-2024 bundled string tables establish their original gaps exactly.
Complete pre-2024 per-language responses from the remote Home/guide pages are
unavailable. Recorded Home fallbacks and preserved English guide content can
be listed, but their first appearance or historical server-side translation
coverage cannot be established from the current English content alone.
Repository/package metadata and APT/dpkg diagnostic output are supplied by
external components; their language is not a missing Cydia catalog entry.

`make verify-settings-localization verify-home-localization` checks the
21-locale baseline, added-key coverage, format arguments, duplicate entries,
original-value preservation and the reviewed shared-word exceptions.
`LocalizationAdditionTests.py` also resolves every explicit bundled guide
title key in all 21 locales. FAQ and Upgrading contracts cover their repaired
navigation-title lookups.

See [the localization audit](native-localization-audit.md) for the historical
web-to-native mapping and catalog provenance.
