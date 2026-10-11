/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceReaderGroups_HPP
#define Cydia_SourceReaderGroups_HPP
#include <unistd.h>
#include <vector>
namespace CydiaSources {
struct ReaderGroups {
    bool valid;
    std::vector<gid_t> values;
    ReaderGroups() {
        const int count(getgroups(0, NULL));
        valid = count >= 0;
        if (!valid) return;
        values.resize(count);
        valid = getgroups(count, values.empty() ? NULL : values.data()) == count;
    }
};
}
#endif
