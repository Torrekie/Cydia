/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_SourceFetchActivity_HPP
#define Cydia_SourceFetchActivity_HPP
#include <map>
#include <set>
#include <string>

namespace CydiaAPT {
// Source rows match the directory of each acquired item. Several translations
// or indexes can share that directory, so one completion cannot clear siblings.
class SourceFetchActivity {
    std::set<std::string> items_;
    std::map<std::string, std::size_t> directories_;
public:
    bool Set(bool fetching, const std::string &uri, std::string *directory) {
        const auto slash(uri.rfind('/'));
        if (!directory || slash == std::string::npos) return false;
        *directory = uri.substr(0, slash);
        if (fetching) {
            if (!items_.insert(uri).second) return false;
            return ++directories_[*directory] == 1;
        }
        if (!items_.erase(uri)) return false;
        const auto found(directories_.find(*directory));
        if (found == directories_.end() || --found->second) return false;
        directories_.erase(found); return true;
    }
    const std::set<std::string> &items() const { return items_; }
    void Clear() { items_.clear(); directories_.clear(); }
};
}
#endif
