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

## Repaired migration additions

The migration repair covers 18 keys in all 21 locale tables. It adds 376 entries:
17 new keys in every locale, plus the missing 19 translations of
`LAST_REPORTED_PROGRESS`. Its existing English and Simplified Chinese entries
were preserved. The new package-management flows below use separate tables.

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

## New native package-management flows

These tables contain newly authored native UI text for the package-management
flows. Their coverage follows the same 21-locale baseline, including separate
Brazilian/European Portuguese and Simplified/Traditional Chinese resources.

| Table | Entries per locale | Native consumers and provenance |
| --- | --- | --- |
| `Settings.strings` | 102 | Settings and Advanced Settings; repository Allow/Warning/Error policy; user-selected bootstrap protection; executable overrides; capability review; public-key import; repository/download diagnostics; transaction failures; bootstrap database access navigation; explicit default/custom tool selection and save/discard states. These explanations and review states were introduced with the optional APT frontend. |
| `Sources.strings` | 45 | Repository Settings for actual `.list` lines and `.sources` stanzas, destination files, enable/disable actions, complete-definition review, bootstrap protection, read-only delegated definitions and conflicts. The Sources tab retains direct package browsing; configuration details live in Settings. Four labels from the retired definition-first browsing route are removed. |
| `Actions.strings` | 14 | Native package version selection, priority/candidate information, purge, hold handling, Essential/Protected safeguards and unavailable installed-version reinstall. These labels explain the expanded APT/dpkg actions. |
| `Recovery.strings` | 21 | Native incomplete-package recovery, normal repair, emergency-removal review, retained script backups and failure states. This is new guidance around the retained historical Forcibly Clear action. |
| `RuntimeAccess.strings` | 20 | The explicit package-management access check in Advanced Settings, its six checks, contention, changed-state and timeout results, and technical-details navigation. Unsuccessful attempted checks and skipped checks have distinct labels; raw diagnostic output has a separate page. This diagnostic view is newly authored. |
| `BootstrapAccess.strings` | 24 | Native review of the selected package database and group-writable ancestor directories, explicit Allow and Revoke actions, trust explanations, changed-access and failure states. This optional approval preserves existing bootstrap permissions. |
| `InfoPlist.strings` | 2 | Localized OpenPGP public-key document-type labels for file sharing and Open in Cydia. Both `CFBundleTypeName` and the declared `OpenPGP Public Key` label are provided. |

All seven tables have matching key sets in every shipped locale. Existing shared
navigation and action labels continue to use `Localizable.strings`, including
Settings, About, Cancel, Confirm, Remove, Reinstall and Forcibly Clear. Historical
About attributions and English-only guide bodies retain their previous scope.

Progress also adds two native outcome titles to `Localizable.strings`:
`TRANSACTION_FAILED_TITLE` (Failed) and `TRANSACTION_CANCELLED` (Cancelled), with
42 entries across all 21 locales. These titles describe the transaction result;
the existing Complete title remains unchanged. They are new native states,
independent of the historical webpage labels and the 18 migration repairs.

Format arguments preserve their types across translations: `%@` carries names,
paths, versions or source definitions; `%lu` carries the capability
count; `%ld` carries package priority. Capability-count prose uses a label and
number rather than an English singular/plural package noun. Repository syntax,
package identifiers, executable names, key fingerprints and user-provided values
remain data rather than translation keys.

The new controllers use native table cells, alerts and text views. Table rows
self-size, explanatory labels allow multiple lines, and body/footnote fonts
follow Dynamic Type. Source-editor constraints use leading/trailing anchors;
ordinary native controls retain UIKit's language-direction behavior. Action and
selection accessibility traits distinguish controls from static review text.
These implementation properties support long translations, RTL and VoiceOver;
they are separate from an observed accessibility or visual acceptance session.

## Settings and Sources navigation

Sources keeps the familiar All Sources and named repository list, icons and
refresh indicators, direct package browsing, Refresh/Cancel, Edit/Done,
Add URL and swipe deletion. Exact source-file, bootstrap-protection and stale
state checks still apply to edits; an ambiguous definition requires a choice.

Settings groups Repository Settings, Repository Security and key import.
Repository Security shows its current value and opens a three-choice list.
Advanced Settings groups bootstrap configuration, compatibility and
troubleshooting. External tools have a separate page with an explicit bootstrap
default or custom path, while capability generation retains its reviewed apply
action. Protected repository selection uses Save/Cancel and confirms discarded
drafts. Access diagnostics lead with a status and Run Check; individual checks,
paths and diagnostic output are disclosed separately. Database approval offers
a direct route to the access check. Revocation remains available even when
strict permissions make a saved approval temporarily inactive.

This structure applies Apple's guidance on
[infrequently changed settings](https://developer.apple.com/design/human-interface-guidelines/settings),
[succinct hierarchical lists](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
and [concise, purposeful alerts](https://developer.apple.com/design/human-interface-guidelines/alerts).
Routine repository browsing and Add/Delete remain in their familiar context;
repository configuration uses the Settings hierarchy. Grouped native tables,
Dynamic Type and platform navigation retain the iOS 12 minimum, with inset
grouped lists where supported.

## Verification

`make verify-home-localization` checks the original Home catalog/mappings,
all 18 new keys across all 21 locales, format-slot compatibility, Apple strings
syntax on macOS, duplicate entries, and preservation of original 2023 values.
French `destination` is intentionally identical to English because the same
word is correct in both languages.

`make verify-settings-localization` checks the new tables with
`SettingsLocalizationTests.py`, `SourcesLocalizationTests.py`,
`ActionsLocalizationTests.py` and `RecoveryLocalizationTests.py`. The checks
require the 21-locale baseline and matching keys, compare format arguments where
used, and check the source/recovery controller key inventories. The Settings
check also covers `RuntimeAccess.strings`, `BootstrapAccess.strings` and the file-type label keys in
`InfoPlist.strings`, and requires translated failure/cancellation titles in every
`Localizable.strings` table. These are structural coverage checks; translation
meaning and native layout remain review concerns.

Localization resources are shipped by the separate `cydia-lproj` package.
