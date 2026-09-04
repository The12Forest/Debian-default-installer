#!/bin/bash
export HOME="${HOME:-/root}"

# =============================================================================
# Restic Multi-Repo Backup Script
# Full TUI configuration, no external editor needed
# Requires: restic >= 0.14, jq, curl, sshpass (for SFTP)
# =============================================================================

# Single place for the version number -- referenced everywhere (title, help,
# etc.) from here so it only needs to be maintained in one spot.
SCRIPT_VERSION="4.0"

SCRIPT_PATH="$(realpath "$0")"
CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.json"
OLD_CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.env"

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="restic-sftp-backup.service"
TIMER_NAME="restic-sftp-backup.timer"

# Background mode (tmux) -- keeps running like a daemon, survives disconnects
TMUX_SESSION="restic-backup"
LOG_DIR="/var/log/restic-backup"

FULL_RESOURCES=false
ECONOMY_MODE=false
EXTRA_RESOURCES=false
DRY_RUN_FLAG=""
NO_COMPRESSION=false

# Our own mutex so that two runs of this script (e.g. cron + manual) never
# overlap and end up creating what looks like a "stale" repo lock
SCRIPT_LOCKFILE="/run/restic-backup-manual.lock"
SCRIPT_LOCK_FD=200

DEFAULT_EXCLUDES=(
    "/proc" "/sys" "/dev" "/run" "/tmp"
    "/var/tmp" "/mnt" "/media" "/lost+found"
)

TUI_RESULT=""
REPO_URL=""
REPO_PW_FILE=""
REPO_OPTS=()
MAIN_URL=""
MAIN_PW_FILE=""
MAIN_OPTS=()
MAIN_TYPE=""
MAIN_USER_VAR=""
MAIN_HOST_VAR=""

# Globals for the shutdown trap -- track the currently active repo
CURRENT_REPO_URL=""
CURRENT_REPO_PW_FILE=""
CURRENT_REPO_OPTS=()

# ==========================================
# Color constants (ANSI)
# ==========================================
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_BLUE="\033[0;34m"
C_CYAN="\033[0;36m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RESET="\033[0m"

# Colored-output helpers
col_ok()   { printf "${C_GREEN}%s${C_RESET}" "$*"; }
col_err()  { printf "${C_RED}%s${C_RESET}" "$*"; }
col_warn() { printf "${C_YELLOW}%s${C_RESET}" "$*"; }
col_info() { printf "${C_CYAN}%s${C_RESET}" "$*"; }
col_bold() { printf "${C_BOLD}%s${C_RESET}" "$*"; }
col_dim()  { printf "${C_DIM}%s${C_RESET}"  "$*"; }

# ==========================================
# Helper functions
# ==========================================

read_password_with_asterisks() {
    local prompt="$1"
    local pass="" char
    echo -n "$prompt" >&2
    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" ]]; then echo >&2; break; fi
        if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
            if [[ -n "$pass" ]]; then pass="${pass%?}"; echo -n -e "\b \b" >&2; fi
        else
            pass+="$char"; echo -n "*" >&2
        fi
    done
    printf '%s' "$pass"
}

require_jq() {
    if ! command -v jq &>/dev/null; then
        echo ">> 'jq' is required but not installed."
        if [ "$EUID" -ne 0 ]; then
            echo ">> Please run as root, or install jq manually."
            exit 1
        fi
        echo ">> Installing jq..."
        if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y jq curl
        elif command -v dnf     &>/dev/null; then dnf install -y jq curl
        elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm jq curl
        elif command -v zypper  &>/dev/null; then zypper install -y jq curl
        else echo ">> Unknown package manager. Please install jq manually."; exit 1; fi
    fi
}

require_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        echo ">> 'sshpass' is required for SFTP but not installed."
        if [ "$EUID" -ne 0 ]; then
            echo ">> Please run as root, or install sshpass manually."; return 1
        fi
        echo ">> Installing sshpass..."
        if   command -v apt-get &>/dev/null; then apt-get install -y sshpass
        elif command -v dnf     &>/dev/null; then dnf install -y sshpass
        elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm sshpass
        elif command -v zypper  &>/dev/null; then zypper install -y sshpass
        else echo ">> Please install sshpass manually."; return 1; fi
    fi
}

require_tmux() {
    if ! command -v tmux &>/dev/null; then
        echo ">> 'tmux' is required for background mode but not installed."
        if [ "$EUID" -ne 0 ]; then
            echo ">> Please run as root, or install tmux manually."; return 1
        fi
        echo ">> Installing tmux..."
        if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y tmux
        elif command -v dnf     &>/dev/null; then dnf install -y tmux
        elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm tmux
        elif command -v zypper  &>/dev/null; then zypper install -y tmux
        elif command -v apk     &>/dev/null; then apk add tmux
        else echo ">> Unknown package manager. Please install tmux manually."; return 1; fi
    fi
}

# ---------------------------------------------------------------------------
# tui_input "Label" "current_value" "Description" [secret=false]
# Result is stored in $TUI_RESULT. Enter = keep the current value.
# ---------------------------------------------------------------------------
tui_input() {
    local label="$1"
    local current="${2:-}"
    local desc="${3:-}"
    local secret="${4:-false}"

    [ -n "$desc" ] && echo "   >> $desc"

    local display_current=""
    if [ -n "$current" ] && [ "$current" != "null" ]; then
        if [ "$secret" = "true" ]; then
            display_current=" [current: ****]"
        else
            display_current=" [current: $current]"
        fi
    fi

    if [ "$secret" = "true" ]; then
        local _pw
        _pw=$(read_password_with_asterisks "   $label${display_current}: ")
        TUI_RESULT="$_pw"
    else
        read -rp "   $label${display_current}: " TUI_RESULT
    fi

    # Keep the current value if Enter was pressed and a value already exists
    if [ -z "$TUI_RESULT" ] && [ -n "$current" ] && [ "$current" != "null" ]; then
        TUI_RESULT="$current"
    fi
}

# Yes/no prompt. Returns 0 (true) for yes, 1 (false) for no.
tui_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local hint="[y/N]"
    [[ "$default" =~ ^[Yy]$ ]] && hint="[Y/n]"
    local answer
    read -rp "   $prompt $hint: " answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Safe config-writing functions (atomic write via mktemp)
# ---------------------------------------------------------------------------
config_set() {
    local jq_filter="$1"
    local tmp_file; tmp_file=$(mktemp)
    if jq "$jq_filter" "$CONFIG_FILE" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        rm -f "$tmp_file"
        echo ">> ERROR: writing config failed (filter: $jq_filter)"
        return 1
    fi
}

config_set_arg() {
    # Uses --arg so special characters in the value are handled safely
    local jq_filter="$1"
    local value="$2"
    local tmp_file; tmp_file=$(mktemp)
    if jq --arg val "$value" "$jq_filter" "$CONFIG_FILE" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        rm -f "$tmp_file"
        echo ">> ERROR: writing config failed (filter: $jq_filter)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# jq_bool FILTER FILE
# Safely reads a JSON boolean: returns "true" or "false".
# IMPORTANT: jq quirk -- `false // "default"` evaluates to "default" because
# false is falsy in jq. This function works around that with an explicit
# comparison instead.
# ---------------------------------------------------------------------------
jq_bool() {
    local filter="$1" file="$2"
    local raw; raw=$(jq -r "$filter" "$file" 2>/dev/null)
    [ "$raw" = "false" ] && echo "false" || echo "true"
}

# Consistent hostname resolution: config file first, then system hostname
get_hostname() {
    local h; h=$(jq -r '.host // ""' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$h" ] || [ "$h" = "null" ]; then
        h=$(hostname 2>/dev/null || echo "unknown")
    fi
    printf '%s' "$h"
}

# Builds --exclude=... args from config (.excludes array), falls back to
# DEFAULT_EXCLUDES. Result is written into the RESTIC_EXCLUDE_ARGS array
# (caller must declare it).
build_exclude_args() {
    RESTIC_EXCLUDE_ARGS=()
    local count; count=$(jq '.excludes | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
        while IFS= read -r path; do
            RESTIC_EXCLUDE_ARGS+=("--exclude=$path")
        done < <(jq -r '.excludes[]' "$CONFIG_FILE" 2>/dev/null)
    else
        for path in "${DEFAULT_EXCLUDES[@]}"; do
            RESTIC_EXCLUDE_ARGS+=("--exclude=$path")
        done
    fi
}

# ==========================================
# Migration: .env -> .json
# ==========================================
migrate_env_to_json() {
    if [ -f "$OLD_CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
        echo ">> Found old .env configuration. Migrating to JSON..."
        # shellcheck source=/dev/null
        source "$OLD_CONFIG_FILE"
        local fallback_hostname; fallback_hostname=$(hostname)
        jq -n \
          --arg host "${RESTIC_HOST:-$fallback_hostname}" \
          --arg u    "${SFTP_USER:-}" \
          --arg h    "${SFTP_HOST:-}" \
          --arg p    "${SFTP_PATH:-}" \
          --arg pwd  "${RESTIC_PASSWORD:-}" \
          --arg ssh  "${SSHPASS:-}" \
          '{
            host: $host,
            compression: "auto",
            retry_lock: "5m",
            unlock_retry_lock: "10m",
            stale_unlock_hours: 2,
            cache_dir: "~/.cache/restic",
            retention: { keep_daily: 31, keep_weekly: 4, keep_monthly: 6, keep_yearly: 0, keep_last: 0, prune: true },
            lock_state: { last_seen: "", last_unlock_attempt: "" },
            notifications: { ntfy: { enabled: false } },
            main: {
              type: "sftp", user: $u, host: $h, path: $p,
              password: $pwd, env: { SSHPASS: $ssh }
            },
            copies: []
          }' > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        mv "$OLD_CONFIG_FILE" "${OLD_CONFIG_FILE}.bak"
        echo ">> Migration complete. Old file backed up as .env.bak."
        sleep 2
    fi
}

# notify_error <exit_code> <action_label> [error_log] [category]
# Categories: backup, network, lock, cache, shutdown, unlock
notify_error() {
    local exit_code="$1" action_label="$2" error_log="${3:-}" category="${4:-backup}"
    local ntfy_enabled
    ntfy_enabled=$(jq_bool '.notifications.ntfy.enabled' "$CONFIG_FILE")
    [ "$ntfy_enabled" != "true" ] && return 0

    local ntfy_url ntfy_topic ntfy_user ntfy_pass
    ntfy_url=$(jq -r   '.notifications.ntfy.url      // "https://ntfy.sh"' "$CONFIG_FILE")
    ntfy_topic=$(jq -r '.notifications.ntfy.topic    // ""'                "$CONFIG_FILE")
    ntfy_user=$(jq -r  '.notifications.ntfy.username // ""'                "$CONFIG_FILE")
    ntfy_pass=$(jq -r  '.notifications.ntfy.password // ""'                "$CONFIG_FILE")

    local auth_args=()
    [ -n "$ntfy_user" ] && [ -n "$ntfy_pass" ] && auth_args+=(-u "${ntfy_user}:${ntfy_pass}")

    local host; host=$(get_hostname)

    # Title and tags by category
    local title tags
    case "$category" in
        network)
            title="Backup network error: ${host}"
            tags="warning"
            ;;
        lock)
            title="Backup repo locked: ${host}"
            tags="warning"
            ;;
        cache)
            title="Backup cache error: ${host}"
            tags="warning"
            ;;
        shutdown)
            title="Backup interrupted: ${host}"
            tags="warning"
            ;;
        unlock)
            title="Backup auto-unlock: ${host}"
            tags="information"
            ;;
        *)
            title="Backup error: ${host}"
            tags="warning"
            ;;
    esac

    local msg="Restic error (${exit_code}) during: ${action_label}"
    if [ -n "$error_log" ] && [ -f "$error_log" ]; then
        msg+=$'\n\nLast log lines:\n'"$(tail -n 10 "$error_log")"
    fi

    curl -s -o /dev/null "${auth_args[@]}" \
        -H "Title: ${title}" -H "Tags: ${tags}" \
        -d "$msg" "${ntfy_url}/${ntfy_topic}" || true
}

# Check if restic supports --retry-lock (added in restic 0.16.0)
restic_supports_retry_lock() {
    local ver; ver=$(restic version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$ver" ]; then return 1; fi
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [ "$major" -gt 0 ] || { [ "$major" -eq 0 ] && [ "$minor" -ge 16 ]; }
}

# Returns the short restic version (e.g. "0.17.0") or "not installed"
get_restic_version() {
    if command -v restic &>/dev/null; then
        restic version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    else
        echo "not installed"
    fi
}

# Convert a restic duration string to seconds (e.g. "5m" -> 300, "1h" -> 3600)
parse_duration() {
    local d="$1"
    local num unit
    num=$(echo "$d" | grep -oE '[0-9]+' | head -1)
    unit=$(echo "$d" | grep -oE '[smhd]' | head -1)
    case "$unit" in
        s) echo "$num" ;;
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        *) echo 300 ;;  # default 5 minutes
    esac
}

# Loads --retry-lock and --cache-dir into RESTIC_EXTRA_OPTS (for backup /
# forget / copy) and a separate, deliberately SHORT --retry-lock into
# RESTIC_UNLOCK_OPTS (for unlock / lock-check calls), so those never hang
# for hours waiting on the very lock they're supposed to inspect or remove.
# Call once before running restic commands.
load_restic_extra_opts() {
    RESTIC_EXTRA_OPTS=()
    RESTIC_UNLOCK_OPTS=()
    if restic_supports_retry_lock; then
        local retry_lock; retry_lock=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE" 2>/dev/null || echo "5m")
        RESTIC_EXTRA_OPTS+=(--retry-lock "$retry_lock")

        local unlock_retry_lock; unlock_retry_lock=$(jq -r '.unlock_retry_lock // "10m"' "$CONFIG_FILE" 2>/dev/null || echo "10m")
        RESTIC_UNLOCK_OPTS+=(--retry-lock "$unlock_retry_lock")
    fi

    local cache_dir; cache_dir=$(jq -r '.cache_dir // "~/.cache/restic"' "$CONFIG_FILE" 2>/dev/null || echo "~/.cache/restic")
    if [ -n "$cache_dir" ] && [ "$cache_dir" != "~/.cache/restic" ]; then
        cache_dir="${cache_dir/#\~/$HOME}"
        RESTIC_EXTRA_OPTS+=(--cache-dir "$cache_dir")
        RESTIC_UNLOCK_OPTS+=(--cache-dir "$cache_dir")
    fi
}

RESTIC_EXTRA_OPTS=()
RESTIC_UNLOCK_OPTS=()

# ==========================================
# Read retention rules from config
# Result goes into RETENTION_ARGS (array, declared by caller)
# ==========================================
build_retention_args() {
    RETENTION_ARGS=()
    local kd kw km ky kl
    kd=$(jq -r '.retention.keep_daily   // 31' "$CONFIG_FILE" 2>/dev/null)
    kw=$(jq -r '.retention.keep_weekly  // 4'  "$CONFIG_FILE" 2>/dev/null)
    km=$(jq -r '.retention.keep_monthly // 6'  "$CONFIG_FILE" 2>/dev/null)
    ky=$(jq -r '.retention.keep_yearly  // 0'  "$CONFIG_FILE" 2>/dev/null)
    kl=$(jq -r '.retention.keep_last    // 0'  "$CONFIG_FILE" 2>/dev/null)
    [[ "$kd" =~ ^[0-9]+$ ]] && [ "$kd" -gt 0 ] && RETENTION_ARGS+=(--keep-daily "$kd")
    [[ "$kw" =~ ^[0-9]+$ ]] && [ "$kw" -gt 0 ] && RETENTION_ARGS+=(--keep-weekly "$kw")
    [[ "$km" =~ ^[0-9]+$ ]] && [ "$km" -gt 0 ] && RETENTION_ARGS+=(--keep-monthly "$km")
    [[ "$ky" =~ ^[0-9]+$ ]] && [ "$ky" -gt 0 ] && RETENTION_ARGS+=(--keep-yearly "$ky")
    [[ "$kl" =~ ^[0-9]+$ ]] && [ "$kl" -gt 0 ] && RETENTION_ARGS+=(--keep-last "$kl")
}

# true if prune should run automatically after forget (default: on)
retention_prune_enabled() {
    [ "$(jq_bool '.retention.prune' "$CONFIG_FILE" 2>/dev/null)" = "true" ]
}

# ==========================================
# Script mutex: prevents overlapping runs
# (e.g. cron + manual), which would otherwise look
# like a "stale" repo lock
# ==========================================
acquire_script_lock() {
    eval "exec ${SCRIPT_LOCK_FD}>\"$SCRIPT_LOCKFILE\"" 2>/dev/null || return 0
    if ! flock -n "$SCRIPT_LOCK_FD"; then
        echo ">> ERROR: a backup run of this script is already in progress."
        echo ">> (Lockfile: $SCRIPT_LOCKFILE)"
        echo ">> This is probably the cause of the 'repo locked' error --"
        echo ">> not an old/orphaned lock, but a backup that's genuinely running."
        echo ">> Check e.g.: tmux has-session -t $TMUX_SESSION ; ps aux | grep restic"
        exit 1
    fi
    echo $$ >&"$SCRIPT_LOCK_FD"
}

release_script_lock() {
    flock -u "$SCRIPT_LOCK_FD" 2>/dev/null || true
    eval "exec ${SCRIPT_LOCK_FD}>&-" 2>/dev/null || true
}

# ==========================================
# Force-unlock: removes ALL locks (--remove-all), including ones restic
# itself can't recognize as "stale" (e.g. because they were set from a
# different host/container). Only use manually when you're sure no backup
# is actually running!
# ==========================================
force_unlock_repo() {
    echo "=========================================="
    echo "   FORCE UNLOCK (--remove-all)"
    echo "=========================================="
    echo "  WARNING: removes ALL locks on the repo, even ones restic doesn't"
    echo "  recognize as 'stale' itself. Only run this when you are SURE"
    echo "  no backup is currently running!"
    echo "------------------------------------------"
    if [ -f "$SCRIPT_LOCKFILE" ] && ! flock -n -x "$SCRIPT_LOCKFILE" -c true 2>/dev/null; then
        echo "  WARNING: another run of this script currently holds the mutex."
    fi
    read -rp "  Really remove ALL locks? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "  Cancelled."
        sleep 1; return
    fi

    if load_repo_context "main"; then
        if restic "${RESTIC_UNLOCK_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock --remove-all; then
            echo ">> All locks removed."
        else
            echo ">> ERROR: force unlock failed."
        fi
        cleanup_repo_context
    else
        echo ">> ERROR: main repo not configured."
    fi
    ! $INTERNAL_WORKER && [[ -t 0 ]] && read -rp "Press Enter to continue..."
}

# ==========================================
# Restic execution with error handling
# ==========================================
run_restic() {
    local label="$1"; shift
    local tmp_log; tmp_log=$(mktemp)
    if ! "$@" 2> >(tee "$tmp_log" >&2); then
        local rc=$?
        local stderr; stderr=$(cat "$tmp_log" 2>/dev/null)

        # Detect error category from stderr patterns
        local category="backup"
        if echo "$stderr" | grep -qiE "no route to host|connection refused|connection timed out|network is unreachable|temporary failure in name resolution|i/o timeout|connection reset by peer|broken pipe|name or service not known|could not resolve host"; then
            category="network"
            echo ">> NETWORK ERROR detected. Backup will exit cleanly -- the timer will try again next time."
        elif echo "$stderr" | grep -qiE "cache|cache directory|unable to create cache|cache dir"; then
            category="cache"
            echo ">> CACHE ERROR detected."
        elif echo "$stderr" | grep -qiE "already locked|repository is already locked|unable to create lock|lock exists"; then
            category="lock"
            echo ">> REPO LOCKED -- a lock already exists."
            record_lock_detected
        fi

        notify_error "$rc" "$label" "$tmp_log" "$category"
        rm -f "$tmp_log"
        return $rc
    fi
    rm -f "$tmp_log"
    return 0
}

# ==========================================
# Shutdown trap: unlock repos on shutdown
# ==========================================
cleanup_on_shutdown() {
    echo ""
    echo "=========================================="
    echo ">> SYSTEM SHUTDOWN detected! Unlocking repos..."
    echo "=========================================="
    # Deliberately use the SHORT (unlock-specific) retry-lock time -- otherwise
    # unlocking on shutdown/abort could itself hang for hours.
    local retry_lock; retry_lock=$(jq -r '.unlock_retry_lock // "10m"' "$CONFIG_FILE" 2>/dev/null || echo "10m")
    local RETRY_ARR=()
    restic_supports_retry_lock && RETRY_ARR=(--retry-lock "$retry_lock")

    if [ -n "$CURRENT_REPO_URL" ] && [ -n "$CURRENT_REPO_PW_FILE" ]; then
        echo ">> Unlocking active repo..."
        restic "${RETRY_ARR[@]}" "${CURRENT_REPO_OPTS[@]}" -r "$CURRENT_REPO_URL" \
            --password-file "$CURRENT_REPO_PW_FILE" unlock 2>/dev/null || true
    fi
    if [ -n "$MAIN_URL" ] && [ -n "$MAIN_PW_FILE" ] && [ "$MAIN_URL" != "$CURRENT_REPO_URL" ]; then
        echo ">> Unlocking main repo..."
        restic "${RETRY_ARR[@]}" "${MAIN_OPTS[@]}" -r "$MAIN_URL" \
            --password-file "$MAIN_PW_FILE" unlock 2>/dev/null || true
    fi

    notify_error 0 "Backup interrupted by system shutdown" "" "shutdown"
    echo ">> Repos unlocked. Exiting."
    exit 0
}

# ==========================================
# Auto-unlock: unlock the repo if it's been locked too long
# ==========================================
auto_unlock_if_stale() {
    local last_seen last_unlock
    last_seen=$(jq -r '.lock_state.last_seen // ""' "$CONFIG_FILE" 2>/dev/null)
    last_unlock=$(jq -r '.lock_state.last_unlock_attempt // ""' "$CONFIG_FILE" 2>/dev/null)

    # No previous lock detected -> nothing to do
    [ -z "$last_seen" ] || [ "$last_seen" = "null" ] && return 0

    # Already unlocked after the last detected lock -> nothing to do
    if [ -n "$last_unlock" ] && [ "$last_unlock" != "null" ]; then
        local unlock_ts seen_ts
        unlock_ts=$(date -d "$last_unlock" +%s 2>/dev/null || echo 0)
        seen_ts=$(date -d "$last_seen" +%s 2>/dev/null || echo 0)
        [ "$unlock_ts" -gt "$seen_ts" ] && return 0
    fi

    # Threshold is configurable (default 2h instead of 24h -- for REST-server
    # repos, "restic unlock" without --remove-all often doesn't recognize a
    # lock as stale, e.g. when it wasn't created by the current host; a 24h
    # wait would then unnecessarily block daily backups for a long time)
    local stale_hours; stale_hours=$(jq -r '.stale_unlock_hours // 2' "$CONFIG_FILE" 2>/dev/null)
    [[ "$stale_hours" =~ ^[0-9]+$ ]] || stale_hours=2

    local now_ts seen_ts
    now_ts=$(date +%s)
    seen_ts=$(date -d "$last_seen" +%s 2>/dev/null || echo 0)
    local age_hours=$(( (now_ts - seen_ts) / 3600 ))
    [ "$age_hours" -lt "$stale_hours" ] && return 0

    echo ">> Repo has been locked for ${age_hours}h (>${stale_hours}h). Attempting auto-unlock..."

    # First try a normal (safe) unlock, then --remove-all as a hard fallback:
    # after $stale_hours hours, a genuinely still-running backup is virtually
    # ruled out (the script mutex prevents overlaps anyway), so --remove-all
    # is acceptable here.
    if load_repo_context "main"; then
        if restic "${RESTIC_UNLOCK_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock 2>/dev/null; then
            echo ">> Main repo unlocked successfully (auto-unlock after ${age_hours}h)."
        elif restic "${RESTIC_UNLOCK_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock --remove-all 2>/dev/null; then
            echo ">> Main repo unlocked with --remove-all (normal unlock didn't recognize the lock as stale)."
        else
            echo ">> WARNING: auto-unlock of the main repo failed."
        fi
        cleanup_repo_context
    fi

    # Update timestamp
    local now_iso; now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    config_set_arg '.lock_state.last_unlock_attempt = $val' "$now_iso"

    local host; host=$(get_hostname)
    notify_error 0 "Repo was locked for ${age_hours}h -- auto-unlock performed" "" "unlock"
}

# Periodic unlock retry loop: keep trying to unlock until the repo is
# accessible or the timeout is reached. Deliberately uses the short
# unlock_retry_lock time (default 10m) instead of the potentially very long
# main retry_lock time (e.g. 20h) -- otherwise the lock CHECK itself would hang.
pre_backup_unlock_retry() {
    local repo_url="$1" repo_pw="$2"
    shift 2
    local repo_opts=("$@")
    local timeout_str; timeout_str=$(jq -r '.unlock_retry_lock // "10m"' "$CONFIG_FILE" 2>/dev/null || echo "10m")
    local timeout_secs; timeout_secs=$(parse_duration "$timeout_str")
    local waited=0 interval=30

    while [ "$waited" -lt "$timeout_secs" ]; do
        if restic "${RESTIC_UNLOCK_OPTS[@]}" "${repo_opts[@]}" \
            -r "$repo_url" --password-file "$repo_pw" \
            snapshots --last &>/dev/null; then
            return 0
        fi
        restic "${RESTIC_UNLOCK_OPTS[@]}" "${repo_opts[@]}" \
            -r "$repo_url" --password-file "$repo_pw" unlock &>/dev/null || true
        sleep "$interval"
        waited=$((waited + interval))
    done
    return 1
}

# Track lock detection in the JSON config for stale-lock detection
record_lock_detected() {
    local now_iso; now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    config_set_arg '.lock_state.last_seen = $val' "$now_iso" 2>/dev/null || true
}

# ==========================================
# Load repo context
# Sets: REPO_URL, REPO_PW_FILE, REPO_OPTS
# SFTP connections: economy=2 / standard=8 / full-resources=16
# ==========================================
load_repo_context() {
    local repo_idx="$1"
    local jq_query
    [ "$repo_idx" = "main" ] && jq_query=".main" || jq_query=".copies[$repo_idx]"

    local r_type
    r_type=$(jq -r "${jq_query}.type // \"\"" "$CONFIG_FILE")
    [ -z "$r_type" ] || [ "$r_type" = "null" ] && return 1

    # Password file
    local r_pwd; r_pwd=$(jq -r "${jq_query}.password // \"\"" "$CONFIG_FILE")
    REPO_PW_FILE=$(mktemp)
    printf '%s' "$r_pwd" > "$REPO_PW_FILE"
    chmod 600 "$REPO_PW_FILE"

    # SFTP connection count depending on mode
    local conn=8
    [ "${FULL_RESOURCES:-false}" = "true" ] && conn=16
    [ "${ECONOMY_MODE:-false}"   = "true" ] && conn=2

    REPO_OPTS=()
    REPO_URL=""

    case "$r_type" in
        sftp)
            require_sshpass || return 1
            local r_user r_host r_path r_ssh
            r_user=$(jq -r "${jq_query}.user        // \"\"" "$CONFIG_FILE")
            r_host=$(jq -r "${jq_query}.host        // \"\"" "$CONFIG_FILE")
            r_path=$(jq -r "${jq_query}.path        // \"\"" "$CONFIG_FILE")
            r_ssh=$(jq -r  "${jq_query}.env.SSHPASS // \"\"" "$CONFIG_FILE")
            REPO_URL="sftp:${r_user}@${r_host}:${r_path}"
            export SSHPASS="$r_ssh"
            # Directly as an array - no eval needed, no parsing pitfalls
            REPO_OPTS=(
                -o "sftp.connections=${conn}"
                -o "sftp.command=sshpass -e ssh -oBatchMode=no -o StrictHostKeyChecking=no ${r_user}@${r_host} -s sftp"
            )
            ;;
        s3)
            local r_host r_bucket r_path r_ak r_sk
            r_host=$(jq -r   "${jq_query}.host                     // \"s3.amazonaws.com\"" "$CONFIG_FILE")
            r_bucket=$(jq -r "${jq_query}.bucket                   // \"\""                 "$CONFIG_FILE")
            r_path=$(jq -r   "${jq_query}.path                     // \"\""                 "$CONFIG_FILE")
            r_ak=$(jq -r     "${jq_query}.env.AWS_ACCESS_KEY_ID    // \"\""                 "$CONFIG_FILE")
            r_sk=$(jq -r     "${jq_query}.env.AWS_SECRET_ACCESS_KEY// \"\""                 "$CONFIG_FILE")
            REPO_URL="s3:${r_host}/${r_bucket}${r_path}"
            export AWS_ACCESS_KEY_ID="$r_ak"
            export AWS_SECRET_ACCESS_KEY="$r_sk"
            ;;
        b2)
            local r_bucket r_path r_kid r_k
            r_bucket=$(jq -r "${jq_query}.bucket             // \"\"" "$CONFIG_FILE")
            r_path=$(jq -r   "${jq_query}.path               // \"\"" "$CONFIG_FILE")
            r_kid=$(jq -r    "${jq_query}.env.B2_ACCOUNT_ID  // \"\"" "$CONFIG_FILE")
            r_k=$(jq -r      "${jq_query}.env.B2_ACCOUNT_KEY // \"\"" "$CONFIG_FILE")
            REPO_URL="b2:${r_bucket}:${r_path}"
            export B2_ACCOUNT_ID="$r_kid"
            export B2_ACCOUNT_KEY="$r_k"
            ;;
        rest)
            local r_url r_ruser r_bpass
            r_url=$(jq -r   "${jq_query}.url            // \"\"" "$CONFIG_FILE")
            r_ruser=$(jq -r "${jq_query}.username       // \"\"" "$CONFIG_FILE")
            r_bpass=$(jq -r "${jq_query}.basic_password // \"\"" "$CONFIG_FILE")
            if [ -n "$r_ruser" ] && [ -n "$r_bpass" ]; then
                REPO_URL=$(printf '%s' "$r_url" | sed -E "s|^(https?://)|rest:\1${r_ruser}:${r_bpass}@|")
            else
                REPO_URL="rest:${r_url}"
            fi
            ;;
        local)
            local r_path; r_path=$(jq -r "${jq_query}.path // \"\"" "$CONFIG_FILE")
            REPO_URL="$r_path"
            ;;
        *)
            REPO_URL=$(jq -r "${jq_query}.url // \"\"" "$CONFIG_FILE")
            ;;
    esac

    return 0
}

cleanup_repo_context() {
    rm -f "$REPO_PW_FILE" 2>/dev/null || true
    REPO_PW_FILE=""
    REPO_OPTS=()
    REPO_URL=""
}

# ==========================================
# Backup logic
# ==========================================
run_backup() {
    local mode_label="$1"
    echo "=========================================="
    echo ">> Starting backup: $mode_label"
    echo "=========================================="

    require_jq
    migrate_env_to_json

    if [ ! -f "$CONFIG_FILE" ]; then
        echo ">> ERROR: no configuration found."
        echo ">> Please run setup: sudo $0 -s"
        exit 1
    fi

    # Script mutex first: prevents two simultaneous runs (cron + manual,
    # double-start, etc.) from creating a genuine lock conflict that would
    # then falsely look like a "stale" repo lock
    acquire_script_lock
    trap 'release_script_lock' EXIT

    # Set a trap: unlock repos on shutdown/SIGTERM (in addition to the EXIT trap)
    trap 'cleanup_on_shutdown; release_script_lock' SIGTERM SIGINT SIGHUP

    # Load extra opts (--retry-lock, --cache-dir)
    load_restic_extra_opts

    # Auto-unlock if the repo has been locked too long
    auto_unlock_if_stale

    # Silent pre-unlock: immediately clear stale locks from crashed backups
    if load_repo_context "main"; then
        restic "${RESTIC_UNLOCK_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock &>/dev/null || true
        # Periodic retry: wait if the repo is locked by a genuinely running backup
        pre_backup_unlock_retry "$REPO_URL" "$REPO_PW_FILE" "${REPO_OPTS[@]}" || true
        cleanup_repo_context
    fi

    # Compression setting
    local conf_compression; conf_compression=$(jq -r '.compression // "auto"' "$CONFIG_FILE")
    local RESTIC_SPEED_OPTS=()
    if $NO_COMPRESSION; then
        RESTIC_SPEED_OPTS=("--compression" "off")
        echo ">> Compression: DISABLED (override)"
    else
        RESTIC_SPEED_OPTS=("--compression" "$conf_compression")
        echo ">> Compression: $conf_compression"
    fi
    $EXTRA_RESOURCES && RESTIC_SPEED_OPTS+=("--pack-size" "128")

    # CPU/IO priority
    local NICE_PREFIX=""
    if $FULL_RESOURCES; then
        export GOMAXPROCS; GOMAXPROCS=$(nproc)
        NICE_PREFIX="nice -n -15"
        echo ">> Mode: FULL THROTTLE | CPUs: ${GOMAXPROCS} | Priority: -15 | SFTP connections: 16"
    elif $ECONOMY_MODE; then
        export GOMAXPROCS=1
        NICE_PREFIX="nice -n 19 ionice -c 3"
        echo ">> Mode: ECONOMY | CPUs: 1 | Priority 19, idle I/O | SFTP connections: 2"
    else
        NICE_PREFIX="nice -n 10"
        echo ">> Mode: STANDARD | SFTP connections: 8"
    fi

    local DRY_RUN_ARGS=()
    [ -n "$DRY_RUN_FLAG" ] && DRY_RUN_ARGS=("$DRY_RUN_FLAG")

    local r_host; r_host=$(jq -r '.host // ""' "$CONFIG_FILE")
    local RESTIC_HOST_OPT=()
    [ -n "$r_host" ] && [ "$r_host" != "null" ] && RESTIC_HOST_OPT=("--host" "$r_host")

    local RETENTION_ARGS=()
    build_retention_args
    local PRUNE_ARGS=()
    retention_prune_enabled && PRUNE_ARGS=(--prune)

    # ------------------------------------------------------------------
    # STEP 1: Backup to the main repository
    # ------------------------------------------------------------------
    echo ""
    echo ">> [1/2] Backing up to the main repository..."
    if ! load_repo_context "main"; then
        echo ">> ERROR: main repo not configured or type missing."
        exit 1
    fi

    # Save main repo info for later copy operations
    MAIN_URL="$REPO_URL"
    MAIN_TYPE=$(jq -r ".main.type // \"\"" "$CONFIG_FILE")
    MAIN_USER_VAR=$(jq -r ".main.user // \"\"" "$CONFIG_FILE")
    MAIN_HOST_VAR=$(jq -r ".main.host // \"\"" "$CONFIG_FILE")
    MAIN_PW_FILE=$(mktemp)
    cp "$REPO_PW_FILE" "$MAIN_PW_FILE"
    chmod 600 "$MAIN_PW_FILE"
    MAIN_OPTS=("${REPO_OPTS[@]}")

    local RESTIC_EXCLUDE_ARGS=()
    build_exclude_args

    # Track the active repo for the shutdown trap
    CURRENT_REPO_URL="$REPO_URL"
    CURRENT_REPO_PW_FILE="$REPO_PW_FILE"
    CURRENT_REPO_OPTS=("${REPO_OPTS[@]}")

    run_restic "backup main" $NICE_PREFIX restic \
        "${RESTIC_EXTRA_OPTS[@]}" \
        "${REPO_OPTS[@]}" \
        -r "$REPO_URL" \
        --password-file "$REPO_PW_FILE" \
        backup / \
        "${RESTIC_HOST_OPT[@]}" \
        "${RESTIC_EXCLUDE_ARGS[@]}" \
        "${RESTIC_SPEED_OPTS[@]}" \
        "${DRY_RUN_ARGS[@]}"

    run_restic "forget main" $NICE_PREFIX restic \
        "${RESTIC_EXTRA_OPTS[@]}" \
        "${REPO_OPTS[@]}" \
        -r "$REPO_URL" \
        --password-file "$REPO_PW_FILE" \
        forget \
        "${RESTIC_HOST_OPT[@]}" \
        "${RETENTION_ARGS[@]}" "${PRUNE_ARGS[@]}" \
        "${DRY_RUN_ARGS[@]}"

    cleanup_repo_context

    # ------------------------------------------------------------------
    # STEP 2: Copy snapshots to copy repositories
    # ------------------------------------------------------------------
    local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)

    if [ "$copy_count" -gt 0 ]; then
        echo ""
        echo ">> [2/2] Copying to $copy_count copy repo(s)..."

        for i in $(seq 0 $((copy_count - 1))); do
            local c_enabled c_name
            c_enabled=$(jq_bool ".copies[$i].enabled"       "$CONFIG_FILE")
            c_name=$(jq -r    ".copies[$i].name    // \"Copy #$((i+1))\"" "$CONFIG_FILE")

            if [ "$c_enabled" != "true" ]; then
                echo ">> -> Skipping '$c_name' (disabled)"
                continue
            fi

            echo ">> -> Syncing: $c_name"

            if ! load_repo_context "$i"; then
                echo ">> -> ERROR loading '$c_name', skipping."
                continue
            fi

            # Initialize the copy repo (ignore errors = already exists)
            restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" \
                --password-file "$REPO_PW_FILE" init &>/dev/null || true

            # ------------------------------------------------------------------
            # SFTP-to-SFTP issue:
            # SSHPASS env can only hold one value.
            # Fix: the copy repo uses sshpass -f <tmpfile> (no env conflict),
            #      the main repo (from-repo) keeps using sshpass -e (SSHPASS env).
            # Requires restic >= 0.14 for --from-option
            # ------------------------------------------------------------------
            local copy_type; copy_type=$(jq -r ".copies[$i].type // \"\"" "$CONFIG_FILE")
            local COPY_REPO_OPTS=("${REPO_OPTS[@]}")
            local COPY_FROM_OPTS=()
            local copy_ssh_tmp=""

            if [ "$MAIN_TYPE" = "sftp" ]; then
                local main_ssh_pw; main_ssh_pw=$(jq -r ".main.env.SSHPASS // \"\"" "$CONFIG_FILE")

                # from-option for main repo SFTP (restic >= 0.14)
                local conn_main=8
                $FULL_RESOURCES && conn_main=16
                $ECONOMY_MODE   && conn_main=2
                COPY_FROM_OPTS=(
                    --from-option "sftp.connections=${conn_main}"
                    --from-option "sftp.command=sshpass -e ssh -oBatchMode=no -o StrictHostKeyChecking=no ${MAIN_USER_VAR}@${MAIN_HOST_VAR} -s sftp"
                )
                export SSHPASS="$main_ssh_pw"

                if [ "$copy_type" = "sftp" ]; then
                    # Copy repo SFTP: uses -f <tmpfile> to avoid conflicting with SSHPASS env
                    local copy_ssh_pw c_user c_host conn_c
                    copy_ssh_pw=$(jq -r ".copies[$i].env.SSHPASS // \"\"" "$CONFIG_FILE")
                    c_user=$(jq -r      ".copies[$i].user        // \"\"" "$CONFIG_FILE")
                    c_host=$(jq -r      ".copies[$i].host        // \"\"" "$CONFIG_FILE")
                    conn_c=8
                    $FULL_RESOURCES && conn_c=16
                    $ECONOMY_MODE   && conn_c=2
                    copy_ssh_tmp=$(mktemp)
                    printf '%s' "$copy_ssh_pw" > "$copy_ssh_tmp"
                    chmod 600 "$copy_ssh_tmp"
                    COPY_REPO_OPTS=(
                        -o "sftp.connections=${conn_c}"
                        -o "sftp.command=sshpass -f ${copy_ssh_tmp} ssh -oBatchMode=no -o StrictHostKeyChecking=no ${c_user}@${c_host} -s sftp"
                    )
                fi
            fi

            # Track the copy repo for the shutdown trap
            CURRENT_REPO_URL="$REPO_URL"
            CURRENT_REPO_PW_FILE="$REPO_PW_FILE"
            CURRENT_REPO_OPTS=("${COPY_REPO_OPTS[@]}")

            run_restic "copy -> $c_name" $NICE_PREFIX restic \
                "${RESTIC_EXTRA_OPTS[@]}" \
                "${COPY_REPO_OPTS[@]}" \
                -r "$REPO_URL" \
                --password-file "$REPO_PW_FILE" \
                "${COPY_FROM_OPTS[@]}" \
                copy --from-repo "$MAIN_URL" --from-password-file "$MAIN_PW_FILE"

            run_restic "forget $c_name" $NICE_PREFIX restic \
                "${REPO_OPTS[@]}" \
                -r "$REPO_URL" \
                --password-file "$REPO_PW_FILE" \
                forget \
                "${RESTIC_HOST_OPT[@]}" \
                "${RETENTION_ARGS[@]}" "${PRUNE_ARGS[@]}" \
                "${DRY_RUN_ARGS[@]}"

            rm -f "$copy_ssh_tmp" 2>/dev/null || true
            cleanup_repo_context
        done
    else
        echo ""
        echo ">> [2/2] No copy repositories defined. Skipping."
    fi

    rm -f "$MAIN_PW_FILE" 2>/dev/null || true

    # Remove the shutdown trap -- backup finished normally
    trap - SIGTERM SIGINT SIGHUP
    CURRENT_REPO_URL=""
    CURRENT_REPO_PW_FILE=""
    CURRENT_REPO_OPTS=()

    echo ""
    echo ">> Backup finished."
    # IMPORTANT: when running as the background worker (INTERNAL_WORKER),
    # skip the "press enter" prompt: a tmux pane always provides a pty even
    # when nobody is attached, so [[ -t 0 ]] would still be true and this
    # would wait forever for a keypress that nobody can give.
    ! $INTERNAL_WORKER && [[ -t 0 ]] && read -rp "Press Enter to continue..."
}

# ==========================================
# Action on all repositories
# ==========================================
run_action_all_repos() {
    # action: snapshots | snapshots_all | init | unlock
    local action="$1"
    require_jq
    migrate_env_to_json

    load_restic_extra_opts

    # Silent pre-unlock for snapshot/init actions (not for the explicit unlock action)
    if [ "$action" != "unlock" ]; then
        if load_repo_context "main"; then
            restic "${RESTIC_UNLOCK_OPTS[@]}" "${REPO_OPTS[@]}" \
                -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock &>/dev/null || true
            cleanup_repo_context
        fi
    fi

    local r_host; r_host=$(jq -r '.host // ""' "$CONFIG_FILE")
    # snapshots_all = show all hosts (no --host filter)
    # snapshots     = only this host (--host filter active)
    local RESTIC_HOST_OPT=()
    if [ "$action" = "snapshots" ]; then
        [ -n "$r_host" ] && [ "$r_host" != "null" ] && RESTIC_HOST_OPT=("--host" "$r_host")
        echo "=========================================="
        echo ">> Snapshots for host: ${r_host:-<no filter>}"
        echo "=========================================="
    elif [ "$action" = "snapshots_all" ]; then
        echo "=========================================="
        echo ">> Snapshots for ALL hosts (no host filter)"
        echo "=========================================="
    else
        echo "=========================================="
        echo ">> Action '$action' on all repositories"
        echo "=========================================="
    fi

    if load_repo_context "main"; then
        echo ">> [MAIN REPO]"
        case "$action" in
            snapshots|snapshots_all)
                restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" \
                    snapshots "${RESTIC_HOST_OPT[@]}" ;;
            init)
                restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" \
                    init 2>/dev/null || echo "  (repo already exists)" ;;
            unlock)
                restic "${RESTIC_UNLOCK_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock ;;
        esac
        cleanup_repo_context
    else
        echo ">> WARNING: main repo not configured."
    fi

    local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    for i in $(seq 0 $((copy_count - 1))); do
        local c_enabled c_name
        c_enabled=$(jq_bool ".copies[$i].enabled" "$CONFIG_FILE")
        c_name=$(jq -r ".copies[$i].name // \"Copy #$((i+1))\"" "$CONFIG_FILE")
        [ "$c_enabled" != "true" ] && continue
        if load_repo_context "$i"; then
            echo ">> [$c_name]"
            case "$action" in
                snapshots|snapshots_all)
                    restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" \
                        snapshots "${RESTIC_HOST_OPT[@]}" ;;
                init)
                    restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" \
                        init 2>/dev/null || echo "  (repo already exists)" ;;
                unlock)
                    restic "${RESTIC_UNLOCK_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock ;;
            esac
            cleanup_repo_context
        fi
    done

    echo ">> Done."
    ! $INTERNAL_WORKER && [[ -t 0 ]] && read -rp "Press Enter to continue..."
}

# ==========================================
# Manual repo cleanup (forget + prune)
# Uses the same retention rules as the automatic run after every backup,
# but can be run by hand at any time, with a preview (--dry-run).
# ==========================================
_cleanup_repo_loop() {
    local mode="$1" dry="$2"   # mode: forget | prune

    local DRY=()
    [ "$dry" = "true" ] && DRY=(--dry-run)

    local RETENTION_ARGS=()
    build_retention_args
    local PRUNE_ARGS=()
    { [ "$mode" = "forget" ] && [ "$dry" != "true" ] && retention_prune_enabled; } && PRUNE_ARGS=(--prune)

    local r_host; r_host=$(jq -r '.host // ""' "$CONFIG_FILE")
    local RESTIC_HOST_OPT=()
    [ -n "$r_host" ] && [ "$r_host" != "null" ] && RESTIC_HOST_OPT=("--host" "$r_host")

    _cleanup_one_repo() {
        local label="$1"
        echo ">> [$label]"
        if [ "$mode" = "forget" ]; then
            restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" \
                forget "${RESTIC_HOST_OPT[@]}" "${RETENTION_ARGS[@]}" "${PRUNE_ARGS[@]}" "${DRY[@]}"
        else
            restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" prune
        fi
    }

    if load_repo_context "main"; then
        _cleanup_one_repo "MAIN REPO"
        cleanup_repo_context
    else
        echo ">> WARNING: main repo not configured."
    fi

    local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    for i in $(seq 0 $((copy_count - 1))); do
        local c_enabled c_name
        c_enabled=$(jq_bool ".copies[$i].enabled" "$CONFIG_FILE")
        c_name=$(jq -r ".copies[$i].name // \"Copy #$((i+1))\"" "$CONFIG_FILE")
        [ "$c_enabled" != "true" ] && continue
        if load_repo_context "$i"; then
            _cleanup_one_repo "$c_name"
            cleanup_repo_context
        fi
    done
}

run_manual_cleanup() {
    require_jq
    migrate_env_to_json
    load_restic_extra_opts

    local RETENTION_ARGS=()
    build_retention_args
    local retention_str="${RETENTION_ARGS[*]:-<no limits set>}"
    local prune_str="off"; retention_prune_enabled && prune_str="on"

    clear
    echo "=========================================="
    echo "   REPO CLEANUP (forget + prune)"
    echo "=========================================="
    echo "  Retention: $retention_str"
    echo "  Prune after forget: $prune_str"
    echo "  (Adjustable under: Edit configuration -> Global settings)"
    echo "------------------------------------------"
    echo "  1) Preview (--dry-run, nothing gets deleted)"
    echo "  2) Actually run it now (main + active copies)"
    echo "  3) Prune only (reclaim space, no snapshots removed)"
    echo "  4) Clean up local cache (restic cache --cleanup)"
    echo "  0) Back"
    echo "=========================================="
    read -rp "  Choice: " cchoice

    case "$cchoice" in
        1) echo ""; _cleanup_repo_loop "forget" "true" ;;
        2) if tui_confirm "Really delete snapshots per the retention rules?" "n"; then
               echo ""; _cleanup_repo_loop "forget" "false"
           fi ;;
        3) if tui_confirm "Run prune on all active repos?" "y"; then
               echo ""; _cleanup_repo_loop "prune" "false"
           fi ;;
        4) echo ""; restic "${RESTIC_EXTRA_OPTS[@]}" cache --cleanup ;;
        0) return ;;
    esac

    echo ""
    echo ">> Done."
    [[ -t 0 ]] && read -rp "Press Enter to continue..."
}

# ==========================================
# Ask for repo fields (new & edit)
# Result: JSON in $TUI_RESULT
# ==========================================
wizard_repo_input() {
    local default_type="${1:-sftp}"
    local jq_path="${2:-}"

    local cur_type="" cur_user="" cur_host="" cur_bucket="" cur_path=""
    local cur_url="" cur_user2="" cur_bpass="" cur_pwd=""
    local cur_ak="" cur_sk="" cur_kid="" cur_k="" cur_ssh=""

    if [ -n "$jq_path" ] && [ -f "$CONFIG_FILE" ]; then
        cur_type=$(jq -r   "${jq_path}.type                         // \"\"" "$CONFIG_FILE")
        cur_user=$(jq -r   "${jq_path}.user                         // \"\"" "$CONFIG_FILE")
        cur_host=$(jq -r   "${jq_path}.host                         // \"\"" "$CONFIG_FILE")
        cur_bucket=$(jq -r "${jq_path}.bucket                       // \"\"" "$CONFIG_FILE")
        cur_path=$(jq -r   "${jq_path}.path                         // \"\"" "$CONFIG_FILE")
        cur_url=$(jq -r    "${jq_path}.url                          // \"\"" "$CONFIG_FILE")
        cur_user2=$(jq -r  "${jq_path}.username                     // \"\"" "$CONFIG_FILE")
        cur_bpass=$(jq -r  "${jq_path}.basic_password               // \"\"" "$CONFIG_FILE")
        cur_ak=$(jq -r     "${jq_path}.env.AWS_ACCESS_KEY_ID        // \"\"" "$CONFIG_FILE")
        cur_sk=$(jq -r     "${jq_path}.env.AWS_SECRET_ACCESS_KEY    // \"\"" "$CONFIG_FILE")
        cur_kid=$(jq -r    "${jq_path}.env.B2_ACCOUNT_ID            // \"\"" "$CONFIG_FILE")
        cur_k=$(jq -r      "${jq_path}.env.B2_ACCOUNT_KEY           // \"\"" "$CONFIG_FILE")
        cur_ssh=$(jq -r    "${jq_path}.env.SSHPASS                  // \"\"" "$CONFIG_FILE")
        cur_pwd=$(jq -r    "${jq_path}.password                     // \"\"" "$CONFIG_FILE")
    fi

    echo ""
    echo "   Available storage types:"
    echo "   sftp  = SFTP via SSH/sshpass (password-based)"
    echo "   s3    = Amazon S3 or compatible (MinIO, Wasabi, Hetzner, etc.)"
    echo "   b2    = Backblaze B2 object storage"
    echo "   rest  = Restic REST server (self-hosted)"
    echo "   local = Local path / mounted drive (USB, NFS, etc.)"
    tui_input "Storage type" "${cur_type:-$default_type}" ""
    local r_type="$TUI_RESULT"
    local json="{}"

    case "$r_type" in
        sftp)
            echo ""; echo "   --- SFTP ---"
            tui_input "User"       "$cur_user"  "SSH/SFTP login username on the backup server"
            local r_user="$TUI_RESULT"
            tui_input "Host"           "$cur_host"  "Hostname or IP address of the backup server"
            local r_host_val="$TUI_RESULT"
            tui_input "Path"           "$cur_path"  "Path on the server, e.g. /volume1/restic/my-server"
            local r_path="$TUI_RESULT"
            tui_input "Restic password" "$cur_pwd"  "Encrypts your data. Back this up separately, this is critical!" "true"
            local r_pwd="$TUI_RESULT"
            tui_input "SSH password"   "$cur_ssh"   "SSH login password for sshpass (NOT the restic password)" "true"
            local r_ssh="$TUI_RESULT"
            json=$(jq -n \
              --arg t "sftp" --arg u "$r_user" --arg h "$r_host_val" \
              --arg p "$r_path" --arg pwd "$r_pwd" --arg ssh "$r_ssh" \
              '{type:$t, user:$u, host:$h, path:$p, password:$pwd, env:{SSHPASS:$ssh}}')
            ;;
        s3)
            echo ""; echo "   --- S3 ---"
            tui_input "Endpoint"       "${cur_host:-s3.amazonaws.com}" \
                "S3 endpoint, e.g. s3.amazonaws.com or minio.example.com:9000"
            local r_host_val="$TUI_RESULT"
            tui_input "Bucket name"    "$cur_bucket" "Name of the S3 bucket (must already exist)"
            local r_bucket="$TUI_RESULT"
            tui_input "Path in bucket" "${cur_path:-/backup}" "Subfolder, e.g. /server1 (empty = root)"
            local r_path="$TUI_RESULT"
            tui_input "Restic password" "$cur_pwd"  "Encryption password" "true"
            local r_pwd="$TUI_RESULT"
            tui_input "AWS access key ID" "$cur_ak" "IAM/MinIO access key ID"
            local r_ak="$TUI_RESULT"
            tui_input "AWS secret key"  "$cur_sk"   "IAM/MinIO secret access key" "true"
            local r_sk="$TUI_RESULT"
            json=$(jq -n \
              --arg t "s3" --arg h "$r_host_val" --arg b "$r_bucket" \
              --arg p "$r_path" --arg pwd "$r_pwd" --arg ak "$r_ak" --arg sk "$r_sk" \
              '{type:$t, host:$h, bucket:$b, path:$p, password:$pwd,
                env:{AWS_ACCESS_KEY_ID:$ak, AWS_SECRET_ACCESS_KEY:$sk}}')
            ;;
        b2)
            echo ""; echo "   --- Backblaze B2 ---"
            tui_input "Bucket name"    "$cur_bucket" "Backblaze B2 bucket name (must already exist in B2)"
            local r_bucket="$TUI_RESULT"
            tui_input "Path in bucket" "${cur_path:-/backup}" "Subfolder (empty = root)"
            local r_path="$TUI_RESULT"
            tui_input "Restic password" "$cur_pwd"  "Encryption password" "true"
            local r_pwd="$TUI_RESULT"
            tui_input "B2 application key ID" "$cur_kid" "Backblaze application key ID"
            local r_kid="$TUI_RESULT"
            tui_input "B2 application key"    "$cur_k"   "Backblaze application key (secret)" "true"
            local r_k="$TUI_RESULT"
            json=$(jq -n \
              --arg t "b2" --arg b "$r_bucket" --arg p "$r_path" \
              --arg pwd "$r_pwd" --arg kid "$r_kid" --arg k "$r_k" \
              '{type:$t, bucket:$b, path:$p, password:$pwd,
                env:{B2_ACCOUNT_ID:$kid, B2_ACCOUNT_KEY:$k}}')
            ;;
        rest)
            echo ""; echo "   --- REST server ---"
            tui_input "Server URL"     "$cur_url"   "Full URL, e.g. https://backup.example.com:8000/"
            local r_url="$TUI_RESULT"
            tui_input "Basic auth user" "$cur_user2" "HTTP basic auth username (empty = disabled)"
            local r_user2="$TUI_RESULT"
            local r_bpass=""
            if [ -n "$r_user2" ]; then
                tui_input "Basic auth password" "$cur_bpass" "HTTP basic auth password" "true"
                r_bpass="$TUI_RESULT"
            fi
            tui_input "Restic password" "$cur_pwd"  "Encryption password" "true"
            local r_pwd="$TUI_RESULT"
            json=$(jq -n \
              --arg t "rest" --arg u "$r_url" --arg usr "$r_user2" \
              --arg bp "$r_bpass" --arg pwd "$r_pwd" \
              '{type:$t, url:$u, username:$usr, basic_password:$bp, password:$pwd, env:{}}')
            ;;
        local)
            echo ""; echo "   --- Local path ---"
            tui_input "Path"           "$cur_path"  "Full path, e.g. /mnt/usb-backup or /backup"
            local r_path="$TUI_RESULT"
            tui_input "Restic password" "$cur_pwd"  "Encryption password" "true"
            local r_pwd="$TUI_RESULT"
            json=$(jq -n \
              --arg t "local" --arg p "$r_path" --arg pwd "$r_pwd" \
              '{type:$t, path:$p, password:$pwd, env:{}}')
            ;;
        *)
            echo ">> ERROR: unknown type '$r_type'."
            TUI_RESULT="{}"
            return 1
            ;;
    esac

    TUI_RESULT="$json"
    return 0
}

# ==========================================
# Initial setup wizard
# ==========================================
do_setup_wizard() {
    require_jq
    clear
    echo "=========================================="
    echo "     RESTIC BACKUP - INITIAL SETUP        "
    echo "=========================================="
    echo ""
    echo "  Welcome! Press Enter to accept the suggested defaults."
    echo "  Passwords are displayed as ****."
    echo ""

    # Host name
    local cur_host=""; [ -f "$CONFIG_FILE" ] && cur_host=$(jq -r '.host // ""' "$CONFIG_FILE")
    tui_input "Host name for snapshots" \
        "${cur_host:-$(hostname)}" \
        "Identifies this machine in restic. Important when multiple hosts share one repo."
    local r_host="$TUI_RESULT"

    # Compression
    echo ""
    echo "   Compression modes:"
    echo "   auto = Automatic (recommended) - compresses uncompressed files"
    echo "   max  = Maximum compression (higher CPU load, smaller backups)"
    echo "   off  = No compression (faster for already-compressed data like JPGs, videos)"
    local cur_comp="auto"; [ -f "$CONFIG_FILE" ] && cur_comp=$(jq -r '.compression // "auto"' "$CONFIG_FILE")
    tui_input "Compression mode" "$cur_comp" ""
    local r_comp="$TUI_RESULT"

    # Retry-lock
    echo ""
    echo "   --retry-lock wait time (for backup/forget/copy):"
    echo "   If the repo is locked (e.g. a backup already running), restic waits"
    echo "   up to this long before giving up. Format: 30s, 5m, 1h"
    local cur_retry="5m"; [ -f "$CONFIG_FILE" ] && cur_retry=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE")
    tui_input "Retry-lock wait time" "$cur_retry" "Recommended: 5m (5 minutes)"
    local r_retry="$TUI_RESULT"

    # Unlock-retry-lock
    echo ""
    echo "   --retry-lock wait time ONLY for unlock/lock-check calls:"
    echo "   Keep this deliberately SHORT! This applies to all unlock attempts"
    echo "   (auto-unlock, pre-backup check, force-unlock, manual unlocking)."
    echo "   If set too long (e.g. as long as above), unlocking itself can"
    echo "   hang for hours. Format: 30s, 5m, 10m, 1h"
    local cur_unlock_retry="10m"; [ -f "$CONFIG_FILE" ] && cur_unlock_retry=$(jq -r '.unlock_retry_lock // "10m"' "$CONFIG_FILE")
    tui_input "Unlock-retry-lock wait time" "$cur_unlock_retry" "Recommended: 10m (10 minutes)"
    local r_unlock_retry="$TUI_RESULT"

    # Cache directory
    echo ""
    echo "   Cache directory for restic:"
    echo "   Default: ~/.cache/restic (resolved via HOME)"
    local cur_cache="~/.cache/restic"; [ -f "$CONFIG_FILE" ] && cur_cache=$(jq -r '.cache_dir // "~/.cache/restic"' "$CONFIG_FILE")
    tui_input "Cache directory" "$cur_cache" "Leave empty for restic's default (~/.cache/restic)"
    local r_cache="$TUI_RESULT"

    # Main repo
    echo ""
    echo "--- Main repository ---"
    echo "   The primary backup target. All backups go here first."
    local jq_path_main=""
    [ -f "$CONFIG_FILE" ] && jq_path_main=".main"
    wizard_repo_input "sftp" "$jq_path_main"
    local main_json="$TUI_RESULT"

    # Ntfy
    echo ""
    echo "--- Push notifications via ntfy.sh (optional) ---"
    echo "   ntfy sends you a message when a backup fails."
    echo "   Free at https://ntfy.sh, or self-hosted."
    local cur_ntfy="false"
    [ -f "$CONFIG_FILE" ] && cur_ntfy=$(jq_bool '.notifications.ntfy.enabled' "$CONFIG_FILE")
    local ntfy_default="n"; [ "$cur_ntfy" = "true" ] && ntfy_default="y"
    local njson; njson='{"enabled": false}'

    if tui_confirm "Configure ntfy notifications?" "$ntfy_default"; then
        local cur_nurl="" cur_ntopic="" cur_nuser=""
        if [ -f "$CONFIG_FILE" ]; then
            cur_nurl=$(jq -r    '.notifications.ntfy.url      // "https://ntfy.sh"' "$CONFIG_FILE")
            cur_ntopic=$(jq -r  '.notifications.ntfy.topic   // ""'                 "$CONFIG_FILE")
            cur_nuser=$(jq -r   '.notifications.ntfy.username // ""'                "$CONFIG_FILE")
        fi
        tui_input "Ntfy server URL" "${cur_nurl:-https://ntfy.sh}" \
            "Public: https://ntfy.sh | self-hosted: https://ntfy.your.domain"
        local n_url="$TUI_RESULT"
        tui_input "Ntfy topic" "$cur_ntopic" \
            "Your topic name (e.g. my-server-alerts) - you subscribe to this in the app"
        local n_top="$TUI_RESULT"
        tui_input "Ntfy user" "$cur_nuser" \
            "Only needed for protected topics. Leave empty if not needed."
        local n_user="$TUI_RESULT"
        local n_pwd=""
        if [ -n "$n_user" ]; then
            tui_input "Ntfy password" "" "Password for ntfy authentication" "true"
            n_pwd="$TUI_RESULT"
        fi
        njson=$(jq -n \
          --arg u "$n_url" --arg t "$n_top" --arg usr "$n_user" --arg pwd "$n_pwd" \
          '{enabled:true, url:$u, topic:$t, username:$usr, password:$pwd}')
    fi

    # Keep existing copy repos
    local existing_copies="[]"
    [ -f "$CONFIG_FILE" ] && existing_copies=$(jq '.copies // []' "$CONFIG_FILE")

    jq -n \
      --arg h     "$r_host" \
      --arg comp  "$r_comp" \
      --arg retry "$r_retry" \
      --arg uretry "$r_unlock_retry" \
      --arg cache "$r_cache" \
      --argjson main   "$main_json" \
      --argjson ntfy   "$njson" \
      --argjson copies "$existing_copies" \
      '{host:$h, compression:$comp, retry_lock:$retry, unlock_retry_lock:$uretry, cache_dir:$cache,
        lock_state:{last_seen:"", last_unlock_attempt:""},
        notifications:{ntfy:$ntfy}, main:$main, copies:$copies}' \
      > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo ""
    echo ">> Configuration saved: $CONFIG_FILE"
    echo ">> Initializing repository..."
    load_restic_extra_opts
    if load_repo_context "main"; then
        if restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" init 2>/dev/null; then
            echo ">> Repository initialized."
        else
            echo ">> Note: repo already exists, or the connection failed."
            echo ">> Check snapshots with: sudo $0 -l"
        fi
        cleanup_repo_context
    fi
    sleep 2
}

# ==========================================
# Add a new copy repository
# ==========================================
add_copy_repo_wizard() {
    require_jq
    clear
    echo "=========================================="
    echo "     ADD A NEW COPY REPOSITORY            "
    echo "=========================================="
    echo ""
    echo "  Copy repos are additional backup targets."
    echo "  Restic copies finished snapshots here from the main repo."
    echo "  Ideal for 3-2-1 backups:"
    echo "   3 copies | 2 different media | 1 copy offsite"
    echo ""

    tui_input "Name for this copy repo" "Offsite Backup" \
        "A unique display name, e.g. 'Basement NAS', 'Hetzner S3', 'USB Drive'"
    local r_name="$TUI_RESULT"

    wizard_repo_input "s3" ""
    local repo_json="$TUI_RESULT"

    repo_json=$(echo "$repo_json" | jq --arg n "$r_name" '. + {name:$n, enabled:true}')

    local tmp_file; tmp_file=$(mktemp)
    jq --argjson newcopy "$repo_json" '.copies += [$newcopy]' "$CONFIG_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo ""
    echo ">> Copy repository '$r_name' added."
    echo ">> Initializing repository..."
    load_restic_extra_opts
    local new_idx; new_idx=$(jq '.copies | length' "$CONFIG_FILE")
    new_idx=$((new_idx - 1))
    if load_repo_context "$new_idx"; then
        if restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" init 2>/dev/null; then
            echo ">> Repository initialized."
        else
            echo ">> Note: repo already exists, or the connection failed."
        fi
        cleanup_repo_context
    fi
    sleep 2
}

# ==========================================
# TUI: edit individual repo fields
# ==========================================
edit_repo_config() {
    local jq_path="$1"
    local repo_label="$2"

    while true; do
        clear
        local r_type
        r_type=$(jq -r "${jq_path}.type // \"\"" "$CONFIG_FILE")

        # Read all fields depending on the type
        local v_user v_host v_path v_bucket v_url v_username v_bpass
        local v_pwd_set v_ssh_set v_ak v_sk v_kid v_bk
        v_user=$(jq -r     "${jq_path}.user               // \"\"" "$CONFIG_FILE")
        v_host=$(jq -r     "${jq_path}.host               // \"\"" "$CONFIG_FILE")
        v_path=$(jq -r     "${jq_path}.path               // \"\"" "$CONFIG_FILE")
        v_bucket=$(jq -r   "${jq_path}.bucket             // \"\"" "$CONFIG_FILE")
        v_url=$(jq -r      "${jq_path}.url                // \"\"" "$CONFIG_FILE")
        v_username=$(jq -r "${jq_path}.username           // \"\"" "$CONFIG_FILE")
        v_bpass=$(jq -r    "${jq_path}.basic_password     // \"\"" "$CONFIG_FILE")
        v_ak=$(jq -r       "${jq_path}.env.AWS_ACCESS_KEY_ID     // \"\"" "$CONFIG_FILE")
        v_sk=$(jq -r       "${jq_path}.env.AWS_SECRET_ACCESS_KEY // \"\"" "$CONFIG_FILE")
        v_kid=$(jq -r      "${jq_path}.env.B2_ACCOUNT_ID  // \"\"" "$CONFIG_FILE")
        v_bk=$(jq -r       "${jq_path}.env.B2_ACCOUNT_KEY // \"\"" "$CONFIG_FILE")
        local pwd_raw; pwd_raw=$(jq -r "${jq_path}.password      // \"\"" "$CONFIG_FILE")
        local ssh_raw; ssh_raw=$(jq -r "${jq_path}.env.SSHPASS   // \"\"" "$CONFIG_FILE")
        local v_pwd_str v_ssh_str v_ak_str v_sk_str v_kid_str v_bk_str v_bp_str
        [ -n "$pwd_raw" ] && v_pwd_str="$(col_ok 'set')"       || v_pwd_str="$(col_err 'missing')"
        [ -n "$ssh_raw" ] && v_ssh_str="$(col_ok 'set')"       || v_ssh_str="$(col_err 'missing')"
        [ -n "$v_ak"    ] && v_ak_str="$(col_ok "$v_ak")"         || v_ak_str="$(col_err 'missing')"
        [ -n "$v_sk"    ] && v_sk_str="$(col_ok 'set')"         || v_sk_str="$(col_err 'missing')"
        [ -n "$v_kid"   ] && v_kid_str="$(col_ok "$v_kid")"       || v_kid_str="$(col_err 'missing')"
        [ -n "$v_bk"    ] && v_bk_str="$(col_ok 'set')"         || v_bk_str="$(col_err 'missing')"
        [ -n "$v_bpass" ] && v_bp_str="$(col_ok 'set')"         || v_bp_str="$(col_dim '- empty')"

        # Header
        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║  REPO: %-34s║${C_RESET}\n" "$repo_label"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n" "Type:" "$(col_info "$r_type")"
        printf "${C_DIM}  Enter = keep current value${C_RESET}\n"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"

        # Fields depending on type
        case "$r_type" in
            sftp)
                printf "  ${C_BOLD}1)${C_RESET}  User             %s\n" \
                    "$([ -n "$v_user" ] && col_ok "$v_user" || col_err "missing")"
                printf "  ${C_DIM}     SSH username on the backup server${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Host             %s\n" \
                    "$([ -n "$v_host" ] && col_ok "$v_host" || col_err "missing")"
                printf "  ${C_DIM}     IP address or hostname of the server${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Path             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_err "missing")"
                printf "  ${C_DIM}     Directory path on the server${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  Restic password  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Encrypts your backup data${C_RESET}\n"
                printf "  ${C_BOLD}5)${C_RESET}  SSH password     %b\n" "$v_ssh_str"
                printf "  ${C_DIM}     Login password for sshpass${C_RESET}\n"
                ;;
            s3)
                printf "  ${C_BOLD}1)${C_RESET}  Endpoint         %s\n" \
                    "$([ -n "$v_host" ] && col_ok "$v_host" || col_err "missing")"
                printf "  ${C_DIM}     e.g. s3.amazonaws.com or minio.host:9000${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Bucket           %s\n" \
                    "$([ -n "$v_bucket" ] && col_ok "$v_bucket" || col_err "missing")"
                printf "  ${C_DIM}     Name of the S3 bucket${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Path             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_dim "- empty (root)")"
                printf "  ${C_DIM}     Subfolder in the bucket, e.g. /server1${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  Restic password  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Encrypts your backup data${C_RESET}\n"
                printf "  ${C_BOLD}5)${C_RESET}  AWS access key   %b\n" "$v_ak_str"
                printf "  ${C_DIM}     IAM / MinIO access key ID${C_RESET}\n"
                printf "  ${C_BOLD}6)${C_RESET}  AWS secret key   %b\n" "$v_sk_str"
                printf "  ${C_DIM}     IAM / MinIO secret access key${C_RESET}\n"
                ;;
            b2)
                printf "  ${C_BOLD}1)${C_RESET}  Bucket           %s\n" \
                    "$([ -n "$v_bucket" ] && col_ok "$v_bucket" || col_err "missing")"
                printf "  ${C_DIM}     Name of the Backblaze B2 bucket${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Path             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_dim "- empty (root)")"
                printf "  ${C_DIM}     Subfolder in the bucket, e.g. /server1${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Restic password  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Encrypts your backup data${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  B2 application key ID  %b\n" "$v_kid_str"
                printf "  ${C_DIM}     Backblaze application key ID${C_RESET}\n"
                printf "  ${C_BOLD}5)${C_RESET}  B2 application key     %b\n" "$v_bk_str"
                printf "  ${C_DIM}     Backblaze secret key${C_RESET}\n"
                ;;
            rest)
                printf "  ${C_BOLD}1)${C_RESET}  Server URL       %s\n" \
                    "$([ -n "$v_url" ] && col_ok "$v_url" || col_err "missing")"
                printf "  ${C_DIM}     e.g. https://backup.example.com:8000/${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Basic auth user  %s\n" \
                    "$([ -n "$v_username" ] && col_ok "$v_username" || col_dim "- empty (no auth)")"
                printf "  ${C_DIM}     HTTP basic auth username${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Basic auth password  %b\n" "$v_bp_str"
                printf "  ${C_DIM}     HTTP basic auth password${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  Restic password  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Encrypts your backup data${C_RESET}\n"
                ;;
            local)
                printf "  ${C_BOLD}1)${C_RESET}  Path             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_err "missing")"
                printf "  ${C_DIM}     Full path, e.g. /mnt/usb-backup${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Restic password  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Encrypts your backup data${C_RESET}\n"
                ;;
            *)
                printf "  ${C_YELLOW}Unknown type '%s' -- press T to reconfigure.${C_RESET}\n" "$r_type"
                ;;
        esac

        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}${C_YELLOW}T)${C_RESET}  Reconfigure type completely\n"
        printf "  ${C_BOLD}0)${C_RESET}  Back\n"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Choice: " echoice

        case "$echoice" in
            [Tt])
                printf "\n  ${C_YELLOW}WARNING: all settings will be overwritten!${C_RESET}\n"
                if tui_confirm "Really change the type and reconfigure?" "n"; then
                    wizard_repo_input "" "$jq_path"
                    local new_json="$TUI_RESULT"
                    local pres_name pres_enabled
                    pres_name=$(jq -r     "${jq_path}.name    // \"\"" "$CONFIG_FILE")
                    pres_enabled=$(jq_bool "${jq_path}.enabled"        "$CONFIG_FILE")
                    if [ -n "$pres_name" ] && [ "$pres_name" != "null" ]; then
                        new_json=$(printf '%s' "$new_json" | jq --arg n "$pres_name" '. + {name:$n}')
                    fi
                    if [ "$jq_path" != ".main" ]; then
                        new_json=$(printf '%s' "$new_json" | jq --argjson e "$pres_enabled" '. + {enabled:$e}')
                    fi
                    local tmp_file; tmp_file=$(mktemp)
                    if jq --argjson r "$new_json" "${jq_path} = \$r" "$CONFIG_FILE" > "$tmp_file"; then
                        mv "$tmp_file" "$CONFIG_FILE"
                        chmod 600 "$CONFIG_FILE"
                        printf "  ${C_GREEN}>> Repo reconfigured.${C_RESET}\n"
                    else
                        rm -f "$tmp_file"
                        printf "  ${C_RED}>> ERROR writing config!${C_RESET}\n"
                    fi
                    sleep 1
                fi
                continue
                ;;
            0) return ;;
        esac

        # Edit individual fields
        _save_ok() { printf "  ${C_GREEN}>> Saved.${C_RESET}\n"; sleep 1; }
        _no_change() { printf "  ${C_DIM}>> No change.${C_RESET}\n"; sleep 1; }
        _pw_warn() { printf "  ${C_YELLOW}WARNING: changing the password makes existing backups inaccessible!${C_RESET}\n"; }

        case "$r_type" in
            sftp)
                case "$echoice" in
                    1) tui_input "User"       "$v_user"  "SSH/SFTP login username"
                       config_set_arg "${jq_path}.user = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Host"            "$v_host"  "Hostname or IP address"
                       config_set_arg "${jq_path}.host = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) tui_input "Path"            "$v_path"  "Directory path on the server"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    4) _pw_warn
                       tui_input "Restic password" "" "New password (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    5) tui_input "SSH password"   "" "Login password for sshpass (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.env.SSHPASS = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            s3)
                case "$echoice" in
                    1) tui_input "Endpoint"       "$v_host"   "S3 endpoint URL"
                       config_set_arg "${jq_path}.host = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Bucket"         "$v_bucket" "S3 bucket name"
                       config_set_arg "${jq_path}.bucket = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) tui_input "Path"           "$v_path"   "Subfolder in the bucket (empty = root)"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    4) _pw_warn
                       tui_input "Restic password" "" "New password (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    5) tui_input "AWS access key ID" "$v_ak" "IAM / MinIO access key ID"
                       config_set_arg "${jq_path}.env.AWS_ACCESS_KEY_ID = \$val" "$TUI_RESULT"; _save_ok ;;
                    6) tui_input "AWS secret key"  "" "Secret key (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.env.AWS_SECRET_ACCESS_KEY = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            b2)
                case "$echoice" in
                    1) tui_input "Bucket"         "$v_bucket" "Name of the B2 bucket"
                       config_set_arg "${jq_path}.bucket = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Path"           "$v_path"   "Subfolder in the bucket (empty = root)"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) _pw_warn
                       tui_input "Restic password" "" "New password (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    4) tui_input "B2 application key ID" "$v_kid" "Backblaze application key ID"
                       config_set_arg "${jq_path}.env.B2_ACCOUNT_ID = \$val" "$TUI_RESULT"; _save_ok ;;
                    5) tui_input "B2 application key" "" "Secret key (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.env.B2_ACCOUNT_KEY = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            rest)
                case "$echoice" in
                    1) tui_input "Server URL"     "$v_url"      "Full URL"
                       config_set_arg "${jq_path}.url = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Basic auth user" "$v_username" "HTTP basic auth user (empty = no auth)"
                       config_set_arg "${jq_path}.username = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) tui_input "Basic auth password" "" "HTTP basic auth password (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.basic_password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    4) _pw_warn
                       tui_input "Restic password" "" "New password (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            local)
                case "$echoice" in
                    1) tui_input "Path"           "$v_path"  "Full path, e.g. /mnt/usb-backup"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) _pw_warn
                       tui_input "Restic password" "" "New password (empty = no change)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
        esac
    done
}

# ==========================================
# Send an ntfy test message
# ==========================================
ntfy_send_test() {
    local ntfy_url ntfy_topic ntfy_user ntfy_pass
    ntfy_url=$(jq -r   '.notifications.ntfy.url      // "https://ntfy.sh"' "$CONFIG_FILE")
    ntfy_topic=$(jq -r '.notifications.ntfy.topic    // ""'                "$CONFIG_FILE")
    ntfy_user=$(jq -r  '.notifications.ntfy.username // ""'                "$CONFIG_FILE")
    ntfy_pass=$(jq -r  '.notifications.ntfy.password // ""'                "$CONFIG_FILE")

    if [ -z "$ntfy_topic" ]; then
        echo "  >> ERROR: no ntfy topic configured!"
        sleep 2; return
    fi

    local auth_args=()
    [ -n "$ntfy_user" ] && [ -n "$ntfy_pass" ] && auth_args+=(-u "${ntfy_user}:${ntfy_pass}")

    local host; host=$(get_hostname)
    local msg="Test message from Restic Backup Manager on '${host}'. Ntfy is working correctly!"

    echo "  >> Sending test message to ${ntfy_url}/${ntfy_topic} ..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${auth_args[@]}" \
        -H "Title: Backup Test: ${host}" \
        -H "Tags: information" \
        -H "Priority: default" \
        -d "$msg" \
        "${ntfy_url}/${ntfy_topic}")

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "  >> Success! HTTP $http_code -- the message should show up in the ntfy app."
    else
        echo "  >> ERROR! HTTP $http_code -- please check URL, topic, and credentials."
    fi
    sleep 3
}

# ==========================================
# TUI: manage folder excludes
# ==========================================
menu_exclude_settings() {
    while true; do
        clear
        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║    FOLDER EXCLUDES                       ║${C_RESET}\n"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"

        local count; count=$(jq '.excludes | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        local using_defaults=false
        [ "$count" -eq 0 ] && using_defaults=true

        if $using_defaults; then
            printf "  ${C_DIM}(No custom list -- default excludes active)${C_RESET}\n"
            printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
            for i in "${!DEFAULT_EXCLUDES[@]}"; do
                printf "  ${C_DIM}%2d)${C_RESET} %s\n" "$((i+1))" "${DEFAULT_EXCLUDES[$i]}"
            done
        else
            printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
            local idx=0
            while IFS= read -r path; do
                printf "  ${C_BOLD}%2d)${C_RESET} %s\n" "$((idx+1))" "$path"
                idx=$((idx+1))
            done < <(jq -r '.excludes[]' "$CONFIG_FILE" 2>/dev/null)
        fi

        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}A)${C_RESET}  Add a path\n"
        if ! $using_defaults; then
            printf "  ${C_BOLD}R)${C_RESET}  Remove a path (enter number)\n"
        fi
        printf "  ${C_BOLD}D)${C_RESET}  Reset to default excludes\n"
        printf "  ${C_BOLD}0)${C_RESET}  Back\n"
        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Choice: " xchoice

        case "$xchoice" in
            [Aa])
                tui_input "Add path" "" "Full path, e.g. /home/user/Downloads"
                local new_path="$TUI_RESULT"
                [ -z "$new_path" ] && continue
                # Ensure the excludes array exists, then append
                if $using_defaults; then
                    # Initialize with defaults first
                    local defaults_json; defaults_json=$(printf '%s\n' "${DEFAULT_EXCLUDES[@]}" | jq -R . | jq -s .)
                    local tmp_file; tmp_file=$(mktemp)
                    if jq --argjson arr "$defaults_json" '.excludes = $arr' "$CONFIG_FILE" > "$tmp_file"; then
                        mv "$tmp_file" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
                    else rm -f "$tmp_file"; fi
                fi
                config_set_arg '.excludes += [$val]' "$new_path"
                printf "  ${C_GREEN}>> '%s' added.${C_RESET}\n" "$new_path"
                sleep 1
                ;;
            [Rr])
                $using_defaults && continue
                read -rp "  Which number to remove? " rnum
                if [[ "$rnum" =~ ^[0-9]+$ ]]; then
                    local ridx=$((rnum - 1))
                    local cur_count; cur_count=$(jq '.excludes | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
                    if [ "$ridx" -ge 0 ] && [ "$ridx" -lt "$cur_count" ]; then
                        local del_path; del_path=$(jq -r ".excludes[$ridx]" "$CONFIG_FILE")
                        local tmp_file; tmp_file=$(mktemp)
                        if jq "del(.excludes[$ridx])" "$CONFIG_FILE" > "$tmp_file"; then
                            mv "$tmp_file" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
                            printf "  ${C_GREEN}>> '%s' removed.${C_RESET}\n" "$del_path"
                        else rm -f "$tmp_file"; printf "  ${C_RED}>> Error removing entry.${C_RESET}\n"; fi
                        sleep 1
                    fi
                fi
                ;;
            [Dd])
                if tui_confirm "Delete the custom list and use default excludes?" "n"; then
                    config_set 'del(.excludes)'
                    printf "  ${C_GREEN}>> Reset to default excludes.${C_RESET}\n"
                    sleep 1
                fi
                ;;
            0) return ;;
            *)
                # Allow direct number entry to remove a path
                if [[ "$xchoice" =~ ^[0-9]+$ ]] && ! $using_defaults; then
                    local ridx=$((xchoice - 1))
                    local cur_count; cur_count=$(jq '.excludes | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
                    if [ "$ridx" -ge 0 ] && [ "$ridx" -lt "$cur_count" ]; then
                        local del_path; del_path=$(jq -r ".excludes[$ridx]" "$CONFIG_FILE")
                        if tui_confirm "  Remove '$del_path'?" "n"; then
                            local tmp_file; tmp_file=$(mktemp)
                            if jq "del(.excludes[$ridx])" "$CONFIG_FILE" > "$tmp_file"; then
                                mv "$tmp_file" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
                                printf "  ${C_GREEN}>> Removed.${C_RESET}\n"
                            else rm -f "$tmp_file"; fi
                            sleep 1
                        fi
                    fi
                fi
                ;;
        esac
    done
}

# ==========================================
# TUI: global settings
# ==========================================
edit_global_settings() {
    while true; do
        clear
        local r_host r_comp ntfy_en ntfy_url ntfy_topic
        r_host=$(jq -r    '.host                        // ""'             "$CONFIG_FILE")
        r_comp=$(jq -r    '.compression                 // "auto"'         "$CONFIG_FILE")
        ntfy_en=$(jq_bool '.notifications.ntfy.enabled' "$CONFIG_FILE")
        ntfy_url=$(jq -r  '.notifications.ntfy.url      // "https://ntfy.sh"' "$CONFIG_FILE")
        ntfy_topic=$(jq -r '.notifications.ntfy.topic   // ""'             "$CONFIG_FILE")

        local ntfy_user; ntfy_user=$(jq -r '.notifications.ntfy.username // ""' "$CONFIG_FILE")
        local ntfy_status_str="OFF"; [ "$ntfy_en" = "true" ] && ntfy_status_str="ON"

        echo "=========================================="
        echo "   GLOBAL SETTINGS"
        echo "=========================================="
        echo "  1) Host name:           $r_host"
        echo "     (Identifies this host in snapshots)"
        echo ""
        echo "  2) Compression:         $r_comp"
        echo "     (auto | max | off)"
        echo ""
        local r_retry r_cache
        r_retry=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE")
        r_cache=$(jq -r '.cache_dir // "~/.cache/restic"' "$CONFIG_FILE")
        echo "  3) Retry-lock wait time (backup/forget/copy):  $r_retry"
        echo "     Wait time when the repo is locked (30s, 5m, 1h)"
        echo ""
        local r_uretry; r_uretry=$(jq -r '.unlock_retry_lock // "10m"' "$CONFIG_FILE")
        echo " 19) Retry-lock wait time ONLY for unlock calls:  $r_uretry"
        echo "     Keep this short! Prevents unlocking itself from hanging for hours."
        echo ""
        echo "  4) Cache directory:     $r_cache"
        echo "     Path to the restic cache (~/.cache/restic = default)"
        echo "------------------------------------------"
        local r_stale; r_stale=$(jq -r '.stale_unlock_hours // 2' "$CONFIG_FILE")
        echo " 11) Auto-unlock after:     ${r_stale}h"
        echo "     When a still-existing lock gets forcibly removed"
        echo "     (only relevant if 'restic unlock' doesn't recognize it as stale itself,"
        echo "      e.g. for REST-server repos accessed from multiple hosts)"
        echo " 12) Unlock the repo right now (--remove-all)"
        echo "     Manual emergency unlock -- only when you're sure no backup is running!"
        echo "------------------------------------------"
        local r_kd r_kw r_km r_ky r_kl r_prune
        r_kd=$(jq -r '.retention.keep_daily   // 31' "$CONFIG_FILE")
        r_kw=$(jq -r '.retention.keep_weekly  // 4'  "$CONFIG_FILE")
        r_km=$(jq -r '.retention.keep_monthly // 6'  "$CONFIG_FILE")
        r_ky=$(jq -r '.retention.keep_yearly  // 0'  "$CONFIG_FILE")
        r_kl=$(jq -r '.retention.keep_last    // 0'  "$CONFIG_FILE")
        r_prune=$(jq_bool '.retention.prune' "$CONFIG_FILE")
        echo "  Retention / cleanup (forget after every backup):"
        echo " 13) Keep daily:             $r_kd"
        echo " 14) Keep weekly:            $r_kw"
        echo " 15) Keep monthly:           $r_km"
        echo " 16) Keep yearly:            $r_ky      (0 = disabled)"
        echo " 17) Keep last N:            $r_kl      (0 = disabled, in addition to the above)"
        echo " 18) Prune after forget:     $r_prune"
        echo "------------------------------------------"
        echo "  Ntfy push notifications: [$ntfy_status_str]"
        echo "  5) Enabled:            $ntfy_en"
        echo "  6) Server URL:         $ntfy_url"
        echo "  7) Topic:              $ntfy_topic"
        echo "  8) User:               ${ntfy_user:-<none>}"
        echo "  9) Change password:    ****"
        if [ "$ntfy_en" = "true" ]; then
            echo " 10) Send test message"
        fi
        echo "------------------------------------------"
        echo "  0) Back"
        echo "=========================================="
        read -rp "  Choice: " gchoice

        case $gchoice in
            1) tui_input "Host name" "$r_host" \
                   "Changing this: old snapshots are no longer shown automatically (different host ID)!"
               config_set_arg '.host = $val' "$TUI_RESULT" ;;
            2) echo "   auto = recommended | max = smaller but slower | off = no compression"
               tui_input "Compression mode" "$r_comp" ""
               config_set_arg '.compression = $val' "$TUI_RESULT" ;;
            3) tui_input "Retry-lock wait time" "$r_retry" "Format: 30s, 5m, 1h (restic duration) - for backup/forget/copy"
               config_set_arg '.retry_lock = $val' "$TUI_RESULT" ;;
            4) echo "   Default: ~/.cache/restic (resolved via HOME)"
               tui_input "Cache directory" "$r_cache" "Leave empty for restic's default"
               config_set_arg '.cache_dir = $val' "$TUI_RESULT" ;;
            5) if [ "$ntfy_en" = "true" ]; then
                   config_set '.notifications.ntfy.enabled = false'
                   echo "  >> Ntfy disabled."
               else
                   config_set '.notifications.ntfy.enabled = true'
                   echo "  >> Ntfy enabled."
               fi; sleep 1 ;;
            6) tui_input "Ntfy URL" "$ntfy_url" "URL of the ntfy server"
               config_set_arg '.notifications.ntfy.url = $val' "$TUI_RESULT" ;;
            7) tui_input "Ntfy topic" "$ntfy_topic" "Topic name (you subscribe to this in the ntfy app)"
               config_set_arg '.notifications.ntfy.topic = $val' "$TUI_RESULT" ;;
            8) tui_input "Ntfy user" "$ntfy_user" "Leave empty if no auth is needed"
               config_set_arg '.notifications.ntfy.username = $val' "$TUI_RESULT" ;;
            9) tui_input "Ntfy password" "" "Password for ntfy login" "true"
               [ -n "$TUI_RESULT" ] && config_set_arg '.notifications.ntfy.password = $val' "$TUI_RESULT" ;;
            10) if [ "$ntfy_en" = "true" ]; then
                   ntfy_send_test
               fi ;;
            11) tui_input "Auto-unlock after (hours)" "$r_stale" \
                    "Whole number, e.g. 2. Smaller = more aggressive, larger = more cautious."
                if [[ "$TUI_RESULT" =~ ^[0-9]+$ ]]; then
                    config_set_arg '.stale_unlock_hours = ($val | tonumber)' "$TUI_RESULT"
                else
                    echo "  >> Invalid, must be a number."; sleep 1
                fi ;;
            12) force_unlock_repo ;;
            13) tui_input "Keep daily (keep-daily)" "$r_kd" "Whole number, 0 = disabled"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_daily = ($val | tonumber)' "$TUI_RESULT" ;;
            14) tui_input "Keep weekly (keep-weekly)" "$r_kw" "Whole number, 0 = disabled"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_weekly = ($val | tonumber)' "$TUI_RESULT" ;;
            15) tui_input "Keep monthly (keep-monthly)" "$r_km" "Whole number, 0 = disabled"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_monthly = ($val | tonumber)' "$TUI_RESULT" ;;
            16) tui_input "Keep yearly (keep-yearly)" "$r_ky" "Whole number, 0 = disabled"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_yearly = ($val | tonumber)' "$TUI_RESULT" ;;
            17) tui_input "Keep last N (keep-last)" "$r_kl" "Whole number, 0 = disabled"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_last = ($val | tonumber)' "$TUI_RESULT" ;;
            18) if [ "$r_prune" = "true" ]; then
                    config_set '.retention.prune = false'
                    echo "  >> Prune after forget disabled (space won't be reclaimed automatically)."
                else
                    config_set '.retention.prune = true'
                    echo "  >> Prune after forget enabled."
                fi; sleep 1 ;;
            19) tui_input "Unlock-retry-lock wait time" "$r_uretry" \
                    "Format: 30s, 5m, 10m, 1h - ONLY for unlock/lock-check calls. Keep it short!"
                config_set_arg '.unlock_retry_lock = $val' "$TUI_RESULT" ;;
            0) return ;;
        esac
    done
}

# ==========================================
# TUI: delete a copy repo
# ==========================================
menu_delete_copy_repo() {
    clear
    echo "=========================================="
    echo "   DELETE A COPY REPOSITORY FROM CONFIG"
    echo "=========================================="
    echo "  (Backup data on the storage medium itself is NOT deleted!)"
    echo ""
    local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "$copy_count" -eq 0 ]; then
        echo "  No copy repositories exist."; sleep 1; return
    fi
    for i in $(seq 0 $((copy_count - 1))); do
        local c_name c_type
        c_name=$(jq -r ".copies[$i].name // \"Copy #$((i+1))\"" "$CONFIG_FILE")
        c_type=$(jq -r ".copies[$i].type // \"?\"" "$CONFIG_FILE")
        echo "  $((i+1))) $c_name [$c_type]"
    done
    echo "  0) Cancel"
    echo "=========================================="
    read -rp "  Which repo to remove from config? " dchoice
    [ "$dchoice" = "0" ] && return
    if [[ "$dchoice" =~ ^[0-9]+$ ]] && [ "$dchoice" -ge 1 ] && [ "$dchoice" -le "$copy_count" ]; then
        local idx=$((dchoice - 1))
        local c_name; c_name=$(jq -r ".copies[$idx].name // \"Copy #$((idx+1))\"" "$CONFIG_FILE")
        echo ""
        echo "  Note: '$c_name' will be removed from the configuration."
        echo "  The actual backup data itself is preserved."
        if tui_confirm "Really remove it?" "n"; then
            local tmp_file; tmp_file=$(mktemp)
            jq "del(.copies[$idx])" "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            echo "  >> '$c_name' removed."
            sleep 2
        fi
    fi
}

# ==========================================
# TUI: edit configuration (main menu)
# ==========================================
menu_edit_configs() {
    while true; do
        clear
        echo "=========================================="
        echo "   EDIT CONFIGURATION"
        echo "=========================================="
        echo "  1) Global settings"
        echo "     (Host name, compression, ntfy)"
        echo "  2) Edit main repository"
        echo "     Type: $(jq -r '.main.type // "?"' "$CONFIG_FILE")"

        local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        if [ "$copy_count" -gt 0 ]; then
            echo "------------------------------------------"
            echo "  Copy repositories:"
        fi
        for i in $(seq 0 $((copy_count - 1))); do
            local c_name c_type c_enabled
            c_name=$(jq -r    ".copies[$i].name    // \"Copy #$((i+1))\"" "$CONFIG_FILE")
            c_type=$(jq -r    ".copies[$i].type    // \"?\"" "$CONFIG_FILE")
            c_enabled=$(jq_bool ".copies[$i].enabled" "$CONFIG_FILE")
            local status_str="ON"
            [ "$c_enabled" != "true" ] && status_str="OFF"
            echo "  $((i + 3))) $c_name [$c_type][$status_str]"
        done

        echo "------------------------------------------"
        echo "  E) Edit folder excludes"
        echo "  N) Add a new copy repository"
        echo "  D) Delete a copy repository from config"
        echo "  0) Back"
        echo "=========================================="
        read -rp "  Choice: " echoice

        case "$echoice" in
            1)    edit_global_settings ;;
            2)    edit_repo_config ".main" "Main repository" ;;
            [Ee]) menu_exclude_settings ;;
            [Nn]) add_copy_repo_wizard ;;
            [Dd]) menu_delete_copy_repo ;;
            0)    return ;;
            *)
                if [[ "$echoice" =~ ^[0-9]+$ ]]; then
                    local copy_idx=$((echoice - 3))
                    if [ "$copy_idx" -ge 0 ] && [ "$copy_idx" -lt "$copy_count" ]; then
                        local c_name; c_name=$(jq -r ".copies[$copy_idx].name // \"Copy #$((copy_idx+1))\"" "$CONFIG_FILE")
                        edit_repo_config ".copies[$copy_idx]" "$c_name"
                    fi
                fi
                ;;
        esac
    done
}

# ==========================================
# Enable/disable copy repos
# ==========================================
menu_toggle_copies() {
    while true; do
        clear
        echo "=========================================="
        echo "   MANAGE COPY REPOSITORIES"
        echo "=========================================="
        local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        if [ "$copy_count" -eq 0 ]; then
            echo "  No copy repositories configured."
            echo "  Add a new one: option 7 in the main menu."
            echo ""; read -rp "  Press Enter to continue..."; return
        fi
        for i in $(seq 0 $((copy_count - 1))); do
            local c_name c_enabled status_str
            c_name=$(jq -r ".copies[$i].name // \"Copy #$((i+1))\"" "$CONFIG_FILE")
            c_enabled=$(jq_bool ".copies[$i].enabled" "$CONFIG_FILE")
            [ "$c_enabled" = "true" ] && status_str="[ ON  ]" || status_str="[ OFF ]"
            echo "  $((i+1))) $status_str $c_name"
        done
        echo "------------------------------------------"
        echo "  D<Nr>) Delete, e.g. D1 or D2"
        echo "  0) Back"
        echo "=========================================="
        echo "  Number = toggle ON/OFF"
        read -rp "  Choice: " tchoice

        [ "$tchoice" = "0" ] && return

        # Delete: D1, D2, d1 etc.
        if [[ "$tchoice" =~ ^[Dd]([0-9]+)$ ]]; then
            local del_num="${BASH_REMATCH[1]}"
            if [ "$del_num" -ge 1 ] && [ "$del_num" -le "$copy_count" ]; then
                local del_idx=$((del_num - 1))
                local del_name; del_name=$(jq -r ".copies[$del_idx].name // \"Copy #${del_num}\"" "$CONFIG_FILE")
                echo ""
                echo "  WARNING: '$del_name' will be removed from the configuration."
                echo "  The backup data on the storage medium is preserved."
                if tui_confirm "Really delete it?" "n"; then
                    local tmp_file; tmp_file=$(mktemp)
                    if jq "del(.copies[$del_idx])" "$CONFIG_FILE" > "$tmp_file"; then
                        mv "$tmp_file" "$CONFIG_FILE"
                        chmod 600 "$CONFIG_FILE"
                        echo "  >> '$del_name' removed from configuration."
                    else
                        rm -f "$tmp_file"
                        echo "  >> ERROR removing entry!"
                    fi
                    sleep 2
                fi
            fi
            continue
        fi

        # Toggle ON/OFF
        if [[ "$tchoice" =~ ^[0-9]+$ ]] && [ "$tchoice" -ge 1 ] && [ "$tchoice" -le "$copy_count" ]; then
            local idx=$((tchoice - 1))
            local c_en; c_en=$(jq_bool ".copies[$idx].enabled" "$CONFIG_FILE")
            local new_val="true"; [ "$c_en" = "true" ] && new_val="false"
            local tmp_file; tmp_file=$(mktemp)
            if jq ".copies[$idx].enabled = $new_val" "$CONFIG_FILE" > "$tmp_file"; then
                mv "$tmp_file" "$CONFIG_FILE"
                chmod 600 "$CONFIG_FILE"
                local new_label="ON"; [ "$new_val" = "false" ] && new_label="OFF"
                echo "  >> Repo set to $new_label."
            else
                rm -f "$tmp_file"
                echo "  >> ERROR changing the setting!"
            fi
            sleep 1
        fi
    done
}

# ==========================================
# Restic update (cross-distro)
# ==========================================
update_restic() {
    clear
    echo "=========================================="
    echo "   RESTIC UPDATE"
    echo "=========================================="
    local current; current=$(get_restic_version)
    echo "  Current version: $current"
    echo ""

    if ! command -v restic &>/dev/null; then
        echo ">> Restic is not installed. Please install it first:"
        echo "   https://restic.net  or  sudo apt install restic"
        sleep 3; return
    fi

    # Attempt 1: system package manager
    echo ">> Trying update via system package manager..."

    if command -v apt-get &>/dev/null; then
        echo "   (apt-get update && apt-get install --only-upgrade restic)"
        apt-get update -qq && apt-get install --only-upgrade -y restic 2>/dev/null && {
            echo ">> Update via apt succeeded."
            echo "   New version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v dnf &>/dev/null; then
        echo "   (dnf upgrade restic)"
        dnf upgrade -y restic 2>/dev/null && {
            echo ">> Update via dnf succeeded."
            echo "   New version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v pacman &>/dev/null; then
        echo "   (pacman -Sy restic)"
        pacman -Sy --noconfirm restic 2>/dev/null && {
            echo ">> Update via pacman succeeded."
            echo "   New version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v zypper &>/dev/null; then
        echo "   (zypper update restic)"
        zypper update -y restic 2>/dev/null && {
            echo ">> Update via zypper succeeded."
            echo "   New version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v apk &>/dev/null; then
        echo "   (apk update && apk add restic)"
        apk update && apk add --upgrade restic 2>/dev/null && {
            echo ">> Update via apk succeeded."
            echo "   New version: $(get_restic_version)"
            sleep 2; return
        }
    fi

    # Attempt 2: restic self-update (for binary installs)
    echo ""
    echo ">> Package-manager update failed or unavailable."
    if restic_supports_retry_lock; then
        echo ">> Trying restic self-update..."
        if restic self-update 2>/dev/null; then
            echo ">> Self-update succeeded."
            echo "   New version: $(get_restic_version)"
            sleep 2; return
        else
            echo ">> Self-update failed (no write access to the binary?)."
            echo "   Manual update: https://github.com/restic/restic/releases/latest"
        fi
    else
        echo ">> restic self-update is only available from v0.15.0 onward."
        echo ">> Please update manually: https://github.com/restic/restic/releases/latest"
        echo "   Or via package manager: sudo apt install restic"
    fi

    sleep 3
}

# ==========================================
# Cancel a running background task (backup, unlock, or force-unlock)
# Sends SIGTERM to the worker process in the tmux session (not to the
# session itself). The existing shutdown trap in run_backup() (see
# cleanup_on_shutdown) catches SIGTERM and unlocks the repos cleanly before
# the process exits.
# ==========================================
cancel_running_task() {
    clear
    echo "=========================================="
    echo "   CANCEL RUNNING TASK"
    echo "=========================================="

    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo ">> No task is currently running in the background."
        sleep 2; return
    fi

    echo "  Sends SIGTERM to the running background process."
    echo "  For a backup, this unlocks the repos cleanly (shutdown trap)"
    echo "  before exiting. This can take a few seconds."
    echo "------------------------------------------"
    if ! tui_confirm "Really cancel the running task?" "n"; then
        return
    fi

    # Find the worker process: the script invocation carrying the internal
    # -Z marker, running inside the tmux session (see launch_and_attach)
    local worker_pid
    worker_pid=$(pgrep -f -- "$SCRIPT_PATH .*-Z" 2>/dev/null | head -1)
    if [ -z "$worker_pid" ]; then
        worker_pid=$(pgrep -f -- "restic-backup .*-Z" 2>/dev/null | head -1)
    fi

    if [ -z "$worker_pid" ]; then
        echo ">> Could not clearly identify the worker process."
        echo ">> Trying to stop restic directly instead..."
        pkill -TERM -f "restic .*backup" 2>/dev/null || true
    else
        echo ">> Sending SIGTERM to process $worker_pid ..."
        kill -TERM "$worker_pid" 2>/dev/null || true
    fi

    echo ">> Waiting for a clean exit (up to 30s)..."
    local waited=0
    while tmux has-session -t "$TMUX_SESSION" 2>/dev/null && [ "$waited" -lt 30 ]; do
        sleep 1; waited=$((waited + 1))
    done

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo ">> Session still running after 30s. Forcing a harder stop..."
        pkill -KILL -f "restic .*backup" 2>/dev/null || true
        sleep 2
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            echo ">> WARNING: the session is still running."
            echo "   Check manually: tmux attach -t $TMUX_SESSION"
            echo "   Or force-kill the session: tmux kill-session -t $TMUX_SESSION"
        else
            echo ">> Task stopped."
        fi
    else
        echo ">> Task stopped successfully and repos unlocked."
    fi
    sleep 2
}

# ==========================================
# Background mode (tmux) -- keeps running like a daemon
#
# Kept deliberately simple: a plain tmux session that runs the script
# directly. This gives restic a real pty, so you get restic's normal live
# output when attached. Detaching/attaching works exactly like any other
# tmux session: Ctrl+B then D to detach, "tmux attach" (or menu option A)
# to reattach. No custom log-piping or line-by-line timestamp wrapping.
# ==========================================
build_mode_args() {
    # -Z is an internal marker: tells the script instance actually running
    # inside tmux that it IS the worker and should run the action directly
    # (instead of trying to background itself again -- otherwise every
    # backgrounded action would try to re-launch itself into a "new"
    # session and immediately fail because that session already exists).
    MODE_ARGS=("-r" "-Z")
    $FULL_RESOURCES   && MODE_ARGS+=("-f")
    $ECONOMY_MODE     && MODE_ARGS+=("-e")
    $EXTRA_RESOURCES  && MODE_ARGS+=("-x")
    $NO_COMPRESSION   && MODE_ARGS+=("-n")
    [ -n "$DRY_RUN_FLAG" ] && MODE_ARGS+=("-d")
}

# launch_and_attach <label> <script-args...>
# Starts a plain tmux session running this script with the given args, logs
# its output to a file via `tmux pipe-pane` (for later review, e.g. after an
# unattended cron run), and attaches to it immediately if we're at an
# interactive terminal.
launch_and_attach() {
    local mode_label="$1"; shift
    local mode_args=("$@")

    require_tmux || { echo ">> tmux not available, aborting."; return 1; }

    if [ "$EUID" -ne 0 ]; then
        echo ">> ERROR: background mode requires root privileges (for the log directory & backup)."
        return 1
    fi

    # Check the mutex in addition to the tmux session: prevents a race
    # between a cron trigger and a manual start
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo ">> A task is already running in the background (session: $TMUX_SESSION)."
        echo ">> Attach with: sudo $0 -A"
        return 1
    fi

    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_DIR"
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local logfile="$LOG_DIR/${mode_label// /_}-${ts}.log"
    touch "$logfile"
    ln -sf "$logfile" "$LOG_DIR/latest.log"

    echo ">> Starting in the background: $mode_label (log: $logfile)"

    # Plain tmux session running the script directly -- a real pty, so
    # restic's normal terminal output (including live progress) works as
    # expected. The session ends on its own once the script exits.
    tmux new-session -d -s "$TMUX_SESSION" -- "$SCRIPT_PATH" "${mode_args[@]}"

    # Also capture a plain-text copy of the pane's output to a log file, so
    # unattended (e.g. cron-triggered) runs can still be reviewed later.
    tmux pipe-pane -t "$TMUX_SESSION" -o "cat >> '$logfile'"

    # Without a terminal (e.g. cron/systemd) don't attach -- just start and return
    if [ ! -t 1 ]; then
        echo ">> Started non-interactively, running in the background."
        return 0
    fi

    echo ">> Attaching... (detach with Ctrl+B, then D -- the task keeps running)"
    sleep 1
    tmux attach -t "$TMUX_SESSION"
}

attach_daemon() {
    require_tmux || { echo ">> tmux not available."; return 1; }

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo ">> Attaching to the running task... (detach with Ctrl+B, then D)"
        tmux attach -t "$TMUX_SESSION"
    else
        echo ">> No task is currently running in the background."
        if [ -f "$LOG_DIR/latest.log" ]; then
            echo ">> Last log (last 80 lines):"
            echo "------------------------------------------"
            tail -n 80 "$LOG_DIR/latest.log"
        else
            echo ">> No background task has been run yet."
        fi
    fi
}

# ==========================================
# systemd service management
# ==========================================
install_systemd_automatic() {
    cat > "$SYSTEMD_DIR/$SERVICE_NAME" << EOF
[Unit]
Description=Restic Backup Service (starts a background job via tmux)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH -f
StandardOutput=journal
StandardError=journal
Environment="HOME=/root"
# IMPORTANT: the actual backup process keeps running in its own tmux
# session, even after this oneshot unit is "done". KillMode=none prevents
# systemd from also killing the tmux session (which lives in the same
# cgroup) when it stops this unit.
KillMode=none
EOF

    cat > "$SYSTEMD_DIR/$TIMER_NAME" << EOF
[Unit]
Description=Restic Backup Timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$TIMER_NAME"
    echo ">> Auto-backup service installed."
    echo ">> Runs daily at 02:00 (plus up to a 5-minute random delay)."
    echo ">> Whether triggered by cron or started manually, it always runs in the"
    echo ">> same background session -- reconnect/logs any time with: sudo $0 -A"
    sleep 2
}

update_timer_settings() {
    clear
    echo "--- Adjust timer schedule ---"
    echo ""
    echo "   Examples of OnCalendar expressions:"
    echo "   *-*-* 02:00:00       Daily at 02:00"
    echo "   Mon *-*-* 03:00:00   Every Monday at 03:00"
    echo "   *-*-1 00:00:00       Monthly on the 1st at midnight"
    echo "   Sat,Sun *-*-* 04:00  Weekends at 04:00"
    echo ""

    if [ ! -f "$SYSTEMD_DIR/$TIMER_NAME" ]; then
        echo ">> ERROR: service not installed. Please use option 8 first."
        sleep 2; return
    fi

    local current_sched; current_sched=$(grep "OnCalendar" "$SYSTEMD_DIR/$TIMER_NAME" | cut -d'=' -f2)
    tui_input "New schedule" "$current_sched" "Systemd OnCalendar expression"
    local new_sched="$TUI_RESULT"

    sed -i "s|OnCalendar=.*|OnCalendar=$new_sched|" "$SYSTEMD_DIR/$TIMER_NAME"
    systemctl daemon-reload
    systemctl restart "$TIMER_NAME"
    echo ">> Schedule updated: $new_sched"
    sleep 2
}

# ==========================================
# Backup mode selection menu
# ==========================================
menu_run_vorgang() {
    clear
    echo "=========================================="
    echo "          START A BACKUP RUN              "
    echo "  (always runs in the background via tmux --"
    echo "   survives a lost connection)"
    echo "=========================================="
    echo "  1) Standard       Nice 10 | auto compression | SFTP x8"
    echo "  2) Full throttle (-f)  All CPUs | priority -15 | SFTP x16"
    echo "  3) Economy (-e)   1 CPU | idle I/O | SFTP x2"
    echo "  4) Dry run        Test run, NO real changes"
    echo "  5) Full throttle, no comp.  Like full throttle, no compression"
    echo "  0) Back"
    echo "=========================================="
    read -rp "  Choice: " vchoice

    FULL_RESOURCES=false; ECONOMY_MODE=false
    DRY_RUN_FLAG=""; NO_COMPRESSION=false

    case $vchoice in
        1) : ;;
        2) FULL_RESOURCES=true ;;
        3) ECONOMY_MODE=true ;;
        4) DRY_RUN_FLAG="--dry-run" ;;
        5) FULL_RESOURCES=true; NO_COMPRESSION=true ;;
        0) return ;;
        *) return ;;
    esac

    build_mode_args
    launch_and_attach "Backup" "${MODE_ARGS[@]}"
}

menu_action_unlock() {
    launch_and_attach "Unlock" "-u" "-Z"
}

menu_action_force_unlock() {
    launch_and_attach "Force_unlock" "-U" "-Z"
}

# ==========================================
# TUI: manage ntfy notifications
# Accessible directly from the main menu (N)
# Works even without an existing config
# ==========================================
menu_ntfy_settings() {
    require_jq

    # If no config exists yet: create a minimal ntfy section
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${C_YELLOW}  >> No main configuration exists yet.${C_RESET}\n"
        if tui_confirm "Create only the ntfy configuration (without full setup)?" "y"; then
            jq -n '{
                host: "",
                compression: "auto",
                retry_lock: "5m",
                unlock_retry_lock: "10m",
                stale_unlock_hours: 2,
                cache_dir: "~/.cache/restic",
                retention: { keep_daily: 31, keep_weekly: 4, keep_monthly: 6, keep_yearly: 0, keep_last: 0, prune: true },
                lock_state: { last_seen: "", last_unlock_attempt: "" },
                notifications: { ntfy: { enabled: false } },
                main: {},
                copies: []
            }' > "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
        else
            return
        fi
    fi

    while true; do
        clear
        local ntfy_en ntfy_url ntfy_topic ntfy_user
        ntfy_en=$(jq_bool    '.notifications.ntfy.enabled'       "$CONFIG_FILE")
        ntfy_url=$(jq -r     '.notifications.ntfy.url      // "https://ntfy.sh"' "$CONFIG_FILE")
        ntfy_topic=$(jq -r   '.notifications.ntfy.topic    // ""' "$CONFIG_FILE")
        ntfy_user=$(jq -r    '.notifications.ntfy.username // ""' "$CONFIG_FILE")

        local en_str
        [ "$ntfy_en" = "true" ] && en_str="$(col_ok 'Active')" \
                                 || en_str="$(col_warn '- Inactive')"

        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║    NTFY PUSH NOTIFICATIONS                ║${C_RESET}\n"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"
        printf "  ${C_BOLD}%-16s${C_RESET} %b\n"  "Status:"    "$en_str"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "Server:"    "$(col_info "$ntfy_url")"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "Topic:"     "$(col_info "${ntfy_topic:-<not set>}")"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "User:"      "${ntfy_user:-<none>}"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "Password:"  "****"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}1)${C_RESET}  Toggle enabled/disabled\n"
        printf "  ${C_BOLD}2)${C_RESET}  Change server URL\n"
        printf "  ${C_DIM}       e.g. https://ntfy.sh or self-hosted${C_RESET}\n"
        printf "  ${C_BOLD}3)${C_RESET}  Set topic\n"
        printf "  ${C_DIM}       Name of the topic in the ntfy app${C_RESET}\n"
        printf "  ${C_BOLD}4)${C_RESET}  Set user  ${C_DIM}(empty = no auth)${C_RESET}\n"
        printf "  ${C_BOLD}5)${C_RESET}  Set password\n"
        if [ "$ntfy_en" = "true" ] && [ -n "$ntfy_topic" ]; then
            printf "  ${C_BOLD}${C_GREEN}6)${C_RESET}  Send test message\n"
        fi
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}0)${C_RESET}  Back\n"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Choice: " nchoice

        case $nchoice in
            1)
                if [ "$ntfy_en" = "true" ]; then
                    config_set '.notifications.ntfy.enabled = false'
                    printf "${C_YELLOW}  >> Ntfy disabled.${C_RESET}\n"
                else
                    config_set '.notifications.ntfy.enabled = true'
                    printf "${C_GREEN}  >> Ntfy enabled.${C_RESET}\n"
                fi
                sleep 1 ;;
            2)
                echo ""
                echo "  ntfy server options:"
                printf "  ${C_DIM}• Public:       https://ntfy.sh${C_RESET}\n"
                printf "  ${C_DIM}• Self-hosted:  https://ntfy.your.domain${C_RESET}\n"
                tui_input "Server URL" "$ntfy_url" ""
                config_set_arg '.notifications.ntfy.url = $val' "$TUI_RESULT" ;;
            3)
                echo ""
                printf "  ${C_DIM}The topic is a unique name (e.g. 'my-server-alerts').${C_RESET}\n"
                printf "  ${C_DIM}You subscribe to this topic in the ntfy app.${C_RESET}\n"
                tui_input "Topic" "$ntfy_topic" ""
                config_set_arg '.notifications.ntfy.topic = $val' "$TUI_RESULT" ;;
            4)
                echo ""
                printf "  ${C_DIM}Only needed for protected/self-hosted servers.${C_RESET}\n"
                tui_input "User" "$ntfy_user" "Leave empty if no login is needed"
                config_set_arg '.notifications.ntfy.username = $val' "$TUI_RESULT" ;;
            5)
                tui_input "Password" "" "Ntfy login password" "true"
                [ -n "$TUI_RESULT" ] && config_set_arg '.notifications.ntfy.password = $val' "$TUI_RESULT" ;;
            6)
                if [ "$ntfy_en" = "true" ] && [ -n "$ntfy_topic" ]; then
                    ntfy_send_test
                fi ;;
            0) return ;;
        esac
    done
}

# ==========================================
# Main settings menu
# ==========================================
menu_settings() {
    if [ "$EUID" -ne 0 ]; then
        printf "${C_RED}>> ERROR: root privileges required.${C_RESET}\n"
        echo ">> Please run with: sudo $0 -s"
        exit 1
    fi

    require_jq
    migrate_env_to_json

    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${C_YELLOW}>> No configuration found. Starting initial setup...${C_RESET}\n"
        sleep 1
        do_setup_wizard
    fi

    while true; do
        clear

        # -- gather status ---------------------------------------------------
        local svc_ok=false; [ -f "$SYSTEMD_DIR/$SERVICE_NAME" ] && svc_ok=true
        local timer_active=false
        systemctl is-active --quiet "$TIMER_NAME" 2>/dev/null && timer_active=true

        local current_sched="-"
        $svc_ok && current_sched=$(grep "OnCalendar" "$SYSTEMD_DIR/$TIMER_NAME" \
            2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "-")

        local r_host r_comp main_type copy_count ntfy_active ntfy_topic
        r_host=$(jq -r      '.host               // "?"'    "$CONFIG_FILE")
        r_comp=$(jq -r      '.compression        // "auto"' "$CONFIG_FILE")
        main_type=$(jq -r   '.main.type          // "?"'    "$CONFIG_FILE")
        main_host=$(jq -r   '.main.host          // ""'     "$CONFIG_FILE")
        copy_count=$(jq     '.copies | length'              "$CONFIG_FILE" 2>/dev/null || echo 0)
        ntfy_active=$(jq_bool '.notifications.ntfy.enabled' "$CONFIG_FILE")
        ntfy_topic=$(jq -r  '.notifications.ntfy.topic // ""' "$CONFIG_FILE")

        # Count active copy repos
        local enabled_copies=0
        for _i in $(seq 0 $((copy_count - 1))); do
            [ "$(jq_bool ".copies[$_i].enabled" "$CONFIG_FILE")" = "true" ] \
                && enabled_copies=$((enabled_copies + 1))
        done

        # -- colored status strings ------------------------------------------
        local tmr_str ntfy_str comp_str

        if $timer_active; then
            tmr_str="$(col_ok "Active") $(col_info "[$current_sched]")"
        elif $svc_ok; then
            tmr_str="$(col_warn 'Paused')"
        else
            tmr_str="$(col_err 'Not set up')"
        fi

        if [ "$ntfy_active" = "true" ]; then
            ntfy_str="$(col_ok 'On')"
            [ -n "$ntfy_topic" ] && ntfy_str+=" $(col_info "(Topic: $ntfy_topic)")"
        else
            ntfy_str="$(col_warn '- Off')"
        fi

        case "$r_comp" in
            auto) comp_str="$(col_ok 'auto')" ;;
            max)  comp_str="$(col_warn 'max')" ;;
            off)  comp_str="$(col_err 'off')" ;;
            *)    comp_str="$r_comp" ;;
        esac

        local main_str copy_str
        if [ "$main_type" = "?" ] || [ -z "$main_type" ]; then
            main_str="$(col_err 'Not configured')"
        else
            main_str="$(col_ok "$main_type")"
            [ -n "$main_host" ] && main_str+=" $(col_info "-> $main_host")"
        fi

        if [ "$copy_count" -eq 0 ]; then
            copy_str="$(col_dim '- none')"
        else
            copy_str="$(col_ok "$enabled_copies") of $(col_info "$copy_count") active"
        fi

        # -- header ------------------------------------------------------------
        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║    RESTIC BACKUP MANAGER  v%-4s          ║${C_RESET}\n" "$SCRIPT_VERSION"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"

        # -- status panel --------------------------------------------------------
        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Host:"        "$(col_info "$r_host")"

        local restic_ver_str restic_lock_warn=""
        restic_ver_str=$(get_restic_version)
        restic_supports_retry_lock || restic_lock_warn=" $(col_warn '(update recommended)')"
        printf "  ${C_BOLD}%-14s${C_RESET} %s%s\n" "Restic:" "$(col_info "$restic_ver_str")" "$restic_lock_warn"

        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Compression:" "$comp_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Main repo:"   "$main_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Copy repos:"  "$copy_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %b\n"  "Ntfy:"        "$ntfy_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %b\n"  "Auto-backup:" "$tmr_str"

        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"

        # -- menu --------------------------------------------------------------
        printf "  ${C_BOLD}${C_GREEN}B)${C_RESET}  Start a backup run\n"
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            printf "  ${C_BOLD}${C_GREEN}A)${C_RESET}  Attach to the running task / logs\n"
            printf "  ${C_BOLD}${C_RED}X)${C_RESET}  Cancel the running task\n"
        fi
        printf "${C_DIM}  ── Snapshots & maintenance ───────────────${C_RESET}\n"
        printf "  ${C_BOLD}1)${C_RESET}  Snapshots for this host\n"
        printf "  ${C_BOLD}2)${C_RESET}  Snapshots for ${C_BOLD}ALL${C_RESET} hosts\n"
        printf "  ${C_BOLD}3)${C_RESET}  Unlock repositories\n"
        printf "  ${C_BOLD}F)${C_RESET}  Repository force-unlock\n"
        printf "  ${C_BOLD}4)${C_RESET}  Check repository init\n"
        printf "  ${C_BOLD}C)${C_RESET}  Cleanup / prune\n"
        printf "  ${C_BOLD}R)${C_RESET}  Update restic\n"
        printf "${C_DIM}  ── Configuration ─────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}5)${C_RESET}  Edit configuration\n"
        printf "  ${C_BOLD}6)${C_RESET}  Restart initial setup\n"
        printf "  ${C_BOLD}7)${C_RESET}  Manage copy repos\n"
        printf "  ${C_BOLD}8)${C_RESET}  Add a new copy repository\n"
        printf "  ${C_BOLD}E)${C_RESET}  Edit folder excludes\n"
        printf "  ${C_BOLD}N)${C_RESET}  Ntfy notifications\n"
        printf "${C_DIM}  ── Auto-backup ───────────────────────────${C_RESET}\n"
        if $svc_ok; then
            printf "  ${C_BOLD}9)${C_RESET}  Adjust schedule\n"
            if $timer_active; then
                printf " ${C_BOLD}10)${C_RESET}  Pause\n"
            else
                printf " ${C_BOLD}10)${C_RESET}  Enable\n"
            fi
            printf " ${C_BOLD}11)${C_RESET}  Remove\n"
        else
            printf "  ${C_BOLD}9)${C_RESET}  Set up\n"
        fi
        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}0)${C_RESET}  Exit\n"
        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Choice: " schoice

        case $schoice in
            [Bb]) menu_run_vorgang ;;
            [Aa]) attach_daemon ;;
            [Xx]) cancel_running_task ;;
            1)    menu_action_unlock_view() { :; }; run_action_all_repos "snapshots" ;;
            2)    run_action_all_repos "snapshots_all" ;;
            3)    menu_action_unlock ;;
            [Ff]) menu_action_force_unlock ;;
            4)    run_action_all_repos "init" ;;
            [Cc]) run_manual_cleanup ;;
            [Rr]) update_restic ;;
            5)    menu_edit_configs ;;
            6)    do_setup_wizard ;;
            7)    menu_toggle_copies ;;
            8)    add_copy_repo_wizard ;;
            [Ee]) menu_exclude_settings ;;
            [Nn]) menu_ntfy_settings ;;
            9)
                if $svc_ok; then update_timer_settings; else install_systemd_automatic; fi ;;
            10)
                if $svc_ok; then
                    if $timer_active; then
                        systemctl disable --now "$TIMER_NAME"
                        printf "${C_YELLOW}>> Auto-backup paused.${C_RESET}\n"
                    else
                        systemctl enable --now "$TIMER_NAME"
                        printf "${C_GREEN}>> Auto-backup started.${C_RESET}\n"
                    fi
                    sleep 1
                fi ;;
            11)
                if $svc_ok && tui_confirm "Really remove the service completely?" "n"; then
                    systemctl disable --now "$TIMER_NAME" 2>/dev/null || true
                    rm -f "$SYSTEMD_DIR/$SERVICE_NAME" "$SYSTEMD_DIR/$TIMER_NAME"
                    systemctl daemon-reload
                    printf "${C_GREEN}>> Service removed.${C_RESET}\n"
                    sleep 1
                fi ;;
            0) exit 0 ;;
        esac
    done
}

# ==========================================
# Install the script system-wide (-i)
# ==========================================
install_script() {
    if [ "$EUID" -ne 0 ]; then
        echo ">> ERROR: please run with 'sudo $0 -i' to install the script."
        exit 1
    fi

    local target="/usr/local/bin/restic-backup"

    echo ">> Installing script to $target ..."
    cp "$SCRIPT_PATH" "$target"
    chmod +x "$target"

    # Copy an existing configuration, if present
    if [ -f "$CONFIG_FILE" ]; then
        echo ">> Copying existing configuration to /etc/restic_backup.json ..."
        cp "$CONFIG_FILE" "/etc/restic_backup.json"
        chmod 600 "/etc/restic_backup.json"
    fi

    # If a very old .env file still exists
    if [ -f "$OLD_CONFIG_FILE" ]; then
        echo ">> Copying old .env configuration to /etc/restic_backup.env ..."
        cp "$OLD_CONFIG_FILE" "/etc/restic_backup.env"
        chmod 600 "/etc/restic_backup.env"
    fi

    # Point the config location in the installed file to /etc
    sed -i 's|CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.json"|CONFIG_FILE="/etc/restic_backup.json"|' "$target"
    sed -i 's|OLD_CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.env"|OLD_CONFIG_FILE="/etc/restic_backup.env"|' "$target"

    echo ">> Installation successful!"
    echo ">> You can now start the backup tool from anywhere with the command 'restic-backup'."
    echo ">> The configuration file will now be stored at '/etc/restic_backup.json'."

    # Alias option
    echo ""
    read -rp ">> Would you like to set up an additional alias command? (empty = no): " alias_name
    if [ -n "$alias_name" ]; then
        local alias_target="/usr/local/bin/$alias_name"
        if [ -e "$alias_target" ]; then
            echo ">> WARNING: '$alias_target' already exists and will not be overwritten."
        else
            ln -s "$target" "$alias_target"
            echo ">> Alias '$alias_name' -> '$target' set up."
            echo ">> You can now also start the tool with '$alias_name'."
        fi
    fi
    exit 0
}

# ==========================================
# Help
# ==========================================
show_help() {
    local S; S=$(basename "$0")
    local CFG; CFG="$(dirname "$(realpath "$0")")/.restic_backup.json"
    cat << HELPEOF

══════════════════════════════════════════════════════════
  Restic Multi-Repo Backup Manager  v$SCRIPT_VERSION
  Encrypted system backup -- multiple backup targets
══════════════════════════════════════════════════════════

USAGE:  $S [FLAGS]    (flags can be combined)

── BACKUP MODES ───────────────────────────────────────────
  -r   Standard backup
         nice 10 | auto compression | SFTP: 8 connections
         Recommended for the systemd timer / daily operation

  -f   Full-throttle mode
         All CPU cores | priority -15 | SFTP: 16 connections
         Fastest backup, high system load

  -e   Economy mode
         1 core | priority 19 | idle I/O | SFTP: 2 connections
         Runs unobtrusively in the background

  -n   No compression   (combinable with -f / -e)
         Useful for already-compressed data:
         videos, JPEGs, zip archives, encrypted files

  -x   Large pack format   (combinable)
         --pack-size 128 -> fewer, larger pack files
         Better for HDDs / slow connections

  -d   Dry run / test run
         Shows what would happen -- changes absolutely nothing
         No data transfer, no snapshot created

── BACKGROUND / ATTACH ─────────────────────────────────────
  Every backup start (-r/-f/-e/-n/-x/-d), unlock (-u), and force-unlock
  (-U) automatically runs in the background (a plain tmux session) --
  survives logout and connection loss, whether triggered manually or by
  the auto-backup timer. Requires root and tmux (installed automatically
  if needed).

  This is a genuinely normal tmux session:
  - Attach:  sudo $S -A   (or: tmux attach -t $TMUX_SESSION)
  - Detach:  Ctrl+B, then D  -- the task keeps running in the background
  - X (in the TUI menu)  Actually cancel the running task
         Sends SIGTERM to the worker process; for a backup, the shutdown
         trap unlocks the repos cleanly before it exits.

── SNAPSHOT LISTING ───────────────────────────────────────
  -l   Snapshots for this host
  -L   Snapshots for ALL hosts

── MAINTENANCE ────────────────────────────────────────────
  -u   Unlock repositories (runs in the background, like a backup)
         Removes lock files after a crash / kill

  -U   Repository force-unlock (--remove-all, runs in the background)
         Removes ALL locks, including ones restic itself doesn't
         recognize as "stale" (e.g. for REST-server repos accessed
         from multiple hosts). Only use when you're sure no backup
         is currently running!

  -I   Initialize / check the repository

  -C   Cleanup / prune (TUI menu: preview, run, prune-only,
         clean up the local restic cache)
         Uses the retention rules configured in settings
         (keep-daily/-weekly/-monthly/...)

── SYSTEM ─────────────────────────────────────────────────
  -i   Install the script system-wide
         Copies the script to /usr/local/bin/restic-backup

  -s   TUI settings menu  (requires sudo)

  -h   Show this help

── COMBINATION EXAMPLES ───────────────────────────────────
  $S -r            Normal daily backup (runs in the background)
  $S -f -n         Full throttle, data already compressed
  $S -e -d         Economy-mode test run, no changes
  $S -l            List snapshots for this host
  $S -u            After a crash: unlock repos
  $S -U            Emergency: force-unlock a repo
  sudo $S -s       TUI menu for setup & management
  sudo $S -A       Attach to a running task (cron or manual)

── SFTP CONNECTIONS ───────────────────────────────────────
  Mode         Connections   Nice   CPU cores   I/O class
  Standard      8            10     all         normal
  Full throttle 16          -15     all         normal
  Economy       2            19     1           idle (3)

  SFTP-to-SFTP copy (main + copy both SFTP):
  • Main repo:  sshpass -e  (SSHPASS environment variable)
  • Copy repo:  sshpass -f <tmpfile>  (no env conflict)
  • Requires restic >= 0.14 for --from-option

── RETENTION RULES (automatic after every backup) ─────────
  Default values (adjustable in the TUI settings):
  --keep-daily   31   last month: daily
  --keep-weekly   4   last 4 weeks: weekly
  --keep-monthly  6   last 6 months: monthly
  Older snapshots get deleted, then optionally --prune
  Applies to the main repo and all active copy repos
  Run manually with a preview: $S -C  (or TUI: C)

── RETRY-LOCK SETTINGS ────────────────────────────────────
  There are TWO separate wait times (both in the TUI settings):
  • Retry-lock (backup/forget/copy): can be long (e.g. 20h),
    since these operations should genuinely wait for another
    running task to finish.
  • Unlock-retry-lock (ONLY for unlock/lock-check calls):
    deliberately short (default 10m) -- prevents unlocking
    itself from hanging for hours while waiting on the very
    lock it's supposed to remove.

── CONFIGURATION FILE ─────────────────────────────────────
  Path:          $CFG
  Permissions:   600 (root-readable only, passwords protected)
  Format:        JSON (processed with jq)
  Edit:          sudo $S -s  -> "Edit configuration"

── REQUIREMENTS ───────────────────────────────────────────
  Required:  restic >= 0.14, jq, curl
  For SFTP:  sshpass
  For push:  curl (ntfy.sh notifications)
  Setup:     sudo $S -s  (installs any missing tools)

══════════════════════════════════════════════════════════

HELPEOF
    exit 0
}

# ==========================================
# CLI entry point
# ==========================================

RUN_BACKUP=false
RUN_UNLOCK=false
RUN_FORCE_UNLOCK=false
SHOW_SETTINGS=false
INIT_REPO=false
INTERNAL_WORKER=false

# No arguments -> show help
if [ $# -eq 0 ]; then
    show_help
fi

# getopts string: 'i' for install, 'I' for init, 'b' kept for compatibility
# (background is now always on), 'A' for attach, 'U' for force-unlock,
# 'C' for cleanup, 'Z' internal worker marker (undocumented)
while getopts "hsfexrdnuIiLlbAUCZ" opt; do
    case $opt in
        h) show_help ;;
        s) SHOW_SETTINGS=true ;;
        I) INIT_REPO=true ;;
        i) install_script ;;
        r) RUN_BACKUP=true ;;
        f) FULL_RESOURCES=true;  RUN_BACKUP=true ;;
        e) ECONOMY_MODE=true;    RUN_BACKUP=true ;;
        x) EXTRA_RESOURCES=true; RUN_BACKUP=true ;;
        d) DRY_RUN_FLAG="--dry-run"; RUN_BACKUP=true ;;
        n) NO_COMPRESSION=true ;;
        b) : ;;  # -b is now default behavior, flag kept valid for compatibility
        A) attach_daemon; exit 0 ;;
        u) RUN_UNLOCK=true ;;
        U) RUN_FORCE_UNLOCK=true ;;
        C) run_manual_cleanup; exit 0 ;;
        l) run_action_all_repos "snapshots";     exit 0 ;;
        L) run_action_all_repos "snapshots_all"; exit 0 ;;
        Z) INTERNAL_WORKER=true ;;  # internal: set by launch_and_attach inside tmux
        *) show_help ;;
    esac
done

if $INIT_REPO; then
    run_action_all_repos "init"
    exit 0
fi

if $SHOW_SETTINGS; then
    menu_settings
    exit 0
fi

# Unlock and force-unlock now also run in the background (plain tmux
# session), the same way a backup does -- unless we're already the
# internal worker running inside that session.
if $RUN_UNLOCK && ! $INTERNAL_WORKER; then
    launch_and_attach "Unlock" "-u" "-Z"
    exit $?
fi
if $RUN_UNLOCK; then
    run_action_all_repos "unlock"
    exit 0
fi

if $RUN_FORCE_UNLOCK && ! $INTERNAL_WORKER; then
    launch_and_attach "Force_unlock" "-U" "-Z"
    exit $?
fi
if $RUN_FORCE_UNLOCK; then
    require_jq
    migrate_env_to_json
    force_unlock_repo
    exit 0
fi

# Every backup start now always runs in the background -- unless this is
# already the internal worker call running inside the tmux session.
if $RUN_BACKUP && ! $INTERNAL_WORKER; then
    build_mode_args
    launch_and_attach "Backup" "${MODE_ARGS[@]}"
    exit $?
fi

if $RUN_BACKUP; then
    run_backup "CLI mode"
    exit 0
fi

show_help