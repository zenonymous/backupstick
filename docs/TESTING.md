# Testing

## Quick start

```bash
tests/run-tests.sh              # all tests
tests/run-tests.sh history      # only tests whose name contains "history"
shellcheck usb-mirror-backup.sh tests/*.sh tests/mocks/diskutil tests/mocks/launchctl tests/mocks/osascript tests/mocks/linux/*
```

Needs `bash`, `rsync` and the usual coreutils. No root, no real disks. On Linux,
`pip install shellcheck-py` gives you `shellcheck`.

CI (`.github/workflows/ci.yml`) runs ShellCheck and the suite on Ubuntu (bash 5,
GNU tools, rsync 3.x) and on macOS with `BASH_UNDER_TEST=/bin/bash`: real bash 3.2,
BSD `find`/`mktemp`, `shasum`, and Apple's openrsync. The macOS job is the one
that matters most; the script's real users run exactly that toolchain.

## How it works

The script only reaches macOS through a few commands, which the suite fakes on `PATH`:

| Mock | Behaviour |
|------|-----------|
| `tests/mocks/diskutil` | Sticks live in `$MOCK_STATE`: `<LABEL>.present` = plugged in, `<LABEL>.data/` = contents while locked. `unlockVolume` checks the passphrase against `$MOCK_PASSPHRASE` and moves the data dir to `$MOCK_VOLUMES/<LABEL>`; `lockVolume` moves it back. Also `info`, `unmount`, `eraseDisk` (needs `$MOCK_STATE/disks/<diskN>`), `apfs encryptVolume`. Every call is appended to `$MOCK_STATE/diskutil.calls`. |
| `tests/mocks/launchctl`, `osascript` | Record their arguments in `$MOCK_STATE/*.calls`. |
| `tests/mocks/linux/{uname,shasum,mktemp}` | Linux only: report Darwin, map `shasum -a 256` to `sha256sum`, accept BSD `mktemp -t prefix`. |

Mock knobs: `MOCK_UNLOCK_DELAY` (seconds), `MOCK_LOCK_FAIL=<LABEL>` (first lock fails, tests
the force-unmount path), `MOCK_ENCRYPT_FAIL=1`.

Each test gets a fresh temp dir `$T` with sources in `$T/src/{docs,keys}` and a config
file (`$T/test.conf`) that sets `SOURCES`, `LOG_DIR`, `STATE_DIR` and
`VOLUMES_ROOT=$MOCK_VOLUMES`, so the script never touches `/Volumes` or your home directory.
`HOME` is also pointed at `$T/home`.

## Writing a test

Add a function named `test_...` to `tests/test-cases.sh`; it is picked up automatically.

```bash
test_something() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D   # plugged-in, locked sticks with a shared canary
    run_backup                                          # runs the script; sets $OUT and $RC
    assert_rc 0
    printf 'changed\n' > "${T}/src/docs/a.txt"
    unplug BACKUP_D
    run_backup --available-only
    assert_out "Missing            BACKUP_D"
    assert_locked BACKUP_A BACKUP_B BACKUP_C
    assert_file "$(stick_dir BACKUP_A)/data/docs/a.txt"
}
```

Fixture helpers: `make_stick LABEL [canary]`, `make_sticks`, `plug`, `unplug`, `stick_dir`,
`is_unlocked`, `make_disk diskN [External|Internal]`, `corrupt_file_keep_size_mtime`.
Knobs for `run_backup`: `SOURCES_LINE`, `EXTRA_CONFIG` (appended to the config),
`STDIN_INPUT` (e.g. the `--init-stick` confirmation), `PASS_OVERRIDE` (wrong passphrase).

Assertions: `assert_rc`, `assert_out`, `assert_not_out`, `assert_count`, `assert_log`,
`assert_file`, `assert_no_file`, `assert_same_file`, `assert_locked`, `assert_unlocked`,
or `fail "message"` for anything custom. They record failures without stopping the test;
a failing test prints the tail of the script output.

Two runs in the same second share a `TIMESTAMP` (log name and snapshot name). Tests
that need distinct snapshots `sleep 1` between runs.

## What the mocks don't cover

Real `diskutil` output formats and error behaviour, async mounting, `eraseDisk` and
`encryptVolume` on real hardware, Spotlight holding files open, `sudo mdutil`, real
`launchd` scheduling and notifications. See `docs/KNOWN_ISSUES.md` for what has not been
tried on a real Mac. To try those safely, use a spare stick; or for the backup flow,
disk images:

```bash
printf '%s' 'test-pass' | hdiutil create -size 200m -fs APFSX -encryption AES-256 \
    -volname BACKUP_A -stdinpass test_a.dmg
hdiutil attach test_a.dmg          # repeat per label
```

(disk images are not "external" disks, so `--init-stick` refuses them by design.)
