# Testing

There is no automated test suite yet. Two ways to test changes:

## 1. Static checks (anywhere)

```bash
bash -n usb-mirror-backup.sh
shellcheck usb-mirror-backup.sh      # pip install shellcheck-py, or brew install shellcheck
```

Both must pass. `shellcheck` does **not** catch bash-3.2 incompatibilities; review
those by hand (see `CLAUDE.md`).

## 2. Linux mock harness (no Mac needed)

The script only talks to macOS through `uname`, `diskutil`, `shasum` and BSD
`mktemp`. Fake those on `PATH` and the full flow runs on Linux. The harness below
was used to verify the bugs in `KNOWN_ISSUES.md`. It needs root because it
writes to `/Volumes`, so run it in a throwaway container, never on a real Mac.

A mocked stick is "present" when `/tmp/mockstate/<LABEL>.present` exists.
"Unlocking" moves `/tmp/mockstate/<LABEL>.data` to `/Volumes/<LABEL>`, "locking"
moves it back.

```bash
T=$(mktemp -d); mkdir -p "$T/bin" "$T/src/docs"; cd "$T"

cat > bin/uname <<'EOF'
#!/bin/sh
echo Darwin
EOF

cat > bin/shasum <<'EOF'
#!/bin/sh
# shasum -a 256 <args>  ->  sha256sum <args>
shift 2; exec sha256sum "$@"
EOF

cat > bin/mktemp <<'EOF'
#!/bin/bash
# BSD `mktemp [-d] -t prefix` -> GNU needs a template
a=(); while [[ $# -gt 0 ]]; do if [[ $1 == -t ]]; then a+=(-t "$2.XXXXXX"); shift; else a+=("$1"); fi; shift; done
exec /usr/bin/mktemp "${a[@]}"
EOF

cat > bin/diskutil <<'EOF'
#!/bin/bash
st=/tmp/mockstate
case "$1" in
  info) l="${2#/Volumes/}"; [[ -e $st/$l.present ]] || exit 1
        echo "   File System Personality:  APFS" ;;
  apfs) case "$2" in
          unlockVolume) cat >/dev/null; rm -rf "/Volumes/$3"; mv "$st/$3.data" "/Volumes/$3" ;;
          lockVolume)   mv "/Volumes/$3" "$st/$3.data" ;;
        esac ;;
  unmount) exit 1 ;;
esac
EOF
chmod +x bin/*

# Four mocked sticks with a shared canary
mkdir -p /tmp/mockstate
for l in BACKUP_A BACKUP_B BACKUP_C BACKUP_D; do
  touch /tmp/mockstate/$l.present
  mkdir -p /tmp/mockstate/$l.data
  echo canary > /tmp/mockstate/$l.data/INTEGRITY_CANARY.txt
  (cd /tmp/mockstate/$l.data && sha256sum INTEGRITY_CANARY.txt > .canary.sha256)
done

# Copy of the script pointing at a test source and a local log dir
echo hello > src/docs/a.txt
sed "s|^    # \"\${HOME}/Documents/backup-me\"|    \"$T/src/docs\"|; s|^LOG_DIR=.*|LOG_DIR=$T/logs|" \
  /path/to/backupstick/usb-mirror-backup.sh > test.sh

export PATH="$T/bin:$PATH" USB_BACKUP_PASSPHRASE=dummy
bash test.sh --no-color; echo "exit=$?"
```

(`rsync` must be installed: `apt-get install rsync`.)

Useful scenarios:

| Scenario | How |
|----------|-----|
| Happy path | run as above, expect exit 0 and `/tmp/mockstate/*/data/docs/a.txt` |
| Offsite stick | `rm /tmp/mockstate/BACKUP_D.present`, run with `--available-only` |
| Too few sticks | remove two `.present` files, run with `--available-only`, expect exit 2 |
| Stale stick returns | change a source, run `--available-only` without D, put D back, run `--dry-run` |
| Hash mismatch | after a successful run, change the content of `/tmp/mockstate/BACKUP_C.data/data/docs/a.txt` but keep its size and mtime (`touch -r` from a copy), so rsync skips it; then run again |
| Canary failure | edit `/tmp/mockstate/BACKUP_B.data/INTEGRITY_CANARY.txt`, expect exit 4 |
| Wrong passphrase | make the mock `unlockVolume` `exit 1`, expect exit 5 |

Logs land in `$T/logs/`. After a failed run check `ls /Volumes` to see
whether sticks were left "unlocked".

What the mock does **not** cover: real `diskutil` output formats, async mounts,
lock failures caused by Spotlight, Apple rsync 2.6.9 / openrsync flag
differences, and bash 3.2 itself (Linux has bash 5). Those need a real Mac.

## 3. On a real Mac

1. Use spare sticks or a disk image, not your real backup set:
   `hdiutil create -size 200m -fs APFSX -encryption AES-256 -volname BACKUP_A -stdinpass test_a.dmg`
   (repeat per label; attach with `hdiutil attach`), then follow `docs/SETUP.md` steps 4–6.
2. Run with `/bin/bash usb-mirror-backup.sh` to make sure you are on bash 3.2.
3. Try `--dry-run`, `--available-only`, Ctrl-C mid-rsync, and a run with Finder
   open on a stick (tests the force-unmount path in `lock_volume`).
