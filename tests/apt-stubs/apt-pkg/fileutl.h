/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_Test_APT_Fileutl_H
#define Cydia_Test_APT_Fileutl_H
#include <string>
#define APT_CYDIA_LOCK_FILE_OPENER 1
using LockFileOpener = bool (*)(std::string const &, int *, void *);
void SetLockFileOpener(LockFileOpener opener, void *context);
#endif
