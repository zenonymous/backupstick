# AGENTS.md

Agent instructions for this repository live in [`CLAUDE.md`](CLAUDE.md).
They apply to every coding agent (Claude, Codex, Copilot, Cursor, …), not only Claude.

Quick orientation:

- The whole program is [`usb-mirror-backup.sh`](usb-mirror-backup.sh): a Bash 3.2, macOS-only,
  encrypted multi-USB-stick mirror backup.
- Tests: `tests/run-tests.sh` (mocked `diskutil`, runs on Linux and macOS). CI runs them
  under real bash 3.2 on macOS.
- Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Open limitations and unverified behaviour, read before changing things:
  [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md)
- Writing tests: [`docs/TESTING.md`](docs/TESTING.md)
