/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/DpkgAdminAccess.hpp"
#include <cassert>
#include <iostream>
#ifdef __APPLE__
#include <membership.h>
#endif

int main() {
    char pattern[] = "/tmp/cydia-admin-permissions.XXXXXX";
    const char *directory(mkdtemp(pattern)); assert(directory != NULL);
    struct stat identity; assert(lstat(directory, &identity) == 0);
    std::string first, second;
    assert(CydiaRuntime::AdminAccess::PermissionText(directory, identity, &first));
    assert(CydiaRuntime::AdminAccess::PermissionText(directory, identity, &second) && first == second);
#ifdef __APPLE__
    uuid_t principal; assert(mbr_uid_to_uuid(getuid(), principal) == 0);
    acl_t acl(acl_init(1)); assert(acl != NULL);
    acl_entry_t entry; acl_permset_t permissions;
    assert(acl_create_entry(&acl, &entry) == 0 && acl_set_tag_type(entry, ACL_EXTENDED_DENY) == 0 && acl_set_qualifier(entry, principal) == 0 &&
           acl_get_permset(entry, &permissions) == 0 && acl_add_perm(permissions, ACL_DELETE) == 0 &&
           acl_set_file(directory, ACL_TYPE_EXTENDED, acl) == 0);
    assert(lstat(directory, &identity) == 0 &&
           CydiaRuntime::AdminAccess::PermissionText(directory, identity, &second) && first != second);
    assert(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0 && acl_set_file(directory, ACL_TYPE_EXTENDED, acl) == 0);
    assert(lstat(directory, &identity) == 0 && !CydiaRuntime::AdminAccess::PermissionText(directory, identity, &second));
    acl_free(acl);
    acl = acl_init(0); assert(acl != NULL && acl_set_file(directory, ACL_TYPE_EXTENDED, acl) == 0); acl_free(acl);
#endif
    assert(rmdir(directory) == 0);
    std::cout << "Administration permission snapshots preserve ACL restrictions and reject undisclosed ACL grants\n";
}
