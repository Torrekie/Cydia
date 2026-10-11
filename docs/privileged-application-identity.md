# Privileged application authorization

`cydo` authorizes a non-root caller only when its immediate parent is the
installed Cydia application. It retains the launchd job PID, executable inode,
and rejection of `DYLD_` environment overrides. It additionally compares
canonical identities derived from the kernel's running-process signing data
with `application.identities` beside the installed helper. The final signed
application supplies that manifest at package build time; its versioned header
is followed by hexadecimal SHA-256 hashes truncated to 20 bytes, covering its supported
CodeDirectories and executable slices.

The kernel query uses `csops(CS_OPS_BLOB)` (operation 10), which retrieves the
running executable's cached signing blob rather than trusting a pathname opened
later. See [Darwin's implementation](https://github.com/apple-oss-distributions/xnu/blob/xnu-7195.81.3/bsd/kern/kern_proc.c).
The helper parses every primary and alternate executable CodeDirectory. Each
must have a valid format, bounds, identifier and nonempty executable-page hash
coverage; duplicate or overlapping signature slots, missing primary
directories and CodeDirectory decoys in other slots are rejected. Every
returned executable directory must produce an identity allowed by the
protected manifest. A matching directory cannot hide an additional unapproved
directory, and an empty identity set never grants access.

Both the package generator and helper canonicalize the validated CodeDirectory
bytes before hashing them. They normalize only the version field and the
XML/DER entitlement special-slot hashes (slots 5 and 7, when present). This
permits jailbreak signature loaders to rewrite that metadata while retaining
the application's executable identity. Every executable-page hash, identifier,
flag, resource and Info hash, hash-coverage field, and remaining CodeDirectory
byte stays pinned. The manifest is read and rechecked through the same complete
root-owned, non-writable parent-chain validation used for privileged
configuration.

Shared Applications directories may be writable by bootstrap administrators.
Cydia does not change their ownership or permissions. Its own executable and
bundle directory must still be root-owned and not writable by group or others.
That leaf check alone never grants access: the parent process must match the
package's code identity before and after the launchd checks. Renaming a different
root-owned executable into the application path therefore does not authorize it.
Other privileged files and tools retain complete parent-chain validation.

Self-upgrades retain authorization for the already verified process. A normal
frontend-lock descriptor request records a protected private grant binding its
PID, kernel start time, boot epoch, sorted canonical identity set, and
independently validated dpkg administrator directory. It does not bind the raw
`CS_OPS_CDHASH` value. The outgoing process may continue while it owns that
database's actual frontend lock. The first helper that observes lock release
changes the grant once to a five-minute finalization grace for state reload and
icon registration. Continued sessions cannot renew the grant; PID reuse, another
boot, another process or another canonical identity set cannot use it. Read-only
diagnostics never create or transition a grant. Subsequent app sessions use the
current manifest, and the upgraded application must be reopened after
finalization.

Signature metadata rewrites limited to the normalized version and entitlement
hashes can retain authorization. Independently changed executable code,
resources, flags or other pinned CodeDirectory metadata require a regenerated
manifest. Distributors must run `scripts/write-application-identity.py` after
final application signing and ship the matching executable, helper and
`application.identities`; changing a pinned identity without updating that
manifest is refused. Missing manifests, malformed signing data and unavailable
kernel identity queries fail closed. Root administrative invocations retain
their existing separately checked path.
The manifest starts with `CYDIA-APPLICATION-IDENTITY-1`, distinguishing canonical
identities from legacy raw signature hashes. Package inspection recomputes its
contents from the final shipped executable.
