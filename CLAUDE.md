# CLAUDE.md — agent guide for `backupstick`

Read this first if you are an AI agent (or a new human) picking up this repo.
`AGENTS.md` points here, so there is one source of truth.

## What this project is

A single Bash script, `usb-mirror-backup.sh`, that backs up a small set of
irreplaceable personal files (password-manager exports, wallet seeds, SSH/GPG
keys, Apple Notes, a few documents) from a **macOS** machine to **2–4 USB sticks**
that are **APFS-encrypted volumes sharing one passphrase**. One run:

1. detects which configured sticks (`LABELS`) are plugged in,
2. unlocks them with one passphrase prompt,
3. checks an "integrity canary" file on each stick,
4. rsyncs `SOURCES` → the **hub** (first present stick),
5. rsyncs hub → every other present stick (**star topology**, never a chain),
6. hashes every file on every stick and compares against the hub,
7. writes `BACKUP_MANIFEST.txt` on each stick,
8. locks all sticks again (via the `EXIT` trap).

One stick usually lives offsite; weekly runs use `--available-only`, monthly
rotation runs use all sticks. The data on a stick is a plain rsync mirror in
`/Volumes/<LABEL>/data/`, readable without the script.

There is no build, no dependencies beyond stock macOS tools, no tests yet, no CI.

## Repository layout

| Path | What |
|------|------|
| `usb-mirror-backup.sh` | The whole program (~1150 lines of Bash). Config block at the top. |
| `README.md` | User-facing docs: features, usage, rotation schedule, threat model. |
| `CLAUDE.md` | This file. |
| `AGENTS.md` | Pointer to this file for non-Claude agents. |
| `docs/ARCHITECTURE.md` | Run flow, function map, on-stick layout, trap/cleanup semantics. |
| `docs/SETUP.md` | Concrete one-time stick setup (format, encrypt, canary, Spotlight). |
| `docs/TESTING.md` | How to test on Linux with mocked `diskutil`, and on a real Mac. |
| `docs/KNOWN_ISSUES.md` | Verified bugs and gotchas. **Check before changing behaviour.** |
| `CHANGELOG.md` | History. Add an entry for user-visible changes. |

## Hard constraints (do not break)

- **Bash 3.2 compatible.** Stock macOS `/bin/bash` is 3.2. No associative
  arrays (`declare -A`), no `mapfile`/`readarray`, no `${var,,}`, no `|&`,
  no `wait -n`, no negative array indices. Empty-array expansion under
  `set -u` must use the `${arr[@]+"${arr[@]}"}` idiom (see `dry_flag`).
- **ShellCheck clean.** `shellcheck usb-mirror-backup.sh` must return 0.
  (`pip install shellcheck-py` gives you a binary on Linux.) Existing
  `# shellcheck disable=` lines are deliberate.
- **macOS tools only**: `diskutil`, `shasum`, BSD `find`/`xargs`/`mktemp`/`du`,
  Apple `rsync` (2.6.9 or openrsync). Optional: Homebrew `rsync` 3.x, `b3sum`.
  Note BSD `mktemp -t prefix` semantics (GNU needs an `XXXXXX` template).
- **Sticks must always end locked** except on the documented forensics path
  (exit 3). Any new exit path must go through the `EXIT` trap (`cleanup`).
- **`rsync --delete` only ever targets `<mount>/data/`.** Canary and manifest
  live at the volume root and must never be inside `DATA_SUBDIR`.
- **Star topology.** Secondaries are only ever written from the hub.
- **The passphrase never touches disk or argv.** It is piped via
  `printf` (a builtin) into `diskutil ... -stdinpassphrase`, and cleared
  (`PASSPHRASE=""`) right after unlock and again in `cleanup`.
- **Logs are ANSI-free.** Terminal output goes to stderr (colour optional);
  the log file gets plain text.
- **Exit codes are a public contract** (README table + header comment). Keep
  them in sync if you change them.

## Shell conventions used in the script

- `set -euo pipefail` and `IFS=$'\n\t'` globally. Consequences you must keep in mind:
  - Any pipeline whose *first* stage legitimately exits non-zero (e.g. `diff`,
    `grep` with no match, `cmp`) will abort the script. Guard with `|| true` or
    an `if`. This already bit the script — see KNOWN_ISSUES #1.
  - `"${arr[*]}"` joins with newline, not space. Use `join_by` for display.
  - Don't `| head -1` a command that keeps writing (SIGPIPE + pipefail); see
    `detect_rsync_capabilities` for the pattern used instead.
- All terminal output goes through `log`, `print_ok/warn/fail`, `print_phase`,
  `die <code> <msg>`. `log` and `die` also write the log file and stop any spinner.
- Fancy UI (colours, spinner, progress bar) only when `IS_TTY=1`
  (stderr is a TTY and `--no-color` not given).
- Functions are `snake_case`, globals are `UPPER_CASE`, locals are declared
  with `local`. Section banners are `# ----` comment blocks.
- Timestamps are UTC ISO-8601.

## How to validate a change

1. `bash -n usb-mirror-backup.sh` and `shellcheck usb-mirror-backup.sh`.
2. Run the Linux mock harness described in `docs/TESTING.md` (happy path,
   `--available-only`, `--dry-run`, a hash mismatch).
3. If possible, have the owner run `--dry-run` on a real Mac before a real run.

You cannot run the real thing in a Linux container: it needs `diskutil` and
APFS volumes. Never claim a macOS behaviour is verified if you only mocked it.

## Things to ask the owner rather than guess

- Their macOS version (affects which `rsync` ships: 2.6.9 vs `openrsync`).
- Whether they have Homebrew `rsync` / `b3sum` installed.
- Actual `SOURCES` in use (the committed config has them commented out on purpose;
  **never commit real personal paths**).
- Anything that changes the on-stick layout — existing sticks in a drawer and
  offsite must keep working, or a migration path must be documented.
