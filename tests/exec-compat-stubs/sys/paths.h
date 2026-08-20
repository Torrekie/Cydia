/* Copyright (C) 2026 Torrekie */
/* SPDX-License-Identifier: GPL-3.0-or-later */

/*
 * Linux host compilers do not provide Darwin's <sys/paths.h>.  The generated
 * libiosexec paths.h under test supplies every path used by get_new_argv.c,
 * so this intentionally empty shim keeps the host-only parser test portable.
 */
