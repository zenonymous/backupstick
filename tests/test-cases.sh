# shellcheck shell=bash
# shellcheck disable=SC2034  # OUT/RC/SOURCES_LINE/EXTRA_CONFIG are read by run-tests.sh
# Test cases for tests/run-tests.sh. Every function named test_* is run with a
# fresh fixture (see setup() in run-tests.sh).

# --- basics ------------------------------------------------------------------

test_happy_path_all_sticks() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    assert_rc 0
    assert_out "Backup Complete"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    local l
    for l in BACKUP_A BACKUP_B BACKUP_C BACKUP_D; do
        assert_same_file "${T}/src/docs/a.txt" "$(stick_dir "$l")/data/docs/a.txt"
        assert_file "$(stick_dir "$l")/BACKUP_MANIFEST.txt"
    done
}

test_summary_shows_real_counts() {
    # KNOWN_ISSUES #3: summary used to say "Files 0 / Size 0 B" after locking
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    assert_rc 0
    assert_out "Files              3"
    assert_not_out "Size               0 B"
}

test_missing_stick_requires_available_only() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    run_backup
    assert_rc 2
    assert_out "Missing: BACKUP_D"
}

test_available_only_with_offsite_stick() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    run_backup --available-only
    assert_rc 0
    assert_locked BACKUP_A BACKUP_B BACKUP_C
    assert_out "Missing            BACKUP_D"
}

test_available_only_too_few_sticks() {
    make_sticks BACKUP_A BACKUP_B
    run_backup --available-only
    assert_rc 2
}

test_hub_is_first_present_stick() {
    make_sticks BACKUP_B BACKUP_C BACKUP_D
    run_backup --available-only
    assert_rc 0
    assert_out "Hub                BACKUP_B"
}

test_unknown_option() {
    # KNOWN_ISSUES #7: die before logging used to write to '>> ""'
    run_backup --bogus
    assert_rc 1
    assert_out "Unknown option: --bogus"
    assert_not_out "No such file or directory"
}

test_empty_sources() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    SOURCES_LINE="SOURCES=()"
    run_backup
    assert_rc 1
    assert_out "SOURCES array is empty"
}

# --- dry run -----------------------------------------------------------------

test_dry_run_writes_nothing() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    printf 'changed\n' > "${T}/src/docs/a.txt"
    run_backup --dry-run
    assert_rc 0
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    grep -q hello "$(stick_dir BACKUP_A)/data/docs/a.txt" || fail "dry run modified hub"
}

test_dry_run_on_fresh_sticks() {
    # KNOWN_ISSUES #4: used to die with exit 2 (data/ missing)
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup --dry-run
    assert_rc 0
    assert_out "fresh stick"
    assert_no_file "$(stick_dir BACKUP_A)/data"
}

test_dry_run_with_stale_offsite_stick() {
    # KNOWN_ISSUES #2: stale stick made dry run fail
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    unplug BACKUP_D
    printf 'changed\n' > "${T}/src/docs/a.txt"
    run_backup --available-only
    assert_rc 0
    plug BACKUP_D
    run_backup --dry-run
    assert_rc 0
    assert_out "a real run would update them"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

# --- failures ----------------------------------------------------------------

corrupt_file_keep_size_mtime() {
    # Flip content but keep size+mtime so rsync's quick check skips it.
    local f="$1" ref="${T}/ref"
    cp -p "$f" "$ref"
    printf 'HELLO\n' > "$f"
    touch -r "$ref" "$f"
}

test_hash_mismatch_exits_3_and_leaves_unlocked() {
    # KNOWN_ISSUES #1: used to exit 1 and lock everything
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    corrupt_file_keep_size_mtime "$(stick_dir BACKUP_C)/data/docs/a.txt"
    run_backup
    assert_rc 3
    assert_out "Hash mismatch on BACKUP_C"
    assert_unlocked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    assert_log "Mismatches: BACKUP_C"
    assert_log "Lock manually when done"
}

test_canary_corruption_exits_4() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    printf 'tampered\n' > "$(stick_dir BACKUP_B)/INTEGRITY_CANARY.txt"
    run_backup
    assert_rc 4
    assert_out "BACKUP_B: canary integrity check FAILED"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_canary_from_other_set_exits_4() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    make_stick BACKUP_D other-set
    run_backup
    assert_rc 4
    assert_out "not from the same backup set"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_wrong_passphrase_exits_5() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    PASS_OVERRIDE=wrong run_backup
    assert_rc 5
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_lock_dissenter_falls_back_to_force_unmount() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    export MOCK_LOCK_FAIL=BACKUP_B
    run_backup
    unset MOCK_LOCK_FAIL
    assert_rc 0
    assert_out "Locked BACKUP_B (after force unmount)"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_unexpected_error_is_reported() {
    # KNOWN_ISSUES #6: set -e failures used to exit 1 silently
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    mkdir -p "${T}/failbin"
    printf '#!/bin/sh\nexit 1\n' > "${T}/failbin/mktemp"
    chmod +x "${T}/failbin/mktemp"
    local saved="$TEST_PATH"
    TEST_PATH="${T}/failbin:${TEST_PATH}"
    run_backup
    TEST_PATH="$saved"
    assert_rc 1
    assert_out "Unexpected error"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_pre_hook_failure_exits_1() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    EXTRA_CONFIG='PRE_BACKUP_HOOK="false"'
    run_backup
    assert_rc 1
    assert_out "Pre-backup hook failed"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_env_passphrase_not_passed_to_hook() {
    # KNOWN_ISSUES #14
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    EXTRA_CONFIG="PRE_BACKUP_HOOK=\"env > '${T}/hook.env'\""
    run_backup
    assert_rc 0
    assert_file "${T}/hook.env"
    ! grep -q USB_BACKUP_PASSPHRASE "${T}/hook.env" || fail "passphrase leaked into hook env"
}

test_sigterm_cleans_up_once() {
    # KNOWN_ISSUES #5: cleanup used to run twice
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    write_config
    export MOCK_UNLOCK_DELAY=3
    PATH="$TEST_PATH" USB_BACKUP_PASSPHRASE=secret USB_BACKUP_CONFIG="${T}/test.conf" \
        "$BASH_UNDER_TEST" "$SCRIPT" --no-color > "${T}/out" 2>&1 &
    local pid=$!
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        grep -q "Unlocking volumes" "${T}/out" 2>/dev/null && break
        sleep 0.2
    done
    kill -TERM "$pid"
    wait "$pid"
    RC=$?
    unset MOCK_UNLOCK_DELAY
    OUT="$(cat "${T}/out")"
    assert_rc 143
    assert_count 1 "Backup Failed"
    assert_not_out "Backup Complete"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

# --- config ------------------------------------------------------------------

test_config_world_writable_refused() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    write_config
    chmod 666 "${T}/test.conf"
    OUT="$(PATH="$TEST_PATH" USB_BACKUP_PASSPHRASE=secret "$BASH_UNDER_TEST" "$SCRIPT" --no-color --config "${T}/test.conf" 2>&1)"
    RC=$?
    assert_rc 1
    assert_out "world-writable"
}

test_config_missing_file() {
    OUT="$(PATH="$TEST_PATH" "$BASH_UNDER_TEST" "$SCRIPT" --no-color --config "${T}/nope.conf" 2>&1)"
    RC=$?
    assert_rc 1
    assert_out "Config file not found"
}
