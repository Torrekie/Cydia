#include "Cydia/Package.h"
#include "Cydia/Database.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "CyteKit/Localize.h"
#include "CyteKit/RegEx.hpp"

#include <cstring>
#include <fstream>
#include <string>

@interface Package (Operations)
@end

@implementation Package (Operations)

- (NSArray *) files {
    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    const std::string infoPath(paths.DpkgInfoFile([static_cast<NSString *>(id_) UTF8String], ".list"));
    if (infoPath.empty())
        return nil;

    NSMutableArray *files = [NSMutableArray arrayWithCapacity:128];

    std::ifstream fin;
    fin.open(infoPath.c_str());
    if (!fin.is_open())
        return nil;

    std::string line;
    while (std::getline(fin, line))
        [files addObject:[NSString stringWithUTF8String:line.c_str()]];

    return files;
}

- (NSString *) state {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return nil;

    CydiaAPT::PackageStateData state([database_ packageState:handle_]);
    return state.state.empty() ? (NSString *) [NSNull null] : [NSString stringWithUTF8String:state.state.c_str()];
} }

- (NSString *) selection {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return nil;

    CydiaAPT::PackageStateData state([database_ packageState:handle_]);
    return state.selection.empty() ? (NSString *) [NSNull null] : [NSString stringWithUTF8String:state.selection.c_str()];
} }

- (NSArray *) warnings {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return nil;

    NSMutableArray *warnings([NSMutableArray arrayWithCapacity:4]);
    const char *name([[self id] UTF8String]);

    size_t length(strlen(name));
    if (length < 2) invalid:
        [warnings addObject:UCLocalize("ILLEGAL_PACKAGE_IDENTIFIER")];
    else for (size_t i(0); i != length; ++i)
        if (
            /* XXX: technically this is not allowed */
            (name[i] < 'A' || name[i] > 'Z') &&
            (name[i] < 'a' || name[i] > 'z') &&
            (name[i] < '0' || name[i] > '9') &&
            (i == 0 || name[i] != '+' && name[i] != '-' && name[i] != '.')
        ) goto invalid;

    if (strcmp(name, "cydia") != 0) {
        bool cydia = false;
        bool user = false;
        bool _private = false;
        bool stash = false;
        bool dbstash = false;
        bool dsstore = false;

        bool repository = [[self section] isEqualToString:@"Repositories"];

        if (NSArray *files = [self files])
            for (NSString *file in files)
                if (!cydia && [file isEqualToString:@"/Applications/Cydia.app"])
                    cydia = true;
                else if (!user && [file isEqualToString:@"/User"])
                    user = true;
                else if (!_private && [file isEqualToString:@"/private"])
                    _private = true;
                else if (!stash && [file isEqualToString:@"/var/stash"])
                    stash = true;
                else if (!dbstash && [file isEqualToString:@"/var/db/stash"])
                    dbstash = true;
                else if (!dsstore && [file hasSuffix:@"/.DS_Store"])
                    dsstore = true;

        /* XXX: this is not sensitive enough. only some folders are valid. */
        if (cydia && !repository)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"Cydia.app"]];
        if (user)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/User"]];
        if (_private)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/private"]];
        if (stash)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/var/stash"]];
        if (dbstash)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/var/db/stash"]];
        if (dsstore)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @".DS_Store"]];
    }

    return [warnings count] == 0 ? nil : warnings;
} }

- (NSArray *) applications {
    NSString *me([[NSBundle mainBundle] bundleIdentifier]);

    NSMutableArray *applications([NSMutableArray arrayWithCapacity:2]);

    static RegEx application_r("/Applications/(.*)\\.app/Info.plist");
    if (NSArray *files = [self files])
        for (NSString *file in files)
            if (application_r(file)) {
                NSDictionary *info([NSDictionary dictionaryWithContentsOfFile:file]);
                if (info == nil)
                    continue;
                NSString *id([info objectForKey:@"CFBundleIdentifier"]);
                if (id == nil || [id isEqualToString:me])
                    continue;

                NSString *display([info objectForKey:@"CFBundleDisplayName"]);
                if (display == nil)
                    display = application_r[1];

                NSString *bundle([file stringByDeletingLastPathComponent]);
                NSString *icon([info objectForKey:@"CFBundleIconFile"]);
                // XXX: maybe this should check if this is really a string, not just for length
                if (icon == nil || ![icon respondsToSelector:@selector(length)] || [icon length] == 0)
                    icon = @"icon.png";
                NSURL *url([NSURL fileURLWithPath:[bundle stringByAppendingPathComponent:icon]]);

                NSMutableArray *application([NSMutableArray arrayWithCapacity:2]);
                [applications addObject:application];

                [application addObject:id];
                [application addObject:display];
                [application addObject:url];
            }

    return [applications count] == 0 ? nil : applications;
}


- (void) clear {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return;

    (void) [database_ clearPackageHandle:handle_];
} }

- (void) install {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return;

    (void) [database_ installPackageHandle:handle_];
} }

- (void) remove {
@synchronized (database_) {
    if ([database_ era] != era_ || !handle_.valid())
        return;

    (void) [database_ removePackageHandle:handle_];
} }

@end
