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
#        ./usb-mirror-backup.sh --no-color          # disable colored output
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
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION  —  user-tunable knobs
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

# Optional pre-backup hook (e.g. export Apple Notes via osascript).
# Leave empty for none. Example:
#   PRE_BACKUP_HOOK="osascript ${HOME}/bin/export-notes.scpt"
PRE_BACKUP_HOOK=""

# =============================================================================
# END CONFIGURATION  —  don't edit below unless you know what you're doing
# =============================================================================

# Runtime state
DRY_RUN=0
AVAILABLE_ONLY=0
NO_COLOR=0
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
RSYNC_PROGRESS_FLAGS=()
VERIFY_WORKDIR=""
VERIFIED_HUB_HASHES=""
START_EPOCH=0

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
    local status="$1"   # "success" or "failure"
    local hub_mount
    hub_mount="$(mount_point_for "$HUB_LABEL")"

    local file_count total_bytes duration_sec
    if [[ -n "$VERIFIED_HUB_HASHES" && -f "${hub_mount}/${DATA_SUBDIR}" ]] 2>/dev/null; then
        :
    fi
    file_count="$(count_files_under_data "$hub_mount" 2>/dev/null || echo 0)"
    total_bytes="$(bytes_under_data "$hub_mount" 2>/dev/null || echo 0)"
    duration_sec=$(( $(date +%s) - START_EPOCH ))

    local status_icon status_text status_color
    if [[ "$status" == "success" ]]; then
        status_icon="✓"; status_text="Backup Complete"; status_color="$C_GREEN"
    else
        status_icon="✗"; status_text="Backup Failed";   status_color="$C_RED"
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
        printf '  %-18s %s\n' "Synced"    "$(join_by "${PRESENT_LABELS[@]}")"
        if [[ "${#MISSING_LABELS[@]}" -gt 0 ]]; then
            printf '  %-18s %s\n' "Missing" "$(join_by "${MISSING_LABELS[@]}")"
        fi
        printf '  %-18s %s\n' "Files"     "$(format_number "$file_count")"
        printf '  %-18s %s\n' "Size"      "$(format_bytes "$total_bytes")"
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
  --dry-run          Simulate the full flow without rsync writes or
                     manifest updates. Volumes are still unlocked and
                     hashes are still computed.
  --available-only   Work with the sticks that are actually present
                     (minimum MIN_STICKS_AVAILABLE, default 3). Without
                     this flag, ALL configured sticks must be present.
                     Intended for offsite rotation workflows.
  --no-color         Disable colored output and animations.
  -h, --help         Show this help message.

Environment:
  USB_BACKUP_PASSPHRASE   If set: use instead of the interactive prompt.
                          Caution: a passphrase in env is visible in 'ps'
                          and shell history. Automation scenarios only.
EOF
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log() {
    # Plain to log file, dimmed timestamp to terminal.
    stop_spinner
    local ts msg
    ts="[$(date -u +%Y-%m-%dT%H:%M:%SZ)]"
    msg="$*"
    printf '%s %s\n' "$ts" "$msg" >> "$LOG_FILE"
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
    printf '[%s] FATAL: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
    exit "$code"
}

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        die 2 "Required tool not found: $tool"
    fi
}

mount_point_for() {
    printf '/Volumes/%s' "$1"
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
            UNLOCKED_LABELS+=("$label")
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

pick_hasher_cmd() {
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
        die 2 "Data directory missing: ${data_root}"
    fi

    local find_args=()
    local excl
    for excl in "${RSYNC_EXCLUDES[@]}"; do
        find_args+=( "-name" "$excl" "-prune" "-o" )
    done
    find_args+=( "-type" "f" "-print0" )

    # Pre-count for progress bar
    local total
    total=$(count_files_under_data "$root")

    if [[ "$total" -eq 0 ]]; then
        : > "$out"
        print_warn "${label}: 0 files to hash (empty data directory)"
        return 0
    fi

    # Pipe: find | sort | hash-batches → tee to output file → progress counter
    (
        cd "$root"
        find "$DATA_SUBDIR" ${find_args[@]+"${find_args[@]}"} \
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
    local workdir
    workdir="$(mktemp -d -t usb-mirror-verify)"
    VERIFY_WORKDIR="$workdir"

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
                diff "$hub_hashes" "$other_hashes" | head -30
            } >> "$LOG_FILE"
        fi
    done

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
    } > "$tmp"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] would write manifest to ${manifest}"
    else
        mv "$tmp" "$manifest"
    fi
    rm -f "$tmp"
}

write_manifests_to_all_sticks() {
    local hub_mount
    hub_mount="$(mount_point_for "$HUB_LABEL")"
    local file_count total_bytes root_hash
    file_count="$(count_files_under_data "$hub_mount")"
    total_bytes="$(bytes_under_data "$hub_mount")"
    root_hash="$(root_hash_of_manifest "$VERIFIED_HUB_HASHES")"

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
    local find_args=()
    local excl
    for excl in "${RSYNC_EXCLUDES[@]}"; do
        find_args+=( "-name" "$excl" "-prune" "-o" )
    done
    find_args+=( "-type" "f" "-print0" )

    if [[ ! -d "${mount}/${DATA_SUBDIR}" ]]; then
        printf '0'
        return 0
    fi

    (
        cd "$mount"
        find "$DATA_SUBDIR" ${find_args[@]+"${find_args[@]}"} | tr -cd '\0' | wc -c | tr -d ' '
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
# Passphrase prompt
# -----------------------------------------------------------------------------

prompt_passphrase() {
    if [[ -n "${USB_BACKUP_PASSPHRASE:-}" ]]; then
        PASSPHRASE="$USB_BACKUP_PASSPHRASE"
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

cleanup() {
    local rc=$?
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
        if [[ -n "${VERIFY_WORKDIR}" && -d "${VERIFY_WORKDIR}" ]]; then
            rm -rf "$VERIFY_WORKDIR"
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

    if [[ -n "${VERIFY_WORKDIR}" && -d "${VERIFY_WORKDIR}" ]]; then
        rm -rf "$VERIFY_WORKDIR"
    fi

    if [[ "$rc" -eq 0 ]]; then
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
            --no-color) NO_COLOR=1 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die 1 "Unknown option: $1" ;;
        esac
        shift
    done
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

    if [[ "${#SOURCES[@]}" -eq 0 ]]; then
        die 1 "SOURCES array is empty. Edit the config in $0 and add source paths."
    fi
    if [[ "${#LABELS[@]}" -lt 2 ]]; then
        die 1 "LABELS must contain at least 2 sticks for mirror semantics."
    fi

    detect_present_sticks

    if [[ "${#PRESENT_LABELS[@]}" -eq 0 ]]; then
        die 2 "None of the configured sticks are present: $(join_by "${LABELS[@]}")"
    fi

    if [[ "$AVAILABLE_ONLY" -eq 0 ]]; then
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
    init_tty
    init_logging
    trap cleanup EXIT INT TERM

    printf '[%s] === start USB mirror backup (run %s) ===\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TIMESTAMP" >> "$LOG_FILE"

    if [[ "$IS_TTY" -eq 1 ]]; then
        printf '\n%s%s  USB Mirror Backup%s  %s%s%s\n' \
            "$C_BOLD" "$C_CYAN" "$C_RESET" \
            "$C_DIM" "run $TIMESTAMP" "$C_RESET" >&2
    else
        printf '\n=== USB Mirror Backup — run %s ===\n' "$TIMESTAMP" >&2
    fi

    print_phase 1 5 "Preflight & detection"
    preflight
    prompt_passphrase

    print_phase 2 5 "Unlocking volumes"
    local label
    for label in "${PRESENT_LABELS[@]}"; do
        unlock_volume "$label"
    done
    PASSPHRASE=""

    print_phase 3 5 "Integrity checks"
    for label in "${PRESENT_LABELS[@]}"; do
        verify_canary "$label"
    done
    verify_canaries_match

    if [[ "$DRY_RUN" -eq 0 ]]; then
        for label in "${PRESENT_LABELS[@]}"; do
            mkdir -p "$(mount_point_for "$label")/${DATA_SUBDIR}"
        done
    fi

    run_pre_hook

    print_phase 4 5 "Syncing data"
    sync_sources_to_hub
    mirror_hub_to_secondaries

    print_phase 5 5 "Verification & manifests"
    verify_all_sticks_identical
    write_manifests_to_all_sticks

    # EXIT trap handles locking, summary, and final log line
}

main "$@"
