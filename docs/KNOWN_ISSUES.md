# Known issues and limitations

Updated 2026-09-27. The bugs found in the first review (wrong exit code on hash
mismatch, dry-run failures, zero counts in the summary, double cleanup on Ctrl-C,
silent `set -e` exits, stale sources, basename collisions, passphrase in the hook's
environment) are fixed and covered by tests; see `CHANGELOG.md`.

When you fix or verify something here, update this file and add a changelog entry.

## Not yet verified on a real Mac

The test suite runs on macOS in CI (bash 3.2, openrsync), but with a **mocked `diskutil`**.
These parts have only been tested against the mock:

1. **`--init-stick`**: `diskutil eraseDisk APFSX …`, `diskutil apfs encryptVolume … -user disk -stdinpassphrase`
   and the `diskutil info` fields used for the external-disk check (`Whole`,
   `Device Location`, `Protocol`). If `encryptVolume` rejects `-stdinpassphrase` on your macOS,
   the command fails with exit 5 and tells you the new volume is not encrypted; fall back
   to the manual steps in `docs/SETUP.md`. First real use: a spare stick.
2. **Locking a freshly encrypted volume** at the end of `--init-stick` while encryption may
   still be finishing in the background.
3. **`--install-reminder`**: the plist is checked with `plutil -lint` in CI, but whether
   launchd fires it and the notification appears has not been observed.
4. **Spotlight**: `.metadata_never_index` is only a hint on recent macOS; `sudo mdutil -i off`
   is what counts.

## Limitations

### 5. Verification compares sticks with each other, not with the sources

A backup run checks that all sticks agree. A file read wrongly from the Mac would be
copied to every stick and pass. rsync's own transfer checksum makes this unlikely; a
source-vs-hub hash check was proposed but not implemented.

### 6. Corruption on the hub looks like corruption on every secondary

If a file rots on the hub (first present stick), the run reports a mismatch on *all*
secondaries (exit 3). Run `--verify-only` to see which stick really changed: it checks
each stick against its own stored hashes.

### 7. In-place modifications are mirrored

The deletion guard only counts deletions. Ransomware that encrypts files in place (same
names) passes the guard and is mirrored to the present sticks. The previous versions stay
in `history/` for `HISTORY_KEEP` changing runs, and on the offsite stick.

### 8. `history/` is not verified

Snapshots are hard links of earlier `data/` states. They are not in `BACKUP_HASHES.txt`.
Also, if rsync only changes a file's permissions or mtime (not content), it does that in
place, so the snapshot's copy gets the new metadata too (content is unaffected).

### 9. Canary is corruption detection, not tamper-proofing

`.canary.sha256` lives next to the canary on the same volume. Anyone who can unlock the
stick can change both.

### 10. "Total bytes" / "Size" is disk usage, not file size

`bytes_under_data` uses `du -sk`: allocated blocks, rounded to KiB.

### 11. Filenames containing newlines

File lists and hash files are newline-separated. A backed-up filename containing a
newline would confuse the deletion guard and the hash comparison. Not a realistic case
for this data, so not handled.

### 12. Failures inside `$(...)` are not caught by `set -e`

Bash doesn't propagate `set -e` into command substitutions (and bash 3.2 has no
`inherit_errexit`). A failing command inside `$(...)` usually yields an empty or zero
value instead of stopping the run. Only affects statistics today (`bytes_under_data`).

### 13. Two runs in the same second

The run `TIMESTAMP` has one-second resolution; it names the log file and the snapshot
directory. Two runs within one second would share both. Only happens in tests.

### 14. Apple Notes is copied live

The Notes group container holds SQLite databases with WAL files. Copying them while
Notes is running can give an inconsistent snapshot. Quit Notes first, or use
`PRE_BACKUP_HOOK` to export notes instead.

### 15. rsync progress output with openrsync

`detect_rsync_capabilities` doesn't recognise openrsync's version line and falls back to
`--progress` (per-file progress). This works (CI runs openrsync), it's just less pretty
than Homebrew rsync 3.x's single progress line.
