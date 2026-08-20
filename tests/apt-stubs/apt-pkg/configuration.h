/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Tests_AptStubs_Configuration_H
#define Tests_AptStubs_Configuration_H

#include <cstddef>
#include <map>
#include <string>

class Configuration {
  public:
    void Set(const char *name, const std::string &value) {
        values_[name] = value;
    }

    void Set(const char *name, const char *value) {
        values_[name] = value;
    }

    void Set(const char *name, bool value) {
        values_[name] = value ? "true" : "false";
    }

    void Set(const char *name, int value) {
        values_[name] = std::to_string(value);
    }

    std::string Find(const char *name, const char *defaultValue = NULL) const {
        std::map<std::string, std::string>::const_iterator value(values_.find(name));
        if (value != values_.end())
            return value->second;
        return defaultValue == NULL ? std::string() : std::string(defaultValue);
    }

  private:
    std::map<std::string, std::string> values_;
};

extern Configuration *_config;

#endif // Tests_AptStubs_Configuration_H
