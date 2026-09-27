# Architecture

Everything lives in `usb-mirror-backup.sh`. This document maps the script so
you can change it without reading all ~2000 lines first. Function names are
used as anchors; line numbers drift.

## Topology

```
                            ┌──→ BACKUP_B
SOURCES ──→ BACKUP_A (hub) ─┼──→ BACKUP_C
                            └──→ BACKUP_D   (may be offsite / missing)
```

- **Hub** = first label in `LABELS` that is present this run (`PRESENT_LABELS[0]`).
  If `BACKUP_A` is offsite, `BACKUP_B` is the hub. The hub role is per run, not fixed.
- **Secondaries** are always written from the hub, never from each other, so
  corruption on one secondary cannot spread to another.
- Sources are authoritative: every run makes the hub match `SOURCES`, then
  makes every secondary match the hub.

## On-stick layout

```
/Volumes/BACKUP_X/              APFS (case-sensitive), encrypted, same passphrase on all sticks
├── INTEGRITY_CANARY.txt        identical on every stick of one backup set (created at setup)
├── .canary.sha256              `shasum -a 256` line for the canary, relative path
├── .metadata_never_index       Spotlight hint (created by --init-stick)
├── BACKUP_MANIFEST.txt         rewritten every real run (metadata, hasher, root hash)
├── BACKUP_HASHES.txt           per-file "hash  data/path" list, same on all sticks after a run
├── data/                       DATA_SUBDIR — the backup
│   ├── <basename of source 1>
│   └── …
└── history/                    HISTORY_SUBDIR
    └── 2026-09-27T05-45-06Z/   state of data/ *before* that run (hard links)
```

`BACKUP_HASHES.txt` uses plain hasher output, so `cd /Volumes/X && shasum -a 256 -c BACKUP_HASHES.txt`
works without the script (or `b3sum -c` when the manifest's `Hasher:` is `b3sum`).
Sticks written by the original version have no `BACKUP_HASHES.txt` or `history/`;
everything still works with them, and the next run adds both.

## Modes (`MODE`)

| Mode | Option | Touches sticks | Log file / trap |
|------|--------|----------------|-----------------|
| `backup` | (default), `--dry-run`, `--available-only`, `--allow-deletions` | yes | yes |
| `verify` | `--verify-only` | read-only | yes |
| `init` | `--init-stick LABEL --disk DISK [--new-set]` | erases one disk | yes |
| `check-reminder` | `--check-reminder` | no | no |
| `install-reminder` / `uninstall-reminder` | `--install-reminder` / `--uninstall-reminder` | no | no |

`main` handles the reminder modes right after `load_config` and returns before logging starts.

## Backup run flow (`main`)

| Phase | Functions | Notes |
|-------|-----------|-------|
| setup | `parse_args`, `load_config`, `init_tty`, `init_logging`, traps | Config: `--config` > `$USB_BACKUP_CONFIG` > `~/.config/usb-backup/config`; refused if group/world-writable or not owned by the user. Traps: `EXIT`→`cleanup`, `INT`→`exit 130`, `TERM`→`exit 143`, `ERR`→`on_err`. |
| 1 Preflight | `preflight` (tools, `detect_rsync_capabilities`, `check_layout_config`, `normalize_sources`, `check_source_names`, `detect_present_sticks`), `mktemp` → `WORKDIR`, `prompt_passphrase` | Without `--available-only` all labels must be present; with it `>= MIN_STICKS_AVAILABLE`; `--verify-only` accepts any number ≥1. Trailing slashes are stripped from sources; duplicate basenames are refused. |
| 2 Unlock | `unlock_volume` per present label | Label goes into `UNLOCKED_LABELS` *before* `diskutil` runs, so a signal mid-unlock still gets it locked. Already-unlocked volumes are locked at the end too. |
| 3 Integrity | `verify_canary`, `verify_canaries_match`, `mkdir data/`, `run_pre_hook` | |
| 4 Sync | `check_deletion_guard`, `snapshot_sticks`, `remove_stale_sources`, `sync_sources_to_hub`, `mirror_hub_to_secondaries` | Guard runs before any write. `rsync -a --delete --human-readable` + excludes; no xattrs on purpose (hashes cover content only). |
| 5 Verify | `verify_all_sticks_identical`, `write_manifests_to_all_sticks`, `finalize_history`, `record_last_sync` | |
| teardown | `cleanup` | Locks every label in `UNLOCKED_LABELS` (force-unmount fallback), removes `WORKDIR`, prints summary. Exit 3 skips locking. Runs once (`CLEANUP_DONE`). |

## Deletion guard

`check_deletion_guard` builds, in `WORKDIR`:

- `<LABEL>.before.files`: sorted `data/...` paths on each present stick (`list_data_files`);
- `expected.files`: what `data/` will contain after the run (`plan_expected_files`):
  all files of existing sources, plus the hub's files for sources that are configured
  but missing on the Mac (those are kept, not deleted).

Per stick, `comm -23 before expected` = files this run deletes. The guard trips when
`deletions > MAX_DELETE_MIN` **and** `deletions*100 > MAX_DELETE_PERCENT*files_on_stick`.
Tripped: `die 7` (nothing written yet). `--allow-deletions` overrides; `--dry-run` warns.
The list of files to delete goes to the log either way.

## History

`snapshot_sticks` first copies each stick's current `BACKUP_HASHES.txt` to
`WORKDIR/<LABEL>.prev.hashes`, then (if `HISTORY_KEEP > 0` and `data/` isn't empty) runs
`rsync -a --link-dest=<data> <data>/ history/<TIMESTAMP>/`: every file becomes a hard link.
rsync later replaces changed files by writing a temp file and renaming it, so the snapshot
keeps the old content. `finalize_history` removes the new snapshot again if the stick's
previous hash list equals the new one (nothing changed), then keeps only the newest
`HISTORY_KEEP` directories named like a timestamp. `history/` is not hash-verified.

## Verification

- `generate_file_manifest`: `cd <mount>; find data <excludes-pruned> -type f -print0 | LC_ALL=C sort -z | xargs -0 -n 32 <hasher>`,
  teed to a file in `WORKDIR` and counted for the progress bar.
- Hasher: `b3sum` if installed, else `shasum -a 256` (`pick_hasher_cmd`); `--verify-only`
  forces the hasher named in the stick's manifest (`use_hasher_named`).
- Backup runs compare the sticks **with each other** (hub vs each secondary). In dry-run,
  differences are warnings (sticks weren't synced). A real mismatch exits 3.
- `--verify-only` (`verify_stored_hashes`) compares each stick **with its own**
  `BACKUP_HASHES.txt`, so a single stick can be checked. Mismatch exits 3.
- `RSYNC_EXCLUDES` (macOS noise) is used for rsync and, via `set_find_args`, for all
  file listings, so every view of "the files" agrees.

## Canary

`INTEGRITY_CANARY.txt` + `.canary.sha256` are created once (`--init-stick --new-set`) and
copied to every stick of the set. Each run checks (a) the file still matches its stored
hash, and (b) all present sticks carry the identical canary. (a) detects corruption of the
volume root; (b) prevents mixing sticks from different backup sets. It is **not** a
tamper seal: anyone who can unlock a stick can rewrite both files.

## `--init-stick`

`init_stick`: checks label (must be in `LABELS`, must not exist yet) and disk (`diskN`, not a
partition; `diskutil info` must say `Whole: Yes` and `Device Location: External` or
`Protocol: USB`, and not `Internal`) → picks a present stick as reference (unless
`--new-set`) → asks to type the label back → unlocks the reference with the passphrase
(proves it) → `diskutil eraseDisk APFSX LABEL GPT diskN` → `diskutil apfs encryptVolume LABEL -user disk -stdinpassphrase`
→ copies or creates the canary → `mkdir data`, `.metadata_never_index`, `sudo mdutil -i off`
if interactive. `cleanup` locks the new stick and the reference.

## Reminders

`record_last_sync` (end of a real backup) writes `STATE_DIR/last-sync`: one line
`<LABEL> <epoch> <ISO time>` per stick, updating present sticks and keeping the others.
`check_reminder` sends one `osascript` notification listing: last backup older than
`REMIND_AFTER_DAYS`, sticks not synced for `REMIND_STICK_DAYS`, sticks never synced.
`install_reminder` writes `~/Library/LaunchAgents/com.backupstick.reminder.plist` (daily
10:07, `/bin/bash <script> --check-reminder [--config FILE]`) and `launchctl bootstrap`s it.

## Global state

Config (top of file, overridable by the config file): `LABELS`, `MIN_STICKS_AVAILABLE`,
`DATA_SUBDIR`, `SOURCES`, `RSYNC_EXCLUDES`, `LOG_DIR`, `VOLUMES_ROOT`, `PRE_BACKUP_HOOK`,
`MAX_DELETE_PERCENT`, `MAX_DELETE_MIN`, `HISTORY_KEEP`, `HISTORY_SUBDIR`,
`REMIND_AFTER_DAYS`, `REMIND_STICK_DAYS`, `STATE_DIR`.

Runtime: `MODE`, `DRY_RUN`, `AVAILABLE_ONLY`, `VERIFY_ONLY`, `ALLOW_DELETIONS`, `NO_COLOR`,
`CONFIG_FILE`, `INIT_*`, `PRESENT_LABELS`, `MISSING_LABELS`, `UNLOCKED_LABELS`, `HUB_LABEL`,
`LOG_FILE`, `TIMESTAMP`, `SCRIPT_PATH`, `SCRIPT_HASH`, `PASSPHRASE`, `HASHER_CMD`,
`HASHER_FORCED`, `RSYNC_PROGRESS_FLAGS`, `FIND_ARGS`, `WORKDIR`, `SNAPSHOT_LABELS`,
`VERIFIED_HUB_HASHES`, `SUMMARY_FILE_COUNT`, `SUMMARY_TOTAL_BYTES`, `START_EPOCH`,
`CLEANUP_DONE`, plus TTY/colour vars and `SPINNER_PID`.

## Output channels

- **stderr**: everything the user sees (phases, marks, spinner, progress bar, summary).
- **log file**: plain-text copy of `log`/`die` lines, phase headers, full rsync and
  `diskutil` output, files to delete, hash diffs on mismatch, unexpected errors.
- **stdout**: `--help` and `--check-reminder` messages.

## Exit codes

| Code | Meaning | Sticks at exit |
|------|---------|----------------|
| 0 | success | locked |
| 1 | usage/config error, pre-hook failure, unexpected command failure (`on_err` names it) | locked |
| 2 | prerequisite missing (tool, volume, data dir, no stored hashes for `--verify-only`) | locked |
| 3 | hash mismatch between sticks, or against stored hashes in `--verify-only` | **left unlocked** for forensics |
| 4 | canary failure | locked |
| 5 | unlock/mount/format/encrypt failure | locked |
| 6 | rsync failure (sync, mirror, snapshot) | locked |
| 7 | deletion guard tripped, nothing written | locked |
| 130/143 | SIGINT/SIGTERM | locked |
