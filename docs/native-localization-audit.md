# Native UI localization audit

The historical baseline is the September 2023 source revision
`876d9f30d2b3087d7e72d6c5bcb4c82a294d1a35`.
The repair covers text introduced after the historical baseline. Existing
untranslated guide prose and original partial locale coverage are excluded.

## Locale baseline

The baseline and current app both provide these 21 locales:

| Locale | Language | Translation table |
| --- | --- | --- |
| `ar` | Arabic | [Localizable.strings](../MobileCydia.app/ar.lproj/Localizable.strings) |
| `de` | German | [Localizable.strings](../MobileCydia.app/de.lproj/Localizable.strings) |
| `el` | Greek | [Localizable.strings](../MobileCydia.app/el.lproj/Localizable.strings) |
| `en` | English | [Localizable.strings](../MobileCydia.app/en.lproj/Localizable.strings) |
| `es` | Spanish | [Localizable.strings](../MobileCydia.app/es.lproj/Localizable.strings) |
| `fr` | French | [Localizable.strings](../MobileCydia.app/fr.lproj/Localizable.strings) |
| `he` | Hebrew | [Localizable.strings](../MobileCydia.app/he.lproj/Localizable.strings) |
| `it` | Italian | [Localizable.strings](../MobileCydia.app/it.lproj/Localizable.strings) |
| `ja` | Japanese | [Localizable.strings](../MobileCydia.app/ja.lproj/Localizable.strings) |
| `ko` | Korean | [Localizable.strings](../MobileCydia.app/ko.lproj/Localizable.strings) |
| `nl` | Dutch | [Localizable.strings](../MobileCydia.app/nl.lproj/Localizable.strings) |
| `pl` | Polish | [Localizable.strings](../MobileCydia.app/pl.lproj/Localizable.strings) |
| `pt` | Portuguese (Brazil) | [Localizable.strings](../MobileCydia.app/pt.lproj/Localizable.strings) |
| `pt-PT` | Portuguese (Portugal) | [Localizable.strings](../MobileCydia.app/pt-PT.lproj/Localizable.strings) |
| `ru` | Russian | [Localizable.strings](../MobileCydia.app/ru.lproj/Localizable.strings) |
| `sv` | Swedish | [Localizable.strings](../MobileCydia.app/sv.lproj/Localizable.strings) |
| `th` | Thai | [Localizable.strings](../MobileCydia.app/th.lproj/Localizable.strings) |
| `tr` | Turkish | [Localizable.strings](../MobileCydia.app/tr.lproj/Localizable.strings) |
| `vi` | Vietnamese | [Localizable.strings](../MobileCydia.app/vi.lproj/Localizable.strings) |
| `zh-Hans` | Chinese (Simplified) | [Localizable.strings](../MobileCydia.app/zh-Hans.lproj/Localizable.strings) |
| `zh-Hant` | Chinese (Traditional) | [Localizable.strings](../MobileCydia.app/zh-Hant.lproj/Localizable.strings) |

`pt` is Brazilian Portuguese and `pt-PT` is European Portuguese.
`zh-Hans` and `zh-Hant` remain separate simplified/traditional Chinese tables.
The original 220-key tables and the 185-key tables in `he`, `ja`, `ko`, `pl`,
`pt`, `pt-PT`, `ru`, `th`, `tr`, and `vi` retain every historical entry and value.
All original section-name tables also remain unchanged.

## Historical web UI comparison

The old bundled `localize.js` replaced elements carrying a `localize` attribute
with `cydia.localize(key, fallback)`. The Objective-C bridge in the 2023
`CyteKit/CyteObject.mm` used the same bundled `Localizable.strings` table as the
native UI. Raw English HTML alone therefore does not establish an English UI.

| Former web surface | Historical translation mechanism | Current finding |
| --- | --- | --- |
| Home | Server-provided locale labels and native title | Existing `Home.strings` tables recover 21 labels in all 21 locales and retain original partial English fallbacks. |
| Package details | Ten wrapper localization keys plus queue mode | Native details reuse the original keys and values. |
| Confirmation | DOM localization and bridge calls for warnings, statistics and actions | Native confirmation reuses the original keys. |
| Progress | Native localized title/finish values passed to JavaScript | Native progress retains those translations. The new last-progress label needed 19 missing locale entries. |
| Network error | Bundled `NETWORK_ERROR` and `UNABLE_TO_LOAD` | Native error presentation retains those keys; generic error fallback now also uses existing `ERROR`. |
| Storage | Localized `STORAGE` title, English body/category names | Existing title translation preserved. New native states, category heading and condensed warning translated. |
| Application Extensions | English explanatory prose and localized application names | Native names retain their existing mechanism. New count, empty/loading errors and unavailable-package notice translated. |
| Informational guides and Package Support | Inspected preserved bodies lack client localization hooks | Existing English prose retained; new native navigation/accessibility text translated. |
| Unknown package | Five original localization keys | Former standalone screen is absent from the native route; its original translations still exist. This is an omitted state, not an untranslated displayed string. |

Historical per-language server responses are not available in the source
repository, and some FAQ descendant content is unavailable. Bundled keys
can be compared; complete historical remote translation coverage cannot
be inferred from English HTML alone.

The existing Home catalog maps `en-us` to `en`, `pt-br` to `pt`, `pt-pt` to
`pt-PT`, `zh-cn` to `zh-Hans`, and `zh-tw` to `zh-Hant`. Its recorded server
fallbacks remain untouched, including the English Find Extensions label and
Japanese welcome/byline gaps.

## Repaired additions

All 18 keys now resolve in all 21 locale tables. Added 376 entries: 17 new keys
in every locale, plus the missing 19 translations of `LAST_REPORTED_PROGRESS`.
Its existing English and Simplified Chinese entries were preserved.

| Key | English text |
| --- | --- |
| `EXTENSIONS_LOAD_ERROR` | Unable to load extensions. Check your connection and application access, then tap to retry. |
| `EXTENSIONS_EMPTY` | No extensions are listed for these applications. |
| `EXTENSIONS_COUNT` | Extensions: %lu |
| `EXTENSIONS_PACKAGE_UNAVAILABLE` | This package is not available in your configured sources. No source or package has been changed. |
| `LAST_REPORTED_PROGRESS` | Last reported progress |
| `HOME_UPGRADING_SELECT` | Select a guide |
| `HOME_UPGRADING_SHORT_TITLE` | Upgrading |
| `HOME_EMPTY_DESTINATION` | No content is available here. |
| `MORE_SOURCES_READ_ONLY` | This bootstrap has not enabled source editing in Cydia. Manage repositories with your bootstrap's package manager; Cydia will read the same APT sources. |
| `HOME_GUIDE_OBSOLETE` | Obsolete: |
| `HOME_GUIDE_NETWORK_DETAILS` | Network details button |
| `HOME_STORAGE_CALCULATING` | Measuring… |
| `HOME_STORAGE_ERROR` | Unavailable |
| `HOME_STORAGE_CATEGORIES` | Private data |
| `HOME_STORAGE_WARNING` | Note: Storage may take a long time to display while data is measured. |
| `APT_EXTENDED_STATE_PERSIST_ERROR` | Unable to persist APT extended state (kind=%d, code=%d, error=%d) |
| `ERROR_DESTINATION` | destination |
| `ABOUT_REFURBISHED_COPYRIGHT` | Refurbished work Copyright (C) %@ |

`EXTENSIONS_COUNT` uses a label followed by the number instead of an inflected
number/noun phrase, so counts of one and many do not require an English-style
plural in languages with different plural rules. Storage's new category heading
refers to the data/Private filesystem, not confidential personal information.
The About year remains a format argument; names and URLs are unchanged.

The three formerly hardcoded additions now use localization keys in
`Database.mm`, `ErrorViewModel.mm`, and `HomeController.mm`.
Old About attributions remain as they were before 2024.

Historical English-only prose, existing partial gaps, old `DPKG_LOCKED` fallback,
repository/package-provided metadata, and diagnostics hidden behind localized
UI errors are excluded. The complete classification and original table digests
are in `tests/fixtures/ui/native-localization-baseline.json`.

## Verification

`make verify-home-localization` checks the original Home catalog/mappings,
all 18 new keys across all 21 locales, format-slot compatibility, Apple strings
syntax on macOS, duplicate entries, and preservation of original 2023 values.
French `destination` is intentionally identical to English because the same
word is correct in both languages.

Localization resources are shipped by the separate `cydia-lproj` package.
