#include "Cydia/Package.h"
#include "Cydia/Database.h"
#include "Cydia/DpkgRunner.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "CyteKit/Localize.h"
#include "CyteKit/RegEx.hpp"

#include <cstring>
#include <string>

@interface Package (Operations)
@end

@implementation Package (Operations)

- (NSArray *) files {
    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    const std::string queryPath(paths.BootstrapBinaryPath("dpkg-query"));
    const char *name([[self dpkgId] UTF8String]);
    if (queryPath.empty() || name == NULL || name[0] == '\0')
        return nil;

    std::string output;
    CydiaRuntime::Dpkg::Runner runner(queryPath);
    const CydiaRuntime::Dpkg::Result result(runner.RunAndCapture({"--listfiles", name}, &output));
    if (!result.succeeded())
        return nil;

    NSMutableArray *files = [NSMutableArray arrayWithCapacity:128];
    size_t begin(0);
    while (begin != output.size()) {
        const size_t newline(output.find('\n', begin));
        size_t end(newline == std::string::npos ? output.size() : newline);
        if (end != begin && output[end - 1] == '\r')
            --end;
        if (end != begin) {
            NSString *file([[NSString alloc] initWithBytes:output.data() + begin
                                                    length:end - begin
                                                  encoding:NSUTF8StringEncoding]);
            if (file != nil)
                [files addObject:file];
        }

        if (newline == std::string::npos)
            break;
        begin = newline + 1;
    }

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
    const char *name([[self baseId] UTF8String]);

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
