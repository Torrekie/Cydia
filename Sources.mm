/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2013  Jay Freeman (saurik)
 */

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
/* }}} */

#include "CyteKit/UCPlatform.h"

#include <Foundation/Foundation.h>
#include <Menes/ObjectHandle.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <set>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

#include "Cydia/AptRuntime.hpp"
#include "Cydia/DpkgRunner.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Sources.h"

NSString *Cache_;
static NSString *CydiaManagedSourceListPath_;

static const char *kManagedBegin = "# BEGIN CYDIA MANAGED SOURCES\n";
static const char *kManagedEnd = "# END CYDIA MANAGED SOURCES\n";

/* `Sources_` is a user-facing metadata cache, not an ownership manifest.  A
 * source can remain there after an upgrade even when its old file was owned by
 * another package.  Keep a small process-local set for records explicitly
 * added during this run; records already in the marker block are discovered
 * from that block instead of being inferred from the whole preference. */
static std::set<std::string> CydiaManagedSourceKeys_;
static std::set<std::string> CydiaPendingSourceKeys_;
static std::set<std::string> CydiaDeletedSourceKeys_;
static bool CydiaManagedSourceStateInitialized_(false);

NSString *Cache(const char *file) {
    return [NSString stringWithFormat:@"%@/%s", Cache_, file];
}

extern _H<NSMutableDictionary> Sources_;

static bool ValidateManagedTargetPath(std::string *target,
                                      std::string *parent,
                                      std::string *leaf,
                                      bool report = true);

void CydiaSetManagedSourceListPath(NSString *path) {
    NSString *validated([path isKindOfClass:[NSString class]] ? path : nil);
    if (![CydiaManagedSourceListPath_ isEqual:validated]) {
        CydiaManagedSourceKeys_.clear();
        CydiaPendingSourceKeys_.clear();
        CydiaDeletedSourceKeys_.clear();
        CydiaManagedSourceStateInitialized_ = false;
    }
    CydiaManagedSourceListPath_ = [validated copy];
}

NSString *CydiaManagedSourceListPath() {
    return CydiaManagedSourceListPath_;
}

bool CydiaHasManagedSourceListPath() {
    return [CydiaManagedSourceListPath_ length] != 0;
}

bool CydiaCanEditManagedSources() {
    if (!CydiaHasManagedSourceListPath())
        return false;

    /* MobileCydia normally installs this value directly from the initialized
     * APT runtime.  Keep the check here as well so a stale preference or an
     * internal caller cannot make the UI expose an edit path that the writer
     * would later reject. */
    const char *configured([CydiaManagedSourceListPath_ fileSystemRepresentation]);
    const std::string runtime(CydiaAPT::ManagedSourceListPath());
    if (configured == NULL || runtime.empty() || runtime != configured)
        return false;

    std::string target;
    std::string parent;
    std::string leaf;
    if (!ValidateManagedTargetPath(&target, &parent, &leaf, false))
        return false;

    /* A missing leaf is valid for first materialization.  Existing leaves,
     * however, must already be regular files; the writer will repeat this
     * check immediately before the privileged handoff. */
    struct stat status;
    if (lstat(target.c_str(), &status) == 0)
        return S_ISREG(status.st_mode);
    return errno == ENOENT;
}

/* This file is private staging state.  APT never receives this path; the
 * validated maintainer path is installed separately below. */
static bool WriteStagingCache(const std::string &contents) {
    NSString *cache(SOURCES_STAGING);
    const char *destination([cache fileSystemRepresentation]);
    if (destination == NULL)
        return false;

    std::string temporary(destination);
    temporary += ".tmp.XXXXXX";
    std::vector<char> templatePath(temporary.begin(), temporary.end());
    templatePath.push_back('\0');
    const int descriptor(mkstemp(templatePath.data()));
    if (descriptor == -1)
        return false;

    if (fchmod(descriptor, 0644) == -1) {
        close(descriptor);
        unlink(templatePath.data());
        return false;
    }

    FILE *file(fdopen(descriptor, "w"));
    if (file == NULL) {
        close(descriptor);
        unlink(templatePath.data());
        return false;
    }

    const bool written(fwrite(contents.data(), 1, contents.size(), file) == contents.size());
    const bool synced(written && fflush(file) == 0 && fsync(fileno(file)) != -1);
    const bool closed(fclose(file) == 0);
    if (!written || !synced || !closed) {
        unlink(templatePath.data());
        return false;
    }

    if (rename(templatePath.data(), destination) == -1) {
        unlink(templatePath.data());
        return false;
    }
    return true;
}

static std::string TrimTrailingSlashes(const std::string &value) {
    std::string result(value);
    while (result.size() > 1 && result[result.size() - 1] == '/')
        result.erase(result.size() - 1);
    return result;
}

static bool IsDirectListLeaf(const std::string &sourceParts,
                             const std::string &target,
                             std::string *parent,
                             std::string *leaf) {
    if (parent == NULL || leaf == NULL)
        return false;

    const std::string normalizedParts(TrimTrailingSlashes(sourceParts));
    if (normalizedParts.empty() || normalizedParts[0] != '/' ||
        target.empty() || target[0] != '/')
        return false;

    const std::string::size_type slash(target.rfind('/'));
    if (slash == std::string::npos || slash == 0 ||
        target.substr(0, slash) != normalizedParts)
        return false;

    const std::string candidate(target.substr(slash + 1));
    if (candidate.empty() || candidate.find('/') != std::string::npos ||
        candidate.find('\\') != std::string::npos || candidate == "." ||
        candidate == "..")
        return false;

    const std::string suffix(".list");
    if (candidate.size() <= suffix.size() ||
        candidate.compare(candidate.size() - suffix.size(), suffix.size(), suffix) != 0)
        return false;

    *parent = target.substr(0, slash);
    *leaf = candidate;
    return *parent == normalizedParts;
}

static bool CanonicalDirectory(const std::string &path, std::string *canonical) {
    if (canonical == NULL || path.empty())
        return false;

    char resolved[PATH_MAX];
    if (realpath(path.c_str(), resolved) == NULL)
        return false;

    struct stat status;
    if (stat(resolved, &status) == -1 || !S_ISDIR(status.st_mode))
        return false;

    canonical->assign(resolved);
    return true;
}

/* The runtime validates the lexical leaf.  Re-check the relationship here at
 * the filesystem boundary as well: a maintainer sourceparts directory may be
 * a symlink, but the target's resolved parent must be that same directory.
 * This prevents a stale preference or a path-component redirect from sending
 * the privileged copy into an unrelated tree. */
static bool ValidateManagedTargetPath(std::string *target,
                                      std::string *parent,
                                      std::string *leaf,
                                      bool report) {
    if (target == NULL || parent == NULL || leaf == NULL)
        return false;

    NSString *managed(CydiaManagedSourceListPath_);
    const char *representation([managed fileSystemRepresentation]);
    if (representation == NULL)
        return false;

    const std::string candidate(representation);
    const std::string sourceParts(CydiaAPT::SourcePartsDirectory());
    if (!IsDirectListLeaf(sourceParts, candidate, parent, leaf))
        return false;

    std::string canonicalParts;
    std::string canonicalParent;
    if (!CanonicalDirectory(TrimTrailingSlashes(sourceParts), &canonicalParts) ||
        !CanonicalDirectory(*parent, &canonicalParent) ||
        canonicalParts != canonicalParent) {
        if (report)
            NSLog(@"Refusing Cydia source target outside the effective APT sourceparts directory");
        return false;
    }

    /* `lstat` intentionally allows a symlink for the sourceparts directory
     * itself (APT may use one), but the final managed leaf is never followed.
     * InstallManagedSourceFile performs the final leaf check again immediately
     * before invoking the privileged helper. */
    struct stat parentStatus;
    if (lstat(parent->c_str(), &parentStatus) == -1 ||
        (!S_ISDIR(parentStatus.st_mode) && !S_ISLNK(parentStatus.st_mode)))
        return false;

    *target = candidate;
    return true;
}

static bool ReadManagedTarget(std::string *contents) {
    if (contents == NULL)
        return false;
    contents->clear();

    std::string target;
    std::string parent;
    std::string leaf;
    if (!ValidateManagedTargetPath(&target, &parent, &leaf))
        return false;

    /* Open the leaf without following a symlink.  The privileged install
     * path performs the same lstat check immediately before replacement; the
     * descriptor here closes the read-side TOCTOU window that existed when a
     * path-based NSData load followed a swapped leaf. */
    const int descriptor(open(target.c_str(), O_RDONLY | O_NOFOLLOW));
    if (descriptor == -1)
        return errno == ENOENT;

    struct stat status;
    if (fstat(descriptor, &status) == -1 || !S_ISREG(status.st_mode)) {
        close(descriptor);
        return false;
    }

    char buffer[8192];
    bool success(true);
    for (;;) {
        const ssize_t count(read(descriptor, buffer, sizeof(buffer)));
        if (count == 0)
            break;
        if (count == -1) {
            if (errno == EINTR)
                continue;
            success = false;
            break;
        }
        contents->append(buffer, static_cast<std::size_t>(count));
    }
    if (close(descriptor) == -1)
        success = false;
    return success;
}

struct ManagedSourceDocument {
    std::string before;
    std::string body;
    std::string after;
    bool hasBlock;
};

static bool SplitManagedSourceDocument(const std::string &existing,
                                       ManagedSourceDocument *document) {
    if (document == NULL)
        return false;

    const std::string begin(kManagedBegin);
    const std::string end(kManagedEnd);
    const std::string::size_type start(existing.find(begin));
    if (start == std::string::npos) {
        document->before = existing;
        document->body.clear();
        document->after.clear();
        document->hasBlock = false;
        return true;
    }

    /* Markers are line-oriented.  Treat an inline or unterminated marker as
     * malformed rather than risking a rewrite of maintainer text. */
    if (start != 0 && existing[start - 1] != '\n')
        return false;

    const std::string::size_type finish(existing.find(end, start + begin.size()));
    if (finish == std::string::npos ||
        (finish != 0 && existing[finish - 1] != '\n'))
        return false;

    /* There is one ownership block per managed leaf.  Refuse ambiguous
     * documents so a second block cannot be silently deleted or merged. */
    if (existing.find(begin, start + begin.size()) != std::string::npos ||
        existing.find(end, finish + end.size()) != std::string::npos)
        return false;

    document->before = existing.substr(0, start);
    document->body = existing.substr(start + begin.size(),
                                     finish - (start + begin.size()));
    document->after = existing.substr(finish + end.size());
    document->hasBlock = true;
    return true;
}

static bool IsSafeSourceField(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0)
        return false;

    if ([value rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
        return false;
    return [value rangeOfString:@"#"].location == NSNotFound;
}

static bool NextSourceToken(const std::string &line, std::size_t *offset,
                            std::string *token) {
    if (offset == NULL || token == NULL)
        return false;

    token->clear();
    while (*offset < line.size() &&
           std::isspace(static_cast<unsigned char>(line[*offset])) != 0)
        ++*offset;
    if (*offset == line.size() || line[*offset] == '#')
        return false;

    const std::size_t start(*offset);
    while (*offset < line.size() &&
           std::isspace(static_cast<unsigned char>(line[*offset])) == 0)
        ++*offset;
    token->assign(line, start, *offset - start);
    return !token->empty();
}

struct ParsedSourceLine {
    std::string type;
    std::string uri;
    std::string distribution;
};

/* Parse only a classic one-line APT source definition.  Unknown syntax and
 * comments are deliberately reported as false so callers retain their bytes
 * and never mistake arbitrary prose for an existing repository. */
static bool ParseSourceLine(const std::string &line, ParsedSourceLine *source) {
    if (source == NULL)
        return false;

    source->type.clear();
    source->uri.clear();
    source->distribution.clear();

    std::size_t offset(0);
    if (!NextSourceToken(line, &offset, &source->type) ||
        (source->type != "deb" && source->type != "deb-src"))
        return false;

    std::string token;
    if (!NextSourceToken(line, &offset, &token))
        return false;
    if (!token.empty() && token[0] == '[') {
        /* APT options normally occupy one token, but accepting whitespace
         * inside the bracket keeps hand-edited managed lines recoverable. */
        while (token[token.size() - 1] != ']') {
            std::string continuation;
            if (!NextSourceToken(line, &offset, &continuation))
                return false;
            token += ' ';
            token += continuation;
        }
        if (!NextSourceToken(line, &offset, &token))
            return false;
    }

    source->uri = token;
    if (!NextSourceToken(line, &offset, &source->distribution) ||
        source->uri.empty() || source->distribution.empty())
        return false;

    return true;
}

/* Return the stable Cydia key for a one-line source record. */
static bool ParseSourceLineKey(const std::string &line, std::string *key) {
    if (key == NULL)
        return false;
    key->clear();

    ParsedSourceLine source;
    if (!ParseSourceLine(line, &source))
        return false;
    *key = source.type + ":" + source.uri + ":" + source.distribution;
    return true;
}

static bool IsDeb822FieldName(const std::string &name,
                              const char *wanted) {
    if (wanted == NULL || name.size() != std::strlen(wanted))
        return false;

    for (std::size_t index(0); index != name.size(); ++index) {
        const unsigned char lhs(static_cast<unsigned char>(name[index]));
        const unsigned char rhs(static_cast<unsigned char>(wanted[index]));
        if (std::tolower(lhs) != std::tolower(rhs))
            return false;
    }
    return true;
}

static bool URIValueContains(const std::string &value,
                             const std::string &wanted) {
    std::size_t offset(0);
    std::string token;
    while (NextSourceToken(value, &offset, &token))
        if (token == wanted)
            return true;
    return false;
}

/* Deb822 source stanzas use `URIs:` (and older/provisional producers may use
 * `URI:`) instead of the URI token in a classic `deb` line.  Parse only those
 * exact field names and their indented continuations; comments, arbitrary
 * prose, and classic lines remain untouched.  This is used solely for
 * duplicate detection, so the original bytes are never rewritten here. */
static bool HasDeb822SourceURI(const std::string &existing,
                               const std::string &wanted) {
    bool uriField(false);
    std::size_t offset(0);
    while (offset < existing.size()) {
        const std::size_t newline(existing.find('\n', offset));
        const std::size_t length(newline == std::string::npos
            ? existing.size() - offset : newline + 1 - offset);
        const std::string line(existing.substr(offset, length));

        std::size_t first(0);
        while (first < line.size() &&
               std::isspace(static_cast<unsigned char>(line[first])) != 0 &&
               line[first] != '\n' && line[first] != '\r')
            ++first;

        if (first == line.size() || line[first] == '\n' ||
            line[first] == '\r' || line[first] == '#') {
            uriField = false;
            offset += length;
            continue;
        }

        /* Deb822 continuation values are indented.  They belong to the
         * immediately preceding URI field only; an indented line elsewhere
         * must not be mistaken for a source declaration. */
        if (first != 0) {
            if (uriField && URIValueContains(line.substr(first), wanted))
                return true;
            offset += length;
            continue;
        }

        const std::size_t colon(line.find(':'));
        if (colon == std::string::npos || colon == 0) {
            uriField = false;
            offset += length;
            continue;
        }

        bool validName(true);
        for (std::size_t index(0); index != colon; ++index) {
            const unsigned char character(
                static_cast<unsigned char>(line[index]));
            if (!(std::isalnum(character) != 0 || character == '-')) {
                validName = false;
                break;
            }
        }
        if (!validName) {
            uriField = false;
            offset += length;
            continue;
        }

        const std::string name(line.substr(0, colon));
        uriField = IsDeb822FieldName(name, "URI") ||
            IsDeb822FieldName(name, "URIs");
        if (uriField && URIValueContains(line.substr(colon + 1), wanted))
            return true;

        offset += length;
    }
    return false;
}

static bool HasSourceURI(const std::string &existing, NSString *uri) {
    const char *value([uri UTF8String]);
    if (value == NULL || value[0] == '\0')
        return false;

    const std::string wanted(value);
    std::size_t offset(0);
    while (offset < existing.size()) {
        const std::size_t newline(existing.find('\n', offset));
        const std::size_t length(newline == std::string::npos
            ? existing.size() - offset : newline + 1 - offset);
        ParsedSourceLine source;
        if (ParseSourceLine(existing.substr(offset, length), &source) &&
            source.uri == wanted)
            return true;
        offset += length;
    }
    return HasDeb822SourceURI(existing, wanted);
}

static void PrimeManagedSourceState(const ManagedSourceDocument &document) {
    if (CydiaManagedSourceStateInitialized_)
        return;

    /* The marker is the persistent ownership boundary.  Reconstruct its
     * keys before the first write in a fresh process so a deletion made after
     * relaunch is not mistaken for an uninitialized file and resurrected. */
    CydiaManagedSourceKeys_.clear();
    if (document.hasBlock) {
        std::size_t offset(0);
        while (offset < document.body.size()) {
            const std::size_t newline(document.body.find('\n', offset));
            const std::size_t length(newline == std::string::npos
                ? document.body.size() - offset : newline + 1 - offset);
            std::string key;
            if (ParseSourceLineKey(document.body.substr(offset, length), &key))
                CydiaManagedSourceKeys_.insert(key);
            offset += length;
        }
    }
    CydiaManagedSourceStateInitialized_ = true;
}

static bool ManagedDocumentContainsKey(const ManagedSourceDocument &document,
                                       const std::string &wanted) {
    if (!document.hasBlock || wanted.empty())
        return false;

    std::size_t offset(0);
    while (offset < document.body.size()) {
        const std::size_t newline(document.body.find('\n', offset));
        const std::size_t length(newline == std::string::npos
            ? document.body.size() - offset : newline + 1 - offset);
        std::string key;
        if (ParseSourceLineKey(document.body.substr(offset, length), &key) &&
            key == wanted)
            return true;
        offset += length;
    }
    return false;
}

bool CydiaManagedSourceKeyIsOwned(NSString *key) {
    if (!CydiaHasManagedSourceListPath() ||
        ![key isKindOfClass:[NSString class]] || [key length] == 0)
        return false;

    const char *value([key UTF8String]);
    if (value == NULL || value[0] == '\0')
        return false;

    std::string existing;
    if (!ReadManagedTarget(&existing))
        return false;

    ManagedSourceDocument document;
    if (!SplitManagedSourceDocument(existing, &document))
        return false;
    return ManagedDocumentContainsKey(document, value);
}

void CydiaRemoveSource(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || [key length] == 0)
        return;

    const char *value([key UTF8String]);
    if (value == NULL || value[0] == '\0' || !CydiaHasManagedSourceListPath())
        return;

    /* A pending record is owned by this process even before its first marker
     * write.  Every other removal must prove that the key is inside the
     * maintainer-declared ownership block before touching Cydia preferences;
     * a stale Sources_ record must never be treated as authority. */
    if (!CydiaPendingSourceKeys_.count(value) &&
        !CydiaManagedSourceKeyIsOwned(key))
        return;

    if (Sources_ != nil)
        [Sources_ removeObjectForKey:key];

    CydiaPendingSourceKeys_.erase(value);
    CydiaDeletedSourceKeys_.insert(value);
}

static bool FormatSourceLine(NSDictionary *source, const std::string &binaryOptions,
                             std::string *line, std::string *key) {
    if (source == nil || line == NULL || key == NULL)
        return false;

    NSString *type([source objectForKey:@"Type"]);
    NSString *uri([source objectForKey:@"URI"]);
    NSString *distribution([source objectForKey:@"Distribution"]);
    if (!IsSafeSourceField(type) || !IsSafeSourceField(uri) ||
        !IsSafeSourceField(distribution) ||
        (![type isEqualToString:@"deb"] && ![type isEqualToString:@"deb-src"]))
        return false;

    const char *typeValue([type UTF8String]);
    const char *uriValue([uri UTF8String]);
    const char *distributionValue([distribution UTF8String]);
    if (typeValue == NULL || uriValue == NULL || distributionValue == NULL)
        return false;

    NSArray *sections([source objectForKey:@"Sections"]);
    if (sections == nil)
        sections = [NSArray array];
    if (![sections isKindOfClass:[NSArray class]])
        return false;

    std::string result(typeValue);
    result += " ";
    if ([type isEqualToString:@"deb"])
        result += binaryOptions;
    result += uriValue;
    result += " ";
    result += distributionValue;

    for (id section in sections) {
        if (!IsSafeSourceField(section))
            return false;
        const char *sectionValue([section UTF8String]);
        if (sectionValue == NULL)
            return false;
        result += " ";
        result += sectionValue;
    }
    result += "\n";

    NSString *objectKey([NSString stringWithFormat:@"%@:%@:%@",
        type, uri, distribution]);
    const char *keyValue([objectKey UTF8String]);
    if (keyValue == NULL)
        return false;

    *line = result;
    *key = keyValue;
    return true;
}

static std::string BuildManagedBlock(const ManagedSourceDocument &document,
                                     const std::string &base,
                                     std::set<std::string> *managedKeys) {
    std::string body;
    std::set<std::string> represented;

    const std::string architectureOption(CydiaAPT::SourceArchitectureOption());
    const std::string binaryOptions(
        architectureOption.empty() ? std::string() : architectureOption + ' ');

    std::size_t offset(0);
    while (offset < document.body.size()) {
        const std::size_t newline(document.body.find('\n', offset));
        const std::size_t length(newline == std::string::npos
            ? document.body.size() - offset : newline + 1 - offset);
        const std::string line(document.body.substr(offset, length));
        std::string key;
        const bool parsed(ParseSourceLineKey(line, &key));

        /* The marker itself is the persistent ownership evidence.  Keep
         * marker-owned records even when a legacy preference record is
         * missing; only an explicit CydiaRemoveSource call may delete one.
         * Lines we cannot parse are retained conservatively. */
        if (!parsed || !CydiaDeletedSourceKeys_.count(key)) {
            std::string outputLine(line);
            if (parsed && CydiaManagedSourceKeys_.count(key)) {
                /* Re-render records from the current Cydia metadata so
                 * section visibility edits are reflected in APT.  If the
                 * record was lost or became invalid, retain the original
                 * marker line rather than deleting a source implicitly. */
                NSString *objectKey([NSString stringWithUTF8String:key.c_str()]);
                NSDictionary *source(objectKey == nil ? nil :
                    [Sources_ objectForKey:objectKey]);
                std::string formatted;
                std::string formattedKey;
                if (FormatSourceLine(source, binaryOptions, &formatted,
                                     &formattedKey) && formattedKey == key)
                    outputLine.swap(formatted);
            }
            body += outputLine;
            if (parsed) {
                represented.insert(key);
                if (managedKeys != NULL)
                    managedKeys->insert(key);
            }
        }
        offset += length;
    }

    for (std::set<std::string>::const_iterator pending(CydiaPendingSourceKeys_.begin());
         pending != CydiaPendingSourceKeys_.end(); ++pending) {
        if (represented.count(*pending) != 0)
            continue;

        NSString *objectKey([NSString stringWithUTF8String:pending->c_str()]);
        NSDictionary *source(objectKey == nil ? nil : [Sources_ objectForKey:objectKey]);
        std::string line;
        std::string key;
        if (!FormatSourceLine(source, binaryOptions, &line, &key))
            continue;
        NSString *uri([source objectForKey:@"URI"]);
        if (HasSourceURI(base, uri))
            continue;

        body += line;
        represented.insert(key);
        if (managedKeys != NULL)
            managedKeys->insert(key);
    }

    std::string block(kManagedBegin);
    block += body;
    if (!body.empty() && body[body.size() - 1] != '\n')
        block += '\n';
    block += kManagedEnd;
    return block;
}

static bool InstallManagedSourceFile() {
    std::string target;
    std::string parent;
    std::string leaf;
    if (!ValidateManagedTargetPath(&target, &parent, &leaf))
        return false;

    const char *staging([SOURCES_STAGING fileSystemRepresentation]);
    if (staging == NULL)
        return false;

    struct stat stagingStatus;
    if (lstat(staging, &stagingStatus) == -1 || !S_ISREG(stagingStatus.st_mode))
        return false;

    struct stat status;
    const int targetResult(lstat(target.c_str(), &status));
    if (targetResult == 0) {
        if (!S_ISREG(status.st_mode)) {
            NSLog(@"Refusing to replace non-regular Cydia source file %s", target.c_str());
            return false;
        }
    } else if (errno != ENOENT) {
        return false;
    }

    const CydiaRuntime::PackageDatabasePaths &paths(
        CydiaRuntime::PackageDatabasePaths::Current());
    CydiaRuntime::Dpkg::Runner privileged(CydiaRuntime::Dpkg::Executable::Cydo);

    std::string temporary(target);
    temporary += ".cydia-tmp-";
    temporary += std::to_string(static_cast<long long>(getpid()));
    struct stat temporaryStatus;
    const int temporaryResult(lstat(temporary.c_str(), &temporaryStatus));
    if (temporaryResult == 0 || (temporaryResult == -1 && errno != ENOENT))
        return false;

    const std::string copyPath(paths.BootstrapBSDCommandPath(
        CydiaRuntime::BootstrapBSDCommand::Copy));
    const std::string movePath(paths.BootstrapBSDCommandPath(
        CydiaRuntime::BootstrapBSDCommand::Move));
    const std::string removePath(paths.BootstrapBSDCommandPath(
        CydiaRuntime::BootstrapBSDCommand::Remove));
    if (copyPath.empty() || movePath.empty() || removePath.empty())
        return false;

    /* Clone an existing target first so the second copy (which updates only
     * the contents) retains its mode and owner.  A new target is created
     * without `-p`, allowing the privileged helper to assign the bootstrap's
     * ownership instead of inheriting the mobile staging file. */
    CydiaRuntime::Dpkg::Result copied(targetResult == 0
        ? privileged.Run({copyPath, "-p", target, temporary})
        : privileged.Run({copyPath, staging, temporary}));
    if (!copied.succeeded())
        return false;

    if (targetResult == 0) {
        copied = privileged.Run({copyPath, "-f", staging, temporary});
        if (!copied.succeeded()) {
            (void) privileged.Run({removePath, "-f", temporary});
            return false;
        }
    }

    const CydiaRuntime::Dpkg::Result moved(privileged.Run({
        movePath, "-f", temporary, target,
    }));
    if (!moved.succeeded()) {
        (void) privileged.Run({
            removePath,
            "-f", temporary,
        });
        return false;
    }
    return true;
}

bool CydiaWriteSources() {
    /* Distinguish an absent maintainer declaration (a normal read-only setup)
     * from an invalid declaration.  The latter must reach the validation
     * path and fail closed rather than being mistaken for a successful no-op. */
    if ([CydiaManagedSourceListPath_ length] == 0)
        return true;

    const std::string runtimePath(CydiaAPT::ManagedSourceListPath());
    const char *managedPath([CydiaManagedSourceListPath_ fileSystemRepresentation]);
    if (managedPath == NULL || runtimePath.empty() || runtimePath != managedPath) {
        NSLog(@"Cydia source path is not validated by the maintainer APT configuration");
        return false;
    }

    std::string existing;
    if (!ReadManagedTarget(&existing))
        return false;

    ManagedSourceDocument document;
    if (!SplitManagedSourceDocument(existing, &document)) {
        NSLog(@"Refusing to rewrite a malformed Cydia managed source block");
        return false;
    }

    PrimeManagedSourceState(document);

    /* Merely having an optional maintainer key must not create a new empty
     * file on every launch.  A source file is materialized only for a real
     * pending addition; an absent file with no pending source is left alone. */
    if (!document.hasBlock && CydiaPendingSourceKeys_.empty()) {
        CydiaManagedSourceKeys_.clear();
        CydiaManagedSourceStateInitialized_ = true;
        CydiaDeletedSourceKeys_.clear();
        return true;
    }

    /* Dedupe only against bytes outside the ownership block.  The block's
     * records are tracked by their marker and stable key, so a URL in a
     * managed comment cannot hide a newly added source. */
    std::string base(document.before);
    base += document.after;
    std::set<std::string> managedKeys;
    std::string block(BuildManagedBlock(document, base, &managedKeys));

    std::string output;
    if (document.hasBlock) {
        output = document.before;
        output += block;
        output += document.after;
    } else {
        output = document.before;
        if (!output.empty() && output[output.size() - 1] != '\n')
            output += '\n';
        output += block;
    }

    /* A pending source may be deduplicated against a maintainer-owned source
     * outside the marker.  In that case do not leave an empty marker behind;
     * the source remains under the maintainer's ownership as intended. */
    if (!document.hasBlock && managedKeys.empty()) {
        CydiaManagedSourceKeys_.clear();
        CydiaManagedSourceStateInitialized_ = true;
        CydiaPendingSourceKeys_.clear();
        CydiaDeletedSourceKeys_.clear();
        return true;
    }

    if (output == existing) {
        CydiaManagedSourceKeys_.swap(managedKeys);
        CydiaManagedSourceStateInitialized_ = true;
        CydiaPendingSourceKeys_.clear();
        CydiaDeletedSourceKeys_.clear();
        return true;
    }

    if (!WriteStagingCache(output)) {
        NSLog(@"Unable to atomically stage the Cydia source list");
        return false;
    }

    if (!InstallManagedSourceFile())
        return false;

    CydiaManagedSourceKeys_.swap(managedKeys);
    CydiaManagedSourceStateInitialized_ = true;
    CydiaPendingSourceKeys_.clear();
    CydiaDeletedSourceKeys_.clear();
    return true;
}

void CydiaAddSource(NSDictionary *source) {
    if (source == nil || !CydiaCanEditManagedSources())
        return;
    NSString *type([source objectForKey:@"Type"]);
    NSString *uri([source objectForKey:@"URI"]);
    NSString *distribution([source objectForKey:@"Distribution"]);
    if (!IsSafeSourceField(type) || !IsSafeSourceField(uri) ||
        !IsSafeSourceField(distribution) ||
        (![type isEqualToString:@"deb"] && ![type isEqualToString:@"deb-src"]))
        return;

    if (Sources_ == nil)
        return;

    NSString *key([NSString stringWithFormat:@"%@:%@:%@",
        type, uri, distribution]);
    const char *keyValue([key UTF8String]);
    if (keyValue == NULL)
        return;

    [Sources_ setObject:source forKey:key];
    CydiaDeletedSourceKeys_.erase(keyValue);
    CydiaPendingSourceKeys_.insert(keyValue);
}

void CydiaAddSource(NSString *href, NSString *distribution, NSArray *sections) {
    if (href == nil || distribution == nil)
        return;

    CydiaAddSource([NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"deb", @"Type",
        href, @"URI",
        distribution, @"Distribution",
        sections ?: [NSMutableArray array], @"Sections",
    nil]);
}
