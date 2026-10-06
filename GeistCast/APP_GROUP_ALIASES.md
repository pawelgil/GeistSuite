# Simulator app-group paths

Both broadcast shims install a decorator for
`NSFileManager.containerURLForSecurityApplicationGroupIdentifier:` synchronously
from their constructors. Installation is compiled only for iOS Simulator.

Darwin's `sockaddr_un.sun_path` holds 104 bytes. Simulator app-group containers
can exceed that before a socket filename is appended. The decorator preserves
missing containers and paths of at most 63 filesystem bytes. Longer paths get a
symlink alias with a directory path of at most 63 bytes, leaving 40 bytes for the
slash and socket filename within a 103-byte, null-terminated socket address.
Consumers still need to keep the complete socket address within that limit.

Aliases live in `/tmp/gc-<effective-user-id>/`. Their names are the first 128 bits
of SHA-256 of the canonical container path. Independent host and extension
lookups therefore converge on the same alias; different containers, simulator
device sets, and reinstallations use distinct identities. No SDK identifiers or
socket filenames participate in the policy.

The alias directory must be owned by the current user, have mode `0700`, and not
be a symlink. Creation uses `symlinkat`; an existing entry is accepted only if it
is a symlink to the exact expected target. Unexpected files, links, or permissions
are never repaired or replaced. Any failure logs a diagnostic and returns the
original URL. Aliases are retained across launches and left to temporary-directory
cleanup, avoiding deletion races with other processes.

File access through an alias reaches the original app-group container. Textual
URL equality changes for long paths, and explicitly resolving symlinks recovers
the long path. SDKs that resolve the returned URL before binding a socket still
need their own path-length handling.

`AppGroupContainerAliasesTests` exercises identity, filesystem failures, byte
limits, and concurrent creation. The repository's
`broadcastAppGroupSocketDeliversMetadata` E2E scenario uses independently injected
host and extension processes to transfer screen-sample metadata through a real
Unix socket in a long simulator app-group container.
