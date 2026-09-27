# CLAUDE.md — agent guide for `backupstick`

Read this first if you are an AI agent (or a new human) picking up this repo.
`AGENTS.md` points here, so there is one source of truth.

## What this project is

A single Bash script, `usb-mirror-backup.sh`, that backs up a small set of
irreplaceable personal files (password-manager exports, wallet seeds, SSH/GPG
keys, Apple Notes, a few documents) from a **macOS** machine to **2–4 USB sticks**
that are **APFS-encrypted volumes sharing one passphrase**. A backup run:

1. detects which configured sticks (`LABELS`) are plugged in,
2. unlocks them with one passphrase prompt,
3. checks an "integrity canary" file on each stick,
4. runs the **deletion guard** (stops with exit 7 if too many files would disappear),
5. snapshots each stick's `data/` into `history/<timestamp>/` (hard links),
6. removes sources that are no longer configured, rsyncs `SOURCES` → the **hub** (first present stick),
7. rsyncs hub → every other present stick (**star topology**, never a chain),
8. hashes every file on every stick and compares against the hub,
9. writes `BACKUP_MANIFEST.txt` and `BACKUP_HASHES.txt` on each stick, prunes history,
10. records per-stick sync times for reminders, and locks all sticks (via the `EXIT` trap).

Other modes: `--verify-only` (check sticks against their stored hashes, no writes),
`--init-stick` (format/encrypt/canary a new stick), `--check-reminder` /
`--install-reminder` / `--uninstall-reminder` (launchd notification when overdue).

One stick usually lives offsite; weekly runs use `--available-only`, monthly
rotation runs use all sticks. The owner runs macOS 27 with the stock
`/usr/bin/rsync` (openrsync, "2.6.9 compatible"). The data on a stick is a plain
rsync mirror in `/Volumes/<LABEL>/data/`, readable without the script.

## Repository layout

| Path | What |
|------|------|
| `usb-mirror-backup.sh` | The whole program (~2000 lines of Bash). Defaults block at the top. |
| `usb-backup.conf.example` | Example config; real config lives in `~/.config/usb-backup/config`. |
| `tests/run-tests.sh` | Test runner (fixtures, assertions). `tests/test-cases.sh` holds the `test_*` functions. |
| `tests/mocks/` | Fake `diskutil`, `launchctl`, `osascript`; `tests/mocks/linux/` fakes `uname`, `shasum`, BSD `mktemp` on Linux. |
| `.github/workflows/ci.yml` | ShellCheck + tests on Ubuntu and on macOS (`/bin/bash` 3.2, openrsync). |
| `README.md` | User-facing docs: features, usage, config, rotation, recovery, threat model. |
| `docs/ARCHITECTURE.md` | Modes, run flow, function map, on-stick layout, trap/cleanup semantics. |
| `docs/SETUP.md` | One-time setup (`--init-stick`, and the manual equivalent). |
| `docs/TESTING.md` | How the test suite works and how to add tests. |
| `docs/KNOWN_ISSUES.md` | Open limitations and **things not yet verified on a real Mac**. Check before changing behaviour. |
| `CHANGELOG.md` | History. Add an entry for user-visible changes. |

## Hard constraints (do not break)

- **Bash 3.2 compatible.** Stock macOS `/bin/bash` is 3.2. No associative
  arrays (`declare -A`), no `mapfile`/`readarray`, no `${var,,}`, no `|&`,
  no `wait -n`, no negative array indices, no `$BASHPID` (use `$BASH_SUBSHELL`).
  Empty-array expansion under `set -u` must use the `${arr[@]+"${arr[@]}"}` idiom.
  CI runs the suite under real bash 3.2 on macOS; keep that job green.
- **ShellCheck clean.** `shellcheck usb-mirror-backup.sh tests/*.sh tests/mocks/...`
  (see CI for the exact list) must return 0. Existing `# shellcheck disable=` lines are deliberate.
- **macOS tools only**: `diskutil`, `shasum`, BSD `find`/`xargs`/`mktemp`/`du`,
  stock `rsync` (openrsync). Any rsync flag you add must work with openrsync;
  the macOS CI job is where that gets checked. Optional: Homebrew `rsync` 3.x, `b3sum`.
- **Sticks must always end locked** except on the documented forensics path
  (exit 3). Any new exit path must go through the `EXIT` trap (`cleanup`).
  Add a label to `UNLOCKED_LABELS` *before* unlocking/creating it.
- **Only `data/` and `history/` are ever deleted from.** `rsync --delete` only
  targets `<mount>/data/`; `remove_stale_sources` only removes top-level entries of
  the hub's `data/`; `finalize_history` only removes `history/<timestamp>` dirs.
  Canary, manifest and hash files live at the volume root.
- **Nothing is written before the deletion guard has run.**
- **Star topology.** Secondaries are only ever written from the hub.
- **The passphrase never touches disk or argv.** It is piped via `printf`
  (a builtin) into `diskutil ... -stdinpassphrase`, cleared right after use and in
  `cleanup`, and `USB_BACKUP_PASSPHRASE` is `unset` after reading.
- **`--init-stick` must never erase a disk that isn't a whole external/USB disk**,
  and never before the label has been typed back and the passphrase proven.
- **Logs are ANSI-free.** Terminal output goes to stderr (colour optional);
  the log file gets plain text.
- **Exit codes are a public contract** (README table + header comment + usage). Keep
  them in sync if you change them.
- **On-stick layout is a contract too.** Sticks sit in drawers and offsite for months;
  a new version must still read what an old version wrote (e.g. `--verify-only`
  skips sticks without `BACKUP_HASHES.txt`).
- **Never commit real personal paths.** `SOURCES` in the script stays commented out;
  real settings go in the user's config file.

## Shell conventions used in the script

- `set -Eeuo pipefail` and `IFS=$'\n\t'` globally, plus an `ERR` trap (`on_err`) that
  reports the failing command. Consequences:
  - Any pipeline whose *first* stage legitimately exits non-zero (`diff`, `grep`
    with no match, `cmp`) aborts the script. Wrap it: `{ diff a b || true; } | head`.
  - Failures inside `$(...)` are **not** caught (bash doesn't propagate `set -e`
    into command substitutions). Don't rely on it for correctness.
  - `"${arr[*]}"` joins with newline, not space. Use `join_by` for display.
  - Don't `| head -1` a command that keeps writing (SIGPIPE + pipefail); see
    `detect_rsync_capabilities`.
- Output goes through `log`, `log_to_file`, `print_ok/warn/fail`, `print_phase`,
  `die <code> <msg>`. `log` and `die` also write the log file and stop the spinner.
- Fancy UI (colours, spinner, progress bar) only when `IS_TTY=1`.
- Temporary files go in `$WORKDIR` (created in `main`, removed in `cleanup`).
- File lists always use `set_find_args` so counting, hashing and deletion planning
  apply the same `RSYNC_EXCLUDES`.
- Functions are `snake_case`, globals `UPPER_CASE`, locals declared with `local`.
  Section banners are `# ----` comment blocks. Timestamps are UTC ISO-8601.

## How to validate a change

1. `bash -n usb-mirror-backup.sh` and ShellCheck (`pip install shellcheck-py` on Linux).
2. `tests/run-tests.sh` (or `tests/run-tests.sh <name-substring>`). Add a test for
   every behaviour change or bug fix; see `docs/TESTING.md`.
3. Push and check the CI `test-macos` job: that is real bash 3.2 + openrsync.
4. For anything touching real `diskutil` behaviour (unlock/lock/erase/encrypt), the
   mocks prove nothing. Say so, and ask the owner to try it on a spare stick.

## Things to ask the owner rather than guess

- Actual `SOURCES` in use (never commit them).
- Anything that changes the on-stick layout or exit codes.
- Whether behaviour marked "unverified" in `docs/KNOWN_ISSUES.md` has been tried on the real Mac.
