# Architecture

Everything lives in `usb-mirror-backup.sh`. This document maps the script so
you can change it without reading all ~1150 lines first. Function names are
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
├── BACKUP_MANIFEST.txt         rewritten every non-dry run (metadata + root hash)
└── data/                       DATA_SUBDIR — the only place rsync --delete touches
    ├── <basename of source 1>
    ├── <basename of source 2>
    └── …
```

Each source is rsynced **without** a trailing slash into `data/`, so it lands
as `data/<basename>`. Consequences (see KNOWN_ISSUES): two sources with the same
basename collide, and a source removed from `SOURCES` is never deleted from sticks.

## Run flow (`main`)

| Phase | Functions | Notes |
|-------|-----------|-------|
| setup | `parse_args`, `init_tty`, `init_logging`, `trap cleanup EXIT INT TERM` | Log file created at `LOG_DIR/backup-<UTC ts>.log`; script's own SHA-256 recorded. |
| 1 Preflight | `preflight` → `require_tool`×N, `detect_rsync_capabilities`, `detect_present_sticks`; then `prompt_passphrase` | Refuses non-Darwin, empty `SOURCES`, `<2` labels. Without `--available-only` all labels must be present; with it, `>= MIN_STICKS_AVAILABLE`. Passphrase from `USB_BACKUP_PASSPHRASE` or hidden TTY prompt. |
| 2 Unlock | `unlock_volume` per present label | Skips already-unlocked volumes (still recorded in `UNLOCKED_LABELS`, so they get **locked** at the end). Waits up to 10 s for the mount. `PASSPHRASE` cleared afterwards. |
| 3 Integrity | `verify_canary` per label, `verify_canaries_match` | Canary must self-verify against `.canary.sha256` and be byte-identical to the hub's. Then `mkdir -p data/` (non-dry-run) and `run_pre_hook`. |
| 4 Sync | `sync_sources_to_hub`, `mirror_hub_to_secondaries` | `rsync -a --delete --human-readable` + excludes. No `-E`/xattrs on purpose (hashes cover content only). Missing sources are warned and skipped. |
| 5 Verify | `verify_all_sticks_identical`, `write_manifests_to_all_sticks` | `generate_file_manifest` per stick → sorted `hash  path` list; each secondary list must equal the hub's. Root hash = SHA-256 of the hub's list. |
| teardown | `cleanup` (EXIT trap) | Locks every label in `UNLOCKED_LABELS` (with force-unmount fallback), removes temp dir, prints summary, writes end-of-run log line. Exit 3 skips locking. |

## Verification details

- `generate_file_manifest`: `cd <mount>; find data <excludes-pruned> -type f -print0 | LC_ALL=C sort -z | xargs -0 -n 32 <hasher>`,
  teed to a file in a `mktemp -d` workdir and counted for the progress bar.
- Hasher: `b3sum` if installed, else `shasum -a 256` (`pick_hasher_cmd`). The same
  hasher is used for all sticks in a run, so lists are comparable. The per-file
  lists are **not** stored on the sticks; only their root hash is (in the manifest).
- `RSYNC_EXCLUDES` (macOS noise: `.DS_Store`, `._*`, `.Spotlight-V100`, …) is used
  both for rsync and as `find -prune` patterns, so the two views agree.
- The verification compares sticks **with each other**, not with `SOURCES`.

## Canary

`INTEGRITY_CANARY.txt` + `.canary.sha256` are created once at setup and copied to
every stick. Each run checks (a) the file still matches its stored hash, and
(b) all present sticks carry the identical canary. (a) detects corruption of the
volume root; (b) prevents mixing sticks from different backup sets. Because the
hash sits next to the file on the same volume, it is **not** a cryptographic
tamper seal against someone who can unlock the stick.

## Global state

Config (top of file): `LABELS`, `MIN_STICKS_AVAILABLE`, `DATA_SUBDIR`, `SOURCES`,
`RSYNC_EXCLUDES`, `LOG_DIR`, `PRE_BACKUP_HOOK`.

Runtime: `DRY_RUN`, `AVAILABLE_ONLY`, `NO_COLOR`, `PRESENT_LABELS`, `MISSING_LABELS`,
`UNLOCKED_LABELS`, `HUB_LABEL`, `LOG_FILE`, `TIMESTAMP`, `SCRIPT_PATH`, `SCRIPT_HASH`,
`PASSPHRASE`, `HASHER_CMD`, `RSYNC_PROGRESS_FLAGS`, `VERIFY_WORKDIR`,
`VERIFIED_HUB_HASHES`, `START_EPOCH`, plus TTY/colour vars and `SPINNER_PID`.

## Output channels

- **stderr**: everything the user sees (phases, marks, spinner, progress bar, summary).
- **log file**: plain-text copy of `log`/`die` lines, phase headers, full rsync and
  `diskutil` output, and hash diffs (first 30 lines) on mismatch.
- **stdout**: unused except for `--help`.

`run_rsync` tees rsync output to the log on a TTY (with progress flags chosen by
`detect_rsync_capabilities`: `--info=progress2` for rsync ≥3, `--progress` otherwise),
and sends it only to the log when not on a TTY.

## Exit codes

| Code | Meaning | Sticks at exit |
|------|---------|----------------|
| 0 | success | locked |
| 1 | usage/config error, pre-hook failure, **or any unexpected command failure under `set -e`** | locked |
| 2 | prerequisite missing (tool, volume, data dir) | locked |
| 3 | hash mismatch between sticks | **left unlocked** for forensics (currently unreachable, see KNOWN_ISSUES #1) |
| 4 | canary failure | locked |
| 5 | unlock/mount failure | locked |
| 6 | rsync failure | locked |
