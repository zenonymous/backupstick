# Changelog

All notable changes to this project. Dates are ISO-8601.

## Unreleased

### Fixed
- A hash mismatch between sticks now exits 3 and leaves the sticks unlocked, as
  documented. Before, `diff | head` under `pipefail` aborted with exit 1 and locked them.
- `--dry-run` no longer fails when a stick is out of date (e.g. the offsite stick just
  came home) or brand new; differences are reported as warnings.
- The summary shows real file and size counts (they were counted after locking: always 0).
- Ctrl-C / SIGTERM exit with 130 / 143, clean up once, and lock a stick that was being
  unlocked when the signal arrived.
- Unexpected command failures are reported with line number and command instead of a
  silent exit 1.
- Argument errors no longer print a "No such file or directory" error.
- `USB_BACKUP_PASSPHRASE` is removed from the environment after reading, so rsync and
  `PRE_BACKUP_HOOK` don't inherit it.
- Sources written as `dir/` are treated like `dir` (rsync would otherwise copy the
  contents straight into `data/`).

### Added
- **Config file**: `--config FILE`, `$USB_BACKUP_CONFIG`, or `~/.config/usb-backup/config`;
  `usb-backup.conf.example`.
- **Deletion guard**: stops before writing (new exit code 7) when a run would delete more
  than `MAX_DELETE_MIN` files and `MAX_DELETE_PERCENT` % on a stick. `--allow-deletions`.
- **Stale sources**: a source removed from `SOURCES` is removed from the sticks.
  Duplicate source basenames are refused.
- **History**: hard-linked snapshots of `data/` in `history/<timestamp>/` before each
  changing run; newest `HISTORY_KEEP` (8) kept.
- **Stored hashes**: `BACKUP_HASHES.txt` on every stick; **`--verify-only`** checks each
  present stick against it without writing.
- **`--init-stick LABEL --disk DISK [--new-set]`**: erase, format, encrypt and install
  the canary on a new stick, with safety checks.
- **Reminders**: `--check-reminder`, `--install-reminder`, `--uninstall-reminder`
  (daily launchd agent, macOS notification when a backup or a stick's sync is overdue).
- Test suite (`tests/run-tests.sh`, 57 scenarios, mocked `diskutil`) and GitHub Actions
  CI on Linux and macOS (bash 3.2, openrsync).
- Docs for agents and contributors: `CLAUDE.md`, `AGENTS.md`, `docs/ARCHITECTURE.md`,
  `docs/SETUP.md`, `docs/TESTING.md`, `docs/KNOWN_ISSUES.md`.

### Changed
- On-stick layout gains `BACKUP_HASHES.txt` and `history/`. Sticks written by the
  previous version keep working; the next backup adds both.
- `SOURCES` should now be set in the config file rather than in the script.

## 2026-04-25 — initial version

- `usb-mirror-backup.sh`: encrypted N-way USB mirror backup for macOS with
  star topology, offsite rotation (`--available-only`), canary checks,
  per-file hash verification, manifests, dry-run, and live progress UI.
- `README.md`.
