/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#ifndef Tests_AptStubs_Configuration_H
#define Tests_AptStubs_Configuration_H

#include <cstddef>
#include <map>
#include <string>
#include <vector>

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

    void CndSet(const char *name, const char *value) {
        if (Find(name).empty())
            Set(name, value);
    }

    std::string Find(const char *name, const char *defaultValue = NULL) const {
        std::map<std::string, std::string>::const_iterator value(values_.find(name));
        if (value != values_.end())
            return value->second;
        return defaultValue == NULL ? std::string() : std::string(defaultValue);
    }

    std::string FindFile(const char *name, const char *defaultValue = NULL) const {
        return ResolvePath(name, Find(name, defaultValue), false);
    }

    std::string FindDir(const char *name, const char *defaultValue = NULL) const {
        return ResolvePath(name, Find(name, defaultValue), true);
    }

    void Clear(const std::string &name) {
        for (std::map<std::string, std::string>::iterator value(values_.begin());
             value != values_.end(); ) {
            if (value->first == name ||
                (value->first.size() > name.size() &&
                 value->first.compare(0, name.size(), name) == 0 &&
                 value->first.compare(name.size(), 2, "::") == 0))
                values_.erase(value++);
            else
                ++value;
        }
    }

    std::vector<std::string> FindVector(const char *name) const {
        std::vector<std::string> result;
        const std::string prefix(std::string(name) + "::");
        for (std::map<std::string, std::string>::const_iterator value(values_.begin());
             value != values_.end(); ++value)
            if (value->first.compare(0, prefix.size(), prefix) == 0)
                result.push_back(value->second);
        return result;
    }

  private:
    std::string ResolvePath(const std::string &name, const std::string &value, bool directory) const {
        if (value.empty() || value == "/dev/null")
            return ApplyRoot(value);
        std::string result(value);
        std::string key(name);
        while (result[0] != '/') {
            const std::string::size_type separator(key.rfind("::"));
            if (separator == std::string::npos)
                break;
            key.erase(separator);
            const std::string parent(Find(key.c_str()));
            if (!parent.empty())
                result = parent + "/" + result;
        }
        if (result.compare(0, 10, "/dev/null/") == 0)
            result.erase(9);
        result = ApplyRoot(result);
        if (result == "/dev/null" ||
            (result.size() > 9 && result.compare(result.size() - 9, 9, "/dev/null") == 0))
            return result;
        if (directory && result[result.size() - 1] != '/')
            result += '/';
        return result;
    }

    std::string ApplyRoot(const std::string &value) const {
        if (value.empty())
            return value;

        const std::string root(Find("RootDir"));
        if (root.empty() || root == "/")
            return value;

        std::string result(root);
        if (result[result.size() - 1] != '/')
            result += '/';
        if (value[0] == '/')
            result.append(value, 1, std::string::npos);
        else
            result += value;
        return result;
    }

    std::map<std::string, std::string> values_;
};

extern Configuration *_config;

#endif // Tests_AptStubs_Configuration_H
