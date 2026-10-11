/* Copyright (C) 2026 Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef Cydia_PrivilegedRuntime_HPP
#define Cydia_PrivilegedRuntime_HPP

#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/SourceReaderGroups.hpp"
#include <map>
#include <string>
#include <vector>
#include <sys/stat.h>

namespace CydiaRuntime {
namespace Privileged {

struct Error {
    std::string code;
    std::string message;
};

struct ExpectedEnvironment {
    std::string aptConfigOverride;
    std::string dpkgRoot;
    std::string dpkgAdmin;
    std::string dpkg;
    std::string dpkgQuery;
    std::string dpkgDeb;
    std::string sourceList;
    std::string sourceParts;
};

struct Request {
    ExpectedEnvironment expected;
    std::string payload;
};

/* Fixed-version netstrings preserve exact bytes and have an 8 MiB limit.
 * The opaque payload is a review token or a separately encoded source edit. */
std::string SerializeRequest(const Request &request);
bool ParseRequest(const std::string &bytes, Request *request, Error *error);
bool ReadRequest(int fd, Request *request, Error *error);
std::string SerializeFields(const std::vector<std::string> &fields);
bool ParseFields(const std::string &bytes, std::size_t count,
                 std::vector<std::string> *fields, Error *error);

struct Evidence {
    std::string path;
    struct stat identity;
    bool directory;
    bool absent;
    bool identityOnly;
    bool sharedState;
    bool sourceInput;
    bool adminAccess;
    uid_t sourceReaderUID;
    gid_t sourceReaderGID;
    CydiaSources::ReaderGroups sourceReaderGroups;
    std::string sourceDelegation;
    std::string bytes;
    std::vector<std::string> entries;
};

struct Environment : ExpectedEnvironment {
    uid_t sourceReaderUID;
    gid_t sourceReaderGID;
    CydiaSources::ReaderGroups sourceReaderGroups;
    std::string extendedStates;
    // Protected APT configuration selects these; they are never wire claims.
    std::string preferences;
    std::string preferencesParts;
    std::string trusted;
    std::string trustedParts;
    std::string gpg; // Independently selected public-key verifier; validated only for key actions.
    std::vector<std::string> trustedDpkgHooks; // Canonical hooks recovered solely from protected DPkg::Options.
    std::vector<Evidence> evidence;
    std::map<std::string, std::string> executableOverrides;
    Environment() : sourceReaderUID(0), sourceReaderGID(0) {}
};

/* Validates the complete canonical parent chain as well as the leaf.
 * Symlinks may be used only through protected root-owned aliases. */
bool ValidateRootOwnedPath(const std::string &path, bool directory,
                          bool executable, Error *error);
bool ValidateDpkgAdminPath(const std::string &path, bool directory, Error *error);
bool CaptureEvidence(const std::string &path, bool directory, bool allowAbsent,
                     Evidence *evidence, Error *error);
bool CaptureAdminEvidence(const std::string &path, bool directory, bool allowAbsent,
                         Evidence *evidence, Error *error);
bool CaptureSharedStateEvidence(const std::string &path, bool directory, bool allowAbsent,
                                Evidence *evidence, Error *error);
bool CaptureSourceEvidence(const std::string &path, bool directory, bool allowAbsent,
                           Evidence *evidence, Error *error);
bool CaptureSourceEvidenceForReader(const std::string &path, bool directory, bool allowAbsent,
                                    Evidence *evidence, Error *error, uid_t uid, gid_t gid,
                                    const CydiaSources::ReaderGroups &groups = CydiaSources::ReaderGroups());
bool CapturePathIdentity(const std::string &path, bool directory, bool executable,
                         Evidence *evidence, Error *error, bool adminAccess = false);
bool RecheckEvidence(const std::vector<Evidence> &evidence, Error *error);
/* Opens only the trusted admin lock leaf. Ownership is validated after open;
 * the descriptor may be transferred, but no fcntl lock is taken here. */
int OpenFrontendLock(const std::string &adminDirectory, const std::string &leaf, Error *error);
bool FrontendLockOwner(const std::string &adminDirectory, pid_t *owner, Error *error);

class FrontendLock {
    int fd_;
  public:
    FrontendLock();
    ~FrontendLock();
    FrontendLock(const FrontendLock &) = delete;
    FrontendLock &operator=(const FrontendLock &) = delete;
    bool Acquire(const std::string &adminDirectory, Error *error);
    bool AcquirePrivate(const std::string &directory, const std::string &leaf, Error *error, bool adminAccess = false);
    bool held() const;
};

/* Root-owned private authority. Native preferences may cache the display,
 * but cannot select a privileged executable. An empty path clears a purpose. */
std::string ExecutableOverridesPath(const PackageDatabasePaths &paths);
bool ReadExecutableOverrides(const PackageDatabasePaths &paths,
                             std::map<std::string, std::string> *overrides,
                             Evidence *evidence, Error *error);
bool ReadExecutableOverridesFromPath(const std::string &path,
                             std::map<std::string, std::string> *overrides,
                             Evidence *evidence, Error *error);
bool WriteExecutableOverride(const PackageDatabasePaths &paths,
                             const std::string &purpose, const std::string &path,
                             Error *error);

/* Uses APT's existing Configuration parser and validates every read through
 * its optional embedding callback. No caller-supplied descriptor is authority. */
bool ResolveEnvironment(const PackageDatabasePaths &paths,
                        const ExpectedEnvironment &expected,
                        Environment *environment, Error *error);
bool ResolveCurrentEnvironment(const PackageDatabasePaths &paths,
                              const std::string &aptConfigOverride,
                              Environment *environment, Error *error, bool reviewAdmin = false);
bool ReviewAdminAccess(const PackageDatabasePaths &paths, const ExpectedEnvironment &expected,
                       std::string *fields, Error *error);
bool ApproveAdminAccess(const PackageDatabasePaths &paths, const ExpectedEnvironment &expected,
                        const std::string &token, Error *error);
bool RevokeAdminAccess(const PackageDatabasePaths &paths, Error *error);
bool ValidateDpkgArguments(const Environment &environment,
                           const std::vector<std::string> &arguments,
                           Error *error);

} // namespace Privileged
} // namespace CydiaRuntime
#endif
