# `Profile.discover` calls one profile two when the snap root is a symlink

Status: **a bug, not fixed.** Found while building the Thunderbird testbed, 2026-11-13.

Started while `~/.thunderbird` existed and its own root didn't, the snap's launcher (Thunderbird
159) created `~/snap/thunderbird/common/.thunderbird -> ~/.thunderbird`. For a user migrated
from the deb that makes both of `Profile::ROOTS` one directory with one `profiles.ini`, and
`Profile.discover` raises "Found Thunderbird profiles under two roots" for what is one profile.

Fix: compare the present roots' `File.realpath` and treat equal ones as one root before calling
it ambiguous. `Profile`'s spec doesn't cover the root scan at all (`ROOTS` is a constant), so the
fix wants a seam for the roots or a spec that stubs them.
