/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_AptMessages_H
#define Cydia_AptMessages_H

#ifdef __cplusplus
extern "C" {
#endif

/* Configure before initializing embedded APT or starting acquisition methods.
 * The provider's installed gettext is preferred; the app-private libintl is
 * a recovery option. Catalogs for this embedded APT revision stay private. */
void CydiaConfigureAPTMessages(const char *bootstrapLibraryDirectory,
                              const char *bootstrapLocaleDirectory,
                              const char *applicationDirectory);
const char *CydiaAPTMessage(const char *message);
const char *CydiaAPTPluralMessage(const char *singular, const char *plural, unsigned long count);
const char *CydiaAPTDomainMessage(const char *domain, const char *message);
const char *CydiaAPTTextDomain(const char *domain);
const char *CydiaAPTBindTextDomain(const char *domain, const char *directory);
int CydiaAPTMessagesAvailable(void);

#ifdef __cplusplus
}
#endif
#endif
