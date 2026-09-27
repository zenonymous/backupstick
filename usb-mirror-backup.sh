#!/usr/bin/env bash
#
# usb-mirror-backup.sh
#
# Weekly encrypted USB mirror backup for macOS, supporting N sticks (default 4)
# with optional offsite rotation.
#
# Topology: sources → hub → each secondary stick (star, not chain).
# The "hub" is the first present stick from LABELS. All other present sticks
# are mirrored from the hub. A star prevents propagation of silent corruption
# on secondary X to secondary Y.
#
# Requirements: all APFS (Case-sensitive, Encrypted) volumes listed in LABELS,
#               sharing the same passphrase, created via the one-time setup
#
# Usage: ./usb-mirror-backup.sh                     # all sticks required
#        ./usb-mirror-backup.sh --dry-run           # no writes
#        ./usb-mirror-backup.sh --available-only    # ≥MIN_STICKS_AVAILABLE present
#        ./usb-mirror-backup.sh --verify-only       # check sticks against stored hashes
#        ./usb-mirror-backup.sh --allow-deletions   # bypass the deletion guard once
#        ./usb-mirror-backup.sh --no-color          # disable colored output
#        ./usb-mirror-backup.sh --config FILE       # settings file
#        ./usb-mirror-backup.sh --init-stick BACKUP_B --disk disk4 [--new-set]
#        ./usb-mirror-backup.sh --check-reminder    # notify if backups are overdue
#        ./usb-mirror-backup.sh --install-reminder  # daily check via launchd
#        ./usb-mirror-backup.sh --help
#
# Exit codes:
#   0  success
#   1  usage / config error
#   2  prerequisite missing (tool, volume, path)
#   3  hash verification mismatch (sticks not identical)
#   4  canary integrity failure
#   5  unlock / mount problem
#   6  rsync fatal error
#   7  deletion guard tripped (nothing was changed)
#

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION  —  user-tunable knobs
#
# These are defaults. Prefer putting your settings in a config file instead
# of editing this script (keeps personal paths out of the repo):
#   --config PATH, else $USB_BACKUP_CONFIG, else ~/.config/usb-backup/config
# The file is sourced as bash and may override any variable below. See
# usb-backup.conf.example.
# =============================================================================

# Volume labels, in order of preference for hub role. The first present label
# becomes the hub for that run. Adjust as you like: remove or add labels.
# All labels must match the one-time setup (same passphrase, shared canary).
LABELS=(
    "BACKUP_A"
    "BACKUP_B"
    "BACKUP_C"
    "BACKUP_D"
)

# Minimum number of sticks that must be present under --available-only.
# Below this threshold the script refuses to run; this protects the
# redundancy guarantee during offsite rotation.
MIN_STICKS_AVAILABLE=3

# Subdirectory within each volume where rsync --delete operates.
# Everything OUTSIDE this subdirectory (manifest, canary) is never deleted.
DATA_SUBDIR="data"

# Source paths — fill in as needed. Quote paths with spaces.
# Each source is copied as a top-level entry under ${MOUNT}/${DATA_SUBDIR}/,
# so a source "/Users/j/Documents/backup-me" ends up at
# "/Volumes/BACKUP_A/data/backup-me/...".
SOURCES=(
    # "${HOME}/path/to/seed.gpg"
    # "${HOME}/Library/Group Containers/group.com.apple.notes"
    # "${HOME}/Documents/backup-me"
    # "${HOME}/.ssh"
    # "${HOME}/.gnupg"
)

# Excludes — macOS-noise generated independently per stick. These patterns
# are filtered from rsync AND from hash comparison. Without this filter,
# sticks would always diverge on metadata.
RSYNC_EXCLUDES=(
    ".DS_Store"
    "._*"
    ".Spotlight-V100"
    ".fseventsd"
    ".Trashes"
    ".TemporaryItems"
    ".DocumentRevisions-V100"
    ".VolumeIcon.icns"
)

# Log directory
LOG_DIR="${HOME}/Library/Logs/usb-backup"

# Where macOS mounts volumes. Only change this for testing.
VOLUMES_ROOT="/Volumes"

# Optional pre-backup hook (e.g. export Apple Notes via osascript).
# Leave empty for none. Example:
#   PRE_BACKUP_HOOK="osascript ${HOME}/bin/export-notes.scpt"
PRE_BACKUP_HOOK=""

# Deletion guard. Before writing anything, the script works out how many
# backed-up files this run would delete on each stick. If that is more than
# MAX_DELETE_MIN files AND more than MAX_DELETE_PERCENT % of the files on
# that stick, it stops (exit 7) without changing anything. This protects
# against a wiped or ransomware-encrypted source being mirrored to every
# stick. --allow-deletions overrides it for one run. MAX_DELETE_PERCENT=0
# disables the guard.
MAX_DELETE_PERCENT=25
MAX_DELETE_MIN=10

# History. Before a run changes a stick, its data/ is snapshotted to
# <volume>/history/<UTC timestamp>/ using hard links, so unchanged files take
# no extra space. A snapshot is dropped again if the run changed nothing.
# The newest HISTORY_KEEP snapshots are kept per stick. 0 disables snapshots
# (existing history/ is then left alone).
HISTORY_KEEP=8
HISTORY_SUBDIR="history"

# Reminders (--check-reminder, run daily by --install-reminder). Each
# successful backup records per stick when it was last synced, in STATE_DIR.
# A macOS notification appears if no backup ran for REMIND_AFTER_DAYS, or a
# stick (typically the offsite one) wasn't synced for REMIND_STICK_DAYS.
REMIND_AFTER_DAYS=8
REMIND_STICK_DAYS=42
STATE_DIR="${HOME}/Library/Application Support/usb-backup"

# =============================================================================
# END CONFIGURATION  —  don't edit below unless you know what you're doing
# =============================================================================

# Runtime state
DRY_RUN=0
AVAILABLE_ONLY=0
VERIFY_ONLY=0
ALLOW_DELETIONS=0
MODE="backup"          # backup | verify | init | check-reminder | install-reminder | uninstall-reminder
INIT_LABEL=""
INIT_DISK=""
INIT_NEW_SET=0
NO_COLOR=0
CONFIG_FILE=""
PRESENT_LABELS=()
MISSING_LABELS=()
UNLOCKED_LABELS=()
HUB_LABEL=""
LOG_FILE=""
TIMESTAMP=""
SCRIPT_PATH=""
SCRIPT_HASH=""
PASSPHRASE=""
HASHER_CMD=()
HASHER_FORCED=()
RSYNC_PROGRESS_FLAGS=()
FIND_ARGS=()
WORKDIR=""
SNAPSHOT_LABELS=()
VERIFIED_HUB_HASHES=""
START_EPOCH=0
SUMMARY_FILE_COUNT=""
SUMMARY_TOTAL_BYTES=""
CLEANUP_DONE=0

# TTY / color state
IS_TTY=0
C_RESET=""
C_BOLD=""
C_DIM=""
C_CYAN=""
C_GREEN=""
C_YELLOW=""
C_RED=""

# Spinner state
SPINNER_PID=""

# Spinner frames (Braille)
SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# -----------------------------------------------------------------------------
# TTY / color init
# -----------------------------------------------------------------------------

init_tty() {
    if [[ "$NO_COLOR" -eq 0 ]] && [[ -t 2 ]]; then
        IS_TTY=1
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_CYAN=$'\033[36m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_RED=$'\033[31m'
    fi
}

# -----------------------------------------------------------------------------
# Formatting helpers
# -----------------------------------------------------------------------------

format_number() {
    # Insert thousand separators (commas). Locale-independent.
    awk -v n="$1" 'BEGIN {
        s = n; res = ""
        while (length(s) > 3) {
            res = "," substr(s, length(s) - 2) res
            s = substr(s, 1, length(s) - 3)
        }
        print s res
    }'
}

format_bytes() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB PB", units)
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d %s\n", b, units[i]
        else        printf "%.2f %s\n", b, units[i]
    }'
}

format_duration() {
    local sec="$1"
    local h=$((sec / 3600))
    local m=$(( (sec % 3600) / 60 ))
    local s=$((sec % 60))
    if [[ "$h" -gt 0 ]]; then
        printf '%dh %dm %ds' "$h" "$m" "$s"
    elif [[ "$m" -gt 0 ]]; then
        printf '%dm %ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

# -----------------------------------------------------------------------------
# UI primitives
# -----------------------------------------------------------------------------

clear_line() {
    if [[ "$IS_TTY" -eq 1 ]]; then
        printf '\r\033[K' >&2
    fi
    return 0
}

print_phase() {
    local n="$1" total="$2" title="$3"
    # Plain to log file
    printf '\n=== Phase %s/%s: %s ===\n' "$n" "$total" "$title" >> "$LOG_FILE"
    # Fancy to terminal
    if [[ "$IS_TTY" -eq 1 ]]; then
        printf '\n%s━━━ %sPhase %s/%s:%s %s%s%s %s━━━%s\n' \
            "$C_CYAN" "$C_BOLD" "$n" "$total" "$C_RESET" \
            "$C_BOLD" "$title" "$C_RESET" \
            "$C_CYAN" "$C_RESET" >&2
    else
        printf '\n=== Phase %s/%s: %s ===\n' "$n" "$total" "$title" >&2
    fi
}

draw_progress_bar() {
    # Args: current total [label]
    [[ "$IS_TTY" -eq 1 ]] || return 0
    local current="$1" total="$2" label="${3:-}"
    [[ "$total" -eq 0 ]] && return 0
    local width=30
    local filled=$((current * width / total))
    [[ "$filled" -gt "$width" ]] && filled="$width"
    local pct=$((current * 100 / total))
    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=filled; i<width; i++ )); do bar+="░"; done
    printf '\r  %s[%s]%s %3d%% %s(%s/%s)%s%s' \
        "$C_CYAN" "$bar" "$C_RESET" \
        "$pct" \
        "$C_DIM" "$(format_number "$current")" "$(format_number "$total")" "$C_RESET" \
        "${label:+ $label}" >&2
}

start_spinner() {
    local msg="$1"
    if [[ "$IS_TTY" -eq 0 ]]; then
        log "${msg}..."
        return 0
    fi
    (
        trap 'exit 0' TERM INT
        local i=0
        while true; do
            printf '\r  %s%s%s %s ' \
                "$C_CYAN" "${SPINNER_FRAMES[$((i % 10))]}" "$C_RESET" \
                "$msg" >&2
            i=$((i + 1))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    # Idempotent
    if [[ -z "${SPINNER_PID:-}" ]]; then
        return 0
    fi
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    clear_line
}

print_mark() {
    # Args: status_char color message
    local ch="$1" color="$2" msg="$3"
    if [[ "$IS_TTY" -eq 1 ]]; then
        printf '  %s%s%s %s\n' "$color" "$ch" "$C_RESET" "$msg" >&2
    else
        printf '  %s %s\n' "$ch" "$msg" >&2
    fi
}

print_ok()   { print_mark "✓" "$C_GREEN"  "$1"; }
print_warn() { print_mark "⚠" "$C_YELLOW" "$1"; }
print_fail() { print_mark "✗" "$C_RED"    "$1"; }

print_summary() {
    # Must not touch the sticks: on success they are already locked when this
    # runs. File/size stats come from SUMMARY_* (set while still unlocked).
    local status="$1"   # "success" or "failure"
    local duration_sec
    duration_sec=$(( $(date +%s) - START_EPOCH ))

    local status_icon status_text status_color
    local what="Backup"
    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
        what="Verification"
    fi
    if [[ "$status" == "success" ]]; then
        status_icon="✓"; status_text="${what} Complete"; status_color="$C_GREEN"
    else
        status_icon="✗"; status_text="${what} Failed";   status_color="$C_RED"
    fi

    local sep="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    {
        printf '\n'
        if [[ "$IS_TTY" -eq 1 ]]; then
            printf '%s%s%s\n'       "$C_CYAN" "$sep" "$C_RESET"
            printf '  %s%s%s %s%s%s\n'  "$status_color" "$status_icon" "$C_RESET" "$C_BOLD" "$status_text" "$C_RESET"
            printf '%s%s%s\n'       "$C_CYAN" "$sep" "$C_RESET"
        else
            printf '%s\n  %s %s\n%s\n' "$sep" "$status_icon" "$status_text" "$sep"
        fi

        printf '  %-18s %s\n' "Hub"       "$HUB_LABEL"
        local sticks_title="Sticks"
        if [[ "$status" == "success" ]]; then
            sticks_title="Synced"
            [[ "$VERIFY_ONLY" -eq 1 ]] && sticks_title="Checked"
        fi
        printf '  %-18s %s\n' "$sticks_title" \
            "$(join_by "${PRESENT_LABELS[@]}")"
        if [[ "${#MISSING_LABELS[@]}" -gt 0 ]]; then
            printf '  %-18s %s\n' "Missing" "$(join_by "${MISSING_LABELS[@]}")"
        fi
        if [[ -n "$SUMMARY_FILE_COUNT" ]]; then
            printf '  %-18s %s\n' "Files" "$(format_number "$SUMMARY_FILE_COUNT")"
            printf '  %-18s %s\n' "Size"  "$(format_bytes "$SUMMARY_TOTAL_BYTES")"
        fi
        printf '  %-18s %s\n' "Duration"  "$(format_duration "$duration_sec")"
        printf '  %-18s %s\n' "Dry run"   "$([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no)"
        printf '  %-18s %s\n' "Log"       "$LOG_FILE"

        if [[ "$IS_TTY" -eq 1 ]]; then
            printf '%s%s%s\n\n' "$C_CYAN" "$sep" "$C_RESET"
        else
            printf '%s\n\n' "$sep"
        fi
    } >&2
}

usage() {
    cat <<'EOF'
Usage: usb-mirror-backup.sh [OPTIONS]

Options:
  --dry-run          Simulate the full flow without changing the sticks
                     (no rsync writes, snapshots, deletions or manifest
                     updates). Volumes are still unlocked and hashed;
                     out-of-date sticks and deletion-guard hits are
                     reported as warnings.
  --available-only   Work with the sticks that are actually present
                     (minimum MIN_STICKS_AVAILABLE, default 3). Without
                     this flag, ALL configured sticks must be present.
                     Intended for offsite rotation workflows.
  --verify-only      Don't back up. Unlock the present sticks and check
                     every file against the hashes stored on that stick by
                     the last backup (detects bit-rot, e.g. on the offsite
                     stick). Any number of sticks may be present.
  --allow-deletions  Run even if the deletion guard (MAX_DELETE_PERCENT /
                     MAX_DELETE_MIN) would stop it. Use after checking that
                     the deletions are intended.
  --no-color         Disable colored output and animations.

  --init-stick LABEL --disk DISK [--new-set]
                     Set up a new stick: ERASE the whole disk DISK (e.g.
                     disk4, see 'diskutil list external'), format it as
                     case-sensitive APFS named LABEL, encrypt it with the
                     backup passphrase and install the integrity canary.
                     Plug in one existing stick of the set too: its canary
                     is copied and it proves the passphrase. --new-set
                     starts a brand new backup set instead.
  --check-reminder   Show a macOS notification if the last backup, or the
                     last sync of any stick, is too old. No sticks needed.
  --install-reminder Install a launchd agent that runs --check-reminder daily.
  --uninstall-reminder
                     Remove that launchd agent.

  --config FILE      Read settings from FILE (default: $USB_BACKUP_CONFIG,
                     else ~/.config/usb-backup/config if it exists).
  -h, --help         Show this help message.

Environment:
  USB_BACKUP_CONFIG       Config file path (overridden by --config).
  USB_BACKUP_PASSPHRASE   If set: use instead of the interactive prompt.
                          Caution: a passphrase in env is visible in 'ps'
                          and shell history. Automation scenarios only.
EOF
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log_to_file() {
    # Append one plain line to the log file. No-op before init_logging
    # (e.g. argument errors), so early die() calls don't fail on '>> ""'.
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$*" >> "$LOG_FILE"
    fi
    return 0
}

log() {
    # Plain to log file, dimmed timestamp to terminal.
    stop_spinner
    local ts msg
    ts="[$(date -u +%Y-%m-%dT%H:%M:%SZ)]"
    msg="$*"
    log_to_file "${ts} ${msg}"
    if [[ "$IS_TTY" -eq 1 ]]; then
        printf '  %s%s%s %s\n' "$C_DIM" "$ts" "$C_RESET" "$msg" >&2
    else
        printf '  %s %s\n' "$ts" "$msg" >&2
    fi
}

die() {
    local code="$1"
    shift
    stop_spinner
    print_fail "$*"
    log_to_file "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*"
    exit "$code"
}

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        die 2 "Required tool not found: $tool"
    fi
}

mount_point_for() {
    printf '%s/%s' "$VOLUMES_ROOT" "$1"
}

join_by() {
    # Join array args with a space separator. Avoids IFS=$'\n\t' surprises
    # when expanding "${arr[*]}" into a log or display string.
    local out=""
    local first=1
    local item
    for item in "$@"; do
        if [[ "$first" -eq 1 ]]; then
            out="$item"
            first=0
        else
            out+=" $item"
        fi
    done
    printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# Volume detection and (un)lock
# -----------------------------------------------------------------------------

apfs_volume_present() {
    # diskutil info returns exit 0 for an existing volume (locked or unlocked),
    # independent of macOS version or output formatting.
    local label="$1"
    diskutil info "$label" >/dev/null 2>&1
}

mountpoint_is_apfs() {
    local mount="$1"
    diskutil info "$mount" 2>/dev/null \
        | grep -E '^[[:space:]]*(File System Personality|Type \(Bundle\)):' \
        | grep -q -i apfs
}

apfs_volume_unlocked() {
    local label="$1"
    local mount
    mount="$(mount_point_for "$label")"
    [[ -d "$mount" ]] && mountpoint_is_apfs "$mount"
}

unlock_volume() {
    local label="$1"
    local mount
    mount="$(mount_point_for "$label")"

    if apfs_volume_unlocked "$label"; then
        print_ok "${label} is already unlocked at ${mount}"
        printf '[%s] %s already unlocked\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" >> "$LOG_FILE"
        UNLOCKED_LABELS+=("$label")
        return 0
    fi

    # Record before unlocking: if a signal arrives while diskutil runs, the
    # volume may end up unlocked and cleanup must still lock it. lock_volume
    # is a no-op for volumes that are not unlocked.
    UNLOCKED_LABELS+=("$label")
    start_spinner "Unlocking ${label}"
    local unlock_rc=0
    printf '%s\n' "$PASSPHRASE" \
        | diskutil apfs unlockVolume "$label" -stdinpassphrase >>"$LOG_FILE" 2>&1 \
        || unlock_rc=$?
    stop_spinner

    if [[ "$unlock_rc" -ne 0 ]]; then
        die 5 "Unlock of ${label} failed (wrong passphrase or volume absent?)"
    fi

    # diskutil mount is async in some versions; wait up to 10s
    local _attempt
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -d "$mount" ]]; then
            print_ok "${label} mounted at ${mount}"
            printf '[%s] %s mounted\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" >> "$LOG_FILE"
            return 0
        fi
        sleep 1
    done

    die 5 "Unlock appeared to succeed but ${mount} is not present after 10s"
}

lock_volume() {
    # Idempotent. On a "dissenter" (Spotlight, Finder, open shell) we fall
    # back to `diskutil unmount force` and try locking again, so a script run
    # always ends with locked volumes.
    local label="$1"
    local mount
    mount="$(mount_point_for "$label")"

    if ! apfs_volume_present "$label"; then
        return 0
    fi
    if ! apfs_volume_unlocked "$label"; then
        return 0
    fi

    if diskutil apfs lockVolume "$label" >>"$LOG_FILE" 2>&1; then
        print_ok "Locked ${label}"
        return 0
    fi

    printf '[%s] lockVolume %s failed (dissenter?), trying force unmount\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" >> "$LOG_FILE"
    if ! diskutil unmount force "$mount" >>"$LOG_FILE" 2>&1; then
        print_warn "Force unmount ${label} failed. Lock manually: diskutil apfs lockVolume ${label}"
        return 0
    fi

    if ! diskutil apfs lockVolume "$label" >>"$LOG_FILE" 2>&1; then
        print_warn "lockVolume ${label} still failed. Lock manually."
        return 0
    fi
    print_ok "Locked ${label} (after force unmount)"
}

# -----------------------------------------------------------------------------
# Canary
# -----------------------------------------------------------------------------

verify_canary() {
    local label="$1"
    local mount
    mount="$(mount_point_for "$label")"
    local canary="${mount}/INTEGRITY_CANARY.txt"
    local canary_sha="${mount}/.canary.sha256"

    if [[ ! -f "$canary" ]]; then
        die 4 "${label}: INTEGRITY_CANARY.txt missing. One-time setup not (properly) performed."
    fi
    if [[ ! -f "$canary_sha" ]]; then
        die 4 "${label}: .canary.sha256 missing. One-time setup not (properly) performed."
    fi

    if ! ( cd "$mount" && shasum -a 256 -c .canary.sha256 ) >>"$LOG_FILE" 2>&1; then
        die 4 "${label}: canary integrity check FAILED. Possible tampering or filesystem corruption. Aborting; manual investigation required."
    fi
    print_ok "${label}: canary OK"
}

verify_canaries_match() {
    # All present sticks must share the same canary (same backup set).
    local hub_canary
    hub_canary="$(mount_point_for "$HUB_LABEL")/INTEGRITY_CANARY.txt"
    local label
    for label in "${PRESENT_LABELS[@]}"; do
        if [[ "$label" == "$HUB_LABEL" ]]; then
            continue
        fi
        local other_canary
        other_canary="$(mount_point_for "$label")/INTEGRITY_CANARY.txt"
        if ! cmp -s "$hub_canary" "$other_canary"; then
            die 4 "Canary on ${label} differs from hub ${HUB_LABEL} — not from the same backup set."
        fi
    done
    print_ok "All canaries match (same backup set)"
}

# -----------------------------------------------------------------------------
# Hashing with live progress bar
# -----------------------------------------------------------------------------

set_find_args() {
    # FIND_ARGS = prune RSYNC_EXCLUDES, then match regular files with the
    # given action (-print or -print0). Shared by every file listing so that
    # counting, hashing and deletion planning see the same set of files.
    local action="$1" excl
    FIND_ARGS=()
    for excl in "${RSYNC_EXCLUDES[@]}"; do
        FIND_ARGS+=( "-name" "$excl" "-prune" "-o" )
    done
    FIND_ARGS+=( "-type" "f" "$action" )
}

pick_hasher_cmd() {
    if [[ "${#HASHER_FORCED[@]}" -gt 0 ]]; then
        HASHER_CMD=( "${HASHER_FORCED[@]}" )
        return 0
    fi
    if command -v b3sum >/dev/null 2>&1; then
        HASHER_CMD=( b3sum )
    else
        HASHER_CMD=( shasum -a 256 )
    fi
}

hasher_name() {
    pick_hasher_cmd
    join_by "${HASHER_CMD[@]}"
}

progress_counter() {
    # Read lines from stdin, update progress bar. Discard input.
    local total="$1" label="$2"
    local count=0
    while IFS= read -r _; do
        count=$((count + 1))
        draw_progress_bar "$count" "$total" "$label"
    done
    clear_line
}

generate_file_manifest() {
    # Write "<hash>  <relative-path>" per file under <root>/<DATA_SUBDIR>,
    # deterministically sorted, with macOS-noise filtered out.
    local root="$1" out="$2" label="$3"

    pick_hasher_cmd

    local data_root="${root}/${DATA_SUBDIR}"
    if [[ ! -d "$data_root" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            # Fresh stick: phase 3 skips mkdir in dry-run mode.
            : > "$out"
            print_warn "${label}: no ${DATA_SUBDIR}/ yet (fresh stick); a real run would create it"
            return 0
        fi
        die 2 "Data directory missing: ${data_root}"
    fi

    # Pre-count for progress bar
    local total
    total=$(count_files_under_data "$root")

    if [[ "$total" -eq 0 ]]; then
        : > "$out"
        print_warn "${label}: 0 files to hash (empty data directory)"
        return 0
    fi

    # Pipe: find | sort | hash-batches → tee to output file → progress counter
    set_find_args -print0
    (
        cd "$root"
        find "$DATA_SUBDIR" "${FIND_ARGS[@]}" \
            | LC_ALL=C sort -z \
            | xargs -0 -n 32 "${HASHER_CMD[@]}"
    ) | tee "$out" | progress_counter "$total" "hashing ${label}"
}

# -----------------------------------------------------------------------------
# Rsync with live progress
# -----------------------------------------------------------------------------

build_rsync_excludes() {
    local excl
    for excl in "${RSYNC_EXCLUDES[@]}"; do
        printf -- "--exclude=%s\n" "$excl"
    done
}

detect_rsync_capabilities() {
    # Apple's stock /usr/bin/rsync is a 2.6.9 fork (GPL2-era) that lacks
    # --info=progress2. Homebrew ships rsync 3.x which has it. We parse the
    # major version and pick the best available progress flags.
    #
    # We capture full --version output first and then take line 1, rather
    # than piping through `head -1`. With `set -o pipefail`, `head -1`
    # closes the pipe after reading 1 line, rsync receives SIGPIPE, and
    # the whole pipeline fails.
    local ver_output ver_line ver_major
    ver_output="$(rsync --version 2>/dev/null || true)"
    ver_line="${ver_output%%$'\n'*}"
    ver_major="$(printf '%s' "$ver_line" | awk '{
        for(i=1;i<=NF;i++) {
            w = $i
            sub(/^v/, "", w)
            if (w ~ /^[0-9]+\.[0-9]+/) {
                split(w, a, ".")
                print a[1]
                exit
            }
        }
    }')"

    if [[ -z "$ver_major" ]]; then
        ver_major=0
    fi

    if [[ "$ver_major" -ge 3 ]]; then
        # Modern rsync: clean single-line overall progress
        RSYNC_PROGRESS_FLAGS=(
            --info=progress2
            --info=stats0
            --info=name0
            --no-inc-recursive
        )
        log "Detected rsync ${ver_major}.x — using --info=progress2"
    else
        # Stock Apple rsync 2.6.9 or similar: fall back to --progress (per-file).
        # Less pretty but works. Users can `brew install rsync` to get the
        # modern experience.
        RSYNC_PROGRESS_FLAGS=( --progress )
        log "Detected legacy rsync ${ver_major}.x (likely stock Apple rsync)"
        log "Tip: 'brew install rsync' gives you cleaner progress output"
    fi
}

run_rsync() {
    # Wrapper: live progress on TTY, full output to log.
    # Args: all are passed to rsync.
    #
    # pipefail (set via `set -euo pipefail`) ensures rsync's nonzero exit
    # propagates through the `| tee` pipeline.
    #
    # Apple ships rsync 2.6.9 (GPL2-era) as /usr/bin/rsync, which predates
    # --info=progress2 (rsync 3.1.0+). We detect the version and adapt.
    # Users with Homebrew rsync (3.x) get the nicer single-line progress.
    if [[ "$IS_TTY" -eq 1 ]]; then
        rsync "${RSYNC_PROGRESS_FLAGS[@]}" "$@" 2>&1 | tee -a "$LOG_FILE" >&2
    else
        rsync "$@" >>"$LOG_FILE" 2>&1
    fi
}

sync_sources_to_hub() {
    local hub_mount
    hub_mount="$(mount_point_for "$HUB_LABEL")"
    local dest_root="${hub_mount}/${DATA_SUBDIR}"

    local dry_flag=()
    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_flag=("--dry-run")
    fi

    local excludes=()
    # shellcheck disable=SC2207
    excludes=( $(build_rsync_excludes) )

    local src
    for src in "${SOURCES[@]}"; do
        if [[ ! -e "$src" ]]; then
            print_warn "Source does not exist, skipping: ${src}"
            continue
        fi
        log "Syncing source → hub ${HUB_LABEL}: ${src}"
        # -a = -rlptgoD (archive), no -E: skip xattrs/resource forks.
        # Rationale: shasum hashes content only; preserving xattrs would make
        # the verification step incomplete.
        if ! run_rsync -a --delete --human-readable \
            ${dry_flag[@]+"${dry_flag[@]}"} \
            "${excludes[@]}" \
            "$src" "${dest_root}/"
        then
            die 6 "rsync failed for source: ${src}"
        fi
    done
    print_ok "All sources synced to hub ${HUB_LABEL}"
}

mirror_hub_to_secondaries() {
    # Star topology: each secondary is filled directly from the hub,
    # never through another secondary.
    local hub_mount
    hub_mount="$(mount_point_for "$HUB_LABEL")"
    local src="${hub_mount}/${DATA_SUBDIR}/"

    if [[ "$DRY_RUN" -eq 1 && ! -d "$src" ]]; then
        # Fresh hub: the dry-run sync above didn't create data/, so there is
        # nothing to mirror from yet (rsync would fail on a missing source).
        print_warn "[dry-run] hub ${HUB_LABEL} has no ${DATA_SUBDIR}/ yet; skipping mirror preview"
        return 0
    fi

    local dry_flag=()
    if [[ "$DRY_RUN" -eq 1 ]]; then
        dry_flag=("--dry-run")
    fi

    local excludes=()
    # shellcheck disable=SC2207
    excludes=( $(build_rsync_excludes) )

    local label
    for label in "${PRESENT_LABELS[@]}"; do
        if [[ "$label" == "$HUB_LABEL" ]]; then
            continue
        fi
        local dst
        dst="$(mount_point_for "$label")/${DATA_SUBDIR}/"
        log "Mirror hub ${HUB_LABEL} → ${label}"
        if ! run_rsync -a --delete --human-readable \
            ${dry_flag[@]+"${dry_flag[@]}"} \
            "${excludes[@]}" \
            "$src" "$dst"
        then
            die 6 "rsync hub → ${label} failed"
        fi
        print_ok "Mirrored ${label}"
    done
}

verify_all_sticks_identical() {
    # Generate hash manifest per present stick, compare all secondaries
    # against the hub. On any mismatch: log diff and abort (exit 3).
    local workdir="$WORKDIR"

    log "Hashing ${#PRESENT_LABELS[@]} stick(s) for verification"
    local label
    for label in "${PRESENT_LABELS[@]}"; do
        local mount
        mount="$(mount_point_for "$label")"
        generate_file_manifest "$mount" "${workdir}/${label}.hashes" "$label"
        print_ok "Hashed ${label}"
    done

    local hub_hashes="${workdir}/${HUB_LABEL}.hashes"
    local mismatches=()
    for label in "${PRESENT_LABELS[@]}"; do
        if [[ "$label" == "$HUB_LABEL" ]]; then
            continue
        fi
        local other_hashes="${workdir}/${label}.hashes"
        if ! diff -q "$hub_hashes" "$other_hashes" >/dev/null 2>&1; then
            mismatches+=("$label")
            print_fail "Hash mismatch on ${label} vs hub ${HUB_LABEL}"
            {
                printf '\n--- Hash diff %s vs %s (first 30 lines) ---\n' "$HUB_LABEL" "$label"
                # diff exits 1 when files differ; under pipefail that would
                # abort the script here (exit 1) instead of reaching exit 3.
                diff "$hub_hashes" "$other_hashes" | head -30 || true
            } >> "$LOG_FILE"
        fi
    done

    if [[ "${#mismatches[@]}" -gt 0 ]] && [[ "$DRY_RUN" -eq 1 ]]; then
        # Nothing was synced, so out-of-date sticks (e.g. the offsite stick
        # that just came home) are expected to differ. A real run fixes them.
        print_warn "[dry-run] $(join_by "${mismatches[@]}") differ(s) from hub ${HUB_LABEL}; a real run would update them"
        log "[dry-run] would update: $(join_by "${mismatches[@]}")"
        VERIFIED_HUB_HASHES="$hub_hashes"
        return 0
    fi

    if [[ "${#mismatches[@]}" -gt 0 ]]; then
        log "Mismatches: $(join_by "${mismatches[@]}")"
        # Exit 3 leaves volumes unlocked for investigation (see cleanup).
        exit 3
    fi

    print_ok "All ${#PRESENT_LABELS[@]} stick(s) verified identical to ${HUB_LABEL}"
    VERIFIED_HUB_HASHES="$hub_hashes"
}

# -----------------------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------------------

write_backup_manifest() {
    local mount="$1"
    local file_count="$2"
    local total_bytes="$3"
    local root_hash="$4"
    local canary_hash
    canary_hash="$(shasum -a 256 "${mount}/INTEGRITY_CANARY.txt" | awk '{print $1}')"

    local manifest="${mount}/BACKUP_MANIFEST.txt"
    local tmp
    tmp="$(mktemp -t backup-manifest)"

    {
        printf 'Backup run:        %s\n' "$TIMESTAMP"
        printf 'Host:              %s\n' "$(hostname)"
        printf 'Script:            %s\n' "$SCRIPT_PATH"
        printf 'Script hash:       sha256:%s\n' "$SCRIPT_HASH"
        printf 'Dry run:           %s\n' "$([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no)"
        printf 'Available-only:    %s\n' "$([[ "$AVAILABLE_ONLY" -eq 1 ]] && echo yes || echo no)"
        printf 'Hasher:            %s\n' "$(hasher_name)"
        printf 'Hub stick:         %s\n' "$HUB_LABEL"
        printf 'Synced sticks:     %s\n' "$(join_by "${PRESENT_LABELS[@]}")"
        if [[ "${#MISSING_LABELS[@]}" -gt 0 ]]; then
            printf 'Missing sticks:    %s\n' "$(join_by "${MISSING_LABELS[@]}")"
        fi
        printf '\nSources:\n'
        local s
        for s in "${SOURCES[@]}"; do
            printf '  - %s\n' "$s"
        done
        printf '\nFile count:        %s\n' "$file_count"
        printf 'Total bytes:       %s\n' "$total_bytes"
        printf 'Root hash:         sha256:%s\n' "$root_hash"
        printf 'Canary SHA:        sha256:%s\n' "$canary_hash"
        printf 'File hashes:       BACKUP_HASHES.txt (check: cd <volume> && %s -c BACKUP_HASHES.txt)\n' "$(hasher_name)"
        if [[ "$HISTORY_KEEP" -gt 0 ]]; then
            printf 'History:           %s/ (newest %s snapshots kept)\n' "$HISTORY_SUBDIR" "$HISTORY_KEEP"
        else
            printf 'History:           disabled\n'
        fi
    } > "$tmp"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] would write manifest and hashes to ${mount}"
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$manifest"

    # Per-file hashes, so a single stick can be checked on its own later
    # (--verify-only, or by hand with the command shown in the manifest).
    local hashes_tmp="${mount}/.BACKUP_HASHES.txt.tmp"
    cp "$VERIFIED_HUB_HASHES" "$hashes_tmp"
    mv "$hashes_tmp" "${mount}/BACKUP_HASHES.txt"
}

write_manifests_to_all_sticks() {
    local hub_mount
    hub_mount="$(mount_point_for "$HUB_LABEL")"
    local file_count total_bytes root_hash
    file_count="$(count_files_under_data "$hub_mount")"
    total_bytes="$(bytes_under_data "$hub_mount")"
    root_hash="$(root_hash_of_manifest "$VERIFIED_HUB_HASHES")"

    SUMMARY_FILE_COUNT="$file_count"
    SUMMARY_TOTAL_BYTES="$total_bytes"
    log "File count: $(format_number "$file_count"), total: $(format_bytes "$total_bytes"), root hash: ${root_hash}"

    local label
    for label in "${PRESENT_LABELS[@]}"; do
        write_backup_manifest "$(mount_point_for "$label")" \
            "$file_count" "$total_bytes" "$root_hash"
    done
    print_ok "Manifests written to all present sticks"
}

# -----------------------------------------------------------------------------
# Stats helpers
# -----------------------------------------------------------------------------

count_files_under_data() {
    local mount="$1"
    if [[ ! -d "${mount}/${DATA_SUBDIR}" ]]; then
        printf '0'
        return 0
    fi

    set_find_args -print0
    (
        cd "$mount"
        find "$DATA_SUBDIR" "${FIND_ARGS[@]}" | tr -cd '\0' | wc -c | tr -d ' '
    )
}

bytes_under_data() {
    local mount="$1"
    if [[ ! -d "${mount}/${DATA_SUBDIR}" ]]; then
        printf '0'
        return 0
    fi
    local kb
    kb="$(du -sk "${mount}/${DATA_SUBDIR}" 2>/dev/null | awk '{print $1}')"
    printf '%s' "$((kb * 1024))"
}

root_hash_of_manifest() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# -----------------------------------------------------------------------------
# Sources, deletion guard, history
# -----------------------------------------------------------------------------

source_basename() {
    local s="$1"
    printf '%s' "${s##*/}"
}

normalize_sources() {
    # "dir/" and "dir" must behave the same: without this, rsync would copy
    # the *contents* of "dir/" straight into data/.
    local i
    for (( i=0; i<${#SOURCES[@]}; i++ )); do
        while [[ "${SOURCES[$i]}" == */ && "${SOURCES[$i]}" != "/" ]]; do
            SOURCES[i]="${SOURCES[$i]%/}"
        done
    done
}

check_source_names() {
    # Every source lands in data/<basename>. Two sources with the same
    # basename would overwrite each other on every run.
    local i j bi bj
    for (( i=0; i<${#SOURCES[@]}; i++ )); do
        bi="$(source_basename "${SOURCES[$i]}")"
        if [[ -z "$bi" || "$bi" == "." || "$bi" == ".." ]]; then
            die 1 "Unsupported source path: '${SOURCES[$i]}' (needs a real file or directory name)"
        fi
        for (( j=i+1; j<${#SOURCES[@]}; j++ )); do
            bj="$(source_basename "${SOURCES[$j]}")"
            if [[ "$bi" == "$bj" ]]; then
                die 1 "Sources '${SOURCES[$i]}' and '${SOURCES[$j]}' would both be stored as ${DATA_SUBDIR}/${bi}. Rename one or back up a parent directory instead."
            fi
        done
    done
}

check_layout_config() {
    local name
    for name in "$DATA_SUBDIR" "$HISTORY_SUBDIR"; do
        if [[ -z "$name" || "$name" == *"/"* || "$name" == "." || "$name" == ".." ]]; then
            die 1 "DATA_SUBDIR and HISTORY_SUBDIR must be plain directory names (got '${name}')"
        fi
    done
    if [[ "$DATA_SUBDIR" == "$HISTORY_SUBDIR" ]]; then
        die 1 "DATA_SUBDIR and HISTORY_SUBDIR must differ"
    fi
    case "$HISTORY_KEEP$MAX_DELETE_PERCENT$MAX_DELETE_MIN" in
        *[!0-9]*) die 1 "HISTORY_KEEP, MAX_DELETE_PERCENT and MAX_DELETE_MIN must be whole numbers" ;;
    esac
}

is_configured_source_name() {
    local name="$1" src
    for src in "${SOURCES[@]}"; do
        if [[ "$(source_basename "$src")" == "$name" ]]; then
            return 0
        fi
    done
    return 1
}

list_data_files() {
    # Sorted relative paths ("data/...") of backed-up files on a volume.
    local mount="$1"
    [[ -d "${mount}/${DATA_SUBDIR}" ]] || return 0
    set_find_args -print
    ( cd "$mount" && find "$DATA_SUBDIR" "${FIND_ARGS[@]}" ) | LC_ALL=C sort
}

plan_expected_files() {
    # Write the sorted list of files that data/ will contain after this run:
    # every file of every existing source, plus whatever the hub already has
    # for sources that are configured but currently missing (those are kept).
    local out="$1" hub_list="$2"
    local src base parent
    : > "$out"
    set_find_args -print
    for src in "${SOURCES[@]}"; do
        base="$(source_basename "$src")"
        if [[ -d "$src" && ! -L "$src" ]]; then
            parent="$(dirname "$src")"
            ( cd "$parent" && find "$base" "${FIND_ARGS[@]}" ) \
                | awk -v p="${DATA_SUBDIR}/" '{ print p $0 }' >> "$out"
        elif [[ -f "$src" && ! -L "$src" ]]; then
            printf '%s/%s\n' "$DATA_SUBDIR" "$base" >> "$out"
        elif [[ ! -e "$src" ]]; then
            awk -v pre="${DATA_SUBDIR}/${base}/" -v exact="${DATA_SUBDIR}/${base}" \
                'index($0, pre) == 1 || $0 == exact' "$hub_list" >> "$out"
        fi
    done
    LC_ALL=C sort -o "$out" "$out"
}

deletion_guard_trips() {
    local n_del="$1" n_total="$2"
    [[ "$MAX_DELETE_PERCENT" -gt 0 ]] || return 1
    [[ "$n_del" -gt "$MAX_DELETE_MIN" ]] || return 1
    [[ $(( n_del * 100 )) -gt $(( MAX_DELETE_PERCENT * n_total )) ]]
}

check_deletion_guard() {
    # Runs before anything is written. Compares each present stick's data/
    # with what it will hold after this run and stops (exit 7) if too much
    # would disappear.
    local hub_list="${WORKDIR}/${HUB_LABEL}.before.files"
    local expected="${WORKDIR}/expected.files"
    list_data_files "$(mount_point_for "$HUB_LABEL")" > "$hub_list"
    plan_expected_files "$expected" "$hub_list"

    local label before dels n_del n_total total_del=0
    local tripped=()
    for label in "${PRESENT_LABELS[@]}"; do
        before="${WORKDIR}/${label}.before.files"
        if [[ "$label" != "$HUB_LABEL" ]]; then
            list_data_files "$(mount_point_for "$label")" > "$before"
        fi
        dels="${WORKDIR}/${label}.deletions"
        LC_ALL=C comm -23 "$before" "$expected" > "$dels"
        n_del="$(wc -l < "$dels" | tr -d ' ')"
        n_total="$(wc -l < "$before" | tr -d ' ')"
        total_del=$(( total_del + n_del ))
        if [[ "$n_del" -gt 0 ]]; then
            log "${label}: this run deletes ${n_del} of ${n_total} file(s)"
            {
                printf -- '--- Files to delete on %s (first 100) ---\n' "$label"
                head -100 "$dels"
            } >> "$LOG_FILE"
        fi
        if deletion_guard_trips "$n_del" "$n_total"; then
            tripped+=("$label")
            print_fail "${label}: this run would delete ${n_del} of ${n_total} files ($(( n_del * 100 / n_total ))%)"
        fi
    done

    if [[ "${#tripped[@]}" -eq 0 ]]; then
        print_ok "Deletion check passed (${total_del} file deletion(s) across all sticks)"
        return 0
    fi
    if [[ "$ALLOW_DELETIONS" -eq 1 ]]; then
        print_warn "Deletion guard overridden by --allow-deletions"
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_warn "[dry-run] a real run would stop here (deletion guard); see the log for the file list"
        return 0
    fi
    die 7 "Deletion guard: too many files would be deleted on $(join_by "${tripped[@]}") (limit: more than ${MAX_DELETE_MIN} files and ${MAX_DELETE_PERCENT}%). Nothing was changed. Check your sources; the file list is in the log. If this is intended, re-run with --allow-deletions."
}

remove_stale_sources() {
    # rsync --delete only works inside data/<source>, so a source that was
    # removed from SOURCES would otherwise stay on the sticks forever.
    # Entries for configured sources that are temporarily missing are kept.
    local data_root
    data_root="$(mount_point_for "$HUB_LABEL")/${DATA_SUBDIR}"
    [[ -d "$data_root" ]] || return 0

    local entry name excl skip
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name="${entry##*/}"
        skip=0
        for excl in "${RSYNC_EXCLUDES[@]}"; do
            # shellcheck disable=SC2053  # glob match against exclude pattern is intended
            if [[ "$name" == $excl ]]; then
                skip=1
            fi
        done
        [[ "$skip" -eq 0 ]] || continue
        is_configured_source_name "$name" && continue
        if [[ "$DRY_RUN" -eq 1 ]]; then
            print_warn "[dry-run] would remove ${DATA_SUBDIR}/${name} (no longer in SOURCES)"
        else
            print_warn "Removing ${DATA_SUBDIR}/${name} from hub ${HUB_LABEL} (no longer in SOURCES)"
            log_to_file "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] removing stale source ${entry}"
            rm -rf "$entry"
        fi
    done <<EOF
$(find "$data_root" -mindepth 1 -maxdepth 1 -print)
EOF
}

snapshot_sticks() {
    # Hard-link copy of each stick's current data/ into history/<timestamp>/
    # before anything is changed. Files updated later by rsync get a new inode
    # (rsync writes a temp file and renames it), so the snapshot keeps the old
    # content. Also saves each stick's previous BACKUP_HASHES.txt so an
    # unchanged run can drop its snapshot again.
    local label mount data dest
    for label in "${PRESENT_LABELS[@]}"; do
        mount="$(mount_point_for "$label")"
        if [[ -f "${mount}/BACKUP_HASHES.txt" ]]; then
            cp "${mount}/BACKUP_HASHES.txt" "${WORKDIR}/${label}.prev.hashes"
        fi
    done

    [[ "$HISTORY_KEEP" -gt 0 ]] || return 0

    local excludes=()
    # shellcheck disable=SC2207
    excludes=( $(build_rsync_excludes) )

    for label in "${PRESENT_LABELS[@]}"; do
        mount="$(mount_point_for "$label")"
        data="${mount}/${DATA_SUBDIR}"
        [[ -s "${WORKDIR}/${label}.before.files" ]] || continue
        dest="${mount}/${HISTORY_SUBDIR}/${TIMESTAMP}"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "[dry-run] would snapshot ${label}:${DATA_SUBDIR}/ to ${HISTORY_SUBDIR}/${TIMESTAMP}"
            continue
        fi
        mkdir -p "${mount}/${HISTORY_SUBDIR}"
        if ! rsync -a --link-dest="$data" "${excludes[@]}" "${data}/" "${dest}/" >>"$LOG_FILE" 2>&1; then
            die 6 "Snapshot of ${label} to ${dest} failed"
        fi
        SNAPSHOT_LABELS+=("$label")
    done
    if [[ "${#SNAPSHOT_LABELS[@]}" -gt 0 ]]; then
        print_ok "Snapshot ${HISTORY_SUBDIR}/${TIMESTAMP} taken on $(join_by "${SNAPSHOT_LABELS[@]}")"
    fi
}

finalize_history() {
    # After a verified run: drop snapshots of sticks that didn't change, then
    # keep only the newest HISTORY_KEEP snapshots per stick.
    [[ "$HISTORY_KEEP" -gt 0 && "$DRY_RUN" -eq 0 ]] || return 0

    local label mount prev
    for label in ${SNAPSHOT_LABELS[@]+"${SNAPSHOT_LABELS[@]}"}; do
        mount="$(mount_point_for "$label")"
        prev="${WORKDIR}/${label}.prev.hashes"
        if [[ -f "$prev" ]] && cmp -s "$prev" "$VERIFIED_HUB_HASHES"; then
            rm -rf "${mount:?}/${HISTORY_SUBDIR:?}/${TIMESTAMP:?}"
            log "${label}: nothing changed, snapshot not kept"
        fi
    done

    local hist snaps n remove snap
    for label in "${PRESENT_LABELS[@]}"; do
        hist="$(mount_point_for "$label")/${HISTORY_SUBDIR}"
        [[ -d "$hist" ]] || continue
        snaps="$(find "$hist" -mindepth 1 -maxdepth 1 -type d \
            -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z' -print | LC_ALL=C sort)"
        [[ -n "$snaps" ]] || continue
        n="$(printf '%s\n' "$snaps" | wc -l | tr -d ' ')"
        remove=$(( n - HISTORY_KEEP ))
        [[ "$remove" -gt 0 ]] || continue
        while IFS= read -r snap; do
            log "${label}: pruning old snapshot ${snap##*/}"
            rm -rf "$snap"
        done <<EOF
$(printf '%s\n' "$snaps" | head -n "$remove")
EOF
    done
}

# -----------------------------------------------------------------------------
# --verify-only: check each stick against its own stored hashes
# -----------------------------------------------------------------------------

manifest_field() {
    # manifest_field FILE "Hasher" -> value after "Hasher:"
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    awk -v k="${key}:" 'index($0, k) == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }' "$file"
}

use_hasher_named() {
    case "$1" in
        b3sum)
            require_tool b3sum
            HASHER_FORCED=( b3sum )
            ;;
        "shasum -a 256"|"")
            HASHER_FORCED=( shasum -a 256 )
            ;;
        *)
            die 1 "Unknown hasher '$1' in BACKUP_MANIFEST.txt"
            ;;
    esac
}

verify_stored_hashes() {
    local label mount stored now hasher run n_bad
    local bad=() checked=() runs=()
    for label in "${PRESENT_LABELS[@]}"; do
        mount="$(mount_point_for "$label")"
        stored="${mount}/BACKUP_HASHES.txt"
        if [[ ! -f "$stored" ]]; then
            print_warn "${label}: no BACKUP_HASHES.txt (last backed up by an older version of this script), skipped"
            continue
        fi
        hasher="$(manifest_field "${mount}/BACKUP_MANIFEST.txt" "Hasher")"
        run="$(manifest_field "${mount}/BACKUP_MANIFEST.txt" "Backup run")"
        use_hasher_named "$hasher"
        now="${WORKDIR}/${label}.now.hashes"
        generate_file_manifest "$mount" "$now" "$label"
        checked+=("$label")
        runs+=("${label}=${run:-unknown}")
        if cmp -s "$stored" "$now"; then
            print_ok "${label}: $(format_number "$(wc -l < "$now" | tr -d ' ')") files match the hashes stored by backup ${run:-?}"
            continue
        fi
        bad+=("$label")
        n_bad="$( { diff "$stored" "$now" || true; } \
            | awk '/^[<>] / { sub(/^[<>] [^ ]+ [ *]?/, ""); if (!seen[$0]++) n++ } END { print n + 0 }')"
        print_fail "${label}: ${n_bad} file(s) changed, missing or added since backup ${run:-?} (details in log)"
        {
            printf '\n--- %s: stored hashes vs now (first 50 lines) ---\n' "$label"
            { diff "$stored" "$now" || true; } | head -50
        } >> "$LOG_FILE"
    done

    if [[ "${#checked[@]}" -eq 0 ]]; then
        die 2 "No present stick has stored hashes yet. Run a normal backup first."
    fi
    log "Last backup per stick: $(join_by "${runs[@]}")"
    SUMMARY_FILE_COUNT="$(wc -l < "${WORKDIR}/${checked[0]}.now.hashes" | tr -d ' ')"
    SUMMARY_TOTAL_BYTES="$(bytes_under_data "$(mount_point_for "${checked[0]}")")"

    if [[ "${#bad[@]}" -gt 0 ]]; then
        log "Mismatches: $(join_by "${bad[@]}")"
        exit 3
    fi
}

# -----------------------------------------------------------------------------
# Reminders (state file + launchd agent)
# -----------------------------------------------------------------------------

REMINDER_AGENT_LABEL="com.backupstick.reminder"

state_file() {
    printf '%s/last-sync' "$STATE_DIR"
}

record_last_sync() {
    # Lines: "<LABEL> <epoch> <ISO time>". Updates present sticks, keeps the
    # rest. Best effort: a failure here must not fail a good backup.
    [[ "$DRY_RUN" -eq 0 ]] || return 0
    local f now iso tmp label
    f="$(state_file)"
    now="$(date +%s)"
    iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$STATE_DIR" 2>/dev/null || { print_warn "Cannot create ${STATE_DIR}; reminders not updated"; return 0; }
    tmp="${f}.tmp"
    {
        if [[ -f "$f" ]]; then
            awk -v present=" $(join_by "${PRESENT_LABELS[@]}") " \
                'index(present, " " $1 " ") == 0' "$f"
        fi
        for label in "${PRESENT_LABELS[@]}"; do
            printf '%s %s %s\n' "$label" "$now" "$iso"
        done
    } > "$tmp"
    if ! mv "$tmp" "$f"; then
        print_warn "Could not update ${f}"
    fi
}

notify() {
    # macOS notification + stdout (visible when run by hand or in launchd logs)
    local msg="$1"
    printf '%s\n' "$msg"
    if command -v osascript >/dev/null 2>&1; then
        local esc
        # Drop quotes and backslashes so the AppleScript string literal stays intact.
        esc="$(printf '%s' "$msg" | tr -d '\\"')"
        osascript -e "display notification \"${esc}\" with title \"USB Mirror Backup\"" >/dev/null 2>&1 || true
    fi
}

check_reminder() {
    local f now newest=0 label line epoch days msgs=()
    f="$(state_file)"
    now="$(date +%s)"
    if [[ ! -f "$f" ]]; then
        notify "No USB backup has been recorded yet. Run usb-mirror-backup.sh."
        return 0
    fi
    for label in "${LABELS[@]}"; do
        line="$(awk -v l="$label" '$1 == l { print $2; exit }' "$f")"
        if [[ -z "$line" ]]; then
            msgs+=("${label} has never been synced")
            continue
        fi
        epoch="$line"
        [[ "$epoch" -gt "$newest" ]] && newest="$epoch"
        days=$(( (now - epoch) / 86400 ))
        if [[ "$days" -ge "$REMIND_STICK_DAYS" ]]; then
            msgs+=("${label} last synced ${days} days ago (bring it home for a rotation run)")
        fi
    done
    if [[ "$newest" -gt 0 ]]; then
        days=$(( (now - newest) / 86400 ))
        if [[ "$days" -ge "$REMIND_AFTER_DAYS" ]]; then
            msgs=("Last USB backup was ${days} days ago" ${msgs[@]+"${msgs[@]}"})
        fi
    fi
    if [[ "${#msgs[@]}" -eq 0 ]]; then
        printf 'Backups are up to date.\n'
        return 0
    fi
    local joined="" m
    for m in "${msgs[@]}"; do
        joined+="${joined:+; }${m}"
    done
    notify "$joined"
}

reminder_plist_path() {
    printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$REMINDER_AGENT_LABEL"
}

xml_escape() {
    local v="$1"
    v="${v//&/&amp;}"; v="${v//</&lt;}"; v="${v//>/&gt;}"
    printf '%s' "$v"
}

install_reminder() {
    local plist script config_args=""
    plist="$(reminder_plist_path)"
    script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    if [[ -n "$CONFIG_FILE" ]]; then
        config_args="        <string>--config</string>
        <string>$(xml_escape "$CONFIG_FILE")</string>"
    fi
    mkdir -p "$(dirname "$plist")"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${REMINDER_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$script")</string>
        <string>--check-reminder</string>
${config_args}
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>10</integer>
        <key>Minute</key>
        <integer>7</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
        die 1 "launchctl bootstrap failed for ${plist}"
    fi
    print_ok "Reminder installed: daily check at 10:07 (${plist})"
    print_ok "It runs ${script}; re-run --install-reminder if you move the script."
}

uninstall_reminder() {
    local plist
    plist="$(reminder_plist_path)"
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    print_ok "Reminder removed"
}

# -----------------------------------------------------------------------------
# --init-stick: format, encrypt and install the canary on a new stick
# -----------------------------------------------------------------------------

disk_is_external_whole_disk() {
    # Refuse anything that isn't a whole, external/USB disk. This is the only
    # thing standing between a typo and erasing the Mac's internal disk.
    local info="$1"
    grep -Eq '^[[:space:]]*Whole:[[:space:]]+Yes' <<<"$info" || return 1
    grep -Eq '^[[:space:]]*(Device Location:[[:space:]]+External|Protocol:[[:space:]]+USB)' <<<"$info" || return 1
    ! grep -Eq '^[[:space:]]*Device Location:[[:space:]]+Internal' <<<"$info"
}

prompt_new_passphrase() {
    if [[ -n "${USB_BACKUP_PASSPHRASE:-}" ]]; then
        PASSPHRASE="$USB_BACKUP_PASSPHRASE"
        unset USB_BACKUP_PASSPHRASE
        return 0
    fi
    [[ -t 0 ]] || die 1 "No passphrase in environment and stdin is not a TTY. Cannot prompt."
    local pw1 pw2
    printf '  New backup-set passphrase (hidden): ' >&2
    IFS= read -rs pw1; printf '\n' >&2
    printf '  Repeat passphrase: ' >&2
    IFS= read -rs pw2; printf '\n' >&2
    [[ -n "$pw1" ]] || die 1 "Empty passphrase."
    [[ "$pw1" == "$pw2" ]] || die 1 "Passphrases do not match."
    PASSPHRASE="$pw1"
}

init_stick() {
    local label="$INIT_LABEL" disk="$INIT_DISK"
    local mount ref="" l

    print_phase 1 3 "Checks"
    [[ "$(uname -s)" == "Darwin" ]] || die 2 "This script is for macOS (Darwin). Current OS: $(uname -s)"
    require_tool diskutil
    require_tool shasum
    [[ -n "$disk" ]] || die 1 "--init-stick needs --disk DISK (see: diskutil list external)"
    case "$disk" in
        disk[0-9]*) ;;
        *) die 1 "--disk must look like disk4 (got '${disk}')" ;;
    esac
    case "$disk" in
        *s[0-9]*) die 1 "--disk must be a whole disk like disk4, not a partition (${disk})" ;;
    esac
    local known=0
    for l in "${LABELS[@]}"; do
        [[ "$l" == "$label" ]] && known=1
    done
    [[ "$known" -eq 1 ]] || die 1 "${label} is not in LABELS ($(join_by "${LABELS[@]}")). Add it to your config first."
    if apfs_volume_present "$label"; then
        die 1 "A volume named ${label} already exists. Refusing to create a second one."
    fi

    local info
    info="$(diskutil info "$disk" 2>/dev/null)" || die 2 "diskutil info ${disk} failed: no such disk?"
    if ! disk_is_external_whole_disk "$info"; then
        die 1 "${disk} is not a whole external/USB disk. Refusing to erase it."
    fi

    detect_present_sticks
    if [[ "$INIT_NEW_SET" -eq 0 ]]; then
        [[ "${#PRESENT_LABELS[@]}" -gt 0 ]] \
            || die 1 "Plug in one existing stick of the backup set (its canary is copied and it proves the passphrase), or use --new-set to start a new set."
        ref="${PRESENT_LABELS[0]}"
        print_ok "Reference stick: ${ref}"
    elif [[ "${#PRESENT_LABELS[@]}" -gt 0 ]]; then
        print_warn "--new-set: a new canary is created; $(join_by "${PRESENT_LABELS[@]}") will NOT be in the same set as ${label}"
    fi

    local media size
    media="$(awk -F': *' '/Device \/ Media Name:/ { print $2; exit }' <<<"$info")"
    size="$(awk -F': *' '/Disk Size:/ { print $2; exit }' <<<"$info")"
    printf '\n  %sAbout to ERASE %s%s (%s, %s).\n  Everything on it will be lost.\n' \
        "$C_BOLD$C_RED" "/dev/${disk}" "$C_RESET" "${media:-unknown media}" "${size:-unknown size}" >&2
    printf '  Type the new volume name (%s) to continue: ' "$label" >&2
    local answer=""
    IFS= read -r answer || true
    [[ "$answer" == "$label" ]] || die 1 "Confirmation did not match. Nothing was changed."

    if [[ -n "$ref" ]]; then
        prompt_passphrase
        unlock_volume "$ref"      # proves the passphrase before anything is erased
        verify_canary "$ref"
    else
        prompt_new_passphrase
    fi

    print_phase 2 3 "Formatting and encrypting ${label}"
    log "Erasing ${disk} as case-sensitive APFS volume ${label}"
    UNLOCKED_LABELS+=("$label")
    if ! diskutil eraseDisk APFSX "$label" GPT "$disk" >>"$LOG_FILE" 2>&1; then
        die 5 "diskutil eraseDisk failed (see log)"
    fi
    print_ok "Formatted /dev/${disk} as ${label}"
    mount="$(mount_point_for "$label")"
    local _attempt
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        [[ -d "$mount" ]] && break
        sleep 1
    done
    [[ -d "$mount" ]] || die 5 "${mount} did not appear after formatting"

    if ! printf '%s\n' "$PASSPHRASE" \
        | diskutil apfs encryptVolume "$label" -user disk -stdinpassphrase >>"$LOG_FILE" 2>&1; then
        die 5 "diskutil apfs encryptVolume failed (see log). ${label} exists but is NOT encrypted: erase it again."
    fi
    PASSPHRASE=""
    print_ok "Encryption enabled on ${label}"

    print_phase 3 3 "Canary and layout"
    if [[ -n "$ref" ]]; then
        local ref_mount
        ref_mount="$(mount_point_for "$ref")"
        cp "${ref_mount}/INTEGRITY_CANARY.txt" "${ref_mount}/.canary.sha256" "${mount}/"
        print_ok "Copied canary from ${ref}"
    else
        {
            printf 'usb-mirror-backup integrity canary\n'
            printf 'Created: %s on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)"
            printf 'Set ID: %s\n' "$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
        } > "${mount}/INTEGRITY_CANARY.txt"
        ( cd "$mount" && shasum -a 256 INTEGRITY_CANARY.txt > .canary.sha256 )
        print_ok "Created a new canary (new backup set)"
    fi
    verify_canary "$label"
    mkdir -p "${mount}/${DATA_SUBDIR}"
    touch "${mount}/.metadata_never_index"

    # Spotlight holding files open is the usual reason lockVolume fails.
    # .metadata_never_index is a hint only; mdutil needs root.
    local spotlight_off=0
    if [[ -t 0 ]] && command -v mdutil >/dev/null 2>&1; then
        log "Turning off Spotlight indexing (sudo may ask for your login password)"
        # shellcheck disable=SC2024  # the log is ours; only mdutil needs root
        if sudo mdutil -i off "$mount" >>"$LOG_FILE" 2>&1; then
            spotlight_off=1
            print_ok "Spotlight indexing off for ${label}"
        fi
    fi

    printf '\n' >&2
    print_ok "${label} is ready."
    if [[ "$spotlight_off" -eq 0 ]]; then
        print_warn "Turn off Spotlight for it: diskutil apfs unlockVolume ${label}; sudo mdutil -i off ${mount}; diskutil apfs lockVolume ${label}"
    fi
    print_warn "Next: run a backup with this stick plugged in to fill it."
    log_to_file "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] init of ${label} on ${disk} complete"
}

# -----------------------------------------------------------------------------
# Passphrase prompt
# -----------------------------------------------------------------------------

prompt_passphrase() {
    if [[ -n "${USB_BACKUP_PASSPHRASE:-}" ]]; then
        PASSPHRASE="$USB_BACKUP_PASSPHRASE"
        # Don't leak it to rsync, diskutil or PRE_BACKUP_HOOK.
        unset USB_BACKUP_PASSPHRASE
        log "Passphrase taken from environment."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        die 1 "No passphrase in environment and stdin is not a TTY. Cannot prompt."
    fi

    if [[ "$IS_TTY" -eq 1 ]]; then
        printf '  %s▸%s Passphrase for %s%s%s (hidden): ' \
            "$C_CYAN" "$C_RESET" "$C_BOLD" "$(join_by "${PRESENT_LABELS[@]}")" "$C_RESET" >&2
    else
        printf 'Passphrase for %s (hidden): ' "$(join_by "${PRESENT_LABELS[@]}")" >&2
    fi
    local pw
    IFS= read -rs pw
    printf '\n' >&2
    if [[ -z "$pw" ]]; then
        die 1 "Empty passphrase."
    fi
    PASSPHRASE="$pw"
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

on_err() {
    # ERR trap (with set -E): report the command that tripped set -e, so an
    # unexpected failure is not a silent "exit 1". Only the main shell
    # reports; subshells and command substitutions would duplicate it.
    local rc="$1" line="$2" cmd="$3"
    [[ "${BASH_SUBSHELL:-0}" -eq 0 ]] || return 0
    stop_spinner
    print_fail "Unexpected error (exit ${rc}) at line ${line}: ${cmd}"
    log_to_file "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: exit ${rc} at line ${line}: ${cmd}"
}

cleanup() {
    local rc=$?
    # INT/TERM handlers call exit, which fires EXIT again: run once only.
    if [[ "$CLEANUP_DONE" -eq 1 ]]; then
        return 0
    fi
    CLEANUP_DONE=1
    trap - ERR
    PASSPHRASE=""
    stop_spinner

    # On hash mismatch (exit 3) leave volumes unlocked for debugging
    if [[ "$rc" -eq 3 ]]; then
        log "Exit 3 (hash mismatch) — volumes remain UNLOCKED for investigation."
        if [[ "${#UNLOCKED_LABELS[@]}" -gt 0 ]]; then
            local lbl lock_cmds=""
            for lbl in "${UNLOCKED_LABELS[@]}"; do
                lock_cmds+="diskutil apfs lockVolume ${lbl}; "
            done
            log "Lock manually when done: ${lock_cmds}"
        fi
        if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
            rm -rf "$WORKDIR"
        fi
        print_summary "failure"
        exit "$rc"
    fi

    # Normal cleanup: lock everything we unlocked
    if [[ "${#UNLOCKED_LABELS[@]}" -gt 0 ]]; then
        local lbl
        for lbl in "${UNLOCKED_LABELS[@]}"; do
            lock_volume "$lbl"
        done
    fi

    if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
        rm -rf "$WORKDIR"
    fi

    if [[ "$MODE" == "init" ]]; then
        :   # init_stick prints its own result
    elif [[ "$rc" -eq 0 ]]; then
        print_summary "success"
    elif [[ -n "$HUB_LABEL" ]]; then
        print_summary "failure"
    fi

    printf '[%s] === end run (exit %d) ===\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$LOG_FILE"
    exit "$rc"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --available-only) AVAILABLE_ONLY=1 ;;
            --verify-only) VERIFY_ONLY=1; MODE="verify" ;;
            --init-stick)
                [[ $# -ge 2 ]] || { usage >&2; die 1 "--init-stick needs a label"; }
                MODE="init"; INIT_LABEL="$2"; shift
                ;;
            --disk)
                [[ $# -ge 2 ]] || { usage >&2; die 1 "--disk needs a disk identifier"; }
                INIT_DISK="${2#/dev/}"; shift
                ;;
            --new-set) INIT_NEW_SET=1 ;;
            --check-reminder) MODE="check-reminder" ;;
            --install-reminder) MODE="install-reminder" ;;
            --uninstall-reminder) MODE="uninstall-reminder" ;;
            --allow-deletions) ALLOW_DELETIONS=1 ;;
            --no-color) NO_COLOR=1 ;;
            --config)
                [[ $# -ge 2 ]] || { usage >&2; die 1 "--config needs a file path"; }
                CONFIG_FILE="$2"
                shift
                ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die 1 "Unknown option: $1" ;;
        esac
        shift
    done
}

load_config() {
    # Source the user's config file, if any, over the defaults above.
    local f="$CONFIG_FILE"
    if [[ -z "$f" ]]; then
        f="${USB_BACKUP_CONFIG:-}"
    fi
    if [[ -z "$f" ]]; then
        f="${HOME}/.config/usb-backup/config"
        [[ -f "$f" ]] || return 0
    fi
    if [[ ! -f "$f" ]]; then
        die 1 "Config file not found: $f"
    fi
    # It's executed as code: refuse files other users could have modified.
    if [[ -n "$(find "$f" \( -perm -020 -o -perm -002 \) -print 2>/dev/null)" ]]; then
        die 1 "Config file is group/world-writable, refusing to source it: $f (chmod 600 it)"
    fi
    if [[ -z "$(find "$f" -user "$(id -u)" -print 2>/dev/null)" ]]; then
        die 1 "Config file is not owned by you, refusing to source it: $f"
    fi
    # shellcheck source=/dev/null
    . "$f"
    CONFIG_FILE="$f"
}

init_logging() {
    TIMESTAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/backup-${TIMESTAMP}.log"
    : > "$LOG_FILE"

    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    SCRIPT_HASH="$(shasum -a 256 "$SCRIPT_PATH" 2>/dev/null | awk '{print $1}')"
    if [[ -z "$SCRIPT_HASH" ]]; then
        SCRIPT_HASH="unknown"
    fi
    START_EPOCH=$(date +%s)
}

detect_present_sticks() {
    PRESENT_LABELS=()
    MISSING_LABELS=()
    local label
    for label in "${LABELS[@]}"; do
        if apfs_volume_present "$label"; then
            PRESENT_LABELS+=("$label")
        else
            MISSING_LABELS+=("$label")
        fi
    done
}

preflight() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        die 2 "This script is for macOS (Darwin). Current OS: $(uname -s)"
    fi

    require_tool diskutil
    require_tool rsync
    require_tool shasum
    require_tool awk
    require_tool find
    require_tool sort
    require_tool xargs
    require_tool du
    print_ok "All required tools present"

    detect_rsync_capabilities

    if [[ "${#LABELS[@]}" -lt 2 ]]; then
        die 1 "LABELS must contain at least 2 sticks for mirror semantics."
    fi
    check_layout_config
    if [[ "$VERIFY_ONLY" -eq 0 ]]; then
        if [[ "${#SOURCES[@]}" -eq 0 ]]; then
            die 1 "SOURCES array is empty. Add source paths to your config file (see usb-backup.conf.example)."
        fi
        normalize_sources
        check_source_names
    fi

    detect_present_sticks

    if [[ "${#PRESENT_LABELS[@]}" -eq 0 ]]; then
        die 2 "None of the configured sticks are present: $(join_by "${LABELS[@]}")"
    fi

    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
        # Checking needs no redundancy: any present stick can be verified.
        if [[ "${#MISSING_LABELS[@]}" -gt 0 ]]; then
            print_warn "Not present (not checked): $(join_by "${MISSING_LABELS[@]}")"
        fi
    elif [[ "$AVAILABLE_ONLY" -eq 0 ]]; then
        if [[ "${#MISSING_LABELS[@]}" -gt 0 ]]; then
            die 2 "Not all configured sticks present. Missing: $(join_by "${MISSING_LABELS[@]}"). Use --available-only to work with $(join_by "${PRESENT_LABELS[@]}")."
        fi
    else
        if [[ "${#PRESENT_LABELS[@]}" -lt "$MIN_STICKS_AVAILABLE" ]]; then
            die 2 "--available-only requires at least ${MIN_STICKS_AVAILABLE} sticks, found: ${#PRESENT_LABELS[@]} ($(join_by "${PRESENT_LABELS[@]}"))."
        fi
        if [[ "${#MISSING_LABELS[@]}" -gt 0 ]]; then
            print_warn "Running with ${#PRESENT_LABELS[@]} sticks; missing: $(join_by "${MISSING_LABELS[@]}")"
        fi
    fi

    HUB_LABEL="${PRESENT_LABELS[0]}"
    log "Config: ${CONFIG_FILE:-built-in defaults}"
    log "Hub: ${HUB_LABEL}"
    log "Present: $(join_by "${PRESENT_LABELS[@]}")"
    if [[ "${#MISSING_LABELS[@]}" -gt 0 ]]; then
        log "Missing: $(join_by "${MISSING_LABELS[@]}")"
    fi
    log "Hasher: $(hasher_name)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_warn "DRY RUN — no data will be written"
    fi
}

run_pre_hook() {
    if [[ -z "$PRE_BACKUP_HOOK" ]]; then
        return 0
    fi
    log "Running pre-backup hook: ${PRE_BACKUP_HOOK}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] pre-backup hook skipped"
        return 0
    fi
    # shellcheck disable=SC2086
    if ! eval "$PRE_BACKUP_HOOK" >>"$LOG_FILE" 2>&1; then
        die 1 "Pre-backup hook failed."
    fi
}

main() {
    parse_args "$@"
    load_config
    init_tty

    # Modes that never touch the sticks: no log file, no cleanup trap.
    case "$MODE" in
        check-reminder)     check_reminder; return 0 ;;
        install-reminder)   install_reminder; return 0 ;;
        uninstall-reminder) uninstall_reminder; return 0 ;;
    esac

    init_logging
    trap cleanup EXIT
    # Convert signals into a normal exit with the conventional code, so
    # cleanup sees a non-zero status and never reports "Backup Complete".
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

    printf '[%s] === start USB mirror backup (run %s) ===\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TIMESTAMP" >> "$LOG_FILE"

    if [[ "$IS_TTY" -eq 1 ]]; then
        printf '\n%s%s  USB Mirror Backup%s  %s%s%s\n' \
            "$C_BOLD" "$C_CYAN" "$C_RESET" \
            "$C_DIM" "run $TIMESTAMP" "$C_RESET" >&2
    else
        printf '\n=== USB Mirror Backup — run %s ===\n' "$TIMESTAMP" >&2
    fi

    if [[ "$MODE" == "init" ]]; then
        init_stick
        return 0
    fi

    local phases=5
    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
        phases=4
    fi

    print_phase 1 "$phases" "Preflight & detection"
    preflight
    WORKDIR="$(mktemp -d -t usb-mirror-backup)"
    prompt_passphrase

    print_phase 2 "$phases" "Unlocking volumes"
    local label
    for label in "${PRESENT_LABELS[@]}"; do
        unlock_volume "$label"
    done
    PASSPHRASE=""

    print_phase 3 "$phases" "Integrity checks"
    for label in "${PRESENT_LABELS[@]}"; do
        verify_canary "$label"
    done
    verify_canaries_match

    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
        print_phase 4 "$phases" "Checking stored hashes"
        verify_stored_hashes
        return 0
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        for label in "${PRESENT_LABELS[@]}"; do
            mkdir -p "$(mount_point_for "$label")/${DATA_SUBDIR}"
        done
    fi

    run_pre_hook

    print_phase 4 "$phases" "Syncing data"
    check_deletion_guard
    snapshot_sticks
    remove_stale_sources
    sync_sources_to_hub
    mirror_hub_to_secondaries

    print_phase 5 "$phases" "Verification & manifests"
    verify_all_sticks_identical
    write_manifests_to_all_sticks
    finalize_history
    record_last_sync || print_warn "Could not record the last-sync time for reminders"

    # EXIT trap handles locking, summary, and final log line
}

main "$@"
