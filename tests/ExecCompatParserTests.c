/* Copyright (C) 2026 Torrekie */
/* SPDX-License-Identifier: GPL-3.0-or-later */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libiosexec_private.h"

static void Fail(const char *message, const char *actual) {
    fprintf(stderr, "[exec-compat-test][FAIL] %s: %s\n", message,
        actual == NULL ? "(null)" : actual);
    exit(1);
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <script> <expected-interpreter>\n", argv[0]);
        return 2;
    }

    char *original[] = {argv[1], (char *)"--preserved-argument", NULL};
    char **rewritten = get_new_argv(argv[1], original);
    if (rewritten == NULL)
        Fail("could not parse canonical helper shebang", strerror(errno));

    if (rewritten[0] == NULL || strcmp(rewritten[0], argv[2]) != 0)
        Fail("unexpected interpreter", rewritten[0]);
    if (rewritten[1] == NULL || strcmp(rewritten[1], argv[1]) != 0)
        Fail("script path was not preserved", rewritten[1]);
    if (rewritten[2] == NULL || strcmp(rewritten[2], original[1]) != 0)
        Fail("script argument was not preserved", rewritten[2]);
    if (rewritten[3] != NULL)
        Fail("unexpected trailing parser argument", rewritten[3]);

    free_new_argv(rewritten);
    printf("[exec-compat-test][ ok ] %s -> %s (arguments preserved)\n",
        argv[1], argv[2]);
    return 0;
}
