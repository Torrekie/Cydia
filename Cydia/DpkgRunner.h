/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2026  Torrekie
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Small, shell-free boundary for invoking the device package manager.  APT
 * owns package-manager policy; this type only owns process construction and
 * exit-status reporting for the external dpkg executable.
 */

#ifndef Cydia_DpkgRunner_H
#define Cydia_DpkgRunner_H

#include <cstddef>
#include <functional>
#include <string>
#include <vector>

namespace CydiaRuntime {
namespace Dpkg {

/* The wrapper used by Cydia can launch either the privileged cydo shim or the
 * device's dpkg directly.  Callers may also pass an explicit path to Runner
 * when a rooted/rootless environment supplies a different location.
 */
enum class Executable {
    Cydo,
    DeviceDpkg,
};

enum class ResultKind {
    Exited,
    Signaled,
    LaunchFailed,
};

struct Result {
    ResultKind kind;
    int code;
    int error;

    bool succeeded() const;
};

class Runner {
  private:
    std::string executable_;

  public:
    explicit Runner(Executable executable = Executable::Cydo);
    explicit Runner(const std::string &executable);

    const std::string &executable() const;

    /*
     * Run an argv-style dpkg command without invoking a shell.  When statusFd
     * is non-negative, --status-fd and its descriptor number are appended to
     * the command unless the caller already supplied --status-fd.  The
     * descriptor is kept open across exec so dpkg/cydo can stream progress to
     * Cydia's existing status reader.
     */
    Result Run(const std::vector<std::string> &arguments, int statusFd = -1) const;

    /* Feed a bounded stdin payload to the child without invoking a shell. */
    Result RunWithInput(const std::vector<std::string> &arguments,
                        const std::string &input,
                        int statusFd = -1) const;

    /* Redirect stdout to a file using posix_spawn file actions. */
    Result RunToFile(const std::vector<std::string> &arguments,
                     const std::string &outputPath,
                     int statusFd = -1) const;

    /* Capture a bounded stdout payload while continuing to drain the child if
     * it exceeds the limit. This is intended for stable dpkg-query output,
     * not transaction progress streams. */
    Result RunAndCapture(const std::vector<std::string> &arguments,
                         std::string *output,
                         std::size_t maxBytes = 4 * 1024 * 1024,
                         int statusFd = -1) const;

    /* For disposable read-only helpers, not dpkg transactions. A timeout,
     * cancellation or output overflow terminates and reaps the helper's own
     * process group. Existing transaction invocations retain their behavior. */
    Result RunAndCaptureBounded(const std::vector<std::string> &arguments,
                               std::string *output, std::size_t maxBytes,
                               unsigned timeoutMilliseconds,
                               const std::function<bool()> &cancelled = std::function<bool()>()) const;
    /* Bidirectional variant for framed, read-only provider probes. Input is
     * capped at 8 MiB; writing and reading share the same cancellation/deadline
     * and neither direction may block the other. Not for dpkg transactions. */
    Result RunWithInputAndCaptureBounded(const std::vector<std::string> &arguments,
                               const std::string &input, std::string *output,
                               std::size_t maxBytes, unsigned timeoutMilliseconds,
                               const std::function<bool()> &cancelled = std::function<bool()>()) const;

    static std::string DefaultPath(Executable executable);

  private:
    Result RunInternal(const std::vector<std::string> &arguments,
                       int statusFd,
                       const std::string *input,
                       const std::string *outputPath,
                       std::string *capturedOutput,
                       std::size_t maxCapturedBytes,
                       unsigned timeoutMilliseconds = 0,
                       const std::function<bool()> &cancelled = std::function<bool()>()) const;
};

} // namespace Dpkg
} // namespace CydiaRuntime

#endif
