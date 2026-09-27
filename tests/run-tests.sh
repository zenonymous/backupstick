#!/usr/bin/env bash
#
# Test suite for usb-mirror-backup.sh. Runs the real script against mocked
# sticks (tests/mocks/diskutil) in a temp directory. No root, no real disks.
#
# Works on Linux (adds tests/mocks/linux shims for uname/shasum/mktemp) and on
# macOS (real /bin/bash 3.2, BSD tools and Apple rsync).
#
# Usage: tests/run-tests.sh [test_name_substring]
#

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO}/usb-mirror-backup.sh"
MOCKS="${REPO}/tests/mocks"
FILTER="${1:-}"
# Run the script under this bash (e.g. BASH_UNDER_TEST=/bin/bash on macOS = 3.2)
BASH_UNDER_TEST="${BASH_UNDER_TEST:-bash}"

PASS=0
FAIL=0
FAILED_TESTS=()

if [[ "$(uname -s)" == "Darwin" ]]; then
    TEST_PATH="${MOCKS}:${PATH}"
else
    TEST_PATH="${MOCKS}:${MOCKS}/linux:${PATH}"
fi

# -----------------------------------------------------------------------------
# Fixture helpers. Each test gets a fresh $T.
# -----------------------------------------------------------------------------

setup() {
    T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/usb-backup-test.XXXXXX")" && pwd -P)"
    export MOCK_STATE="${T}/state"
    export MOCK_VOLUMES="${T}/Volumes"
    export MOCK_PASSPHRASE="secret"
    unset MOCK_UNLOCK_DELAY MOCK_LOCK_FAIL MOCK_ENCRYPT_FAIL STDIN_INPUT PASS_OVERRIDE
    mkdir -p "$MOCK_STATE/disks" "$MOCK_VOLUMES" "${T}/home" "${T}/src/docs" "${T}/src/keys"
    printf 'hello\n' > "${T}/src/docs/a.txt"
    printf 'world\n' > "${T}/src/docs/b.txt"
    printf 'k\n'     > "${T}/src/keys/id"
    SOURCES_LINE="SOURCES=( \"${T}/src/docs\" \"${T}/src/keys\" )"
    EXTRA_CONFIG=""
    OUT=""
    RC=0
}

teardown() {
    rm -rf "$T"
}

make_stick() {
    # make_stick LABEL [canary-content]
    local l="$1" canary="${2:-set-1}"
    touch "${MOCK_STATE}/${l}.present"
    mkdir -p "${MOCK_STATE}/${l}.data"
    printf '%s\n' "$canary" > "${MOCK_STATE}/${l}.data/INTEGRITY_CANARY.txt"
    ( cd "${MOCK_STATE}/${l}.data" && PATH="$TEST_PATH" shasum -a 256 INTEGRITY_CANARY.txt > .canary.sha256 )
}

make_sticks() {
    local l
    for l in "$@"; do make_stick "$l"; done
}

unplug() { rm -f "${MOCK_STATE}/$1.present"; }
plug()   { touch "${MOCK_STATE}/$1.present"; }

stick_dir() {
    # Where a stick's files are right now (locked or unlocked).
    if [[ -d "${MOCK_VOLUMES}/$1" ]]; then
        printf '%s' "${MOCK_VOLUMES}/$1"
    else
        printf '%s' "${MOCK_STATE}/$1.data"
    fi
}

is_unlocked() { [[ -d "${MOCK_VOLUMES}/$1" ]]; }

write_config() {
    cat > "${T}/test.conf" <<EOF
LABELS=(BACKUP_A BACKUP_B BACKUP_C BACKUP_D)
MIN_STICKS_AVAILABLE=3
${SOURCES_LINE}
LOG_DIR="${T}/logs"
STATE_DIR="${T}/home/state"
VOLUMES_ROOT="${MOCK_VOLUMES}"
${EXTRA_CONFIG}
EOF
}

run_backup() {
    # run_backup [args...]; sets OUT (stderr+stdout) and RC
    write_config
    # stdin: STDIN_INPUT (e.g. the --init-stick confirmation); never a TTY.
    OUT="$(printf '%s\n' "${STDIN_INPUT:-}" | PATH="$TEST_PATH" HOME="${T}/home" \
        USB_BACKUP_PASSPHRASE="${PASS_OVERRIDE:-secret}" \
        USB_BACKUP_CONFIG="${T}/test.conf" \
        "$BASH_UNDER_TEST" "$SCRIPT" --no-color "$@" 2>&1)"
    RC=$?
}

last_log() {
    local f
    # shellcheck disable=SC2012  # log names are timestamps, no odd characters
    f="$(ls -t "${T}"/logs/*.log 2>/dev/null | head -1)"
    [[ -n "$f" ]] && cat "$f"
}

# -----------------------------------------------------------------------------
# Assertions. They record failures but don't abort the test.
# -----------------------------------------------------------------------------

CUR_OK=1
fail() {
    CUR_OK=0
    printf '    FAIL: %s\n' "$*"
}
assert_rc()        { [[ "$RC" -eq "$1" ]] || fail "expected exit $1, got $RC"; }
assert_out()       { grep -qF -- "$1" <<<"$OUT" || fail "output lacks: $1"; }
assert_not_out()   { ! grep -qF -- "$1" <<<"$OUT" || fail "output unexpectedly contains: $1"; }
assert_log()       { last_log | grep -qF -- "$1" || fail "log lacks: $1"; }
assert_file()      { [[ -e "$1" ]] || fail "missing file: $1"; }
assert_no_file()   { [[ ! -e "$1" ]] || fail "file should not exist: $1"; }
assert_locked()    { local l; for l in "$@"; do is_unlocked "$l" && fail "$l should be locked"; done; return 0; }
assert_unlocked()  { local l; for l in "$@"; do is_unlocked "$l" || fail "$l should be unlocked"; done; return 0; }
assert_count()     { local n; n="$(grep -cF -- "$2" <<<"$OUT")"; [[ "$n" -eq "$1" ]] || fail "expected '$2' $1x in output, saw $n"; }
assert_same_file() { cmp -s "$1" "$2" || fail "files differ: $1 vs $2"; }

run_test() {
    local name="$1"
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        return 0
    fi
    CUR_OK=1
    setup
    printf '  %s\n' "$name"
    "$name"
    if [[ "$CUR_OK" -eq 1 ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '    --- script output ---\n'
        printf '%s\n' "$OUT" | sed 's/^/    | /' | tail -40
    fi
    teardown
}

# shellcheck source=tests/test-cases.sh
. "${REPO}/tests/test-cases.sh"

# shellcheck disable=SC2016  # $BASH_VERSION is expanded by the bash under test
printf 'Running tests (bash under test: %s)\n' "$("$BASH_UNDER_TEST" -c 'echo $BASH_VERSION')"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    printf 'Failed: %s\n' "${FAILED_TESTS[*]}"
    exit 1
fi
