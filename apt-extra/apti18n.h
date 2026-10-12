/* Embedded APT uses its upstream catalogs through a compatible libintl.
 * Missing optional gettext falls back to upstream English, never a parallel
 * Cydia translation table. Keep the platform locale API visible. */
#ifndef Cydia_APTI18N_H
#define Cydia_APTI18N_H
#include <locale.h>
#include "Cydia/AptMessages.h"
#define textdomain(a) CydiaAPTTextDomain(a)
#define bindtextdomain(a, b) CydiaAPTBindTextDomain(a, b)
#define _(x) CydiaAPTMessage(x)
#define P_(msg,plural,n) CydiaAPTPluralMessage(msg, plural, n)
#define N_(x) x
#define dgettext(d, m) CydiaAPTDomainMessage(d, m)
#endif
