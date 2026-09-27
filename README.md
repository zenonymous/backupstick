# USB Mirror Backup

A weekly encrypted backup script for macOS that mirrors critical data to multiple USB sticks simultaneously, with offsite rotation support.

Designed for backing up irreplaceable personal data — password manager exports, cryptocurrency wallet seeds, SSH/GPG keys, browser bookmarks, notes, and a handful of important documents — to a small fleet of identical USB sticks. One run of one script writes to all present sticks, verifies them byte-for-byte, and leaves them locked.

## Features

- **Native macOS APFS encryption** (AES-XTS-256, hardware-accelerated). No third-party software, no kernel extensions, no `macFUSE`.
- **N-way mirror** with star topology: up to 4 sticks (configurable) kept identical via a single hub-and-spoke sync.
- **Offsite rotation** support: keep one stick at a remote location, run weekly with the sticks at home, do a full sync when the offsite stick comes home for rotation.
- **Cryptographic verification**: every run computes per-file hashes on all present sticks and aborts if they don't match. The per-file hash list is stored on every stick.
- **Bit-rot check for a single stick**: `--verify-only` checks each present stick against its own stored hashes, e.g. the offsite stick when it comes home, without writing anything.
- **Deletion guard**: a run that would delete a large share of the backed-up files (wiped or ransomware-encrypted source) stops before touching any stick.
- **History**: before a run changes a stick, its data is snapshotted with hard links (unchanged files cost no space). The last 8 snapshots are kept per stick.
- **Integrity canary**: a per-backup-set marker file detects corruption of the volume and refuses to mix sticks from different backup sets.
- **One-command stick setup**: `--init-stick` formats, encrypts and installs the canary on a new stick.
- **Reminders**: optional daily macOS notification when a backup is overdue or a stick hasn't been synced for weeks.
- **Live progress UI**: phase headers, status marks, rsync progress, and animated hashing progress bar — auto-disabled when output isn't a terminal.
- **Fail-safe**: trap-based cleanup ensures sticks are always locked at exit, even on `Ctrl-C` or fatal errors. On hash mismatch, sticks stay unlocked for forensics.
- **Idempotent**: re-running is safe; partial state never corrupts.
- **Tested**: ShellCheck-clean, bash 3.2 compatible (stock macOS bash), 57-scenario test suite run in CI on Linux and on macOS.

## How it works

```
                            ┌──→ BACKUP_B
sources ──→ BACKUP_A (hub) ─┼──→ BACKUP_C
                            └──→ BACKUP_D  (or "missing — offsite this week")
```

1. **Detect** which configured sticks are present
2. **Unlock** all present sticks (single passphrase prompt)
3. **Verify** the integrity canary on each stick
4. **Check** how many files this run would delete (deletion guard)
5. **Snapshot** each stick's current data into `history/`
6. **Sync** sources → hub (the first present stick)
7. **Mirror** hub → each other present stick
8. **Hash** every file on every stick and compare
9. **Write** a per-run manifest and the per-file hash list to each stick
10. **Lock** everything

A star topology (rather than a chain) ensures that silent corruption on one secondary stick can't propagate to another.

## Requirements

- macOS (Darwin) — uses `diskutil`, APFS encrypted volumes, native `shasum`
- Bash 3.2+ (stock macOS `/bin/bash` works)
- `rsync` — the stock `/usr/bin/rsync` works (on current macOS this is `openrsync`, "rsync version 2.6.9 compatible"); Homebrew rsync 3.x gives nicer progress output
- 2 or more USB sticks of identical capacity (the script uses 4 by default; minimum 2 supported)
- Optional: `b3sum` (faster hashing, used automatically if installed)

## One-time setup

Full walkthrough: [`docs/SETUP.md`](docs/SETUP.md). Short version:

```bash
# 1. Config: copy the example and list what you want to back up
mkdir -p ~/.config/usb-backup
cp usb-backup.conf.example ~/.config/usb-backup/config
chmod 600 ~/.config/usb-backup/config
$EDITOR ~/.config/usb-backup/config

# 2. First stick: starts a new backup set (ERASES disk4; find yours with: diskutil list external)
./usb-mirror-backup.sh --init-stick BACKUP_A --disk disk4 --new-set

# 3. Every further stick: keep BACKUP_A plugged in (canary is copied from it)
./usb-mirror-backup.sh --init-stick BACKUP_B --disk disk5

# (--init-stick turns Spotlight off via sudo; if it couldn't, it prints the commands)

# 4. Optional: daily reminder
./usb-mirror-backup.sh --install-reminder
```

All sticks of a set share **one passphrase** and **one canary**.

### Passphrase

A 17-character random passphrase from a password manager (94-char alphabet) provides roughly 111 bits of entropy — uncrackable against any realistic attacker, including nation-states with KDF-hardened APFS encryption. A human-chosen passphrase of the same length is far weaker (~40-60 bits of real entropy due to predictable patterns).

**Always keep a paper backup of the passphrase in at least two physically separated locations**, ideally not at the same place as your offsite stick.

## Usage

```bash
# All configured sticks must be present (default — for monthly rotation runs)
./usb-mirror-backup.sh

# Work with present sticks only (>= MIN_STICKS_AVAILABLE) — for weekly runs
# when one stick is offsite
./usb-mirror-backup.sh --available-only

# Simulate without changing anything on the sticks
./usb-mirror-backup.sh --dry-run

# Check present sticks against their stored hashes (no writes, any number of sticks)
./usb-mirror-backup.sh --verify-only

# The deletion guard stopped a run and the deletions are intended
./usb-mirror-backup.sh --allow-deletions

# Use another config file (default: ~/.config/usb-backup/config)
./usb-mirror-backup.sh --config ~/other-backup.conf

# Disable colors and animations
./usb-mirror-backup.sh --no-color

./usb-mirror-backup.sh --help
```

Stick setup and reminders: `--init-stick LABEL --disk DISK [--new-set]`, `--check-reminder`, `--install-reminder`, `--uninstall-reminder` (see `--help`).

## Configuration

Settings live in a config file, so your personal paths never end up in the script or the repo. The script looks for `--config FILE`, then `$USB_BACKUP_CONFIG`, then `~/.config/usb-backup/config`. The file is sourced as bash; it must be owned by you and not group/world-writable. Anything not set keeps the default from the top of the script. See [`usb-backup.conf.example`](usb-backup.conf.example).

```bash
LABELS=(BACKUP_A BACKUP_B BACKUP_C BACKUP_D)   # which volumes the script knows about
MIN_STICKS_AVAILABLE=3                          # --available-only refuses fewer than this
SOURCES=(                                       # what to back up (basenames must be unique)
    "${HOME}/path/to/seed.gpg"
    "${HOME}/Documents/backup-me"
    "${HOME}/.ssh"
)
PRE_BACKUP_HOOK=""                              # command run before syncing
MAX_DELETE_PERCENT=25; MAX_DELETE_MIN=10        # deletion guard (0 disables)
HISTORY_KEEP=8                                  # snapshots per stick (0 disables)
REMIND_AFTER_DAYS=8; REMIND_STICK_DAYS=42       # reminder thresholds
LOG_DIR="${HOME}/Library/Logs/usb-backup"       # where logs go
```

Each source is stored as `data/<basename>` on the sticks. Removing a source from `SOURCES` removes it from the sticks on the next run. A source that is configured but temporarily missing on the Mac is kept on the sticks.

### Deletion guard

Before writing anything, the script works out how many backed-up files this run would delete on each stick. If that is more than `MAX_DELETE_MIN` files **and** more than `MAX_DELETE_PERCENT` % of the files on a stick, it stops with exit code 7 and changes nothing. The list of files is in the log. If the deletions are intended, re-run with `--allow-deletions`.

## Suggested rotation schedule (4 sticks, 1 offsite)

- **Weekly** (3 home sticks): `./usb-mirror-backup.sh --available-only`
- **Monthly** (rotation weekend, all 4 home): `./usb-mirror-backup.sh --verify-only` first (checks the returning stick for bit-rot), then `./usb-mirror-backup.sh`, then take a different stick to the offsite location
- **Quarterly**: test-restore a random file to `/tmp` to verify recoverability
- **Yearly**: check paper passphrase backups are still legible; consider passphrase rotation

A 4-month rotation cycle keeps each stick at home regularly so no stick falls too far out of sync, and ensures every stick gets a full integrity verification at least once per cycle. `--install-reminder` warns you when a stick hasn't been synced for `REMIND_STICK_DAYS` days.

## Recovery

To restore data from any stick on any Mac:

```bash
# Plug in the stick
diskutil apfs unlockVolume BACKUP_A     # prompts for passphrase

# Current data
ls /Volumes/BACKUP_A/data/

# Older versions: state before each run that changed something (UTC timestamps)
ls /Volumes/BACKUP_A/history/

# Optional: check every file against the stored hashes
cd /Volumes/BACKUP_A && shasum -a 256 -c BACKUP_HASHES.txt   # b3sum -c if the manifest says b3sum

# When done
cd ~ && diskutil apfs lockVolume BACKUP_A
```

The data on every stick is a plain rsync mirror — no proprietary format, no script needed for read access.

## On-stick layout

```
/Volumes/BACKUP_X/
├── INTEGRITY_CANARY.txt   identical on every stick of the set
├── .canary.sha256
├── BACKUP_MANIFEST.txt    last run: time, host, sticks, file count, root hash
├── BACKUP_HASHES.txt      per-file hashes of data/
├── data/                  the backup (mirror of SOURCES)
└── history/<timestamp>/   earlier versions of data/ (hard links)
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Usage / configuration error, pre-backup hook failure, or an unexpected command failure (reported with line and command) |
| 2 | Prerequisite missing (tool, volume, source path, stored hashes) |
| 3 | Hash mismatch — sticks not identical, or `--verify-only` found changed files (volumes left unlocked for investigation) |
| 4 | Canary integrity failure — filesystem corruption, or sticks from different backup sets |
| 5 | Unlock / mount / format / encrypt problem |
| 6 | rsync fatal error |
| 7 | Deletion guard tripped — nothing was changed |
| 130 / 143 | Interrupted (Ctrl-C / SIGTERM); sticks are locked |

## Logs

Every run writes a timestamped log to `~/Library/Logs/usb-backup/backup-<timestamp>.log` containing all phases, all rsync output, files to be deleted, and any error diagnostics. Logs are ANSI-free regardless of terminal settings.

## Threat model

**Covered:**

- Loss/theft of any stick (encrypted at rest, no data leak)
- Failure of up to 3 sticks simultaneously (4th survives)
- Bit-rot or silent corruption on one stick (hash verification catches divergence; `--verify-only` checks a single stick against its stored hashes)
- Accidental corruption of the stick's root files (canary check)
- Mass deletion or encryption of sources, e.g. by ransomware (deletion guard; older versions in `history/`)
- Fire/flood at home (offsite stick survives, with data through last rotation)

**Not covered (out of scope):**

- Simultaneous disaster at home and offsite location → use multiple offsite locations or a cloud layer
- Deliberate tampering by someone who knows the passphrase → the canary's hash is stored next to it, so it is not a cryptographic seal
- Ransomware that modifies files in place without deleting them → the change is mirrored, but the previous version stays in `history/` for `HISTORY_KEEP` runs
- Ransomware encrypting mounted sticks during a backup → only plug sticks in during backup
- MacBook compromise during backup → passphrase and plaintext data both pass through a hostile system
- Passphrase loss → paper backup is your only recourse
- Apple Notes WAL inconsistency during active edits → close Notes during backup, or use a pre-backup export hook

## Files in this project

- [`usb-mirror-backup.sh`](usb-mirror-backup.sh) — the backup script
- [`usb-backup.conf.example`](usb-backup.conf.example) — example config file
- [`tests/`](tests/) — test suite with a mocked `diskutil` (`tests/run-tests.sh`)
- [`docs/SETUP.md`](docs/SETUP.md) — step-by-step one-time stick setup
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the script works internally
- [`docs/TESTING.md`](docs/TESTING.md) — running and writing tests
- [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md) — known limitations and unverified behaviour
- [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md) — guide for AI coding agents
- [`CHANGELOG.md`](CHANGELOG.md) — history

## License

Personal project. Use at your own risk.
