# One-time stick setup

The README lists the setup steps briefly. This is the step-by-step version.
Commands are for macOS. **`diskutil eraseDisk` destroys the whole target disk.
Check the disk identifier twice.** Command syntax can change between macOS
releases; if one fails, look at `man diskutil` for your version.

Repeat steps 1–3 for each stick (`BACKUP_A` … `BACKUP_D`), with the **same passphrase**.

## 1. Identify the stick

```bash
diskutil list external        # note the identifier, e.g. /dev/disk4
```

## 2. Format as case-sensitive APFS

```bash
diskutil eraseDisk APFSX BACKUP_A GPT /dev/disk4
```

`APFSX` = case-sensitive APFS. The volume mounts at `/Volumes/BACKUP_A`.

## 3. Encrypt the volume

```bash
diskutil apfs encryptVolume BACKUP_A -user disk -passprompt
```

On an empty volume this finishes almost immediately. Check with
`diskutil apfs list` ("FileVault: Yes"). Then lock and unlock once to confirm
the passphrase works:

```bash
diskutil apfs lockVolume BACKUP_A
diskutil apfs unlockVolume BACKUP_A     # prompts
```

## 4. Disable Spotlight on each stick

```bash
sudo mdutil -i off /Volumes/BACKUP_A
```

Spotlight holding files open is the usual reason `lockVolume` fails.

## 5. Create the integrity canary (once, on the first stick)

The script expects two files at the **volume root** (not in `data/`):
`INTEGRITY_CANARY.txt` and `.canary.sha256`, where the latter is `shasum -a 256`
output with a **relative** path (the script runs `cd <mount> && shasum -a 256 -c .canary.sha256`).

```bash
cd /Volumes/BACKUP_A
{ echo "backupstick integrity canary"; date -u; head -c 32 /dev/urandom | xxd -p -c 64; } > INTEGRITY_CANARY.txt
shasum -a 256 INTEGRITY_CANARY.txt > .canary.sha256
shasum -a 256 -c .canary.sha256        # should print: INTEGRITY_CANARY.txt: OK
```

The random content makes each backup set unique, so sticks from a different
set are refused (`verify_canaries_match`).

## 6. Copy the canary to the other sticks

They must be **byte-identical**:

```bash
for s in BACKUP_B BACKUP_C BACKUP_D; do
  cp /Volumes/BACKUP_A/INTEGRITY_CANARY.txt /Volumes/BACKUP_A/.canary.sha256 "/Volumes/$s/"
done
```

## 7. Configure the script

Edit the config block at the top of `usb-mirror-backup.sh`:

- `SOURCES`: absolute paths to back up. Every source's **basename** must be unique
  (they all land in `data/<basename>`).
- `LABELS`: must match the volume names above.
- `MIN_STICKS_AVAILABLE`: minimum sticks for `--available-only` (default 3).
- Optional `PRE_BACKUP_HOOK`: runs through `eval` before syncing.

Keep your real `SOURCES` out of any public copy of this repo.

## 8. First run

```bash
./usb-mirror-backup.sh --dry-run     # see docs/KNOWN_ISSUES.md #4 on a completely fresh stick
./usb-mirror-backup.sh
```

After the run, check `/Volumes/<LABEL>/BACKUP_MANIFEST.txt` (unlock a stick
manually) and the log in `~/Library/Logs/usb-backup/`.

## Adding or replacing a stick later

1. Do steps 1–4 for the new stick with the same passphrase and a label from `LABELS`
   (or add a new label to `LABELS`).
2. Copy the canary files from an existing stick (step 6).
3. Run the script with all sticks present; the new stick is filled from the hub.
