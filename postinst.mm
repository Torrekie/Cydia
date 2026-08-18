#include "CyteKit/UCPlatform.h"
#include "Cydia/DpkgRunner.h"
#include "Cydia/PackageDatabasePaths.hpp"

#include <dirent.h>
#include <Foundation/Foundation.h>
#include <strings.h>

#include <string>

#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>

#include <Menes/ObjectHandle.h>

/* Set platform binary flag */
#include <dlfcn.h>
#define FLAG_PLATFORMIZE (1 << 1)

void platformize_me() {
	void* handle = dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY);
	if (!handle) return;

	// Reset errors
	dlerror();
	typedef void (*fix_entitle_prt_t)(pid_t pid, uint32_t what);
	fix_entitle_prt_t ptr = (fix_entitle_prt_t)dlsym(handle, "jb_oneshot_entitle_now");

	const char *dlsym_error = dlerror();
	if (dlsym_error) return;

	ptr(getpid(), FLAG_PLATFORMIZE);
}

void Finish(const char *finish) {
    if (finish == NULL)
        return;

    const char *cydia(getenv("CYDIA"));
    if (cydia == NULL)
        return;

    int fd([[[[NSString stringWithUTF8String:cydia] componentsSeparatedByString:@" "] objectAtIndex:0] intValue]);

    FILE *fout(fdopen(fd, "w"));
    fprintf(fout, "finish:%s\n", finish);
    fclose(fout);
}

void UICache() {
    const char *cydia(getenv("CYDIA"));
    if (cydia == NULL)
        return;

    int fd([[[[NSString stringWithUTF8String:cydia] componentsSeparatedByString:@" "] objectAtIndex:0] intValue]);

    FILE *fout(fdopen(fd, "w"));
    fprintf(fout, "uicache:yes\n");
    fclose(fout);
}

static bool setnsfpn(const char *path) {
    if (path == NULL)
        return false;

    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());
    const std::string helper(paths.CydiaHelperPath("setnsfpn"));
    if (helper.empty())
        return false;

    CydiaRuntime::Dpkg::Runner runner(helper);
    return runner.Run({path}).succeeded();
}

static bool RemoveItem(const char *path) {
    if (path == NULL)
        return false;
    NSString *item([NSString stringWithUTF8String:path]);
    if (item == nil)
        return false;
    NSFileManager *manager([NSFileManager defaultManager]);
    if (![manager fileExistsAtPath:item])
        return true;
    return [manager removeItemAtPath:item error:NULL];
}

static bool CopyItem(const char *source, const char *destination) {
    if (source == NULL || destination == NULL)
        return false;
    NSString *from([NSString stringWithUTF8String:source]);
    NSString *to([NSString stringWithUTF8String:destination]);
    return from != nil && to != nil &&
        [[NSFileManager defaultManager] copyItemAtPath:from toPath:to error:NULL];
}

static bool MoveItem(const char *source, const char *destination) {
    if (source == NULL || destination == NULL)
        return false;
    NSString *from([NSString stringWithUTF8String:source]);
    NSString *to([NSString stringWithUTF8String:destination]);
    return from != nil && to != nil &&
        [[NSFileManager defaultManager] moveItemAtPath:from toPath:to error:NULL];
}

static bool MoveDirectoryContents(const char *source, const char *destination) {
    if (source == NULL || destination == NULL)
        return false;

    DIR *directory(opendir(source));
    if (directory == NULL)
        return false;

    bool success(true);
    while (dirent *entry = readdir(directory)) {
        const char *name(entry->d_name);
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
            continue;

        std::string from(source);
        from += '/';
        from += name;
        std::string to(destination);
        to += '/';
        to += name;
        if (rename(from.c_str(), to.c_str()) == -1) {
            success = false;
            break;
        }
    }

    closedir(directory);
    return success;
}

static void ChownTree(const char *path, uid_t uid, gid_t gid) {
    if (path == NULL)
        return;

    NSString *root([NSString stringWithUTF8String:path]);
    if (root == nil)
        return;

    chown(path, uid, gid);
    NSDirectoryEnumerator *entries([[NSFileManager defaultManager] enumeratorAtPath:root]);
    for (NSString *relative in entries) {
        NSString *item([root stringByAppendingPathComponent:relative]);
        chown([item fileSystemRepresentation], uid, gid);
    }
}

enum StashStatus {
    StashDone,
    StashFail,
    StashGood,
};

static StashStatus MoveStash() {
    if (CydiaRuntime::PackageDatabasePaths::Current().layout() ==
        CydiaRuntime::PackageDatabaseLayout::Rootless)
        return StashGood;

    struct stat stat;

    if (lstat("/var/stash", &stat) == -1)
        return errno == ENOENT ? StashGood : StashFail;
    else if (S_ISLNK(stat.st_mode))
        return StashGood;
    else if (!S_ISDIR(stat.st_mode))
        return StashFail;

    if (lstat("/var/db/stash", &stat) == -1) {
        if (errno == ENOENT)
            goto move;
        else return StashFail;
    } else if (S_ISLNK(stat.st_mode))
        // XXX: this is fixable
        return StashFail;
    else if (!S_ISDIR(stat.st_mode))
        return StashFail;
    else {
        if (!setnsfpn("/var/db/stash"))
            return StashFail;
        if (!MoveDirectoryContents("/var/db/stash", "/var/stash"))
            return StashFail;
        if (rmdir("/var/db/stash") == -1)
            return StashFail;
    } move:

    if (!setnsfpn("/var/stash"))
        return StashFail;

    if (rename("/var/stash", "/var/db/stash") == -1)
        return StashFail;
    if (symlink("/var/db/stash", "/var/stash") != -1)
        return StashDone;
    if (rename("/var/db/stash", "/var/stash") != -1)
        return StashFail;

    fprintf(stderr, "/var/stash misplaced -- DO NOT REBOOT\n");
    return StashFail;
}

static bool FixProtections() {
    const std::string &path(CydiaRuntime::PackageDatabasePaths::Current().PackageLibraryDirectory());
    mkdir(path.c_str(), 0755);
    if (!setnsfpn(path.c_str())) {
        fprintf(stderr, "failed to setnsfpn %s\n", path.c_str());
        return false;
    }

    return true;
}

static void FixPermissions() {
    DIR *stash(opendir("/var/stash"));
    if (stash == NULL)
        return;

    while (dirent *entry = readdir(stash)) {
        const char *folder(entry->d_name);
        if (strlen(folder) != 8)
            continue;
        if (strncmp(folder, "_.", 2) != 0)
            continue;

        char path[1024];
        sprintf(path, "/var/stash/%s", folder);

        struct stat stat;
        if (lstat(path, &stat) == -1)
            continue;
        if (!S_ISDIR(stat.st_mode))
            continue;

        chmod(path, 0755);
    }

    closedir(stash);
}

#define APPLICATIONS "/Applications"
static bool FixApplications() {
    char target[1024];
    ssize_t length(readlink(APPLICATIONS, target, sizeof(target)));
    if (length == -1)
        return false;

    if (length >= sizeof(target)) // >= "just in case" (I'm nervous)
        return false;
    target[length] = '\0';

    if (strlen(target) != 30)
        return false;
    if (memcmp(target, "/var/stash/Applications.", 24) != 0)
        return false;
    if (strchr(target + 24, '/') != NULL)
        return false;

    struct stat stat;
    if (lstat(target, &stat) == -1)
        return false;
    if (!S_ISDIR(stat.st_mode))
        return false;

    char temp[] = "/var/stash/_.XXXXXX";
    if (mkdtemp(temp) == NULL)
        return false;

    if (false) undo: {
        unlink(temp);
        return false;
    }

    if (chmod(temp, 0755) == -1)
        goto undo;

    char destiny[strlen(temp) + 32];
    sprintf(destiny, "%s%s", temp, APPLICATIONS);

    if (unlink(APPLICATIONS) == -1)
        goto undo;

    if (rename(target, destiny) == -1) {
        if (symlink(target, APPLICATIONS) == -1)
            fprintf(stderr, "/Applications damaged -- DO NOT REBOOT\n");
        goto undo;
    } else {
        bool success;
        if (symlink(destiny, APPLICATIONS) != -1)
            success = true;
        else {
            fprintf(stderr, "/var/stash/Applications damaged -- DO NOT REBOOT\n");
            success = false;
        }

        // unneccessary, but feels better (I'm nervous)
        symlink(destiny, target);

        [@APPLICATIONS writeToFile:[NSString stringWithFormat:@"%s.lnk", temp] atomically:YES encoding:NSNonLossyASCIIStringEncoding error:NULL];
        return success;
    }
}

int main(int argc, const char *argv[]) {
    if (argc < 2)
        return 0;
    if (strcmp(argv[1], "triggered") == 0)
        UICache();
    if (strcmp(argv[1], "configure") != 0)
        return 0;

    UICache();

    platformize_me();

    @autoreleasepool {

    bool restart(false);

    if (kCFCoreFoundationVersionNumber >= 1000 && kCFCoreFoundationVersionNumber < 1349.56) {
        if (!FixProtections())
            return 1;
        switch (MoveStash()) {
            case StashDone:
                restart = true;
                break;
            case StashFail:
                fprintf(stderr, "failed to move stash\n");
                return 1;
            case StashGood:
                break;
        }
    }

    const CydiaRuntime::PackageDatabasePaths &paths(CydiaRuntime::PackageDatabasePaths::Current());

    #define OldCache_ "/var/root/Library/Caches/com.saurik.Cydia"
    RemoveItem(OldCache_);

    NSDictionary<NSFileAttributeKey, id> *attributes = @{
        NSFileOwnerAccountID: @501,
        NSFileGroupOwnerAccountID: @501
    };
    #define NewCache_ "/var/mobile/Library/Caches/com.saurik.Cydia"
    [[NSFileManager defaultManager] createDirectoryAtPath:@NewCache_
                              withIntermediateDirectories:YES
                                               attributes:attributes
                                                    error:nil
    ];
    std::string newCacheLists(NewCache_);
    newCacheLists += "/lists";
    if (access(newCacheLists.c_str(), F_OK) != 0 && errno == ENOENT)
        CopyItem(paths.AptListsDirectory().c_str(), newCacheLists.c_str());
    ChownTree(NewCache_, 501, 501);

    const std::string oldLibrary(paths.CydiaStateDirectory());

    #define NewLibrary_ "/var/mobile/Library/Cydia"
    [[NSFileManager defaultManager] createDirectoryAtPath:@NewLibrary_
                              withIntermediateDirectories:YES
                                               attributes:attributes
                                                    error:nil
    ];

    #define Cytore_ "/metadata.cb0"

    const std::string cydiaList(paths.CydiaSourcesListPath());
    NSString *cydiaListPath([NSString stringWithUTF8String:cydiaList.c_str()]);
    unlink(cydiaList.c_str());
    if (kCFCoreFoundationVersionNumber >= 1443) {
        [[NSString stringWithFormat:@
            "deb https://apt.bingner.com/ ./\n"
            "deb http://apt.thebigboss.org/repofiles/cydia/ stable main\n"
            "deb http://cydia.zodttd.com/repo/cydia/ stable main\n"
            "deb http://apt.modmyi.com/ stable main\n"
            "deb https://repo.chariz.com/ ./\n"
            "deb https://repo.dynastic.co/ ./\n"
	] writeToFile:cydiaListPath atomically:YES];
    } else {
        [[NSString stringWithFormat:@
            "deb http://apt.saurik.com/ ios/%.2f main\n"
            "deb https://apt.bingner.com/ ./\n"
            "deb http://apt.thebigboss.org/repofiles/cydia/ stable main\n"
            "deb http://cydia.zodttd.com/repo/cydia/ stable main\n"
            "deb http://apt.modmyi.com/ stable main\n"
            "deb https://repo.chariz.com/ ./\n"
            "deb https://repo.dynastic.co/ ./\n"
        , kCFCoreFoundationVersionNumber] writeToFile:cydiaListPath atomically:YES];
    }

    std::string newLibraryMetadata(NewLibrary_);
    newLibraryMetadata += Cytore_;
    std::string newCacheMetadata(NewCache_);
    newCacheMetadata += Cytore_;
    std::string oldLibraryMetadata(oldLibrary);
    oldLibraryMetadata += Cytore_;
    if (access(newLibraryMetadata.c_str(), F_OK) != 0 && errno == ENOENT) {
        if (access(newCacheMetadata.c_str(), F_OK) == 0)
            MoveItem(newCacheMetadata.c_str(), newLibraryMetadata.c_str());
        else if (access(oldLibraryMetadata.c_str(), F_OK) == 0)
            MoveItem(oldLibraryMetadata.c_str(), newLibraryMetadata.c_str());
        chown(newLibraryMetadata.c_str(), 501, 501);
    }

    if (kCFCoreFoundationVersionNumber < 1349.56) {
        FixPermissions();

        restart |= FixApplications();
    }

    if (restart)
        Finish("restart");

    return 0;
    }
}
