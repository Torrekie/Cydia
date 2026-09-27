/* APT 2.7 calls setlocale directly while initializing its locale policy.  The
 * old Cydia shim blanked the name, which now also corrupts the SDK's
 * <locale.h> declaration when it is included through libc++.  Keep the
 * platform implementation visible and continue to stub only gettext APIs. */
#include <locale.h>
#define textdomain(a)
#define bindtextdomain(a, b)
#define _(x) x
#define P_(msg,plural,n) (n == 1 ? msg : plural)
#define N_(x) x
#define dgettext(d, m) m
