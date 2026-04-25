# USB Mirror Backup

A weekly encrypted backup script for macOS that mirrors critical data to multiple USB sticks simultaneously, with offsite rotation support.

Designed for backing up irreplaceable personal data — password manager exports, cryptocurrency wallet seeds, SSH/GPG keys, browser bookmarks, notes, and a handful of important documents — to a small fleet of identical USB sticks. One run of one script writes to all present sticks, verifies them byte-for-byte, and leaves them locked.

## Features

- **Native macOS APFS encryption** (AES-XTS-256, hardware-accelerated). No third-party software, no kernel extensions, no `macFUSE`.
- **N-way mirror** with star topology: up to 4 sticks (configurable) kept identical via a single hub-and-spoke sync.
- **Offsite rotation** support: keep one stick at a remote location, run weekly with the sticks at home, do a full sync when the offsite stick comes home for rotation.
- **Cryptographic verification**: every run computes per-file SHA-256 hashes on all present sticks and aborts if they don't match.
- **Integrity canary**: a per-backup-set marker file detects tampering or corruption between runs.
- **Live progress UI**: phase headers, status marks, rsync progress, and animated hashing progress bar — auto-disabled when output isn't a terminal.
- **Fail-safe**: trap-based cleanup ensures sticks are always locked at exit, even on `Ctrl-C` or fatal errors. On hash mismatch, sticks stay unlocked for forensics.
- **Idempotent**: re-running is safe; partial state never corrupts.
- **ShellCheck-clean**, bash 3.2 compatible (works with stock macOS bash).

## How it works

```
                            ┌──→ BACKUP_B
sources ──→ BACKUP_A (hub) ─┼──→ BACKUP_C
                            └──→ BACKUP_D  (or "missing — offsite this week")
```

1. **Detect** which configured sticks are present
2. **Unlock** all present sticks (single passphrase prompt)
3. **Verify** the integrity canary on each stick
4. **Sync** sources → hub (the first present stick)
5. **Mirror** hub → each other present stick
6. **Hash** every file on every stick and compare
7. **Write** a per-run manifest to each stick
8. **Lock** everything

A star topology (rather than a chain) ensures that silent corruption on one secondary stick can't propagate to another.

## Requirements

- macOS (Darwin) — uses `diskutil`, APFS encrypted volumes, native `shasum`
- Bash 3.2+ (stock macOS bash works)
- `rsync` — stock Apple `/usr/bin/rsync` (2.6.9) works; Homebrew rsync 3.x gives nicer progress output
- 2 or more USB sticks of identical capacity (the script uses 4 by default; minimum 2 supported)

## One-time setup

1. Format each stick as a Case-sensitive APFS encrypted volume with `diskutil eraseDisk` + `diskutil apfs encryptVolume`
2. Label them `BACKUP_A`, `BACKUP_B`, `BACKUP_C`, `BACKUP_D` (or whatever you configure in `LABELS`)
3. Use the **same passphrase** for all sticks
4. Generate the integrity canary on stick A, then copy it to the others
5. Disable Spotlight on each stick (`sudo mdutil -i off /Volumes/BACKUP_X`) to avoid lock conflicts
6. Edit the script's `SOURCES` array with the paths you want to back up

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

# Simulate without writing anything
./usb-mirror-backup.sh --dry-run

# Disable colors and animations
./usb-mirror-backup.sh --no-color

./usb-mirror-backup.sh --help
```

## Configuration

The configuration block is at the top of the script. Common knobs:

```bash
LABELS=(BACKUP_A BACKUP_B BACKUP_C BACKUP_D)   # which volumes the script knows about
MIN_STICKS_AVAILABLE=3                          # refuse to run with fewer than this
SOURCES=(                                       # what to back up
    "${HOME}/path/to/seed.gpg"
    "${HOME}/Library/Group Containers/group.com.apple.notes"
    "${HOME}/Documents/backup-me"
    "${HOME}/.ssh"
    "${HOME}/.gnupg"
)
LOG_DIR="${HOME}/Library/Logs/usb-backup"       # where logs go
```

## Suggested rotation schedule (4 sticks, 1 offsite)

- **Weekly** (3 home sticks): `./usb-mirror-backup.sh --available-only`
- **Monthly** (rotation weekend, all 4 home): `./usb-mirror-backup.sh`, then take a different stick to the offsite location
- **Quarterly**: test-restore a random file to `/tmp` to verify recoverability
- **Yearly**: check paper passphrase backups are still legible; consider passphrase rotation

A 4-month rotation cycle keeps each stick at home regularly so no stick falls too far out of sync, and ensures every stick gets a full integrity verification at least once per cycle.

## Recovery

To restore data from any stick on any Mac:

```bash
# Plug in the stick
diskutil apfs unlockVolume BACKUP_A     # prompts for passphrase

# Data is now at /Volumes/BACKUP_A/data/
ls /Volumes/BACKUP_A/data/

# When done
diskutil apfs lockVolume BACKUP_A
```

The data on every stick is a plain rsync mirror — no proprietary format, no script needed for read access.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Usage / configuration error |
| 2 | Prerequisite missing (tool, volume, source path) |
| 3 | Hash verification mismatch — sticks not identical (volumes left unlocked for investigation) |
| 4 | Canary integrity failure — possible tampering or filesystem corruption |
| 5 | Unlock / mount problem |
| 6 | rsync fatal error |

## Logs

Every run writes a timestamped log to `~/Library/Logs/usb-backup/backup-<timestamp>.log` containing all phases, all rsync output, and any error diagnostics. Logs are ANSI-free regardless of terminal settings.

## Threat model

**Covered:**

- Loss/theft of any stick (encrypted at rest, no data leak)
- Failure of up to 3 sticks simultaneously (4th survives)
- Bit-rot or silent corruption on one stick (hash verification catches divergence)
- Tampering between runs (canary check)
- Fire/flood at home (offsite stick survives, with data through last rotation)

**Not covered (out of scope):**

- Simultaneous disaster at home and offsite location → use multiple offsite locations or a cloud layer
- Ransomware encrypting mounted sticks during a backup → only plug sticks in during backup
- MacBook compromise during backup → passphrase and plaintext data both pass through a hostile system
- Passphrase loss → paper backup is your only recourse
- Apple Notes WAL inconsistency during active edits → close Notes during backup, or use a pre-backup export hook

## Files in this project

- [`usb-mirror-backup.sh`](usb-mirror-backup.sh) — the backup script
- [`README.md`](README.md) — this file

## License

Personal project. Use at your own risk.
