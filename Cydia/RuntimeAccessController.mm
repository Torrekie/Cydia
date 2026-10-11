/* Copyright (C) 2026 Torrekie; SPDX-License-Identifier: GPL-3.0-or-later */
#include "Cydia/RuntimeAccessController.h"
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace CydiaRuntime { namespace RuntimeAccess {
bool ValidSnapshotToken(const char *bytes, unsigned long size) {
    if (bytes == nullptr || (size != 64 && (size != 65 || bytes[64] != '\n'))) return false;
    for (unsigned index = 0; index != 64; ++index)
        if (!((bytes[index] >= '0' && bytes[index] <= '9') ||
              (bytes[index] >= 'a' && bytes[index] <= 'f') ||
              (bytes[index] >= 'A' && bytes[index] <= 'F'))) return false;
    return true;
}
LockCheck CheckLockDescriptor(int &descriptor, pid_t owner, bool releaseInParent, unsigned timeoutMilliseconds) {
    LockCheck result = {false, false, 0, 0};
    if (descriptor < 0 || owner <= 0 || timeoutMilliseconds == 0 || timeoutMilliseconds > 10000) {
        result.errorNumber = EINVAL; return result;
    }
    int response[2], gate[2];
    if (pipe(response) != 0) { result.errorNumber = errno; return result; }
    if (pipe(gate) != 0) {
        result.errorNumber = errno; close(response[0]); close(response[1]); return result;
    }
    for (int fd : {response[0], response[1], gate[0], gate[1]})
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
            result.errorNumber = errno;
            for (int opened : {response[0], response[1], gate[0], gate[1]}) close(opened);
            return result;
        }
    const pid_t child(fork());
    if (child < 0) {
        result.errorNumber = errno;
        for (int fd : {response[0], response[1], gate[0], gate[1]}) close(fd);
        return result;
    }
    if (child == 0) {
        close(response[0]); close(gate[1]);
        char ignored;
        ssize_t ready;
        do { ready = read(gate[0], &ignored, 1); } while (ready < 0 && errno == EINTR);
        close(gate[0]);
        LockCheck observed = {false, false, 0, 0};
        struct flock lock = {};
        lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET;
        if (ready != 0 || fcntl(descriptor, F_GETLK, &lock) != 0) observed.errorNumber = errno ?: EIO;
        else {
            observed.observedOwner = lock.l_type == F_UNLCK ? 0 : lock.l_pid;
            const bool expected(releaseInParent ? observed.observedOwner == 0 : observed.observedOwner == owner);
            if (!expected) {
                observed.busy = observed.observedOwner != 0 && observed.observedOwner != owner;
                observed.errorNumber = observed.busy ? EAGAIN : EIO;
            }
            else {
                lock.l_type = F_WRLCK; lock.l_whence = SEEK_SET; lock.l_start = 0; lock.l_len = 0;
                const int acquired(fcntl(descriptor, F_SETLK, &lock));
                const int error(errno);
                if (acquired == 0) {
                    lock.l_type = F_UNLCK;
                    const bool released(fcntl(descriptor, F_SETLK, &lock) == 0);
                    observed.passed = releaseInParent && released;
                    if (!released) observed.errorNumber = errno;
                    else if (!releaseInParent) observed.errorNumber = EIO;
                } else if (releaseInParent) {
                    observed.busy = error == EACCES || error == EAGAIN; observed.errorNumber = error;
                } else observed.passed = error == EACCES || error == EAGAIN;
            }
        }
        ssize_t written;
        do { written = write(response[1], &observed, sizeof(observed)); } while (written < 0 && errno == EINTR);
        close(descriptor); close(response[1]);
        _exit(written == sizeof(observed) ? 0 : 1);
    }
    close(response[1]); close(gate[0]);
    if (releaseInParent) { close(descriptor); descriptor = -1; }
    // EOF is the signal. Writing to an observer that exited must never raise
    // SIGPIPE in the application process.
    close(gate[1]);
    const auto deadline(std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMilliseconds));
    struct pollfd input = {response[0], POLLIN, 0};
    int available;
    do {
        const auto remaining(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count());
        if (remaining <= 0) { available = 0; break; }
        available = poll(&input, 1, static_cast<int>(remaining));
    } while (available < 0 && errno == EINTR);
    ssize_t count(-1);
    if (available > 0) do { count = read(response[0], &result, sizeof(result)); } while (count < 0 && errno == EINTR);
    if (available <= 0 || count != sizeof(result)) {
        result = {false, false, available == 0 ? ETIMEDOUT : errno ?: EIO, 0};
        kill(child, SIGKILL);
    }
    close(response[0]);
    int status(0); pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        result.passed = false;
        if (result.errorNumber == 0) result.errorNumber = waited < 0 ? errno : EIO;
    }
    return result;
}
} }

#ifndef CYDIA_RUNTIME_ACCESS_TEST
#import "Cydia/Database.h"
#import "Cydia/UIColor+Cydia.h"
#import "CyteKit/Localize.h"
#include "Cydia/AptRuntime.hpp"
#include "Cydia/PrivilegedClient.h"
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <string>
#include <vector>

namespace {
NSString *AccessText(NSString *key) {
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:@"RuntimeAccess"];
}
NSString *AccessString(const std::string &value) {
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding] ?: @"";
}
struct AccessResult {
    bool passed = false;
    bool busy = false;
    bool timedOut = false;
    bool changed = false;
    std::vector<bool> checked = std::vector<bool>(6, false);
    std::string details;
};
void HelperDetails(AccessResult &result, const char *step, const CydiaRuntime::PrivilegedClient::Result &call) {
    result.timedOut = result.timedOut || call.launchError == ETIMEDOUT;
    result.details += std::string(step) + ": exit=" + std::to_string(call.exitCode) +
        ", launch=" + std::to_string(call.launchError) + ", signal=" + std::to_string(call.termSignal) + "\n" + call.error;
}
bool RejectedWithoutLock(const CydiaRuntime::PrivilegedClient::Result &call) {
    return call.launchError == 0 && call.termSignal == 0 && !call.outputLimitExceeded &&
        call.exitCode == 77 && call.output.empty() && call.error.empty();
}
AccessResult CheckAccess() {
    namespace Client = CydiaRuntime::PrivilegedClient;
    namespace Access = CydiaRuntime::RuntimeAccess;
    AccessResult result;
    const std::string helper(CydiaAPT::PrivilegedHelperPath());
    const auto request(Client::RuntimeRequest(""));
    const auto run = [&](const char *command, std::size_t limit = 8 * 1024 * 1024) {
        return Client::Run(helper, command, request, limit, 4000);
    };
    const auto runtimeBefore(run("--cydia-runtime-snapshot", 65536));
    if (!runtimeBefore.succeeded() || !Access::ValidSnapshotToken(runtimeBefore.output.data(), runtimeBefore.output.size())) {
        HelperDetails(result, "runtime snapshot", runtimeBefore); return result;
    }
    result.checked[0] = true;
    const auto trustBefore(run("--cydia-trust-snapshot", 65536));
    if (!trustBefore.succeeded() || !Access::ValidSnapshotToken(trustBefore.output.data(), trustBefore.output.size())) {
        HelperDetails(result, "trust snapshot", trustBefore); return result;
    }
    result.checked[1] = true;
    // Do not open and later close another descriptor if this process already
    // owns the POSIX lock: closing any descriptor would release that lock.
    const auto initialRead(run("--cydia-extended-state-read"));
    if (initialRead.succeeded()) { result.busy = true; return result; }
    if (!RejectedWithoutLock(initialRead)) {
        HelperDetails(result, "unlocked preflight", initialRead); return result;
    }
    int descriptor(-1);
    const unsigned previousTimeout(Client::SetLockBridgeTimeoutMilliseconds(4000));
    _error->PushToStack();
    @try {
        descriptor = GetLock(request.expected.dpkgAdmin + "/lock-frontend", false);
        if (descriptor < 0) {
            result.busy = errno == EACCES || errno == EAGAIN;
            result.timedOut = errno == ETIMEDOUT;
            result.details = "GetLock: " + std::to_string(errno) + "\n";
        } else {
            struct stat identity;
            const bool valid(fstat(descriptor, &identity) == 0 && S_ISREG(identity.st_mode) &&
                identity.st_nlink == 1 && (fcntl(descriptor, F_GETFD) & FD_CLOEXEC) != 0);
            const auto held(valid ? Access::CheckLockDescriptor(descriptor, getpid(), false) : Access::LockCheck{false, false, EIO, 0});
            result.busy = held.busy; result.timedOut = held.errorNumber == ETIMEDOUT;
            if (!held.passed) result.details = "lock ownership/exclusion: " + std::to_string(held.errorNumber) + "\n";
            else {
                result.checked[2] = true;
                const auto firstRead(run("--cydia-extended-state-read"));
                const auto secondRead(firstRead.succeeded() ? run("--cydia-extended-state-read") : firstRead);
                if (!firstRead.succeeded() || !secondRead.succeeded() || firstRead.output != secondRead.output) {
                    HelperDetails(result, "locked state read", firstRead.succeeded() ? secondRead : firstRead);
                } else {
                    result.checked[3] = true;
                    const auto released(Access::CheckLockDescriptor(descriptor, getpid(), true));
                    result.busy = released.busy; result.timedOut = released.errorNumber == ETIMEDOUT;
                    if (!released.passed) result.details = "lock release: " + std::to_string(released.errorNumber) + "\n";
                    else {
                        const auto unlockedRead(run("--cydia-extended-state-read"));
                        if (RejectedWithoutLock(unlockedRead)) result.checked[4] = true;
                        else HelperDetails(result, "unlocked state read", unlockedRead);
                    }
                }
            }
        }
    } @finally {
        if (descriptor >= 0) close(descriptor);
        _error->RevertToStack();
        Client::SetLockBridgeTimeoutMilliseconds(previousTimeout);
    }
    const auto runtimeAfter(run("--cydia-runtime-snapshot", 65536));
    const auto trustAfter(run("--cydia-trust-snapshot", 65536));
    if (!runtimeAfter.succeeded() || !trustAfter.succeeded()) {
        HelperDetails(result, "final snapshot", runtimeAfter.succeeded() ? trustAfter : runtimeAfter);
    } else {
        result.checked[5] = runtimeBefore.output == runtimeAfter.output && trustBefore.output == trustAfter.output;
        result.changed = !result.checked[5];
    }
    result.passed = true;
    for (bool checked : result.checked) result.passed = result.passed && checked;
    return result;
}
}

@interface CydiaRuntimeAccessController () <UITableViewDataSource, UITableViewDelegate>
@end
@implementation CydiaRuntimeAccessController {
    Database *database_;
    UITableView *table_;
    BOOL busy_;
    NSString *message_;
    AccessResult result_;
}
- (instancetype)initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) database_ = database;
    return self;
}
- (void)loadView {
    table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    table_.dataSource = self; table_.delegate = self;
    table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 60;
    table_.accessibilityIdentifier = @"cydia.settings.runtime-access";
    self.view = table_;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.navigationItem.title = AccessText(@"ACCESS_CHECK_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:AccessText(@"ACCESS_CHECK_START")
        style:UIBarButtonItemStyleDone target:self action:@selector(runCheck)];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 6 : result_.details.empty() ? 0 : 1;
}
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return section == 0 ? [AccessText(@"ACCESS_CHECK_EXPLANATION") stringByAppendingFormat:@"\n\n%@", message_ ?: @""] : nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell([[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]);
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = [UIColor cydiaColorForRole:CydiaColorRoleCellBackground traitCollection:cell.traitCollection];
    cell.textLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleLabel traitCollection:cell.traitCollection];
    cell.detailTextLabel.textColor = [UIColor cydiaColorForRole:CydiaColorRoleSecondaryLabel traitCollection:cell.traitCollection];
    if (path.section == 0) {
        NSArray *keys(@[@"ACCESS_CHECK_RUNTIME", @"ACCESS_CHECK_TRUST", @"ACCESS_CHECK_LOCK", @"ACCESS_CHECK_STATE", @"ACCESS_CHECK_RELEASE", @"ACCESS_CHECK_UNCHANGED"]);
        cell.textLabel.text = AccessText(keys[path.row]);
        cell.detailTextLabel.text = AccessText(result_.checked[path.row] ? @"ACCESS_CHECK_COMPLETE" : @"ACCESS_CHECK_NOT_RUN");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (result_.checked[path.row]) cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.textLabel.text = AccessText(@"ACCESS_CHECK_DETAILS"); cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section != 1) return;
    UIViewController *details([[UIViewController alloc] init]); details.navigationItem.title = AccessText(@"ACCESS_CHECK_DETAILS");
    UITextView *text([[UITextView alloc] init]); text.editable = NO;
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; text.adjustsFontForContentSizeCategory = YES;
    text.text = AccessString(result_.details); details.view = text;
    [self.navigationController pushViewController:details animated:YES];
}
- (void)runCheck {
    if (busy_) return;
    busy_ = YES; message_ = AccessText(@"ACCESS_CHECK_RUNNING"); result_ = AccessResult();
    self.navigationItem.rightBarButtonItem.enabled = NO; [table_ reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AccessResult result;
        if (![database_ beginSettingsChange]) result.busy = true;
        else {
            @try { result = CheckAccess(); }
            @finally { [database_ endSettingsChange]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            result_ = result; busy_ = NO; self.navigationItem.rightBarButtonItem.enabled = YES;
            NSString *key(result.passed ? @"ACCESS_CHECK_PASSED" : result.changed ? @"ACCESS_CHECK_CHANGED" :
                result.busy ? @"ACCESS_CHECK_BUSY" : result.timedOut ? @"ACCESS_CHECK_TIMEOUT" : @"ACCESS_CHECK_FAILED");
            message_ = AccessText(key); [table_ reloadData];
        });
    });
}
@end
#endif
