# One-time setup

Two ways to set up sticks: `--init-stick` (recommended) or the manual commands it
wraps. Both give the same result.

> **`--init-stick` and `diskutil eraseDisk` destroy the whole target disk.**
> Check the disk identifier twice with `diskutil list external`.

## 1. Config file

```bash
mkdir -p ~/.config/usb-backup
cp usb-backup.conf.example ~/.config/usb-backup/config
chmod 600 ~/.config/usb-backup/config
```

Edit it:

- `SOURCES`: absolute paths to back up. Each lands in `data/<basename>`, so basenames must be
  unique (the script refuses duplicates). `dir` and `dir/` mean the same.
- `LABELS`: the volume names of your sticks (default `BACKUP_A` … `BACKUP_D`).
- `MIN_STICKS_AVAILABLE`: minimum sticks for `--available-only` (default 3).
- Optional: `PRE_BACKUP_HOOK`, deletion guard, history and reminder settings (see the example).

The script refuses a config file that is group/world-writable or not owned by you,
because it is executed as bash.

## 2. Set up the sticks with `--init-stick`

Choose a passphrase first (see the README: random, from a password manager, paper copy
in two places).

**First stick** (creates a new backup set: new canary, you choose the passphrase):

```bash
diskutil list external                       # find the stick, e.g. /dev/disk4
./usb-mirror-backup.sh --init-stick BACKUP_A --disk disk4 --new-set
```

It asks you to type `BACKUP_A` to confirm, asks for the passphrase twice, then erases,
formats (case-sensitive APFS), encrypts, writes the canary, creates `data/`, and turns off
Spotlight via `sudo mdutil` (asks for your login password). At the end the stick is locked.

**Every further stick**: plug in the new stick **and one existing stick** of the set:

```bash
./usb-mirror-backup.sh --init-stick BACKUP_B --disk disk5
```

The existing stick is unlocked with the passphrase you enter *before* anything is
erased, which proves you typed the right one. Its canary is then copied to the new stick.

The command refuses to run when:

- the disk isn't a whole external/USB disk (so a typo can't hit the internal disk),
- `--disk` is a partition (`disk4s1`) instead of a disk (`disk4`),
- the label isn't in `LABELS`, or a volume with that name already exists,
- no stick of the set is present and `--new-set` isn't given,
- the typed confirmation doesn't match.

## 3. First backup

```bash
./usb-mirror-backup.sh --dry-run
./usb-mirror-backup.sh
```

Afterwards, check the summary and the log in `~/Library/Logs/usb-backup/`.

## 4. Optional: daily reminder

```bash
./usb-mirror-backup.sh --install-reminder
```

Installs a launchd agent that runs `--check-reminder` every day at 10:07. It shows a
notification when the last backup is older than `REMIND_AFTER_DAYS` (8) or a stick,
typically the offsite one, hasn't been synced for `REMIND_STICK_DAYS` (42). The agent
calls the script at its current path, so re-run `--install-reminder` if you move it.
Remove with `--uninstall-reminder`.

## Replacing a stick

Lost or broken `BACKUP_C`? Plug in a new stick plus one existing stick and run
`--init-stick BACKUP_C --disk diskN`, then a normal backup with all sticks.

## Manual setup (what `--init-stick` does)

Useful if `--init-stick` fails on your macOS version. Command syntax can change between
releases; see `man diskutil`.

```bash
# Format as case-sensitive APFS
diskutil eraseDisk APFSX BACKUP_A GPT /dev/disk4

# Encrypt (prompts for the passphrase)
diskutil apfs encryptVolume BACKUP_A -user disk -passprompt

# Spotlight off (it blocks locking otherwise)
sudo mdutil -i off /Volumes/BACKUP_A

# New set only: create the canary (at the volume root, not in data/)
cd /Volumes/BACKUP_A
{ echo "usb-mirror-backup integrity canary"; date -u; head -c 32 /dev/urandom | xxd -p -c 64; } > INTEGRITY_CANARY.txt
shasum -a 256 INTEGRITY_CANARY.txt > .canary.sha256
shasum -a 256 -c .canary.sha256          # INTEGRITY_CANARY.txt: OK
mkdir data

# Further sticks: copy the canary files byte-for-byte from an existing stick
cp /Volumes/BACKUP_A/INTEGRITY_CANARY.txt /Volumes/BACKUP_A/.canary.sha256 /Volumes/BACKUP_B/

# Check the passphrase works
diskutil apfs lockVolume BACKUP_A
diskutil apfs unlockVolume BACKUP_A
```

`.canary.sha256` must contain a **relative** path, because the script runs
`cd <mount> && shasum -a 256 -c .canary.sha256`.
