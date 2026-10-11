# Privileged application authorization

`cydo` authorizes a non-root caller only when its immediate parent is the
installed Cydia application. It retains the launchd job PID, executable inode,
and rejection of `DYLD_` environment overrides. It additionally compares the
kernel's running-process CodeDirectory hash with `application.cdhashes` beside
the installed helper. The final signed application supplies that manifest at
package build time; it contains only hexadecimal hashes, including supported
signature variants and executable slices.

The kernel query uses `csops(CS_OPS_CDHASH)`, which reads the running process's
executable vnode and signature rather than trusting a pathname opened later.
See [Darwin's implementation](https://github.com/apple-oss-distributions/xnu/blob/xnu-7195.81.3/bsd/kern/kern_proc.c).
The manifest is read and rechecked through the same complete root-owned,
non-writable parent-chain validation used for privileged configuration.

Shared Applications directories may be writable by bootstrap administrators.
Cydia does not change their ownership or permissions. Its own executable and
bundle directory must still be root-owned and not writable by group or others.
That leaf check alone never grants access: the parent process must match the
package's code identity before and after the launchd checks. Renaming a different
root-owned executable into the application path therefore does not authorize it.
Other privileged files and tools retain complete parent-chain validation.

Self-upgrades retain authorization for the already verified process. A normal
frontend-lock descriptor request records a protected private grant binding its
PID, kernel start time, boot epoch, code hash, and independently validated dpkg
administrator directory. The outgoing process may continue while it owns that
database's actual frontend lock. The first helper that observes lock release
changes the grant once to a five-minute finalization grace for state reload and
icon registration. Continued sessions cannot renew the grant; PID reuse, another
boot, another process or another signature cannot use it. Read-only diagnostics
never create or transition a grant. Subsequent app sessions use the current
manifest, and the upgraded application must be reopened after finalization.

Applications re-signed or replaced independently of their matching helper and
identity manifest are refused. Distributors that change the application
signature must regenerate the manifest from the final signed executable with
`scripts/write-application-identity.py` and ship the matching package contents.
Missing manifests and unavailable kernel identity queries fail closed. Root
administrative invocations retain their existing separately checked path.
