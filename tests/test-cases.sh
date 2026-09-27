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

# --- deletion guard, stale sources, source names (B) --------------------------

make_many_files() {
    local i
    for (( i=1; i<=20; i++ )); do printf 'file %s\n' "$i" > "${T}/src/docs/f${i}.txt"; done
}

test_deletion_guard_blocks_mass_delete() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    make_many_files
    run_backup
    assert_rc 0
    rm -f "${T}"/src/docs/f1*.txt "${T}"/src/docs/f2*.txt "${T}"/src/docs/f3.txt "${T}"/src/docs/f4.txt
    run_backup
    assert_rc 7
    assert_out "Deletion guard"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    assert_file "$(stick_dir BACKUP_A)/data/docs/f15.txt"
    assert_file "$(stick_dir BACKUP_D)/data/docs/f15.txt"
    assert_log "data/docs/f15.txt"
}

test_deletion_guard_override() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    make_many_files
    run_backup
    rm -f "${T}"/src/docs/f1*.txt
    sleep 1
    run_backup --allow-deletions
    assert_rc 0
    assert_out "overridden"
    assert_no_file "$(stick_dir BACKUP_C)/data/docs/f15.txt"
    # the deleted files survive in the snapshot
    local snap
    snap="$(find "$(stick_dir BACKUP_C)/history" -mindepth 1 -maxdepth 1 -type d | head -1)"
    assert_file "${snap}/docs/f15.txt"
}

test_deletion_guard_dry_run_only_warns() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    make_many_files
    run_backup
    rm -f "${T}"/src/docs/f1*.txt
    run_backup --dry-run
    assert_rc 0
    assert_out "a real run would stop here"
}

test_small_deletions_pass_guard() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    make_many_files
    run_backup
    rm -f "${T}/src/docs/f1.txt"
    run_backup
    assert_rc 0
    assert_no_file "$(stick_dir BACKUP_B)/data/docs/f1.txt"
}

test_deletion_guard_disabled() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    make_many_files
    run_backup
    rm -f "${T}"/src/docs/f1*.txt
    EXTRA_CONFIG="MAX_DELETE_PERCENT=0"
    run_backup
    assert_rc 0
}

test_removed_source_is_deleted_from_sticks() {
    # KNOWN_ISSUES #8
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    assert_file "$(stick_dir BACKUP_B)/data/keys/id"
    SOURCES_LINE="SOURCES=( \"${T}/src/docs\" )"
    run_backup
    assert_rc 0
    assert_out "no longer in SOURCES"
    local l
    for l in BACKUP_A BACKUP_B BACKUP_C BACKUP_D; do
        assert_no_file "$(stick_dir "$l")/data/keys"
    done
}

test_missing_source_is_kept_on_sticks() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    mv "${T}/src/keys" "${T}/keys-away"
    run_backup
    assert_rc 0
    assert_out "Source does not exist, skipping"
    assert_file "$(stick_dir BACKUP_C)/data/keys/id"
}

test_duplicate_source_basenames_refused() {
    # KNOWN_ISSUES #9
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    mkdir -p "${T}/other/docs"
    SOURCES_LINE="SOURCES=( \"${T}/src/docs\" \"${T}/other/docs\" )"
    run_backup
    assert_rc 1
    assert_out "would both be stored as data/docs"
}

test_trailing_slash_source() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    SOURCES_LINE="SOURCES=( \"${T}/src/docs/\" \"${T}/src/keys\" )"
    run_backup
    assert_rc 0
    assert_file "$(stick_dir BACKUP_A)/data/docs/a.txt"
    assert_no_file "$(stick_dir BACKUP_A)/data/a.txt"
}

test_single_file_source() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    printf 'seed\n' > "${T}/seed.gpg"
    SOURCES_LINE="SOURCES=( \"${T}/src/docs\" \"${T}/seed.gpg\" )"
    run_backup
    assert_rc 0
    assert_same_file "${T}/seed.gpg" "$(stick_dir BACKUP_D)/data/seed.gpg"
    run_backup
    assert_rc 0
    assert_file "$(stick_dir BACKUP_D)/data/seed.gpg"
}

# --- history (B) --------------------------------------------------------------

snapshot_count() {
    local d
    d="$(stick_dir "$1")/history"
    [[ -d "$d" ]] || { echo 0; return; }
    find "$d" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

test_history_snapshot_keeps_old_version() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    assert_rc 0
    [[ "$(snapshot_count BACKUP_A)" -eq 0 ]] || fail "first run on empty sticks should not snapshot"
    printf 'version 2\n' > "${T}/src/docs/a.txt"
    sleep 1
    run_backup
    assert_rc 0
    local l snap
    for l in BACKUP_A BACKUP_B BACKUP_C BACKUP_D; do
        [[ "$(snapshot_count "$l")" -eq 1 ]] || fail "$l should have 1 snapshot"
        snap="$(find "$(stick_dir "$l")/history" -mindepth 1 -maxdepth 1 -type d)"
        grep -q hello "${snap}/docs/a.txt" || fail "$l snapshot lacks old version"
        grep -q 'version 2' "$(stick_dir "$l")/data/docs/a.txt" || fail "$l data not updated"
        # unchanged files must be hard links (no extra space), not copies
        [[ "${snap}/docs/b.txt" -ef "$(stick_dir "$l")/data/docs/b.txt" ]] \
            || fail "$l snapshot of unchanged b.txt is not a hard link"
    done
}

test_history_unchanged_run_keeps_no_snapshot() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    sleep 1
    run_backup
    assert_rc 0
    [[ "$(snapshot_count BACKUP_A)" -eq 0 ]] || fail "unchanged run should not keep a snapshot"
}

test_history_pruned_to_keep() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    EXTRA_CONFIG="HISTORY_KEEP=2"
    local i
    for i in 1 2 3 4; do
        printf 'v%s\n' "$i" > "${T}/src/docs/a.txt"
        run_backup
        assert_rc 0
        sleep 1
    done
    [[ "$(snapshot_count BACKUP_B)" -eq 2 ]] || fail "expected 2 snapshots, got $(snapshot_count BACKUP_B)"
}

test_history_disabled() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    EXTRA_CONFIG="HISTORY_KEEP=0"
    run_backup
    printf 'v2\n' > "${T}/src/docs/a.txt"
    run_backup
    assert_rc 0
    assert_no_file "$(stick_dir BACKUP_A)/history"
}

# --- stored hashes and --verify-only (C) -------------------------------------

test_hashes_file_written_and_checkable() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    assert_rc 0
    local d
    d="$(stick_dir BACKUP_C)"
    assert_file "${d}/BACKUP_HASHES.txt"
    ( cd "$d" && PATH="$TEST_PATH" shasum -a 256 -c BACKUP_HASHES.txt >/dev/null ) \
        || fail "shasum -c BACKUP_HASHES.txt failed on the stick"
    grep -q '^File hashes:' "${d}/BACKUP_MANIFEST.txt" || fail "manifest lacks File hashes line"
}

test_verify_only_ok() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    SOURCES_LINE="SOURCES=()"
    run_backup --verify-only
    assert_rc 0
    assert_out "Verification Complete"
    assert_out "BACKUP_D: 3 files match"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_verify_only_detects_bitrot_on_single_stick() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    corrupt_file_keep_size_mtime "$(stick_dir BACKUP_D)/data/docs/a.txt"
    unplug BACKUP_A; unplug BACKUP_B; unplug BACKUP_C
    run_backup --verify-only
    assert_rc 3
    assert_out "BACKUP_D: 1 file(s) changed, missing or added"
    assert_unlocked BACKUP_D
    assert_log "data/docs/a.txt"
}

test_verify_only_without_stored_hashes() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    rm -f "$(stick_dir BACKUP_A)/BACKUP_HASHES.txt" "$(stick_dir BACKUP_B)/BACKUP_HASHES.txt" \
          "$(stick_dir BACKUP_C)/BACKUP_HASHES.txt" "$(stick_dir BACKUP_D)/BACKUP_HASHES.txt"
    run_backup --verify-only
    assert_rc 2
    assert_out "older version"
    assert_locked BACKUP_A BACKUP_B BACKUP_C BACKUP_D
}

test_verify_only_writes_nothing() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    local before
    before="$(cat "$(stick_dir BACKUP_A)/BACKUP_MANIFEST.txt")"
    printf 'changed\n' > "${T}/src/docs/a.txt"
    sleep 1
    run_backup --verify-only
    assert_rc 0
    [[ "$before" == "$(cat "$(stick_dir BACKUP_A)/BACKUP_MANIFEST.txt")" ]] || fail "manifest changed"
    grep -q hello "$(stick_dir BACKUP_A)/data/docs/a.txt" || fail "data changed"
}

# --- --init-stick (D) ---------------------------------------------------------

make_disk() {
    # make_disk diskN External|Internal
    cat > "${MOCK_STATE}/disks/$1" <<INFO
   Device Identifier:         $1
   Whole:                     Yes
   Device / Media Name:       Mock USB Stick
   Protocol:                  USB
   Device Location:           ${2:-External}
   Disk Size:                 64.0 GB (64000000000 Bytes)
INFO
}

test_init_stick_copies_canary_and_encrypts() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    make_disk disk9
    STDIN_INPUT="BACKUP_D"
    run_backup --init-stick BACKUP_D --disk disk9
    assert_rc 0
    assert_out "BACKUP_D is ready"
    assert_file "${MOCK_STATE}/disk9.erased"
    [[ "$(cat "${MOCK_STATE}/BACKUP_D.encrypted" 2>/dev/null)" == "secret" ]] || fail "not encrypted with the set passphrase"
    assert_locked BACKUP_A BACKUP_D
    assert_same_file "$(stick_dir BACKUP_A)/INTEGRITY_CANARY.txt" "$(stick_dir BACKUP_D)/INTEGRITY_CANARY.txt"
    assert_file "$(stick_dir BACKUP_D)/data"
    # the new stick joins a normal full backup
    STDIN_INPUT=""
    run_backup
    assert_rc 0
    assert_file "$(stick_dir BACKUP_D)/data/docs/a.txt"
}

test_init_stick_refuses_internal_disk() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    make_disk disk0 Internal
    STDIN_INPUT="BACKUP_D"
    run_backup --init-stick BACKUP_D --disk disk0
    assert_rc 1
    assert_out "Refusing to erase"
    assert_no_file "${MOCK_STATE}/disk0.erased"
}

test_init_stick_refuses_partition() {
    make_sticks BACKUP_A
    STDIN_INPUT="BACKUP_D"
    run_backup --init-stick BACKUP_D --disk disk9s1
    assert_rc 1
    assert_out "not a partition"
}

test_init_stick_wrong_confirmation() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    make_disk disk9
    STDIN_INPUT="yes"
    run_backup --init-stick BACKUP_D --disk disk9
    assert_rc 1
    assert_out "Nothing was changed"
    assert_no_file "${MOCK_STATE}/disk9.erased"
}

test_init_stick_wrong_passphrase_erases_nothing() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    make_disk disk9
    STDIN_INPUT="BACKUP_D"
    PASS_OVERRIDE=wrong run_backup --init-stick BACKUP_D --disk disk9
    assert_rc 5
    assert_no_file "${MOCK_STATE}/disk9.erased"
    assert_locked BACKUP_A
}

test_init_stick_existing_label_refused() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    make_disk disk9
    STDIN_INPUT="BACKUP_D"
    run_backup --init-stick BACKUP_D --disk disk9
    assert_rc 1
    assert_out "already exists"
}

test_init_stick_unknown_label_refused() {
    make_sticks BACKUP_A
    make_disk disk9
    STDIN_INPUT="BACKUP_Z"
    run_backup --init-stick BACKUP_Z --disk disk9
    assert_rc 1
    assert_out "not in LABELS"
}

test_init_stick_needs_reference_or_new_set() {
    make_disk disk9
    STDIN_INPUT="BACKUP_A"
    run_backup --init-stick BACKUP_A --disk disk9
    assert_rc 1
    assert_out "--new-set"
    assert_no_file "${MOCK_STATE}/disk9.erased"
}

test_init_stick_new_set() {
    make_disk disk9
    STDIN_INPUT="BACKUP_A"
    run_backup --init-stick BACKUP_A --disk disk9 --new-set
    assert_rc 0
    assert_out "new backup set"
    assert_locked BACKUP_A
    ( cd "$(stick_dir BACKUP_A)" && PATH="$TEST_PATH" shasum -a 256 -c .canary.sha256 >/dev/null ) \
        || fail "generated canary does not verify"
}

test_init_stick_encrypt_failure() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C
    make_disk disk9
    STDIN_INPUT="BACKUP_D"
    export MOCK_ENCRYPT_FAIL=1
    run_backup --init-stick BACKUP_D --disk disk9
    unset MOCK_ENCRYPT_FAIL
    assert_rc 5
    assert_out "NOT encrypted"
}

# --- reminders (D) ------------------------------------------------------------

state_file() { printf '%s' "${T}/home/state/last-sync"; }

test_backup_records_last_sync() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup
    assert_rc 0
    [[ "$(wc -l < "$(state_file)" | tr -d ' ')" -eq 4 ]] || fail "expected 4 lines in state file"
    run_backup --check-reminder
    assert_rc 0
    assert_out "Backups are up to date"
}

test_available_only_keeps_offsite_sync_time() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    mkdir -p "${T}/home/state"
    printf 'BACKUP_D 1000 old\n' > "$(state_file)"
    unplug BACKUP_D
    run_backup --available-only
    assert_rc 0
    grep -q '^BACKUP_D 1000 ' "$(state_file)" || fail "offsite stick's time was overwritten"
    run_backup --check-reminder
    assert_rc 0
    assert_out "BACKUP_D last synced"
    grep -q 'BACKUP_D last synced' "${MOCK_STATE}/osascript.calls" || fail "no notification sent"
}

test_reminder_overdue_backup() {
    mkdir -p "${T}/home/state"
    local l
    for l in BACKUP_A BACKUP_B BACKUP_C BACKUP_D; do
        printf '%s %s x\n' "$l" "$(( $(date +%s) - 10 * 86400 ))" >> "$(state_file)"
    done
    run_backup --check-reminder
    assert_rc 0
    assert_out "Last USB backup was 10 days ago"
}

test_reminder_no_state() {
    run_backup --check-reminder
    assert_rc 0
    assert_out "No USB backup has been recorded yet"
}

test_dry_run_does_not_record_sync() {
    make_sticks BACKUP_A BACKUP_B BACKUP_C BACKUP_D
    run_backup --dry-run
    assert_rc 0
    assert_no_file "$(state_file)"
}

test_install_and_uninstall_reminder() {
    write_config
    run_backup --install-reminder --config "${T}/test.conf"
    assert_rc 0
    local plist="${T}/home/Library/LaunchAgents/com.backupstick.reminder.plist"
    assert_file "$plist"
    grep -q '<string>--check-reminder</string>' "$plist" || fail "plist lacks --check-reminder"
    grep -q "<string>${T}/test.conf</string>" "$plist" || fail "plist lacks --config path"
    grep -q 'launchctl bootstrap' "${MOCK_STATE}/launchctl.calls" || fail "launchctl bootstrap not called"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$plist" >/dev/null || fail "plist is not valid (plutil -lint)"
    fi
    run_backup --uninstall-reminder
    assert_rc 0
    assert_no_file "$plist"
}
