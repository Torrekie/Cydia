# Localization gaps and migration coverage

The comparison uses the September 2023 revision
`ca95f5c16e0b47b0396bc781f22157845e3e513b` and the 21 shipped locales:
`ar`, `de`, `el`, `en`, `es`, `fr`, `he`, `it`, `ja`, `ko`, `nl`, `pl`,
`pt`, `pt-PT`, `ru`, `sv`, `th`, `tr`, `vi`, `zh-Hans`, `zh-Hant`.
Every original `Localizable.strings` entry still matches that baseline.

## Additions made after 2023

The eight native catalogs contain 264 added entries per locale: 229 in
Settings, Sources, Actions, Recovery, RuntimeAccess, BootstrapAccess and
InfoPlist, and 35 added to Localizable. Of these, 249 are authored UI additions
and 15 are imported Home/package-support labels. All 5,280 non-English entries
are present. The review found no remaining whole-string English fallback in
these added entries. The separate Home catalog retains the recorded source
fallbacks listed below.

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

## Remaining inherited gaps

These inventories list the text, key or content location, and affected locales.
They separate preserved content from the migration repairs.

| Inventory | What it lists |
| --- | --- |
| [Home English fallbacks](localization-gaps/home-fallbacks.csv) | Six labels, 45 locale/key pairs retained from the recorded Home catalogs. |
| [Missing original keys](localization-gaps/legacy-missing-keys.csv) | 35 original keys missing in each of ten partial locales, 350 locale/key pairs. |
| [Original unresolved key](localization-gaps/inherited-unresolved-keys.csv) | `DPKG_LOCKED` has no entry even in English; the key itself is shown in all 21 locales. The lookup already existed before 2024. |
| [Original English-valued entries](localization-gaps/legacy-english-values.csv) | 74 original keys / 321 locale-key pairs equal to English; 35 keys / 38 pairs contain English prose or labels. The remaining pairs are classified as shared words, brands, formatting or uncertain wording. |
| [Inherited guide and explanatory text](localization-gaps/inherited-prose.csv) | 180 rendered text fields/fallbacks: 95 bodies, 45 titles, 18 headings, 20 explanatory fallbacks and two old copyright attributions; each retains English in the 20 non-English locales. |

The prose inventory's `lookup_or_content_id` is an actual lookup key when
one exists, otherwise a content identifier; its `source` column points to the
rendered field. Duplicate styling fragments, pure commands, URLs and proper-name
labels are excluded. Counts are per resource or rendered field and are not
additive across inventories: the same phrase can appear in multiple resources.

The six complete English Home labels are:

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

Greek Home labels also retain mixed-language wording: **Credits / Ευχαριστούμε**,
**Χρήσιμες πηγές για developers**, and **Μόνο Developers**. These belong to
the preserved source catalog; the native Localizable guide-title translations
are a separate table. The third label also predates 2024 in Localizable.

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
