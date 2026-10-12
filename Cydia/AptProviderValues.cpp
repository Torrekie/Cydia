/* Cydia-owned APT value types; no libapt ABI dependency.
 * Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/AptCompatibility.hpp"
#include <strings.h>

namespace CydiaAPT {

std::string PackageRecordData::Field(const char *name) const {
    if (name == NULL)
        return std::string();
    std::map<std::string, std::string>::const_iterator field(fields.find(name));
    if (field != fields.end())
        return field->second;
    for (field = fields.begin(); field != fields.end(); ++field)
        if (strcasecmp(field->first.c_str(), name) == 0)
            return field->second;
    return std::string();
}

PackageStateData::PackageStateData() :
    essential(false),
    protectedPackage(false),
    ignored(false),
    broken(false),
    hasMode(false),
    half(false),
    halfConfigured(false),
    halfInstalled(false),
    hasCurrent(false),
    upgradable(false),
    candidateMatchesVersion(false),
    newInstall(false),
    deletePackage(false),
    reinstall(false),
    upgrade(false),
    downgrade(false),
    versionAvailable(false),
    installedVersionAvailable(false),
    policyCandidate(false),
    installedVersion(false),
    versionPriority(0),
    versionComparison(0)
{
}

PackageSnapshot::PackageSnapshot() :
    installedSize(0),
    sourceFileID(0),
    hasSourceFile(false),
    defaultPriority(false)
{
}

TransactionData::TransactionData() :
    downloading(0),
    resuming(0),
    removesEssential(false),
    substrate(false)
{
}

SourceSnapshot::SourceSnapshot() :
    trusted(false)
{
}

CacheStateSummary::CacheStateSummary() :
    deletes(0),
    installs(0),
    broken(0)
{
}

FetchResultData::FetchResultData() :
    completed(false)
{
}

SourceListData::SourceListData() :
    success(false)
{
}

UpdateResultData::UpdateResultData() :
    prepared(false),
    success(false),
    metadataComplete(false)
{
}

} // namespace CydiaAPT
