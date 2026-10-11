/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#include "CyteKit/UCPlatform.h"
#include "Cydia/PackageDatabasePaths.hpp"
#include "Cydia/PrivilegedRuntime.hpp"
#include "Cydia/ApplicationIdentity.hpp"
#include "Cydia/ApplicationSession.hpp"
#include "Cydia/SourceDocumentCommit.hpp"
#include "Cydia/RuntimeState.hpp"
#include "Cydia/KeyringImport.hpp"
#include "Cydia/RecoveryPrivileged.hpp"
#include "Cydia/DpkgRunner.h"

#include <cstdio>
#include <cstdlib>

#include <errno.h>
#include <sysexits.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <spawn.h>
#include <vector>
#include <cstring>
#include <climits>
#include <csignal>
#include <chrono>
#include <sys/sysctl.h>

#include "Cydia/LaunchServices.h"

#include <sys/stat.h>

#include <Menes/Function.h>

#include "libiosexec/libiosexec.h"

struct timeval _ltv;
bool _itv;
extern char **environ;
// Darwin's kernel returns the running executable's CodeDirectory hash, rather
// than re-opening its launchd pathname (which a shared parent can rename).
extern "C" int csops(pid_t, unsigned int, void *, size_t);

static bool CurrentApplicationAuthorized_ = false;
static CydiaRuntime::Privileged::ApplicationProcessIdentity ApplicationProcess_;

static uint64_t ApplicationSessionClock() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static bool ReadApplicationProcess(pid_t parent, CydiaRuntime::Privileged::ApplicationProcessIdentity *identity,
                                   CydiaRuntime::Privileged::ApplicationCodeHash *hash) {
    if (parent <= 1 || getppid() != parent) return false;
    if (csops(parent, 5 /* CS_OPS_CDHASH */, hash->data(), hash->size()) != 0) {
        fprintf(stderr, "Cydia kernel code-identity query failed: %s\n", strerror(errno)); return false;
    }
    struct kinfo_proc info = {}; size_t size = sizeof(info);
    int processMib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, parent};
    struct timeval boot = {}; size_t bootSize = sizeof(boot); int bootMib[] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(processMib, 4, &info, &size, NULL, 0) != 0 ||
        sysctl(bootMib, 2, &boot, &bootSize, NULL, 0) != 0) {
        fprintf(stderr, "Cydia kernel process-identity query failed: %s\n", strerror(errno)); return false;
    }
    if (size != sizeof(info) || info.kp_proc.p_pid != parent || info.kp_proc.p_starttime.tv_sec <= 0 ||
        bootSize != sizeof(boot) || boot.tv_sec <= 0) {
        fprintf(stderr, "Cydia kernel process identity is incomplete or changed.\n"); return false;
    }
    std::string hex; const char digits[] = "0123456789abcdef";
    for (unsigned char byte : *hash) { hex += digits[byte >> 4]; hex += digits[byte & 15]; }
    *identity = {std::to_string(parent), std::to_string(boot.tv_sec) + "." + std::to_string(boot.tv_usec),
        std::to_string(info.kp_proc.p_starttime.tv_sec) + "." + std::to_string(info.kp_proc.p_starttime.tv_usec), hex};
    return getppid() == parent;
}

static bool CopyExecutable(const std::string &source, const std::string &destination) {
    int input(open(source.c_str(), O_RDONLY | O_NOFOLLOW));
    if (input == -1)
        return false;

    std::string temporary(destination + ".XXXXXX");
    std::vector<char> name(temporary.begin(), temporary.end()); name.push_back('\0');
    int output(mkstemp(name.data()));
    if (output == -1) {
        close(input);
        return false;
    }

    bool success(fchmod(output, 0755) == 0 && fchown(output, 0, 0) == 0);
    char buffer[64 * 1024];
    for (;;) {
        ssize_t count(read(input, buffer, sizeof(buffer)));
        if (count == 0)
            break;
        if (count == -1) {
            if (errno == EINTR)
                continue;
            success = false;
            break;
        }
        for (ssize_t offset(0); offset != count;) {
            ssize_t written(write(output, buffer + offset, count - offset));
            if (written == -1 && errno == EINTR)
                continue;
            if (written <= 0) {
                success = false;
                break;
            }
            offset += written;
        }
        if (!success)
            break;
    }

    if (close(input) == -1)
        success = false;
    if (fsync(output) == -1) success = false;
    if (close(output) == -1) success = false;
    if (success) success = rename(name.data(), destination.c_str()) == 0;
    if (!success)
        unlink(name.data());
    return success;
}

static unsigned DiagnosticDeadlineMilliseconds_ = 0;
static void DiagnosticDeadlineExpired(int) {
    // The client creates a private process group whose leader is this helper.
    // Elevated children cannot outlive an explicitly bounded read-only check.
    kill(0, SIGKILL);
    _exit(EX_TEMPFAIL);
}
static bool ReadDiagnosticDeadline(int *argc, char **argv) {
    const char prefix[] = "--cydia-deadline-ms=";
    if (*argc < 2 || strncmp(argv[*argc - 1], prefix, sizeof(prefix) - 1) != 0) return true;
    if (*argc < 3 || getpgrp() != getpid()) return false;
    const std::string command(argv[1]);
    if (command != "--cydia-runtime-snapshot" && command != "--cydia-trust-snapshot" &&
        command != "--cydia-extended-state-read" && command != "--cydia-open-lock") return false;
    const char *value(argv[*argc - 1] + sizeof(prefix) - 1);
    if (*value == '\0' || strlen(value) > 5) return false;
    unsigned milliseconds(0);
    for (const char *digit = value; *digit != '\0'; ++digit) {
        if (*digit < '0' || *digit > '9' || milliseconds > 10000) return false;
        milliseconds = milliseconds * 10 + static_cast<unsigned>(*digit - '0');
    }
    if (milliseconds == 0 || milliseconds > 10000) return false;
    struct sigaction action = {};
    action.sa_handler = DiagnosticDeadlineExpired;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, NULL) != 0) return false;
    sigset_t signals;
    sigemptyset(&signals); sigaddset(&signals, SIGALRM);
    if (sigprocmask(SIG_UNBLOCK, &signals, NULL) != 0) return false;
    struct itimerval timer = {};
    timer.it_value.tv_sec = milliseconds / 1000;
    timer.it_value.tv_usec = (milliseconds % 1000) * 1000;
    if (setitimer(ITIMER_REAL, &timer, NULL) != 0) return false;
    DiagnosticDeadlineMilliseconds_ = milliseconds;
    argv[--*argc] = NULL;
    return true;
}

#include <dlfcn.h>
/* Set platform binary flag */
#define FLAG_PLATFORMIZE (1 << 1)

void patch_setuidandplatformize() {
	void* handle = dlopen("/usr/lib/libjailbreak.dylib", RTLD_LAZY);
	if (!handle) return;

	// Reset errors
	dlerror();

	typedef void (*fix_setuid_prt_t)(pid_t pid);
	fix_setuid_prt_t setuidptr = (fix_setuid_prt_t)dlsym(handle, "jb_oneshot_fix_setuid_now");

	typedef void (*fix_entitle_prt_t)(pid_t pid, uint32_t what);
	fix_entitle_prt_t entitleptr = (fix_entitle_prt_t)dlsym(handle, "jb_oneshot_entitle_now");

	const char *dlsym_error = dlerror();
	if (dlsym_error || setuidptr == NULL || entitleptr == NULL) {
		dlclose(handle);
		return;
	}
	setuidptr(getpid());
	setuid(0);
	entitleptr(getpid(), FLAG_PLATFORMIZE);
	dlclose(handle);
}

typedef Function<void, const char *, launch_data_t> LaunchDataIterator;

void launch_data_dict_iterate(launch_data_t data, LaunchDataIterator code) {
    launch_data_dict_iterate(data, [](launch_data_t value, const char *name, void *baton) {
        (*static_cast<LaunchDataIterator *>(baton))(name, value);
    }, &code);
}

namespace {
namespace Privileged = CydiaRuntime::Privileged;

std::string ApplicationSessionPath(const CydiaRuntime::PackageDatabasePaths &paths) {
    return paths.CydiaStateDirectory() + "/application-session";
}

bool SaveApplicationSession(const CydiaRuntime::PackageDatabasePaths &paths, const std::string &admin, Privileged::Error *error) {
    CydiaSources::ProtectedFileSnapshot before;
    const std::string path(ApplicationSessionPath(paths));
    if (!CydiaSources::ReadProtectedFile(path, &before)) {
        if (error != NULL) { error->code = "application_session_failed"; error->message = "Cannot read the protected application upgrade session."; }
        return false;
    }
    Privileged::ApplicationSession session;
    session.process = ApplicationProcess_; session.admin = admin;
    const auto result(CydiaSources::ReplaceProtectedFile(path, before, Privileged::SerializeApplicationSession(session)));
    if (!result.succeeded() && error != NULL) {
        error->code = "application_session_failed"; error->message = "Could not preserve this application's upgrade session.";
    }
    return result.succeeded();
}

bool ContinueApplicationSession(const CydiaRuntime::PackageDatabasePaths &paths, pid_t parent,
                                const Privileged::ApplicationProcessIdentity &process) {
    const std::string path(ApplicationSessionPath(paths));
    CydiaSources::ProtectedFileSnapshot before; Privileged::ApplicationSession session; Privileged::Error error;
    if (!Privileged::ValidateRootOwnedPath(path, false, false, &error) ||
        !CydiaSources::ReadProtectedFile(path, &before) || !before.identity.exists ||
        !Privileged::ParseApplicationSession(before.bytes, &session) || !(session.process == process)) return false;
    const uint64_t now(ApplicationSessionClock());
    pid_t owner = 0;
    if (session.graceDeadline == 0) {
        if (!Privileged::FrontendLockOwner(session.admin, &owner, &error)) return false;
        if (owner != parent) {
            // Observing release ends the transaction phase permanently. A
            // diagnostic is read-only and cannot create the finalization grace.
            if (DiagnosticDeadlineMilliseconds_ != 0 || now == 0 || now > UINT64_MAX - 300000) return false;
            session.graceDeadline = now + 300000;
            if (!CydiaSources::ReplaceProtectedFile(path, before, Privileged::SerializeApplicationSession(session)).succeeded()) return false;
        }
    }
    return Privileged::ApplicationSessionAllows(session, process, now, owner == parent);
}

int Denied(const Privileged::Error &error) {
    fprintf(stderr, "cydo: %s: %s\n", error.code.c_str(), error.message.c_str());
    return error.code == "frontend_busy" ? EX_TEMPFAIL : EX_NOPERM;
}

std::string Canonical(const std::string &path) {
    char *resolved = realpath(path.c_str(), NULL);
    if (resolved == NULL) return "";
    std::string result(resolved); free(resolved); return result;
}

bool InstalledPaths(CydiaRuntime::PackageDatabasePaths *paths, std::string *self) {
    uint32_t size = 0; _NSGetExecutablePath(NULL, &size);
    std::vector<char> name(size);
    if (_NSGetExecutablePath(name.data(), &size) != 0) return false;
    *self = Canonical(name.data());
    const std::size_t slash = self->rfind('/');
    if (slash == std::string::npos) return false;
    const std::string leaf = self->substr(slash + 1);
    if (leaf != "cydo" && leaf != "cydo.dummy") return false;
    for (CydiaRuntime::PackageDatabaseLayout layout : {CydiaRuntime::PackageDatabaseLayout::Rootless,
                                                       CydiaRuntime::PackageDatabaseLayout::Rootful}) {
        const auto candidate = CydiaRuntime::PackageDatabasePaths::ForLayout(layout);
        if (self->substr(0, slash) == Canonical(candidate.CydiaLibexecDirectory())) {
            *paths = candidate; return true;
        }
    }
    return false;
}

void SanitizeEnvironment(const CydiaRuntime::PackageDatabasePaths &paths) {
    std::vector<std::string> names;
    for (char **entry = ::environ; *entry != NULL; ++entry) {
        const std::string value(*entry);
        const std::string name = value.substr(0, value.find('='));
        if (name != "LANG" && name.compare(0, 3, "LC_") != 0 && name != "TERM" &&
            name != "DEBIAN_FRONTEND" && name != "DPKG_COLORS") names.push_back(name);
    }
    for (const std::string &name : names) unsetenv(name.c_str());
    setenv("PATH", paths.DpkgExecutableSearchPath().c_str(), 1);
    setenv("HOME", "/", 1);
    setenv("TMPDIR", "/tmp", 1);
    setenv("CYDIA_PACKAGE_LAYOUT", paths.layout() == CydiaRuntime::PackageDatabaseLayout::Rootless ? "rootless" : "rootful", 1);
}

volatile sig_atomic_t activeChild = -1;
volatile sig_atomic_t pendingSignal = 0;
void ForwardSignal(int signal) {
    pendingSignal = signal;
    if (activeChild > 0) kill(static_cast<pid_t>(activeChild), signal);
}

int SpawnAndWait(const std::string &tool, std::vector<std::string> arguments) {
    arguments.insert(arguments.begin(), tool);
    std::vector<char *> argv;
    for (std::string &argument : arguments) argv.push_back(const_cast<char *>(argument.c_str()));
    argv.push_back(NULL);
    for (int signal : {SIGINT, SIGTERM, SIGHUP}) std::signal(signal, ForwardSignal);
    pid_t child = fork();
    if (child == -1) { fprintf(stderr, "cydo: fork: %s\n", strerror(errno)); return EX_OSERR; }
    if (child == 0) {
        for (int signal : {SIGINT, SIGTERM, SIGHUP}) std::signal(signal, SIG_DFL);
        ie_execv(tool.c_str(), argv.data());
        fprintf(stderr, "cydo: exec: %s\n", strerror(errno));
        _exit(EX_OSERR);
    }
    activeChild = child;
    if (pendingSignal != 0) kill(child, pendingSignal);
    int status;
    while (waitpid(child, &status, 0) == -1) {
        if (errno != EINTR) return EX_OSERR;
    }
    activeChild = -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : EX_OSERR;
}

bool ReviewToken(const std::string &token) {
    if (token.size() != 64) return false;
    for (char c : token) if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) return false;
    return true;
}

int SendLock(int socket, int descriptor) {
    struct sockaddr_storage address; socklen_t length = sizeof(address);
    if (getsockname(socket, reinterpret_cast<struct sockaddr *>(&address), &length) != 0 ||
        address.ss_family != AF_UNIX) return EX_NOPERM;
    char byte = 'L'; struct iovec vector = {&byte, 1};
    union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } control = {};
    struct msghdr message = {};
    message.msg_iov = &vector; message.msg_iovlen = 1;
    message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS; header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &descriptor, sizeof(descriptor));
    return sendmsg(socket, &message, 0) == 1 ? 0 : EX_IOERR;
}

bool LegacyCommand(const CydiaRuntime::PackageDatabasePaths &paths,
                   const Privileged::Environment &environment,
                   std::string *tool, const std::vector<std::string> &args) {
    if (*tool == paths.BootstrapBinaryPath("uicache") && args.empty()) {
        const auto override = environment.executableOverrides.find("uicache");
        if (override != environment.executableOverrides.end()) *tool = override->second;
        return true;
    }
    if (*tool == "/bin/launchctl") return args.size() == 2 && args[0] == "stop" &&
        (args[1] == "com.apple.backboardd" || args[1] == "com.apple.SpringBoard");
    if (*tool == "/usr/bin/killall") return args == std::vector<std::string>({"backboardd", "SpringBoard"});
    return false;
}

int Dispatch(const CydiaRuntime::PackageDatabasePaths &paths, pid_t parent, int argc, char *argv[]) {
    Privileged::Error error;
    const std::string command = argc > 1 ? argv[1] : "";
    if (command == "--cydia-set-executable") {
        Privileged::Request request;
        std::vector<std::string> fields;
        if (argc != 2 || !Privileged::ReadRequest(STDIN_FILENO, &request, &error) ||
            !Privileged::ParseFields(request.payload, 2, &fields, &error)) return Denied(error);
        return Privileged::WriteExecutableOverride(paths, fields[0], fields[1], &error) ? 0 : Denied(error);
    }
    const bool keyPreview = command == "--cydia-key-preview";
    const bool keyImport = command == "--cydia-key-import";
    const bool keyPackage = command == "--cydia-key-package-files" || command == "--cydia-key-package-read";
    const bool preview = command == "--cydia-firmware-preview";
    const bool source = command == "--cydia-source" || command == "--cydia-source-advanced";
    const bool state = command == "--cydia-extended-state-read" || command == "--cydia-extended-state-commit";
    const bool snapshot = command == "--cydia-runtime-snapshot";
    const bool trustSnapshot = command == "--cydia-trust-snapshot";
    const bool recoveryPreview = command == "--cydia-recovery-preview";
    const bool recovery = recoveryPreview || command == "--cydia-recovery-configure" || command == "--cydia-recovery-remove";
    const bool dedicated = keyPreview || keyImport || keyPackage || preview || command == "--cydia-firmware" || source || state || snapshot || trustSnapshot || command == "--cydia-open-lock" || recovery;
    Privileged::Environment environment;
    Privileged::Request request;
    if (dedicated) {
        if (!Privileged::ReadRequest(STDIN_FILENO, &request, &error) ||
            !Privileged::ResolveEnvironment(paths, request.expected, &environment, &error)) return Denied(error);
    } else {
        const char *configuration = getenv("APT_CONFIG");
        if (!Privileged::ResolveCurrentEnvironment(paths, configuration == NULL ? "" : configuration, &environment, &error)) return Denied(error);
    }
    SanitizeEnvironment(paths);
    if (snapshot || trustSnapshot) {
        std::string token;
        if (argc != 2 || !request.payload.empty()) return EX_DATAERR;
        if (!(trustSnapshot ? Privileged::TrustSnapshot(environment, &token, &error) :
                Privileged::RuntimeSnapshot(environment, &token, &error))) return Denied(error);
        return fprintf(stdout, "%s\n", token.c_str()) > 0 && fflush(stdout) == 0 ? 0 : EX_IOERR;
    }
    if (state) {
        pid_t owner(-1);
        if (argc != 2 || !Privileged::FrontendLockOwner(environment.dpkgAdmin, &owner, &error) || owner != parent ||
            !Privileged::RecheckEvidence(environment.evidence, &error)) return EX_NOPERM;
        if (command == "--cydia-extended-state-commit")
            return Privileged::CommitExtendedState(environment, request.payload, &error) ? 0 : Denied(error);
        std::string bytes;
        if (!request.payload.empty() || !Privileged::ReadExtendedState(environment, &bytes, &error)) return Denied(error);
        return fwrite(bytes.data(), 1, bytes.size(), stdout) == bytes.size() && fflush(stdout) == 0 ? 0 : EX_IOERR;
    }
    if (command == "--cydia-open-lock") {
        char *end = NULL; long socket = argc == 3 ? strtol(argv[2], &end, 10) : -1;
        if (argc != 3 || end == argv[2] || *end != '\0' || socket < 3 || socket > INT_MAX ||
            !Privileged::RecheckEvidence(environment.evidence, &error)) return EX_NOPERM;
        int fd = Privileged::OpenFrontendLock(environment.dpkgAdmin, request.payload, &error);
        if (fd < 0) return Denied(error);
        // Capture only a current-package-authorized app, before its own package
        // can replace the helper/manifest. Continued sessions never renew it.
        if (CurrentApplicationAuthorized_ && DiagnosticDeadlineMilliseconds_ == 0 && request.payload == "lock-frontend" &&
            !SaveApplicationSession(paths, environment.dpkgAdmin, &error)) { close(fd); return Denied(error); }
        const int result = SendLock(static_cast<int>(socket), fd); close(fd); return result;
    }
    Privileged::FrontendLock lock;
    if (recovery) {
        std::vector<std::string> fields;
        if (argc != 2 || !Privileged::ParseFields(request.payload, recoveryPreview ? 1 : 2, &fields, &error) ||
            (!recoveryPreview && !ReviewToken(fields[1])) ||
            (!recoveryPreview && !lock.Acquire(environment.dpkgAdmin, &error)) ||
            !Privileged::RecheckEvidence(environment.evidence, &error)) return Denied(error);
        std::string architecture;
        CydiaRuntime::Dpkg::Runner query(environment.dpkg);
        if (!query.RunAndCapture({"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin,
                "--print-architecture"}, &architecture, 32768).succeeded()) return EX_UNAVAILABLE;
        while (!architecture.empty() && (architecture.back() == '\n' || architecture.back() == '\r')) architecture.pop_back();
        namespace Recovery = CydiaRuntime::Recovery;
        Recovery::Snapshot prepared;
        if (!Recovery::Prepare(environment, fields[0], architecture, &prepared, &error) ||
            !Privileged::RecheckEvidence(environment.evidence, &error)) return Denied(error);
        if (recoveryPreview) {
            const std::string output(Recovery::SerializeReview(prepared.review));
            return fwrite(output.data(), 1, output.size(), stdout) == output.size() && fflush(stdout) == 0 ? 0 : EX_IOERR;
        }
        if (fields[1] != prepared.review.token) return EX_TEMPFAIL;
        setenv("DPKG_FRONTEND_LOCKED", "1", 1);
        if (command == "--cydia-recovery-configure") {
            if (!prepared.review.analysis.canConfigure && prepared.review.analysis.state != "half-installed") return EX_NOPERM;
            if (fprintf(stdout, "CYDIA-RECOVERY-CONFIGURE-STARTED\n") < 0 || fflush(stdout) != 0) return EX_IOERR;
            return SpawnAndWait(environment.dpkg, {"--root=" + environment.dpkgRoot,
                "--admindir=" + environment.dpkgAdmin, "--configure", prepared.review.analysis.package});
        }
        if (!Privileged::ValidateRootOwnedPath(paths.CydiaStateDirectory(), true, false, &error)) return Denied(error);
        Recovery::RemovalResult result;
        const bool success(Recovery::Remove(paths.CydiaStateDirectory(), environment, fields[0], architecture, fields[1],
            [&](const std::string &package) { return SpawnAndWait(environment.dpkg, {"--root=" + environment.dpkgRoot,
                "--admindir=" + environment.dpkgAdmin, "--force-remove-reinstreq", "--remove", package}); }, &result, &error));
        if (!result.backupDirectory.empty()) fprintf(stdout, "%s\n", result.backupDirectory.c_str());
        return success ? 0 : Denied(error);
    }
    if (keyPreview || keyImport || keyPackage) {
        if (argc != 2 || (keyImport && !lock.Acquire(environment.dpkgAdmin, &error)) ||
            !Privileged::RecheckEvidence(environment.evidence, &error)) return Denied(error);
        namespace Keys = CydiaRuntime::Keyring;
        if (keyPackage) {
            std::vector<std::string> fields;
            if (!Privileged::ParseFields(request.payload, command == "--cydia-key-package-read" ? 2 : 1, &fields, &error)) return Denied(error);
            std::string output;
            if (command == "--cydia-key-package-read") {
                if (!Keys::ReadPackageKey(environment, fields[0], fields[1], &output, &error)) return Denied(error);
            } else {
                std::vector<std::string> files;
                if (!Keys::PackageKeys(environment, fields[0], &files, &error)) return Denied(error);
                output = Privileged::SerializeFields(files);
            }
            return fwrite(output.data(), 1, output.size(), stdout) == output.size() && fflush(stdout) == 0 ? 0 : EX_IOERR;
        }
        Keys::Input input;
        if (!Keys::ParseInput(request.payload, &input, &error) || (keyPreview && !input.token.empty())) return Denied(error);
        if (keyImport) return Keys::Apply(paths, environment, input, &error) ? 0 : Denied(error);
        Keys::Review review; std::string normalized;
        if (!Keys::Prepare(paths, environment, input, &review, &normalized, &error)) return Denied(error);
        const std::string output(Keys::SerializeReview(review));
        return fwrite(output.data(), 1, output.size(), stdout) == output.size() && fflush(stdout) == 0 ? 0 : EX_IOERR;
    }
    if (dedicated) {
        if (argc != 2 || (!preview && !lock.Acquire(environment.dpkgAdmin, &error)) ||
            !Privileged::RecheckEvidence(environment.evidence, &error)) return Denied(error);
        if (source) {
            CydiaSources::CommitRequest commit;
            if (!CydiaSources::ParseCommitRequest(request.payload, &commit)) return EX_DATAERR;
            if (command == "--cydia-source") {
                if (commit.kind != CydiaSources::CommitKind::EditDocument ||
                    commit.access != CydiaSources::Access::Ordinary || commit.initializePolicy) return EX_NOPERM;
                commit.access = CydiaSources::Access::Ordinary;
            } else commit.access = CydiaSources::Access::AdvancedSettings;
            const CydiaSources::EffectiveLocations locations{environment.sourceList, environment.sourceParts};
            const std::string policy(paths.CydiaStateDirectory() + "/source-protection");
            const auto result = command == "--cydia-source-advanced" && commit.kind == CydiaSources::CommitKind::EditDocument ?
                CydiaSources::CommitSourceRequestWithProtectionRefresh(locations, policy, commit) :
                CydiaSources::CommitSourceRequest(locations, policy, commit);
            if (!result.succeeded()) fprintf(stderr, "cydo: source_commit_%d: %d\n", static_cast<int>(result.status), result.errorNumber);
            return result.succeeded() ? 0 : result.status == CydiaSources::CommitStatus::StaleSnapshot ? EX_TEMPFAIL :
                result.status == CydiaSources::CommitStatus::SourceAppliedPolicyReviewRequired ? EX_IOERR : EX_NOPERM;
        }
        if (!preview && !ReviewToken(request.payload)) return EX_DATAERR;
        if (preview && !request.payload.empty()) return EX_DATAERR;
        const std::string script = paths.CydiaHelperPath("firmware.sh");
        if (!Privileged::ValidateRootOwnedPath(script, false, true, &error) ||
            !Privileged::ValidateRootOwnedPath(paths.CydiaHelperPath("firmware-discovery"), false, true, &error)) return Denied(error);
        setenv("CYDIA_FIRMWARE_ROOT", environment.dpkgRoot.c_str(), 1);
        setenv("CYDIA_FIRMWARE_ADMINDIR", environment.dpkgAdmin.c_str(), 1);
        setenv("CYDIA_FIRMWARE_DPKG", environment.dpkg.c_str(), 1);
        setenv("CYDIA_FIRMWARE_DPKG_QUERY", environment.dpkgQuery.c_str(), 1);
        setenv("CYDIA_FIRMWARE_DPKG_DEB", environment.dpkgDeb.c_str(), 1);
        if (preview) return SpawnAndWait(script, {"--preview"});
        setenv("DPKG_FRONTEND_LOCKED", "1", 1);
        return SpawnAndWait(script, {"--apply", "--require-frontend-lock", "--review-token", request.payload});
    }
    std::vector<std::string> arguments;
    const bool explicitTool = argc > 1 && argv[1][0] == '/';
    for (int index = explicitTool ? 2 : 1; index != argc; ++index) arguments.push_back(argv[index]);
    std::string tool = explicitTool ? command : environment.dpkg;
    if (tool == environment.dpkg || tool == paths.DpkgBinaryPath()) {
        tool = environment.dpkg;
        if (!Privileged::ValidateDpkgArguments(environment, arguments, &error)) return Denied(error);
        pid_t owner = 0;
        if (!Privileged::FrontendLockOwner(environment.dpkgAdmin, &owner, &error)) return Denied(error);
        if (owner != 0 && owner != parent) return EX_TEMPFAIL;
        if (owner == 0 && !lock.Acquire(environment.dpkgAdmin, &error)) return Denied(error);
        if (!Privileged::RecheckEvidence(environment.evidence, &error)) return Denied(error);
        setenv("DPKG_FRONTEND_LOCKED", "1", 1);
        arguments.insert(arguments.begin(), {"--root=" + environment.dpkgRoot, "--admindir=" + environment.dpkgAdmin});
    } else if (!LegacyCommand(paths, environment, &tool, arguments)) return EX_NOPERM;
    if (!Privileged::ValidateRootOwnedPath(tool, false, true, &error)) return Denied(error);
    return SpawnAndWait(tool, arguments);
}
} // namespace

int main(int argc, char *argv[]) {
    if (!ReadDiagnosticDeadline(&argc, argv)) return EX_NOPERM;
    auto paths(CydiaRuntime::PackageDatabasePaths::ForLayout(CydiaRuntime::PackageDatabaseLayout::Rootful));
    std::string self;
    Privileged::Error error;
    if (!InstalledPaths(&paths, &self) || !Privileged::ValidateRootOwnedPath(self, false, true, &error)) return Denied(error);
    const uid_t callerUID = getuid();
    const bool rootCaller = callerUID == 0;
    const std::string dummy(paths.CydiaHelperPath("cydo.dummy"));

    patch_setuidandplatformize();
    /* The platform fix may change real uid before the launchd fallback
     * re-execs this helper. Preserve the original caller identity so that
     * a mobile caller cannot become a root diagnostics caller on retry. */
    if (!rootCaller && setreuid(callerUID, 0) != 0) return EX_NOPERM;
    if (rootCaller) {
        if (setgid(0) != 0 || setuid(0) != 0) return EX_NOPERM;
        return Dispatch(paths, getppid(), argc, argv);
    }
    auto request(launch_data_new_string(LAUNCH_KEY_GETJOBS));
    auto response(launch_msg(request));
    launch_data_free(request);
    if ((response == NULL || launch_data_get_type(response) != LAUNCH_DATA_DICTIONARY ) && argv[0] != NULL && strcmp(argv[0], dummy.c_str()) != 0 ) {
        // A read-only diagnostic must not create the persistent compatibility
        // copy or restart itself with a renewed deadline.
        if (DiagnosticDeadlineMilliseconds_ != 0) return EX_UNAVAILABLE;
        BOOL ok=false;
        struct stat st;
        struct stat myst;
        if (stat(dummy.c_str(), &st) == 0 && stat(argv[0], &myst) == 0 && st.st_size == myst.st_size) {
            int efd = open(dummy.c_str(), O_RDONLY);
            if (efd > 0) {
                void *existing = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, efd, 0);
                if (existing != MAP_FAILED) {
                    int myself = open(argv[0], O_RDONLY);
                    if (myself>0) {
                        void *myselfmap = mmap(NULL, myst.st_size, PROT_READ, MAP_PRIVATE, myself, 0);
                        if (myselfmap != MAP_FAILED) {
                            if (memcmp(existing, myselfmap, st.st_size) == 0) {
                                ok = true;
                            }
                            munmap(myselfmap, myst.st_size);
                        }
                        close(myself);
                    }
                    munmap(existing, st.st_size);
                }
                close(efd);
            }
        }
        fprintf(stderr, "Warning: couldn't communicate with launchd , maybe we're in an intentionally broken jailbreak? Try to work around it.\n");
        if (!ok) {
            if (!CopyExecutable(paths.CydoPath(), dummy))
                return EX_UNAVAILABLE;
        }
        argv[0] = const_cast<char *>(dummy.c_str());
        ie_execv(argv[0], argv);
        _assert(false);
    }

    if (response == NULL || launch_data_get_type(response) != LAUNCH_DATA_DICTIONARY) return EX_UNAVAILABLE;

    auto parent(getppid());

    auto cydia(false);

    Privileged::Evidence applicationIdentity;
    std::set<Privileged::ApplicationCodeHash> codeHashes;
    Privileged::ApplicationCodeHash runningHash;
    struct stat correct;
    if (!Privileged::CaptureEvidence(paths.CydiaHelperPath("application.cdhashes"), false, false, &applicationIdentity, &error) ||
        !Privileged::ParseApplicationCodeHashes(applicationIdentity.bytes, &codeHashes) ||
        !Privileged::InspectApplicationExecutable(paths.CydiaApplicationPath(), &correct) ||
        !ReadApplicationProcess(parent, &ApplicationProcess_, &runningHash)) {
        fprintf(stderr, "Cydia application identity could not be verified.\n");
        return EX_NOPERM;
    }
    CurrentApplicationAuthorized_ = codeHashes.count(runningHash) != 0;
    if (!CurrentApplicationAuthorized_ && !ContinueApplicationSession(paths, parent, ApplicationProcess_)) {
        fprintf(stderr, "Cydia's running signature does not match its package. Reopen Cydia after upgrading it.\n");
        return EX_NOPERM;
    }

    launch_data_dict_iterate(response, [=, &cydia](const char *name, launch_data_t value) {
        if (launch_data_get_type(value) != LAUNCH_DATA_DICTIONARY)
            return;

        auto integer(launch_data_dict_lookup(value, LAUNCH_JOBKEY_PID));
        if (integer == NULL || launch_data_get_type(integer) != LAUNCH_DATA_INTEGER)
            return;

        auto pid(launch_data_get_integer(integer));
        if (pid != parent)
            return;

        auto variables(launch_data_dict_lookup(value, LAUNCH_JOBKEY_ENVIRONMENTVARIABLES));
        if (variables != NULL && launch_data_get_type(variables) == LAUNCH_DATA_DICTIONARY) {
            auto dyld(false);

            launch_data_dict_iterate(variables, [&dyld](const char *name, launch_data_t value) {
                if (strncmp(name, "DYLD_", 5) == 0)
                    dyld = true;
            });

            if (dyld)
                return;
        }

        auto string(launch_data_dict_lookup(value, LAUNCH_JOBKEY_PROGRAM));
        if (string == NULL || launch_data_get_type(string) != LAUNCH_DATA_STRING) {
            auto array(launch_data_dict_lookup(value, LAUNCH_JOBKEY_PROGRAMARGUMENTS));
            if (array == NULL || launch_data_get_type(array) != LAUNCH_DATA_ARRAY)
                return;
            if (launch_data_array_get_count(array) == 0)
                return;

            string = launch_data_array_get_index(array, 0);
            if (string == NULL || launch_data_get_type(string) != LAUNCH_DATA_STRING)
                return;
        }

        auto program(launch_data_get_string(string));
        if (program == NULL)
            return;

        struct stat check;
        if (lstat(program, &check) == -1)
            return;

        if (correct.st_dev == check.st_dev && correct.st_ino == check.st_ino)
            cydia = true;
    });

    Privileged::ApplicationProcessIdentity checkedProcess;
    if (!cydia || !ReadApplicationProcess(parent, &checkedProcess, &runningHash) || !(checkedProcess == ApplicationProcess_) ||
        (!CurrentApplicationAuthorized_ && !ContinueApplicationSession(paths, parent, checkedProcess)) ||
        !Privileged::RecheckEvidence({applicationIdentity}, &error)) {
        fprintf(stderr, "none shall pass\n");
        return EX_NOPERM;
    }

    launch_data_free(response);
    if (setgid(0) != 0 || setuid(0) != 0) return EX_NOPERM;
    return Dispatch(paths, parent, argc, argv);
}
