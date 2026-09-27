# Known issues

Found during a code review on 2026-09-27. Items marked **verified** were
reproduced with the Linux mock harness in `docs/TESTING.md`; the others come
from reading the code or rsync/macOS behaviour and have not been run on a real Mac.

When you fix one, delete it here and add a `CHANGELOG.md` entry.

## Bugs

### 1. Hash mismatch exits 1, not 3, and locks the sticks — verified

`verify_all_sticks_identical` logs the diff with
`diff "$hub_hashes" "$other_hashes" | head -30`. `diff` returns 1 when the files
differ, `pipefail` makes the pipeline fail, and `set -e` kills the script
right there. Result: exit code **1** instead of 3, the "Mismatches:" log line is
never written, and `cleanup` **locks** the volumes, so the documented
"leave unlocked for forensics" behaviour never happens.
Fix: `{ diff … | head -30; } || true` (or `diff … | head -30 || true`).

### 2. `--dry-run` fails when a stick is out of date — verified

In dry-run mode nothing is synced, but phase 5 still hashes and compares the
sticks. If any secondary differs from the hub (e.g. the offsite stick just came
home), a dry run reports a hash mismatch and fails. Once #1 is fixed it would
exit 3 and leave the sticks unlocked. Dry run should skip the comparison
or report it as "would be updated".

### 3. The success summary always shows "Files 0 / Size 0 B" — verified

`cleanup` locks the volumes first and only then calls `print_summary`, which
counts files on the (now unmounted) hub. Compute the stats before locking,
e.g. store them in globals in `write_manifests_to_all_sticks`.

### 4. `--dry-run` on a fresh stick dies with exit 2

`mkdir -p <mount>/data` is skipped in dry-run, and `generate_file_manifest`
calls `die 2` if `data/` does not exist.

### 5. Ctrl-C / SIGTERM runs `cleanup` twice

`trap cleanup EXIT INT TERM`: the INT handler calls `exit`, which fires the EXIT
trap and runs `cleanup` again: double summary and double end-of-run log line.
The summary may also say "Backup Complete" if `$?` happened to be 0 when the
signal arrived. Usual fix: `trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM`.

### 6. Unexpected failures exit silently with code 1

Any command that fails under `set -e` outside a `die` call (e.g. `mktemp`,
`diff`, a full disk) ends the run with exit 1 and **no message** saying what
failed; the summary just says "Backup Failed". An `ERR` trap that logs
`$BASH_COMMAND` and `$LINENO` would make these diagnosable.

### 7. `die` before logging is initialised

`parse_args` runs before `init_logging`, so `die 1 "Unknown option"` writes to
`>> ""` and bash prints a "No such file or directory" error. The exit code is
still 1 by coincidence.

## Design gotchas (behaviour to be aware of)

### 8. Sources removed from `SOURCES` are never deleted from sticks — verified

Each source is rsynced as `rsync --delete <src> data/`. `--delete` only acts
inside `data/<basename>`, so a top-level entry for a removed source stays on
every stick forever (and inflates the manifest file count).

### 9. Basename collisions

`~/a/notes` and `~/b/notes` both land in `data/notes/`, and with `--delete` the
second one wipes the first one's files every run. `preflight` does not check this.

### 10. No history: deletions and corruption propagate

It is a mirror. If a source file is deleted, encrypted by ransomware, or
corrupted on the Mac, the next run faithfully copies that to every present stick.
Only the offsite stick keeps the old version, until the next rotation run.
There is no `--max-delete` safety limit or versioned copy.

### 11. Verification does not compare against the sources

Phase 5 checks that the sticks agree **with each other**. A bad read/write
between the Mac and the hub would be copied to every secondary and pass.

### 12. Per-file hashes are not stored on the sticks

Only the root hash goes into `BACKUP_MANIFEST.txt`, so a single stick (e.g. the
offsite one) cannot be checked for bit-rot on its own, without the other sticks.

### 13. Canary is corruption detection, not tamper-proofing

`.canary.sha256` lives next to the canary on the same volume. Anyone who can
unlock the stick can change both. The README says the canary "detects tampering",
which overstates what it does.

### 14. `USB_BACKUP_PASSPHRASE` stays in the environment

When the passphrase comes from the environment it is copied to `PASSPHRASE`
and cleared, but the exported variable itself is never `unset`, so child
processes (`rsync`, and the `PRE_BACKUP_HOOK` via `eval`) inherit it.

### 15. "Total bytes" is disk usage, not file size

`bytes_under_data` uses `du -sk`, which reports allocated blocks rounded to KiB.

### 16. rsync version detection and `openrsync` (unverified)

Recent macOS releases ship `openrsync` behind `/usr/bin/rsync`. Its
`--version` first line has no `N.N` token, so `detect_rsync_capabilities`
falls back to `--progress`. Whether openrsync accepts every flag used
(`--human-readable`, `--exclude=`, `--delete`) has not been checked on a real
Mac. If a run fails with exit 6 right after upgrading macOS, look here first.

### 17. Apple Notes is copied live

The Notes group container holds SQLite databases with WAL files. Copying them
while Notes is running can give an inconsistent snapshot. The README tells you to
quit Notes first; `PRE_BACKUP_HOOK` can be used to export notes instead.
