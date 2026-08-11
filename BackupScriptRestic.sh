#!/bin/bash
export HOME="${HOME:-/root}"

# =============================================================================
# Restic Multi-Repo Backup Script
# Vollständige TUI-Konfiguration, kein externer Editor benötigt
# Erfordert: restic >= 0.14, jq, curl, sshpass (für SFTP)
# =============================================================================

# Einzige Stelle für die Versionsnummer -- wird überall (Titel, Hilfe, etc.)
# von hier referenziert, damit sie nur an einem Ort gepflegt werden muss.
SCRIPT_VERSION="3.0"

SCRIPT_PATH="$(realpath "$0")"
CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.json"
OLD_CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.env"

SERVICE_NAME="restic-sftp-backup.service"
TIMER_NAME="restic-sftp-backup.timer"
SYSTEMD_DIR="/etc/systemd/system"

# Hintergrund-Modus (tmux) -- laeuft wie ein Daemon weiter
TMUX_SESSION="restic-backup"
LOG_DIR="/var/log/restic-backup"

FULL_RESOURCES=false
ECONOMY_MODE=false
EXTRA_RESOURCES=false
DRY_RUN_FLAG=""
NO_COMPRESSION=false

# Eigener Mutex, damit sich zwei Läufe des Skripts (z.B. Cron + manuell)
# niemals überlappen und dadurch scheinbar "stale" Repo-Locks erzeugen
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

# Globals for shutdown trap — track currently active repo
CURRENT_REPO_URL=""
CURRENT_REPO_PW_FILE=""
CURRENT_REPO_OPTS=()

# ==========================================
# Farb-Konstanten (ANSI)
# ==========================================
C_RED="\033[0;31m"
C_GREEN="\033[0;32m"
C_YELLOW="\033[0;33m"
C_BLUE="\033[0;34m"
C_CYAN="\033[0;36m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RESET="\033[0m"

# Hilfsfunktionen für farbige Ausgabe
col_ok()   { printf "${C_GREEN}%s${C_RESET}" "$*"; }
col_err()  { printf "${C_RED}%s${C_RESET}" "$*"; }
col_warn() { printf "${C_YELLOW}%s${C_RESET}" "$*"; }
col_info() { printf "${C_CYAN}%s${C_RESET}" "$*"; }
col_bold() { printf "${C_BOLD}%s${C_RESET}" "$*"; }
col_dim()  { printf "${C_DIM}%s${C_RESET}"  "$*"; }

# ==========================================
# Hilfsfunktionen
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
        echo ">> 'jq' wird benötigt, ist aber nicht installiert."
        if [ "$EUID" -ne 0 ]; then
            echo ">> Bitte als root ausführen oder jq manuell installieren."
            exit 1
        fi
        echo ">> Installiere jq..."
        if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y jq curl
        elif command -v dnf     &>/dev/null; then dnf install -y jq curl
        elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm jq curl
        elif command -v zypper  &>/dev/null; then zypper install -y jq curl
        else echo ">> Unbekannter Paketmanager. Bitte jq manuell installieren."; exit 1; fi
    fi
}

require_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        echo ">> 'sshpass' wird für SFTP benötigt, ist aber nicht installiert."
        if [ "$EUID" -ne 0 ]; then
            echo ">> Bitte als root ausführen oder sshpass manuell installieren."; return 1
        fi
        echo ">> Installiere sshpass..."
        if   command -v apt-get &>/dev/null; then apt-get install -y sshpass
        elif command -v dnf     &>/dev/null; then dnf install -y sshpass
        elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm sshpass
        elif command -v zypper  &>/dev/null; then zypper install -y sshpass
        else echo ">> Bitte sshpass manuell installieren."; return 1; fi
    fi
}

require_tmux() {
    if ! command -v tmux &>/dev/null; then
        echo ">> 'tmux' wird fuer den Hintergrund-Modus benoetigt, ist aber nicht installiert."
        if [ "$EUID" -ne 0 ]; then
            echo ">> Bitte als root ausfuehren oder tmux manuell installieren."; return 1
        fi
        echo ">> Installiere tmux..."
        if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y tmux
        elif command -v dnf     &>/dev/null; then dnf install -y tmux
        elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm tmux
        elif command -v zypper  &>/dev/null; then zypper install -y tmux
        elif command -v apk     &>/dev/null; then apk add tmux
        else echo ">> Unbekannter Paketmanager. Bitte tmux manuell installieren."; return 1; fi
    fi
}

# ---------------------------------------------------------------------------
# tui_input "Label" "aktueller_wert" "Beschreibung" [secret=false]
# Ergebnis steht in $TUI_RESULT. Enter = aktuellen Wert beibehalten.
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
            display_current=" [aktuell: ****]"
        else
            display_current=" [aktuell: $current]"
        fi
    fi

    if [ "$secret" = "true" ]; then
        local _pw
        _pw=$(read_password_with_asterisks "   $label${display_current}: ")
        TUI_RESULT="$_pw"
    else
        read -rp "   $label${display_current}: " TUI_RESULT
    fi

    # Aktuellen Wert beibehalten wenn Enter gedrueckt und ein Wert existiert
    if [ -z "$TUI_RESULT" ] && [ -n "$current" ] && [ "$current" != "null" ]; then
        TUI_RESULT="$current"
    fi
}

# Ja/Nein-Abfrage. Gibt 0 (true) für Ja, 1 (false) für Nein zurück.
tui_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local hint="[j/N]"
    [[ "$default" =~ ^[Jj]$ ]] && hint="[J/n]"
    local answer
    read -rp "   $prompt $hint: " answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[JjYy]$ ]]
}

# ---------------------------------------------------------------------------
# Sichere Konfig-Schreibfunktionen (atomares Schreiben via mktemp)
# ---------------------------------------------------------------------------
config_set() {
    local jq_filter="$1"
    local tmp_file; tmp_file=$(mktemp)
    if jq "$jq_filter" "$CONFIG_FILE" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        rm -f "$tmp_file"
        echo ">> FEHLER: Config-Schreiben fehlgeschlagen (Filter: $jq_filter)"
        return 1
    fi
}

config_set_arg() {
    # Nutzt --arg um Sonderzeichen im Wert sicher zu behandeln
    local jq_filter="$1"
    local value="$2"
    local tmp_file; tmp_file=$(mktemp)
    if jq --arg val "$value" "$jq_filter" "$CONFIG_FILE" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        rm -f "$tmp_file"
        echo ">> FEHLER: Config-Schreiben fehlgeschlagen (Filter: $jq_filter)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# jq_bool FILTER FILE
# Liest einen JSON-Boolean sicher aus: gibt "true" oder "false" zurück.
# WICHTIG: jq-Bug: false // "default" = "default" weil false falsy ist!
# Diese Funktion umgeht das durch expliziten Vergleich.
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

# Builds --exclude=... args from config (.excludes array), falls back to DEFAULT_EXCLUDES.
# Result is written into the RESTIC_EXCLUDE_ARGS array (caller must declare it).
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
        echo ">> Alte .env Konfiguration gefunden. Starte Migration zu JSON..."
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
        echo ">> Migration abgeschlossen. Alte Datei als .env.bak gesichert."
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
            title="Backup Netzwerk-Fehler: ${host}"
            tags="warning"
            ;;
        lock)
            title="Backup Repo gesperrt: ${host}"
            tags="warning"
            ;;
        cache)
            title="Backup Cache-Fehler: ${host}"
            tags="warning"
            ;;
        shutdown)
            title="Backup unterbrochen: ${host}"
            tags="warning"
            ;;
        unlock)
            title="Backup Auto-Unlock: ${host}"
            tags="information"
            ;;
        *)
            title="Backup Fehler: ${host}"
            tags="warning"
            ;;
    esac

    local msg="Restic Fehler (${exit_code}) bei: ${action_label}"
    if [ -n "$error_log" ] && [ -f "$error_log" ]; then
        msg+=$'\n\nLetzte Log-Einträge:\n'"$(tail -n 10 "$error_log")"
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

# Returns kurze restic-Version (z.B. "0.17.0") oder "nicht installiert"
get_restic_version() {
    if command -v restic &>/dev/null; then
        restic version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    else
        echo "nicht installiert"
    fi
}

# Convert restic duration string to seconds (e.g. "5m" -> 300, "1h" -> 3600)
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
        *) echo 300 ;;  # default 5 min
    esac
}

# Loads --retry-lock and --cache-dir into RESTIC_EXTRA_OPTS array
# Call once before running restic commands
load_restic_extra_opts() {
    RESTIC_EXTRA_OPTS=()
    if restic_supports_retry_lock; then
        local retry_lock; retry_lock=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE" 2>/dev/null || echo "5m")
        RESTIC_EXTRA_OPTS+=(--retry-lock "$retry_lock")
    fi

    local cache_dir; cache_dir=$(jq -r '.cache_dir // "~/.cache/restic"' "$CONFIG_FILE" 2>/dev/null || echo "~/.cache/restic")
    if [ -n "$cache_dir" ] && [ "$cache_dir" != "~/.cache/restic" ]; then
        cache_dir="${cache_dir/#\~/$HOME}"
        RESTIC_EXTRA_OPTS+=(--cache-dir "$cache_dir")
    fi
}

RESTIC_EXTRA_OPTS=()

# ==========================================
# Aufbewahrungsregeln (retention) aus Config lesen
# Ergebnis in RETENTION_ARGS (Array, vom Aufrufer deklariert)
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

# true wenn nach forget automatisch geprunt werden soll (Default: an)
retention_prune_enabled() {
    [ "$(jq_bool '.retention.prune' "$CONFIG_FILE" 2>/dev/null)" = "true" ]
}

# ==========================================
# Skript-Mutex: verhindert ueberlappende Laeufe
# (z.B. Cron + manueller Start), die sonst wie
# ein "stale" Repo-Lock aussehen wuerden
# ==========================================
acquire_script_lock() {
    eval "exec ${SCRIPT_LOCK_FD}>\"$SCRIPT_LOCKFILE\"" 2>/dev/null || return 0
    if ! flock -n "$SCRIPT_LOCK_FD"; then
        echo ">> FEHLER: Es läuft bereits ein Backup-Vorgang dieses Skripts."
        echo ">> (Lockfile: $SCRIPT_LOCKFILE)"
        echo ">> Das ist vermutlich die Ursache für den 'Repo gesperrt'-Fehler —"
        echo ">> nicht ein alter/verwaister Lock, sondern ein wirklich laufendes Backup."
        echo ">> Prüfe z.B.: tmux has-session -t $TMUX_SESSION ; ps aux | grep restic"
        exit 1
    fi
    echo $$ >&"$SCRIPT_LOCK_FD"
}

release_script_lock() {
    flock -u "$SCRIPT_LOCK_FD" 2>/dev/null || true
    eval "exec ${SCRIPT_LOCK_FD}>&-" 2>/dev/null || true
}

# ==========================================
# Force-Unlock: entfernt ALLE Locks (--remove-all),
# auch solche die restic selbst nicht als "stale"
# erkennen kann (z.B. weil sie von einem anderen
# Host/Container gesetzt wurden). Nur manuell nutzen,
# wenn sicher ist, dass kein Backup wirklich läuft!
# ==========================================
force_unlock_repo() {
    echo "=========================================="
    echo "   FORCE-UNLOCK (--remove-all)"
    echo "=========================================="
    echo "  ACHTUNG: Entfernt ALLE Locks im Repo, auch wenn restic"
    echo "  sie nicht selbst als 'stale' erkennt. Nur ausführen,"
    echo "  wenn du SICHER bist, dass kein Backup aktuell läuft!"
    echo "------------------------------------------"
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo "  WARNUNG: Es läuft gerade ein Hintergrund-Backup (tmux: $TMUX_SESSION)!"
        echo "  Bitte erst prüfen (sudo $0 -A), bevor du fortfährst."
    fi
    if [ -f "$SCRIPT_LOCKFILE" ] && ! flock -n -x "$SCRIPT_LOCKFILE" -c true 2>/dev/null; then
        echo "  WARNUNG: Ein anderer Lauf dieses Skripts hält gerade den Mutex."
    fi
    read -rp "  Wirklich ALLE Locks entfernen? (ja/nein): " confirm
    if [ "$confirm" != "ja" ]; then
        echo "  Abgebrochen."
        sleep 1; return
    fi

    if load_repo_context "main"; then
        if restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock --remove-all; then
            echo ">> Alle Locks entfernt."
        else
            echo ">> FEHLER: Force-Unlock fehlgeschlagen."
        fi
        cleanup_repo_context
    else
        echo ">> FEHLER: Main-Repo nicht konfiguriert."
    fi
    read -rp "  Weiter mit Enter..."
}

# ==========================================
# Restic-Ausfuehrung mit Fehlerbehandlung
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
            echo ">> NETZWERK-FEHLER erkannt. Backup wird sauber beendet — Timer läuft beim nächsten Mal weiter."
        elif echo "$stderr" | grep -qiE "cache|cache directory|unable to create cache|cache dir"; then
            category="cache"
            echo ">> CACHE-FEHLER erkannt."
        elif echo "$stderr" | grep -qiE "already locked|repository is already locked|unable to create lock|lock exists"; then
            category="lock"
            echo ">> REPO GESPERRT — Lock besteht bereits."
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
# Shutdown-Trap: Repo entsperren beim Herunterfahren
# ==========================================
cleanup_on_shutdown() {
    echo ""
    echo "=========================================="
    echo ">> SYSTEM SHUTDOWN erkannt! Entsperre Repos..."
    echo "=========================================="
    local retry_lock; retry_lock=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE" 2>/dev/null || echo "5m")
    local RETRY_ARR=()
    restic_supports_retry_lock && RETRY_ARR=(--retry-lock "$retry_lock")

    if [ -n "$CURRENT_REPO_URL" ] && [ -n "$CURRENT_REPO_PW_FILE" ]; then
        echo ">> Entsperre aktives Repo..."
        restic "${RETRY_ARR[@]}" "${CURRENT_REPO_OPTS[@]}" -r "$CURRENT_REPO_URL" \
            --password-file "$CURRENT_REPO_PW_FILE" unlock 2>/dev/null || true
    fi
    if [ -n "$MAIN_URL" ] && [ -n "$MAIN_PW_FILE" ] && [ "$MAIN_URL" != "$CURRENT_REPO_URL" ]; then
        echo ">> Entsperre Main-Repo..."
        restic "${RETRY_ARR[@]}" "${MAIN_OPTS[@]}" -r "$MAIN_URL" \
            --password-file "$MAIN_PW_FILE" unlock 2>/dev/null || true
    fi

    notify_error 0 "Backup durch System-Shutdown unterbrochen" "" "shutdown"
    echo ">> Repos entsperrt. Skript wird beendet."
    exit 0
}

# ==========================================
# Auto-Unlock: Repo entsperren wenn zu lange gesperrt
# ==========================================
auto_unlock_if_stale() {
    local last_seen last_unlock
    last_seen=$(jq -r '.lock_state.last_seen // ""' "$CONFIG_FILE" 2>/dev/null)
    last_unlock=$(jq -r '.lock_state.last_unlock_attempt // ""' "$CONFIG_FILE" 2>/dev/null)

    # Kein vorheriger Lock erkannt -> nichts zu tun
    [ -z "$last_seen" ] || [ "$last_seen" = "null" ] && return 0

    # Bereits nach dem letzten Lock entsperrt -> nichts zu tun
    if [ -n "$last_unlock" ] && [ "$last_unlock" != "null" ]; then
        local unlock_ts seen_ts
        unlock_ts=$(date -d "$last_unlock" +%s 2>/dev/null || echo 0)
        seen_ts=$(date -d "$last_seen" +%s 2>/dev/null || echo 0)
        [ "$unlock_ts" -gt "$seen_ts" ] && return 0
    fi

    # Schwelle konfigurierbar (Standard 2h statt 24h — bei REST-Server-Repos
    # erkennt "restic unlock" ohne --remove-all einen Lock oft nicht als
    # stale, z.B. wenn er nicht vom aktuellen Host stammt; 24h Wartezeit
    # blockiert dann unnötig lange tägliche Backups)
    local stale_hours; stale_hours=$(jq -r '.stale_unlock_hours // 2' "$CONFIG_FILE" 2>/dev/null)
    [[ "$stale_hours" =~ ^[0-9]+$ ]] || stale_hours=2

    local now_ts seen_ts
    now_ts=$(date +%s)
    seen_ts=$(date -d "$last_seen" +%s 2>/dev/null || echo 0)
    local age_hours=$(( (now_ts - seen_ts) / 3600 ))
    [ "$age_hours" -lt "$stale_hours" ] && return 0

    echo ">> Repo seit ${age_hours}h gesperrt (>${stale_hours}h). Versuche Auto-Unlock..."

    # Erst normaler (sicherer) Unlock, dann --remove-all als harter Fallback:
    # nach $stale_hours Stunden ist ein noch echter, laufender Backup-Lauf
    # praktisch ausgeschlossen (der Skript-Mutex verhindert Überlappungen
    # ohnehin), daher ist --remove-all hier vertretbar.
    if load_repo_context "main"; then
        if restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock 2>/dev/null; then
            echo ">> Main-Repo erfolgreich entsperrt (Auto-Unlock nach ${age_hours}h)."
        elif restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock --remove-all 2>/dev/null; then
            echo ">> Main-Repo mit --remove-all entsperrt (normaler Unlock hat Lock nicht als stale erkannt)."
        else
            echo ">> WARNUNG: Auto-Unlock des Main-Repos fehlgeschlagen."
        fi
        cleanup_repo_context
    fi

    # Update timestamp
    local now_iso; now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    config_set_arg '.lock_state.last_unlock_attempt = $val' "$now_iso"

    local host; host=$(get_hostname)
    notify_error 0 "Repo war ${age_hours}h gesperrt — Auto-Unlock durchgeführt" "" "unlock"
}

# Periodic unlock retry loop: keep trying unlock until repo is accessible or timeout
pre_backup_unlock_retry() {
    local repo_url="$1" repo_pw="$2"
    shift 2
    local repo_opts=("$@")
    local timeout_str; timeout_str=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE" 2>/dev/null || echo "5m")
    local timeout_secs; timeout_secs=$(parse_duration "$timeout_str")
    local waited=0 interval=30

    while [ "$waited" -lt "$timeout_secs" ]; do
        if restic "${RESTIC_EXTRA_OPTS[@]}" "${repo_opts[@]}" \
            -r "$repo_url" --password-file "$repo_pw" \
            snapshots --last &>/dev/null; then
            return 0
        fi
        restic "${RESTIC_EXTRA_OPTS[@]}" "${repo_opts[@]}" \
            -r "$repo_url" --password-file "$repo_pw" unlock &>/dev/null || true
        sleep "$interval"
        waited=$((waited + interval))
    done
    return 1
}

# Track lock detection in JSON for stale lock detection
record_lock_detected() {
    local now_iso; now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    config_set_arg '.lock_state.last_seen = $val' "$now_iso" 2>/dev/null || true
}

# ==========================================
# Repo-Kontext laden
# Setzt: REPO_URL, REPO_PW_FILE, REPO_OPTS
# SFTP-Verbindungen: economy=2 / standard=8 / fullresource=16
# ==========================================
load_repo_context() {
    local repo_idx="$1"
    local jq_query
    [ "$repo_idx" = "main" ] && jq_query=".main" || jq_query=".copies[$repo_idx]"

    local r_type
    r_type=$(jq -r "${jq_query}.type // \"\"" "$CONFIG_FILE")
    [ -z "$r_type" ] || [ "$r_type" = "null" ] && return 1

    # Passwortdatei
    local r_pwd; r_pwd=$(jq -r "${jq_query}.password // \"\"" "$CONFIG_FILE")
    REPO_PW_FILE=$(mktemp)
    printf '%s' "$r_pwd" > "$REPO_PW_FILE"
    chmod 600 "$REPO_PW_FILE"

    # SFTP-Verbindungsanzahl je nach Modus
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
            # Direkt als Array - kein eval nötig, keine Parsing-Probleme
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
# Backup-Logik
# ==========================================
run_backup() {
    local mode_label="$1"
    echo "=========================================="
    echo ">> Starte Backup: $mode_label"
    echo "=========================================="

    require_jq
    migrate_env_to_json

    if [ ! -f "$CONFIG_FILE" ]; then
        echo ">> FEHLER: Keine Konfiguration gefunden."
        echo ">> Bitte Setup ausführen: sudo $0 -s"
        exit 1
    fi

    # Eigener Mutex zuerst: verhindert, dass zwei gleichzeitige Läufe
    # (Cron + manuell, Doppelstart etc.) einen echten Lock-Konflikt
    # erzeugen, der dann fälschlich wie ein "stale" Repo-Lock aussieht
    acquire_script_lock
    trap 'release_script_lock' EXIT

    # Trap setzen: bei Shutdown/SIGTERM Repos entsperren (zusätzlich zum EXIT-Trap)
    trap 'cleanup_on_shutdown; release_script_lock' SIGTERM SIGINT SIGHUP

    # Extra-Opts laden (--retry-lock, --cache-dir)
    load_restic_extra_opts

    # Auto-Unlock falls Repo zu lange gesperrt war
    auto_unlock_if_stale

    # Silent pre-unlock: stale locks from crashed backups sofort entfernen
    if load_repo_context "main"; then
        restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" \
            -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock &>/dev/null || true
        # Periodic retry: wenn Repo durch laufendes Backup gesperrt ist, warten
        pre_backup_unlock_retry "$REPO_URL" "$REPO_PW_FILE" "${REPO_OPTS[@]}" || true
        cleanup_repo_context
    fi

    # Kompressions-Einstellung
    local conf_compression; conf_compression=$(jq -r '.compression // "auto"' "$CONFIG_FILE")
    local RESTIC_SPEED_OPTS=()
    if $NO_COMPRESSION; then
        RESTIC_SPEED_OPTS=("--compression" "off")
        echo ">> Komprimierung: DEAKTIVIERT (Override)"
    else
        RESTIC_SPEED_OPTS=("--compression" "$conf_compression")
        echo ">> Komprimierung: $conf_compression"
    fi
    $EXTRA_RESOURCES && RESTIC_SPEED_OPTS+=("--pack-size" "128")

    # CPU/IO-Prioritaet
    local NICE_PREFIX=""
    if $FULL_RESOURCES; then
        export GOMAXPROCS; GOMAXPROCS=$(nproc)
        NICE_PREFIX="nice -n -15"
        echo ">> Modus: VOLLGAS | CPUs: ${GOMAXPROCS} | Prio: -15 | SFTP-Verbindungen: 16"
    elif $ECONOMY_MODE; then
        export GOMAXPROCS=1
        NICE_PREFIX="nice -n 19 ionice -c 3"
        echo ">> Modus: SPARMODUS | CPUs: 1 | Prio 19 Idle I/O | SFTP-Verbindungen: 2"
    else
        NICE_PREFIX="nice -n 10"
        echo ">> Modus: STANDARD | SFTP-Verbindungen: 8"
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
    # SCHRITT 1: Backup ins Main-Repository
    # ------------------------------------------------------------------
    echo ""
    echo ">> [1/2] Backup ins Main-Repository..."
    if ! load_repo_context "main"; then
        echo ">> FEHLER: Main-Repo nicht konfiguriert oder Typ fehlt."
        exit 1
    fi

    # Main-Infos für spaetere Copy-Operationen sichern
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

    # Track active repo for shutdown trap
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
    # SCHRITT 2: Snapshots in Copy-Repositories kopieren
    # ------------------------------------------------------------------
    local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)

    if [ "$copy_count" -gt 0 ]; then
        echo ""
        echo ">> [2/2] Kopiere in $copy_count Copy-Repo(s)..."

        for i in $(seq 0 $((copy_count - 1))); do
            local c_enabled c_name
            c_enabled=$(jq_bool ".copies[$i].enabled"       "$CONFIG_FILE")
            c_name=$(jq -r    ".copies[$i].name    // \"Copy #$((i+1))\"" "$CONFIG_FILE")

            if [ "$c_enabled" != "true" ]; then
                echo ">> -> Überspringe '$c_name' (deaktiviert)"
                continue
            fi

            echo ">> -> Synchronisiere: $c_name"

            if ! load_repo_context "$i"; then
                echo ">> -> FEHLER beim Laden von '$c_name', überspringe."
                continue
            fi

            # Initialisiere Copy-Repo (Fehler ignorieren = existiert bereits)
            restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" \
                --password-file "$REPO_PW_FILE" init &>/dev/null || true

            # ------------------------------------------------------------------
            # SFTP-zu-SFTP Problem:
            # SSHPASS env kann nur einen Wert halten.
            # Loesung: Copy-Repo nutzt sshpass -f <tmpfile> (kein Env-Konflikt),
            #          Main-Repo (from-repo) nutzt weiterhin sshpass -e (SSHPASS env).
            # Erfordert restic >= 0.14 für --from-option
            # ------------------------------------------------------------------
            local copy_type; copy_type=$(jq -r ".copies[$i].type // \"\"" "$CONFIG_FILE")
            local COPY_REPO_OPTS=("${REPO_OPTS[@]}")
            local COPY_FROM_OPTS=()
            local copy_ssh_tmp=""

            if [ "$MAIN_TYPE" = "sftp" ]; then
                local main_ssh_pw; main_ssh_pw=$(jq -r ".main.env.SSHPASS // \"\"" "$CONFIG_FILE")

                # from-option für Main-Repo SFTP (restic >= 0.14)
                local conn_main=8
                $FULL_RESOURCES && conn_main=16
                $ECONOMY_MODE   && conn_main=2
                COPY_FROM_OPTS=(
                    --from-option "sftp.connections=${conn_main}"
                    --from-option "sftp.command=sshpass -e ssh -oBatchMode=no -o StrictHostKeyChecking=no ${MAIN_USER_VAR}@${MAIN_HOST_VAR} -s sftp"
                )
                export SSHPASS="$main_ssh_pw"

                if [ "$copy_type" = "sftp" ]; then
                    # Copy-Repo SFTP: nutzt -f <tmpfile> um Konflikt mit SSHPASS env zu vermeiden
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

            # Track copy repo for shutdown trap
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
        echo ">> [2/2] Keine Copy-Repositories definiert. Überspringe."
    fi

    rm -f "$MAIN_PW_FILE" 2>/dev/null || true

    # Shutdown-Trap entfernen — Backup ist normal beendet
    trap - SIGTERM SIGINT SIGHUP
    CURRENT_REPO_URL=""
    CURRENT_REPO_PW_FILE=""
    CURRENT_REPO_OPTS=()

    echo ""
    echo ">> Backup-Vorgang abgeschlossen."
    # WICHTIG: run_backup läuft jetzt ausschließlich als Hintergrund-Worker
    # innerhalb von tmux (via -Z). "-t 0" ist dort IMMER wahr, auch wenn
    # niemand angehängt ist (tmux stellt jedem Pane ein eigenes pty bereit) --
    # ein "Drücke Enter" würde also für immer auf einen Tastendruck warten,
    # den niemand geben kann, und die tmux-Session nie beenden.
    ! $INTERNAL_WORKER && [[ -t 0 ]] && read -rp "Drücke Enter..."
}

# ==========================================
# Aktion auf allen Repositories
# ==========================================
run_action_all_repos() {
    # action: snapshots | snapshots_all | init | unlock
    local action="$1"
    require_jq
    migrate_env_to_json

    load_restic_extra_opts

    # Silent pre-unlock for snapshot/init actions (not for explicit unlock action)
    if [ "$action" != "unlock" ]; then
        if load_repo_context "main"; then
            restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" \
                -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock &>/dev/null || true
            cleanup_repo_context
        fi
    fi

    local r_host; r_host=$(jq -r '.host // ""' "$CONFIG_FILE")
    # snapshots_all = alle Computer anzeigen (kein --host Filter)
    # snapshots     = nur dieser Computer (--host Filter aktiv)
    local RESTIC_HOST_OPT=()
    if [ "$action" = "snapshots" ]; then
        [ -n "$r_host" ] && [ "$r_host" != "null" ] && RESTIC_HOST_OPT=("--host" "$r_host")
        echo "=========================================="
        echo ">> Snapshots für Host: ${r_host:-<kein Filter>}"
        echo "=========================================="
    elif [ "$action" = "snapshots_all" ]; then
        echo "=========================================="
        echo ">> Snapshots ALLER Computer (kein Host-Filter)"
        echo "=========================================="
    else
        echo "=========================================="
        echo ">> Aktion '$action' auf allen Repositories"
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
                    init 2>/dev/null || echo "  (Repo existiert bereits)" ;;
            unlock)
                restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock ;;
        esac
        cleanup_repo_context
    else
        echo ">> WARNUNG: Main-Repo nicht konfiguriert."
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
                        init 2>/dev/null || echo "  (Repo existiert bereits)" ;;
                unlock)
                    restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" unlock ;;
            esac
            cleanup_repo_context
        fi
    done

    echo ">> Fertig."
    [[ -t 0 ]] && read -rp "Drücke Enter..."
}

# ==========================================
# Manuelles Repo-Cleanup (forget + prune)
# Nutzt dieselben Aufbewahrungsregeln wie der automatische
# Lauf nach jedem Backup, kann aber jederzeit von Hand mit
# Vorschau (--dry-run) ausgeführt werden.
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
        echo ">> WARNUNG: Main-Repo nicht konfiguriert."
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
    local retention_str="${RETENTION_ARGS[*]:-<keine Limits gesetzt>}"
    local prune_str="aus"; retention_prune_enabled && prune_str="an"

    clear
    echo "=========================================="
    echo "   REPO CLEANUP (forget + prune)"
    echo "=========================================="
    echo "  Aufbewahrung: $retention_str"
    echo "  Prune nach Forget: $prune_str"
    echo "  (Einstellbar unter: Konfiguration bearbeiten -> Globale Einstellungen)"
    echo "------------------------------------------"
    echo "  1) Vorschau (--dry-run, es wird NICHTS gelöscht)"
    echo "  2) Jetzt wirklich ausführen (Main + aktive Copies)"
    echo "  3) Nur Prune (Speicher freigeben, keine Snapshots löschen)"
    echo "  4) Lokalen Cache aufräumen (restic cache --cleanup)"
    echo "  0) Zurück"
    echo "=========================================="
    read -rp "  Auswahl: " cchoice

    case "$cchoice" in
        1) echo ""; _cleanup_repo_loop "forget" "true" ;;
        2) if tui_confirm "Wirklich Snapshots gemäß Aufbewahrungsregeln löschen?" "n"; then
               echo ""; _cleanup_repo_loop "forget" "false"
           fi ;;
        3) if tui_confirm "Prune auf allen aktiven Repos ausführen?" "j"; then
               echo ""; _cleanup_repo_loop "prune" "false"
           fi ;;
        4) echo ""; restic "${RESTIC_EXTRA_OPTS[@]}" cache --cleanup ;;
        0) return ;;
    esac

    echo ""
    echo ">> Fertig."
    [[ -t 0 ]] && read -rp "Drücke Enter..."
}

# ==========================================
# Repo-Felder abfragen (Neu & Bearbeitung)
# Ergebnis: JSON in $TUI_RESULT
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
    echo "   Verfügbare Speicher-Typen:"
    echo "   sftp  = SFTP via SSH/sshpass (passwortbasiert)"
    echo "   s3    = Amazon S3 oder kompatibel (MinIO, Wasabi, Hetzner, etc.)"
    echo "   b2    = Backblaze B2 Objektspeicher"
    echo "   rest  = Restic REST-Server (selbst gehostet)"
    echo "   local = Lokaler Pfad / eingehaengtes Laufwerk (USB, NFS, etc.)"
    tui_input "Speicher-Typ" "${cur_type:-$default_type}" ""
    local r_type="$TUI_RESULT"
    local json="{}"

    case "$r_type" in
        sftp)
            echo ""; echo "   --- SFTP ---"
            tui_input "Benutzer"       "$cur_user"  "SSH/SFTP Login-Benutzername auf dem Backup-Server"
            local r_user="$TUI_RESULT"
            tui_input "Host"           "$cur_host"  "Hostname oder IP-Adresse des Backup-Servers"
            local r_host_val="$TUI_RESULT"
            tui_input "Pfad"           "$cur_path"  "Pfad auf dem Server, z.B. /volume1/restic/mein-server"
            local r_path="$TUI_RESULT"
            tui_input "Restic-Passwort" "$cur_pwd"  "Verschlüsselt deine Daten. UNBEDINGT separat sichern!" "true"
            local r_pwd="$TUI_RESULT"
            tui_input "SSH-Passwort"   "$cur_ssh"   "SSH-Login-Passwort für sshpass (NICHT das Restic-Passwort)" "true"
            local r_ssh="$TUI_RESULT"
            json=$(jq -n \
              --arg t "sftp" --arg u "$r_user" --arg h "$r_host_val" \
              --arg p "$r_path" --arg pwd "$r_pwd" --arg ssh "$r_ssh" \
              '{type:$t, user:$u, host:$h, path:$p, password:$pwd, env:{SSHPASS:$ssh}}')
            ;;
        s3)
            echo ""; echo "   --- S3 ---"
            tui_input "Endpoint"       "${cur_host:-s3.amazonaws.com}" \
                "S3 Endpoint, z.B. s3.amazonaws.com oder minio.example.com:9000"
            local r_host_val="$TUI_RESULT"
            tui_input "Bucket-Name"    "$cur_bucket" "Name des S3-Buckets (muss existieren)"
            local r_bucket="$TUI_RESULT"
            tui_input "Pfad im Bucket" "${cur_path:-/backup}" "Unterordner, z.B. /server1 (leer = Root)"
            local r_path="$TUI_RESULT"
            tui_input "Restic-Passwort" "$cur_pwd"  "Verschlüsselungspasswort" "true"
            local r_pwd="$TUI_RESULT"
            tui_input "AWS Access Key ID" "$cur_ak" "IAM/MinIO Access Key ID"
            local r_ak="$TUI_RESULT"
            tui_input "AWS Secret Key"  "$cur_sk"   "IAM/MinIO Secret Access Key" "true"
            local r_sk="$TUI_RESULT"
            json=$(jq -n \
              --arg t "s3" --arg h "$r_host_val" --arg b "$r_bucket" \
              --arg p "$r_path" --arg pwd "$r_pwd" --arg ak "$r_ak" --arg sk "$r_sk" \
              '{type:$t, host:$h, bucket:$b, path:$p, password:$pwd,
                env:{AWS_ACCESS_KEY_ID:$ak, AWS_SECRET_ACCESS_KEY:$sk}}')
            ;;
        b2)
            echo ""; echo "   --- Backblaze B2 ---"
            tui_input "Bucket-Name"    "$cur_bucket" "Backblaze B2 Bucket-Name (muss in B2 existieren)"
            local r_bucket="$TUI_RESULT"
            tui_input "Pfad im Bucket" "${cur_path:-/backup}" "Unterordner (leer = Root)"
            local r_path="$TUI_RESULT"
            tui_input "Restic-Passwort" "$cur_pwd"  "Verschlüsselungspasswort" "true"
            local r_pwd="$TUI_RESULT"
            tui_input "B2 Application Key ID" "$cur_kid" "Backblaze Application Key ID"
            local r_kid="$TUI_RESULT"
            tui_input "B2 Application Key"    "$cur_k"   "Backblaze Application Key (Geheimschlüssel)" "true"
            local r_k="$TUI_RESULT"
            json=$(jq -n \
              --arg t "b2" --arg b "$r_bucket" --arg p "$r_path" \
              --arg pwd "$r_pwd" --arg kid "$r_kid" --arg k "$r_k" \
              '{type:$t, bucket:$b, path:$p, password:$pwd,
                env:{B2_ACCOUNT_ID:$kid, B2_ACCOUNT_KEY:$k}}')
            ;;
        rest)
            echo ""; echo "   --- REST-Server ---"
            tui_input "Server URL"     "$cur_url"   "Vollständige URL, z.B. https://backup.example.com:8000/"
            local r_url="$TUI_RESULT"
            tui_input "Basic-Auth User" "$cur_user2" "HTTP Basic Auth Benutzer (leer = deaktiviert)"
            local r_user2="$TUI_RESULT"
            local r_bpass=""
            if [ -n "$r_user2" ]; then
                tui_input "Basic-Auth Passwort" "$cur_bpass" "HTTP Basic Auth Passwort" "true"
                r_bpass="$TUI_RESULT"
            fi
            tui_input "Restic-Passwort" "$cur_pwd"  "Verschlüsselungspasswort" "true"
            local r_pwd="$TUI_RESULT"
            json=$(jq -n \
              --arg t "rest" --arg u "$r_url" --arg usr "$r_user2" \
              --arg bp "$r_bpass" --arg pwd "$r_pwd" \
              '{type:$t, url:$u, username:$usr, basic_password:$bp, password:$pwd, env:{}}')
            ;;
        local)
            echo ""; echo "   --- Lokaler Pfad ---"
            tui_input "Pfad"           "$cur_path"  "Vollständiger Pfad, z.B. /mnt/usb-backup oder /backup"
            local r_path="$TUI_RESULT"
            tui_input "Restic-Passwort" "$cur_pwd"  "Verschlüsselungspasswort" "true"
            local r_pwd="$TUI_RESULT"
            json=$(jq -n \
              --arg t "local" --arg p "$r_path" --arg pwd "$r_pwd" \
              '{type:$t, path:$p, password:$pwd, env:{}}')
            ;;
        *)
            echo ">> FEHLER: Unbekannter Typ '$r_type'."
            TUI_RESULT="{}"
            return 1
            ;;
    esac

    TUI_RESULT="$json"
    return 0
}

# ==========================================
# Ersteinrichtungs-Wizard
# ==========================================
do_setup_wizard() {
    require_jq
    clear
    echo "=========================================="
    echo "     RESTIC BACKUP - ERSTEINRICHTUNG      "
    echo "=========================================="
    echo ""
    echo "  Willkommen! Drücke Enter um Vorschlaege zu übernehmen."
    echo "  Passwoerter werden als **** angezeigt."
    echo ""

    # Computer-Name
    local cur_host=""; [ -f "$CONFIG_FILE" ] && cur_host=$(jq -r '.host // ""' "$CONFIG_FILE")
    tui_input "Computer-Name für Snapshots" \
        "${cur_host:-$(hostname)}" \
        "Identifiziert diesen Rechner in Restic. Wichtig bei mehreren Hosts im selben Repo."
    local r_host="$TUI_RESULT"

    # Kompression
    echo ""
    echo "   Kompressions-Modi:"
    echo "   auto = Automatisch (empfohlen) - komprimiert unkomprimierte Dateien"
    echo "   max  = Maximale Kompression (hoehe CPU-Last, kleinere Backups)"
    echo "   off  = Keine Kompression (schneller für bereits komprimierte Daten wie JPGs, Videos)"
    local cur_comp="auto"; [ -f "$CONFIG_FILE" ] && cur_comp=$(jq -r '.compression // "auto"' "$CONFIG_FILE")
    tui_input "Kompressions-Modus" "$cur_comp" ""
    local r_comp="$TUI_RESULT"

    # Retry-Lock
    echo ""
    echo "   --retry-lock Wartezeit:"
    echo "   Wenn das Repo gesperrt ist (z.B. laufendes Backup), wartet restic"
    echo "   bis zu dieser Zeit bevor es abbricht. Format: 30s, 5m, 1h"
    local cur_retry="5m"; [ -f "$CONFIG_FILE" ] && cur_retry=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE")
    tui_input "Retry-Lock Wartezeit" "$cur_retry" "Empfohlen: 5m (5 Minuten)"
    local r_retry="$TUI_RESULT"

    # Cache-Verzeichnis
    echo ""
    echo "   Cache-Verzeichnis für restic:"
    echo "   Default: ~/.cache/restic (wird über HOME aufgelöst)"
    local cur_cache="~/.cache/restic"; [ -f "$CONFIG_FILE" ] && cur_cache=$(jq -r '.cache_dir // "~/.cache/restic"' "$CONFIG_FILE")
    tui_input "Cache-Verzeichnis" "$cur_cache" "Leer lassen für restic-Default (~/.cache/restic)"
    local r_cache="$TUI_RESULT"

    # Main-Repo
    echo ""
    echo "--- Haupt-Repository ---"
    echo "   Das primaere Backup-Ziel. Alle Backups laufen zuerst hierhin."
    local jq_path_main=""
    [ -f "$CONFIG_FILE" ] && jq_path_main=".main"
    wizard_repo_input "sftp" "$jq_path_main"
    local main_json="$TUI_RESULT"

    # Ntfy
    echo ""
    echo "--- Push-Benachrichtigungen via ntfy.sh (optional) ---"
    echo "   ntfy sendet dir eine Nachricht wenn ein Backup fehlschlaegt."
    echo "   Kostenlos unter https://ntfy.sh oder selbst hosten."
    local cur_ntfy="false"
    [ -f "$CONFIG_FILE" ] && cur_ntfy=$(jq_bool '.notifications.ntfy.enabled' "$CONFIG_FILE")
    local ntfy_default="n"; [ "$cur_ntfy" = "true" ] && ntfy_default="j"
    local njson; njson='{"enabled": false}'

    if tui_confirm "Ntfy-Benachrichtigungen konfigurieren?" "$ntfy_default"; then
        local cur_nurl="" cur_ntopic="" cur_nuser=""
        if [ -f "$CONFIG_FILE" ]; then
            cur_nurl=$(jq -r    '.notifications.ntfy.url      // "https://ntfy.sh"' "$CONFIG_FILE")
            cur_ntopic=$(jq -r  '.notifications.ntfy.topic   // ""'                 "$CONFIG_FILE")
            cur_nuser=$(jq -r   '.notifications.ntfy.username // ""'                "$CONFIG_FILE")
        fi
        tui_input "Ntfy Server URL" "${cur_nurl:-https://ntfy.sh}" \
            "Öffentlich: https://ntfy.sh | selbst gehostet: https://ntfy.deine.domain"
        local n_url="$TUI_RESULT"
        tui_input "Ntfy Topic" "$cur_ntopic" \
            "Dein Topic-Name (z.B. mein-server-alerts) - dieses abonnierst du in der App"
        local n_top="$TUI_RESULT"
        tui_input "Ntfy Benutzer" "$cur_nuser" \
            "Nur nötig bei geschützten Topics. Leer lassen wenn nicht benötigt."
        local n_user="$TUI_RESULT"
        local n_pwd=""
        if [ -n "$n_user" ]; then
            tui_input "Ntfy Passwort" "" "Passwort für ntfy-Authentifizierung" "true"
            n_pwd="$TUI_RESULT"
        fi
        njson=$(jq -n \
          --arg u "$n_url" --arg t "$n_top" --arg usr "$n_user" --arg pwd "$n_pwd" \
          '{enabled:true, url:$u, topic:$t, username:$usr, password:$pwd}')
    fi

    # Bestehende Copy-Repos beibehalten
    local existing_copies="[]"
    [ -f "$CONFIG_FILE" ] && existing_copies=$(jq '.copies // []' "$CONFIG_FILE")

    jq -n \
      --arg h     "$r_host" \
      --arg comp  "$r_comp" \
      --arg retry "$r_retry" \
      --arg cache "$r_cache" \
      --argjson main   "$main_json" \
      --argjson ntfy   "$njson" \
      --argjson copies "$existing_copies" \
      '{host:$h, compression:$comp, retry_lock:$retry, cache_dir:$cache,
        lock_state:{last_seen:"", last_unlock_attempt:""},
        notifications:{ntfy:$ntfy}, main:$main, copies:$copies}' \
      > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo ""
    echo ">> Konfiguration gespeichert: $CONFIG_FILE"
    echo ">> Initialisiere Repository..."
    load_restic_extra_opts
    if load_repo_context "main"; then
        if restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" init 2>/dev/null; then
            echo ">> Repository initialisiert."
        else
            echo ">> Hinweis: Repo existiert bereits oder Verbindung fehlgeschlagen."
            echo ">> Snapshots prüfen mit: sudo $0 -l"
        fi
        cleanup_repo_context
    fi
    sleep 2
}

# ==========================================
# Neues Copy-Repository hinzufügen
# ==========================================
add_copy_repo_wizard() {
    require_jq
    clear
    echo "=========================================="
    echo "     NEUES COPY-REPOSITORY HINZUFÜGEN    "
    echo "=========================================="
    echo ""
    echo "  Copy-Repos sind zusaetzliche Backup-Ziele."
    echo "  Restic kopiert fertige Snapshots vom Main-Repo hierher."
    echo "  Ideal für 3-2-1-Backups:"
    echo "   3 Kopien | 2 verschiedene Medien | 1 Kopie extern"
    echo ""

    tui_input "Name für dieses Copy-Repo" "Offsite Backup" \
        "Eindeutiger Anzeigename, z.B. 'NAS Keller', 'Hetzner S3', 'USB Drive'"
    local r_name="$TUI_RESULT"

    wizard_repo_input "s3" ""
    local repo_json="$TUI_RESULT"

    repo_json=$(echo "$repo_json" | jq --arg n "$r_name" '. + {name:$n, enabled:true}')

    local tmp_file; tmp_file=$(mktemp)
    jq --argjson newcopy "$repo_json" '.copies += [$newcopy]' "$CONFIG_FILE" > "$tmp_file" \
        && mv "$tmp_file" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    echo ""
    echo ">> Copy-Repository '$r_name' hinzugefügt."
    echo ">> Initialisiere Repository..."
    load_restic_extra_opts
    local new_idx; new_idx=$(jq '.copies | length' "$CONFIG_FILE")
    new_idx=$((new_idx - 1))
    if load_repo_context "$new_idx"; then
        if restic "${RESTIC_EXTRA_OPTS[@]}" "${REPO_OPTS[@]}" -r "$REPO_URL" --password-file "$REPO_PW_FILE" init 2>/dev/null; then
            echo ">> Repository initialisiert."
        else
            echo ">> Hinweis: Repo existiert bereits oder Verbindung fehlgeschlagen."
        fi
        cleanup_repo_context
    fi
    sleep 2
}

# ==========================================
# TUI: Einzelne Repo-Felder bearbeiten
# ==========================================
edit_repo_config() {
    local jq_path="$1"
    local repo_label="$2"

    while true; do
        clear
        local r_type
        r_type=$(jq -r "${jq_path}.type // \"\"" "$CONFIG_FILE")

        # Alle Felder je nach Typ lesen
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
        [ -n "$pwd_raw" ] && v_pwd_str="$(col_ok 'gesetzt')"   || v_pwd_str="$(col_err 'fehlt')"
        [ -n "$ssh_raw" ] && v_ssh_str="$(col_ok 'gesetzt')"   || v_ssh_str="$(col_err 'fehlt')"
        [ -n "$v_ak"    ] && v_ak_str="$(col_ok "$v_ak")"         || v_ak_str="$(col_err 'fehlt')"
        [ -n "$v_sk"    ] && v_sk_str="$(col_ok 'gesetzt')"     || v_sk_str="$(col_err 'fehlt')"
        [ -n "$v_kid"   ] && v_kid_str="$(col_ok "$v_kid")"       || v_kid_str="$(col_err 'fehlt')"
        [ -n "$v_bk"    ] && v_bk_str="$(col_ok 'gesetzt')"     || v_bk_str="$(col_err 'fehlt')"
        [ -n "$v_bpass" ] && v_bp_str="$(col_ok 'gesetzt')"     || v_bp_str="$(col_dim '- leer')"

        # Header
        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║  REPO: %-34s║${C_RESET}\n" "$repo_label"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n" "Typ:" "$(col_info "$r_type")"
        printf "${C_DIM}  Enter = aktuellen Wert behalten${C_RESET}\n"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"

        # Felder je nach Typ
        case "$r_type" in
            sftp)
                printf "  ${C_BOLD}1)${C_RESET}  Benutzer         %s\n" \
                    "$([ -n "$v_user" ] && col_ok "$v_user" || col_err "fehlt")"
                printf "  ${C_DIM}     SSH-Benutzername auf dem Backup-Server${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Host             %s\n" \
                    "$([ -n "$v_host" ] && col_ok "$v_host" || col_err "fehlt")"
                printf "  ${C_DIM}     IP-Adresse oder Hostname des Servers${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Pfad             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_err "fehlt")"
                printf "  ${C_DIM}     Verzeichnispfad auf dem Server${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  Restic-Passwort  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Verschlüsselt deine Backup-Daten${C_RESET}\n"
                printf "  ${C_BOLD}5)${C_RESET}  SSH-Passwort     %b\n" "$v_ssh_str"
                printf "  ${C_DIM}     Login-Passwort für sshpass${C_RESET}\n"
                ;;
            s3)
                printf "  ${C_BOLD}1)${C_RESET}  Endpoint         %s\n" \
                    "$([ -n "$v_host" ] && col_ok "$v_host" || col_err "fehlt")"
                printf "  ${C_DIM}     z.B. s3.amazonaws.com oder minio.host:9000${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Bucket           %s\n" \
                    "$([ -n "$v_bucket" ] && col_ok "$v_bucket" || col_err "fehlt")"
                printf "  ${C_DIM}     Name des S3-Buckets${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Pfad             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_dim "- leer (Root)")"
                printf "  ${C_DIM}     Unterordner im Bucket, z.B. /server1${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  Restic-Passwort  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Verschlüsselt deine Backup-Daten${C_RESET}\n"
                printf "  ${C_BOLD}5)${C_RESET}  AWS Access Key   %b\n" "$v_ak_str"
                printf "  ${C_DIM}     IAM / MinIO Access Key ID${C_RESET}\n"
                printf "  ${C_BOLD}6)${C_RESET}  AWS Secret Key   %b\n" "$v_sk_str"
                printf "  ${C_DIM}     IAM / MinIO Secret Access Key${C_RESET}\n"
                ;;
            b2)
                printf "  ${C_BOLD}1)${C_RESET}  Bucket           %s\n" \
                    "$([ -n "$v_bucket" ] && col_ok "$v_bucket" || col_err "fehlt")"
                printf "  ${C_DIM}     Name des Backblaze B2 Buckets${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Pfad             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_dim "- leer (Root)")"
                printf "  ${C_DIM}     Unterordner im Bucket, z.B. /server1${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Restic-Passwort  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Verschlüsselt deine Backup-Daten${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  B2 Application Key ID  %b\n" "$v_kid_str"
                printf "  ${C_DIM}     Backblaze Application Key ID${C_RESET}\n"
                printf "  ${C_BOLD}5)${C_RESET}  B2 Application Key     %b\n" "$v_bk_str"
                printf "  ${C_DIM}     Backblaze Geheimschlüssel${C_RESET}\n"
                ;;
            rest)
                printf "  ${C_BOLD}1)${C_RESET}  Server-URL       %s\n" \
                    "$([ -n "$v_url" ] && col_ok "$v_url" || col_err "fehlt")"
                printf "  ${C_DIM}     z.B. https://backup.example.com:8000/${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Basic-Auth Benutzer  %s\n" \
                    "$([ -n "$v_username" ] && col_ok "$v_username" || col_dim "- leer (kein Auth)")"
                printf "  ${C_DIM}     HTTP Basic Auth Benutzername${C_RESET}\n"
                printf "  ${C_BOLD}3)${C_RESET}  Basic-Auth Passwort  %b\n" "$v_bp_str"
                printf "  ${C_DIM}     HTTP Basic Auth Passwort${C_RESET}\n"
                printf "  ${C_BOLD}4)${C_RESET}  Restic-Passwort  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Verschlüsselt deine Backup-Daten${C_RESET}\n"
                ;;
            local)
                printf "  ${C_BOLD}1)${C_RESET}  Pfad             %s\n" \
                    "$([ -n "$v_path" ] && col_ok "$v_path" || col_err "fehlt")"
                printf "  ${C_DIM}     Vollständiger Pfad, z.B. /mnt/usb-backup${C_RESET}\n"
                printf "  ${C_BOLD}2)${C_RESET}  Restic-Passwort  %b\n" "$v_pwd_str"
                printf "  ${C_DIM}     Verschlüsselt deine Backup-Daten${C_RESET}\n"
                ;;
            *)
                printf "  ${C_YELLOW}Unbekannter Typ '%s' — T drücken zum neu konfigurieren.${C_RESET}\n" "$r_type"
                ;;
        esac

        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}${C_YELLOW}T)${C_RESET}  Typ komplett neu konfigurieren\n"
        printf "  ${C_BOLD}0)${C_RESET}  Zurück\n"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Auswahl: " echoice

        case "$echoice" in
            [Tt])
                printf "\n  ${C_YELLOW}ACHTUNG: Alle Einstellungen werden überschrieben!${C_RESET}\n"
                if tui_confirm "Wirklich Typ ändern und neu konfigurieren?" "n"; then
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
                        printf "  ${C_GREEN}>> Repo neu konfiguriert.${C_RESET}\n"
                    else
                        rm -f "$tmp_file"
                        printf "  ${C_RED}>> FEHLER beim Schreiben!${C_RESET}\n"
                    fi
                    sleep 1
                fi
                continue
                ;;
            0) return ;;
        esac

        # Einzelfelder bearbeiten
        _save_ok() { printf "  ${C_GREEN}>> Gespeichert.${C_RESET}\n"; sleep 1; }
        _no_change() { printf "  ${C_DIM}>> Keine Änderung.${C_RESET}\n"; sleep 1; }
        _pw_warn() { printf "  ${C_YELLOW}ACHTUNG: Passwort-Änderung macht bestehende Backups unzugänglich!${C_RESET}\n"; }

        case "$r_type" in
            sftp)
                case "$echoice" in
                    1) tui_input "Benutzer"       "$v_user"  "SSH/SFTP Login-Benutzername"
                       config_set_arg "${jq_path}.user = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Host"            "$v_host"  "Hostname oder IP-Adresse"
                       config_set_arg "${jq_path}.host = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) tui_input "Pfad"            "$v_path"  "Verzeichnispfad auf dem Server"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    4) _pw_warn
                       tui_input "Restic-Passwort" "" "Neues Passwort (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    5) tui_input "SSH-Passwort"   "" "Login-Passwort für sshpass (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.env.SSHPASS = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            s3)
                case "$echoice" in
                    1) tui_input "Endpoint"       "$v_host"   "S3 Endpoint URL"
                       config_set_arg "${jq_path}.host = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Bucket"         "$v_bucket" "S3 Bucket-Name"
                       config_set_arg "${jq_path}.bucket = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) tui_input "Pfad"           "$v_path"   "Unterordner im Bucket (leer = Root)"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    4) _pw_warn
                       tui_input "Restic-Passwort" "" "Neues Passwort (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    5) tui_input "AWS Access Key ID" "$v_ak" "IAM / MinIO Access Key ID"
                       config_set_arg "${jq_path}.env.AWS_ACCESS_KEY_ID = \$val" "$TUI_RESULT"; _save_ok ;;
                    6) tui_input "AWS Secret Key"  "" "Secret Key (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.env.AWS_SECRET_ACCESS_KEY = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            b2)
                case "$echoice" in
                    1) tui_input "Bucket"         "$v_bucket" "Name des B2 Buckets"
                       config_set_arg "${jq_path}.bucket = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Pfad"           "$v_path"   "Unterordner im Bucket (leer = Root)"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) _pw_warn
                       tui_input "Restic-Passwort" "" "Neues Passwort (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    4) tui_input "B2 Application Key ID" "$v_kid" "Backblaze Application Key ID"
                       config_set_arg "${jq_path}.env.B2_ACCOUNT_ID = \$val" "$TUI_RESULT"; _save_ok ;;
                    5) tui_input "B2 Application Key" "" "Geheimschlüssel (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.env.B2_ACCOUNT_KEY = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            rest)
                case "$echoice" in
                    1) tui_input "Server-URL"     "$v_url"      "Vollständige URL"
                       config_set_arg "${jq_path}.url = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) tui_input "Basic-Auth Benutzer" "$v_username" "HTTP Basic Auth User (leer = kein Auth)"
                       config_set_arg "${jq_path}.username = \$val" "$TUI_RESULT"; _save_ok ;;
                    3) tui_input "Basic-Auth Passwort" "" "HTTP Basic Auth Passwort (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.basic_password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                    4) _pw_warn
                       tui_input "Restic-Passwort" "" "Neues Passwort (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
            local)
                case "$echoice" in
                    1) tui_input "Pfad"           "$v_path"  "Vollständiger Pfad z.B. /mnt/usb-backup"
                       config_set_arg "${jq_path}.path = \$val" "$TUI_RESULT"; _save_ok ;;
                    2) _pw_warn
                       tui_input "Restic-Passwort" "" "Neues Passwort (leer = keine Änderung)" "true"
                       if [ -n "$TUI_RESULT" ]; then config_set_arg "${jq_path}.password = \$val" "$TUI_RESULT"; _save_ok
                       else _no_change; fi ;;
                esac ;;
        esac
    done
}

# ==========================================
# Ntfy Test-Nachricht senden
# ==========================================
ntfy_send_test() {
    local ntfy_url ntfy_topic ntfy_user ntfy_pass
    ntfy_url=$(jq -r   '.notifications.ntfy.url      // "https://ntfy.sh"' "$CONFIG_FILE")
    ntfy_topic=$(jq -r '.notifications.ntfy.topic    // ""'                "$CONFIG_FILE")
    ntfy_user=$(jq -r  '.notifications.ntfy.username // ""'                "$CONFIG_FILE")
    ntfy_pass=$(jq -r  '.notifications.ntfy.password // ""'                "$CONFIG_FILE")

    if [ -z "$ntfy_topic" ]; then
        echo "  >> FEHLER: Kein Ntfy-Topic konfiguriert!"
        sleep 2; return
    fi

    local auth_args=()
    [ -n "$ntfy_user" ] && [ -n "$ntfy_pass" ] && auth_args+=(-u "${ntfy_user}:${ntfy_pass}")

    local host; host=$(get_hostname)
    local msg="Test-Nachricht von Restic Backup Manager auf '${host}'. Ntfy funktioniert korrekt!"

    echo "  >> Sende Test-Nachricht an ${ntfy_url}/${ntfy_topic} ..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "${auth_args[@]}" \
        -H "Title: Backup Test: ${host}" \
        -H "Tags: information" \
        -H "Priority: default" \
        -d "$msg" \
        "${ntfy_url}/${ntfy_topic}")

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "  >> Erfolg! HTTP $http_code — Nachricht sollte in der ntfy-App erscheinen."
    else
        echo "  >> FEHLER! HTTP $http_code — Bitte URL, Topic und Zugangsdaten prüfen."
    fi
    sleep 3
}

# ==========================================
# TUI: Ordner-Ausschlüsse verwalten
# ==========================================
menu_exclude_settings() {
    while true; do
        clear
        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║    ORDNER-AUSSCHLÜSSE (Excludes)         ║${C_RESET}\n"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"

        local count; count=$(jq '.excludes | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        local using_defaults=false
        [ "$count" -eq 0 ] && using_defaults=true

        if $using_defaults; then
            printf "  ${C_DIM}(Keine eigene Liste — Standard-Excludes aktiv)${C_RESET}\n"
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
        printf "  ${C_BOLD}A)${C_RESET}  Pfad hinzufügen\n"
        if ! $using_defaults; then
            printf "  ${C_BOLD}R)${C_RESET}  Pfad entfernen (Nummer eingeben)\n"
        fi
        printf "  ${C_BOLD}D)${C_RESET}  Auf Standard-Excludes zurücksetzen\n"
        printf "  ${C_BOLD}0)${C_RESET}  Zurück\n"
        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Auswahl: " xchoice

        case "$xchoice" in
            [Aa])
                tui_input "Pfad hinzufügen" "" "Vollständiger Pfad, z.B. /home/user/Downloads"
                local new_path="$TUI_RESULT"
                [ -z "$new_path" ] && continue
                # Ensure the excludes array exists, then append
                if $using_defaults; then
                    # Initialise with defaults first
                    local defaults_json; defaults_json=$(printf '%s\n' "${DEFAULT_EXCLUDES[@]}" | jq -R . | jq -s .)
                    local tmp_file; tmp_file=$(mktemp)
                    if jq --argjson arr "$defaults_json" '.excludes = $arr' "$CONFIG_FILE" > "$tmp_file"; then
                        mv "$tmp_file" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
                    else rm -f "$tmp_file"; fi
                fi
                config_set_arg '.excludes += [$val]' "$new_path"
                printf "  ${C_GREEN}>> '%s' hinzugefügt.${C_RESET}\n" "$new_path"
                sleep 1
                ;;
            [Rr])
                $using_defaults && continue
                read -rp "  Welche Nummer entfernen? " rnum
                if [[ "$rnum" =~ ^[0-9]+$ ]]; then
                    local ridx=$((rnum - 1))
                    local cur_count; cur_count=$(jq '.excludes | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
                    if [ "$ridx" -ge 0 ] && [ "$ridx" -lt "$cur_count" ]; then
                        local del_path; del_path=$(jq -r ".excludes[$ridx]" "$CONFIG_FILE")
                        local tmp_file; tmp_file=$(mktemp)
                        if jq "del(.excludes[$ridx])" "$CONFIG_FILE" > "$tmp_file"; then
                            mv "$tmp_file" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
                            printf "  ${C_GREEN}>> '%s' entfernt.${C_RESET}\n" "$del_path"
                        else rm -f "$tmp_file"; printf "  ${C_RED}>> Fehler beim Entfernen.${C_RESET}\n"; fi
                        sleep 1
                    fi
                fi
                ;;
            [Dd])
                if tui_confirm "Eigene Liste löschen und Standard-Excludes verwenden?" "n"; then
                    config_set 'del(.excludes)'
                    printf "  ${C_GREEN}>> Zurückgesetzt auf Standard-Excludes.${C_RESET}\n"
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
                        if tui_confirm "  '$del_path' entfernen?" "n"; then
                            local tmp_file; tmp_file=$(mktemp)
                            if jq "del(.excludes[$ridx])" "$CONFIG_FILE" > "$tmp_file"; then
                                mv "$tmp_file" "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
                                printf "  ${C_GREEN}>> Entfernt.${C_RESET}\n"
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
# TUI: Globale Einstellungen
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
        local ntfy_status_str="AUS"; [ "$ntfy_en" = "true" ] && ntfy_status_str="AN"

        echo "=========================================="
        echo "   GLOBALE EINSTELLUNGEN"
        echo "=========================================="
        echo "  1) Computer-Name:      $r_host"
        echo "     (Identifiziert diesen Host in Snapshots)"
        echo ""
        echo "  2) Kompression:        $r_comp"
        echo "     (auto | max | off)"
        echo ""
        local r_retry r_cache
        r_retry=$(jq -r '.retry_lock // "5m"' "$CONFIG_FILE")
        r_cache=$(jq -r '.cache_dir // "~/.cache/restic"' "$CONFIG_FILE")
        echo "  3) Retry-Lock Wartezeit:  $r_retry"
        echo "     Wartezeit wenn Repo gesperrt ist (30s, 5m, 1h)"
        echo ""
        echo "  4) Cache-Verzeichnis:     $r_cache"
        echo "     Pfad zum restic-Cache (~/.cache/restic = Default)"
        echo "------------------------------------------"
        local r_stale; r_stale=$(jq -r '.stale_unlock_hours // 2' "$CONFIG_FILE")
        echo " 11) Auto-Unlock nach:     ${r_stale}h"
        echo "     Ab wann ein noch bestehender Lock zwangsweise entfernt wird"
        echo "     (nur relevant wenn 'restic unlock' ihn nicht selbst als stale erkennt,"
        echo "      z.B. bei REST-Server-Repos mit Zugriff von mehreren Hosts)"
        echo " 12) Repo jetzt sofort entsperren (--remove-all)"
        echo "     Manueller Notfall-Unlock — nur wenn sicher kein Backup läuft!"
        echo "------------------------------------------"
        local r_kd r_kw r_km r_ky r_kl r_prune
        r_kd=$(jq -r '.retention.keep_daily   // 31' "$CONFIG_FILE")
        r_kw=$(jq -r '.retention.keep_weekly  // 4'  "$CONFIG_FILE")
        r_km=$(jq -r '.retention.keep_monthly // 6'  "$CONFIG_FILE")
        r_ky=$(jq -r '.retention.keep_yearly  // 0'  "$CONFIG_FILE")
        r_kl=$(jq -r '.retention.keep_last    // 0'  "$CONFIG_FILE")
        r_prune=$(jq_bool '.retention.prune' "$CONFIG_FILE")
        echo "  Aufbewahrung / Cleanup (forget nach jedem Backup):"
        echo " 13) Täglich behalten:      $r_kd"
        echo " 14) Wöchentlich behalten:  $r_kw"
        echo " 15) Monatlich behalten:    $r_km"
        echo " 16) Jährlich behalten:     $r_ky      (0 = deaktiviert)"
        echo " 17) Letzte N behalten:     $r_kl      (0 = deaktiviert, zusätzlich zu obigem)"
        echo " 18) Prune nach Forget:     $r_prune"
        echo "------------------------------------------"
        echo "  Ntfy Push-Benachrichtigungen: [$ntfy_status_str]"
        echo "  5) Aktiviert:          $ntfy_en"
        echo "  6) Server URL:         $ntfy_url"
        echo "  7) Topic:              $ntfy_topic"
        echo "  8) Benutzer:           ${ntfy_user:-<keiner>}"
        echo "  9) Passwort andern:   ****"
        if [ "$ntfy_en" = "true" ]; then
            echo " 10) Test-Nachricht senden"
        fi
        echo "------------------------------------------"
        echo "  0) Zurück"
        echo "=========================================="
        read -rp "  Auswahl: " gchoice

        case $gchoice in
            1) tui_input "Computer-Name" "$r_host" \
                   "Bei Änderung: alte Snapshots nicht mehr automatisch sichtbar (andere Host-ID)!"
               config_set_arg '.host = $val' "$TUI_RESULT" ;;
            2) echo "   auto = Empfohlen | max = Kleiner aber langsamer | off = Keine Kompression"
               tui_input "Kompressions-Modus" "$r_comp" ""
               config_set_arg '.compression = $val' "$TUI_RESULT" ;;
            3) tui_input "Retry-Lock Wartezeit" "$r_retry" "Format: 30s, 5m, 1h (restic-Dauer)"
               config_set_arg '.retry_lock = $val' "$TUI_RESULT" ;;
            4) echo "   Default: ~/.cache/restic (ueber HOME aufgeloest)"
               tui_input "Cache-Verzeichnis" "$r_cache" "Leer lassen fuer restic-Default"
               config_set_arg '.cache_dir = $val' "$TUI_RESULT" ;;
            5) if [ "$ntfy_en" = "true" ]; then
                   config_set '.notifications.ntfy.enabled = false'
                   echo "  >> Ntfy deaktiviert."
               else
                   config_set '.notifications.ntfy.enabled = true'
                   echo "  >> Ntfy aktiviert."
               fi; sleep 1 ;;
            6) tui_input "Ntfy URL" "$ntfy_url" "URL des ntfy-Servers"
               config_set_arg '.notifications.ntfy.url = $val' "$TUI_RESULT" ;;
            7) tui_input "Ntfy Topic" "$ntfy_topic" "Topic-Name (abonnierst du in der ntfy-App)"
               config_set_arg '.notifications.ntfy.topic = $val' "$TUI_RESULT" ;;
            8) tui_input "Ntfy Benutzer" "$ntfy_user" "Leer lassen wenn kein Auth benötigt"
               config_set_arg '.notifications.ntfy.username = $val' "$TUI_RESULT" ;;
            9) tui_input "Ntfy Passwort" "" "Passwort für ntfy-Login" "true"
               [ -n "$TUI_RESULT" ] && config_set_arg '.notifications.ntfy.password = $val' "$TUI_RESULT" ;;
            10) if [ "$ntfy_en" = "true" ]; then
                   ntfy_send_test
               fi ;;
            11) tui_input "Auto-Unlock nach (Stunden)" "$r_stale" \
                    "Ganze Zahl, z.B. 2. Kleiner = aggressiver, größer = vorsichtiger."
                if [[ "$TUI_RESULT" =~ ^[0-9]+$ ]]; then
                    config_set_arg '.stale_unlock_hours = ($val | tonumber)' "$TUI_RESULT"
                else
                    echo "  >> Ungültig, muss eine Zahl sein."; sleep 1
                fi ;;
            12) force_unlock_repo ;;
            13) tui_input "Täglich behalten (keep-daily)" "$r_kd" "Ganze Zahl, 0 = deaktiviert"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_daily = ($val | tonumber)' "$TUI_RESULT" ;;
            14) tui_input "Wöchentlich behalten (keep-weekly)" "$r_kw" "Ganze Zahl, 0 = deaktiviert"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_weekly = ($val | tonumber)' "$TUI_RESULT" ;;
            15) tui_input "Monatlich behalten (keep-monthly)" "$r_km" "Ganze Zahl, 0 = deaktiviert"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_monthly = ($val | tonumber)' "$TUI_RESULT" ;;
            16) tui_input "Jährlich behalten (keep-yearly)" "$r_ky" "Ganze Zahl, 0 = deaktiviert"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_yearly = ($val | tonumber)' "$TUI_RESULT" ;;
            17) tui_input "Letzte N behalten (keep-last)" "$r_kl" "Ganze Zahl, 0 = deaktiviert"
                [[ "$TUI_RESULT" =~ ^[0-9]+$ ]] && config_set_arg '.retention.keep_last = ($val | tonumber)' "$TUI_RESULT" ;;
            18) if [ "$r_prune" = "true" ]; then
                    config_set '.retention.prune = false'
                    echo "  >> Prune nach Forget deaktiviert (Speicher wird nicht automatisch freigegeben)."
                else
                    config_set '.retention.prune = true'
                    echo "  >> Prune nach Forget aktiviert."
                fi; sleep 1 ;;
            0) return ;;
        esac
    done
}

# ==========================================
# TUI: Copy-Repo löschen
# ==========================================
menu_delete_copy_repo() {
    clear
    echo "=========================================="
    echo "   COPY-REPOSITORY AUS KONFIG LÖSCHEN"
    echo "=========================================="
    echo "  (Backup-Daten auf dem Speichermedium werden NICHT gelöscht!)"
    echo ""
    local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "$copy_count" -eq 0 ]; then
        echo "  Keine Copy-Repositories vorhanden."; sleep 1; return
    fi
    for i in $(seq 0 $((copy_count - 1))); do
        local c_name c_type
        c_name=$(jq -r ".copies[$i].name // \"Copy #$((i+1))\"" "$CONFIG_FILE")
        c_type=$(jq -r ".copies[$i].type // \"?\"" "$CONFIG_FILE")
        echo "  $((i+1))) $c_name [$c_type]"
    done
    echo "  0) Abbrechen"
    echo "=========================================="
    read -rp "  Welches Repo aus der Konfig entfernen? " dchoice
    [ "$dchoice" = "0" ] && return
    if [[ "$dchoice" =~ ^[0-9]+$ ]] && [ "$dchoice" -ge 1 ] && [ "$dchoice" -le "$copy_count" ]; then
        local idx=$((dchoice - 1))
        local c_name; c_name=$(jq -r ".copies[$idx].name // \"Copy #$((idx+1))\"" "$CONFIG_FILE")
        echo ""
        echo "  Achtung: '$c_name' wird aus der Konfiguration entfernt."
        echo "  Die tatsaechlichen Backup-Daten bleiben erhalten."
        if tui_confirm "Wirklich entfernen?" "n"; then
            local tmp_file; tmp_file=$(mktemp)
            jq "del(.copies[$idx])" "$CONFIG_FILE" > "$tmp_file" && mv "$tmp_file" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            echo "  >> '$c_name' entfernt."
            sleep 2
        fi
    fi
}

# ==========================================
# TUI: Konfiguration bearbeiten (Hauptmenue)
# ==========================================
menu_edit_configs() {
    while true; do
        clear
        echo "=========================================="
        echo "   KONFIGURATION BEARBEITEN"
        echo "=========================================="
        echo "  1) Globale Einstellungen"
        echo "     (Computer-Name, Kompression, Ntfy)"
        echo "  2) Main-Repository bearbeiten"
        echo "     Typ: $(jq -r '.main.type // "?"' "$CONFIG_FILE")"

        local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        if [ "$copy_count" -gt 0 ]; then
            echo "------------------------------------------"
            echo "  Copy-Repositories:"
        fi
        for i in $(seq 0 $((copy_count - 1))); do
            local c_name c_type c_enabled
            c_name=$(jq -r    ".copies[$i].name    // \"Copy #$((i+1))\"" "$CONFIG_FILE")
            c_type=$(jq -r    ".copies[$i].type    // \"?\"" "$CONFIG_FILE")
            c_enabled=$(jq_bool ".copies[$i].enabled" "$CONFIG_FILE")
            local status_str="EIN"
            [ "$c_enabled" != "true" ] && status_str="AUS"
            echo "  $((i + 3))) $c_name [$c_type][$status_str]"
        done

        echo "------------------------------------------"
        echo "  E) Ordner-Ausschlüsse bearbeiten"
        echo "  N) Neues Copy-Repository hinzufügen"
        echo "  D) Copy-Repository aus Konfig löschen"
        echo "  0) Zurück"
        echo "=========================================="
        read -rp "  Auswahl: " echoice

        case "$echoice" in
            1)    edit_global_settings ;;
            2)    edit_repo_config ".main" "Main-Repository" ;;
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
# Copy-Repos aktivieren / deaktivieren
# ==========================================
menu_toggle_copies() {
    while true; do
        clear
        echo "=========================================="
        echo "   COPY-REPOSITORIES VERWALTEN"
        echo "=========================================="
        local copy_count; copy_count=$(jq '.copies | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        if [ "$copy_count" -eq 0 ]; then
            echo "  Keine Copy-Repositories konfiguriert."
            echo "  Neue hinzufügen: Option 7 im Hauptmenue."
            echo ""; read -rp "  Drücke Enter..."; return
        fi
        for i in $(seq 0 $((copy_count - 1))); do
            local c_name c_enabled status_str
            c_name=$(jq -r ".copies[$i].name // \"Copy #$((i+1))\"" "$CONFIG_FILE")
            c_enabled=$(jq_bool ".copies[$i].enabled" "$CONFIG_FILE")
            [ "$c_enabled" = "true" ] && status_str="[ EIN ]" || status_str="[ AUS ]"
            echo "  $((i+1))) $status_str $c_name"
        done
        echo "------------------------------------------"
        echo "  D<Nr>) Löschen, z.B. D1 oder D2"
        echo "  0) Zurück"
        echo "=========================================="
        echo "  Nummer = EIN/AUS umschalten"
        read -rp "  Auswahl: " tchoice

        [ "$tchoice" = "0" ] && return

        # Löschen: D1, D2, d1 etc.
        if [[ "$tchoice" =~ ^[Dd]([0-9]+)$ ]]; then
            local del_num="${BASH_REMATCH[1]}"
            if [ "$del_num" -ge 1 ] && [ "$del_num" -le "$copy_count" ]; then
                local del_idx=$((del_num - 1))
                local del_name; del_name=$(jq -r ".copies[$del_idx].name // \"Copy #${del_num}\"" "$CONFIG_FILE")
                echo ""
                echo "  ACHTUNG: '$del_name' wird aus der Konfiguration entfernt."
                echo "  Die Backup-Daten auf dem Speichermedium bleiben erhalten."
                if tui_confirm "Wirklich löschen?" "n"; then
                    local tmp_file; tmp_file=$(mktemp)
                    if jq "del(.copies[$del_idx])" "$CONFIG_FILE" > "$tmp_file"; then
                        mv "$tmp_file" "$CONFIG_FILE"
                        chmod 600 "$CONFIG_FILE"
                        echo "  >> '$del_name' aus Konfiguration entfernt."
                    else
                        rm -f "$tmp_file"
                        echo "  >> FEHLER beim Löschen!"
                    fi
                    sleep 2
                fi
            fi
            continue
        fi

        # Toggle EIN/AUS
        if [[ "$tchoice" =~ ^[0-9]+$ ]] && [ "$tchoice" -ge 1 ] && [ "$tchoice" -le "$copy_count" ]; then
            local idx=$((tchoice - 1))
            local c_en; c_en=$(jq_bool ".copies[$idx].enabled" "$CONFIG_FILE")
            local new_val="true"; [ "$c_en" = "true" ] && new_val="false"
            local tmp_file; tmp_file=$(mktemp)
            if jq ".copies[$idx].enabled = $new_val" "$CONFIG_FILE" > "$tmp_file"; then
                mv "$tmp_file" "$CONFIG_FILE"
                chmod 600 "$CONFIG_FILE"
                local new_label="EIN"; [ "$new_val" = "false" ] && new_label="AUS"
                echo "  >> Repo auf $new_label gestellt."
            else
                rm -f "$tmp_file"
                echo "  >> FEHLER beim Ändern der Einstellung!"
            fi
            sleep 1
        fi
    done
}

# ==========================================
# Restic-Update (distributionsuebergreifend)
# ==========================================
update_restic() {
    clear
    echo "=========================================="
    echo "   RESTIC UPDATE"
    echo "=========================================="
    local current; current=$(get_restic_version)
    echo "  Aktuelle Version: $current"
    echo ""

    if ! command -v restic &>/dev/null; then
        echo ">> Restic ist nicht installiert. Bitte zuerst installieren:"
        echo "   https://restic.net  oder  sudo apt install restic"
        sleep 3; return
    fi

    # 1. Versuch: System-Paketmanager
    echo ">> Versuche Update via System-Paketmanager..."

    if command -v apt-get &>/dev/null; then
        echo "   (apt-get update && apt-get install --only-upgrade restic)"
        apt-get update -qq && apt-get install --only-upgrade -y restic 2>/dev/null && {
            echo ">> Update via apt erfolgreich."
            echo "   Neue Version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v dnf &>/dev/null; then
        echo "   (dnf upgrade restic)"
        dnf upgrade -y restic 2>/dev/null && {
            echo ">> Update via dnf erfolgreich."
            echo "   Neue Version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v pacman &>/dev/null; then
        echo "   (pacman -Sy restic)"
        pacman -Sy --noconfirm restic 2>/dev/null && {
            echo ">> Update via pacman erfolgreich."
            echo "   Neue Version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v zypper &>/dev/null; then
        echo "   (zypper update restic)"
        zypper update -y restic 2>/dev/null && {
            echo ">> Update via zypper erfolgreich."
            echo "   Neue Version: $(get_restic_version)"
            sleep 2; return
        }
    elif command -v apk &>/dev/null; then
        echo "   (apk update && apk add restic)"
        apk update && apk add --upgrade restic 2>/dev/null && {
            echo ">> Update via apk erfolgreich."
            echo "   Neue Version: $(get_restic_version)"
            sleep 2; return
        }
    fi

    # 2. Versuch: restic self-update (fuer Binary-Installationen)
    echo ""
    echo ">> Paketmanager-Update nicht erfolgreich/verfuegbar."
    if restic_supports_retry_lock; then
        echo ">> Versuche restic self-update..."
        if restic self-update 2>/dev/null; then
            echo ">> Self-update erfolgreich."
            echo "   Neue Version: $(get_restic_version)"
            sleep 2; return
        else
            echo ">> Self-update fehlgeschlagen (kein Schreibzugriff auf Binary?)."
            echo "   Manuelles Update: https://github.com/restic/restic/releases/latest"
        fi
    else
        echo ">> restic self-update erst ab v0.15.0 verfuegbar."
        echo ">> Bitte manuell updaten: https://github.com/restic/restic/releases/latest"
        echo "   Oder via Paketmanager: sudo apt install restic"
    fi

    sleep 3
}

# ==========================================
# Hintergrund-Modus (tmux) -- laeuft wie ein Daemon weiter
# ==========================================
build_mode_args() {
    # -Z ist ein interner Marker: signalisiert der Skript-Instanz, die
    # tmux tatsaechlich ausfuehrt, dass sie der "Worker" ist und den
    # Backup direkt starten soll (nicht erneut im Hintergrund landen --
    # sonst Endlos-Rekursion, da JEDER Backup-Start jetzt automatisch
    # im Hintergrund laeuft).
    MODE_ARGS=("-r" "-Z")
    $FULL_RESOURCES   && MODE_ARGS+=("-f")
    $ECONOMY_MODE     && MODE_ARGS+=("-e")
    $EXTRA_RESOURCES  && MODE_ARGS+=("-x")
    $NO_COMPRESSION   && MODE_ARGS+=("-n")
    [ -n "$DRY_RUN_FLAG" ] && MODE_ARGS+=("-d")
}

start_daemon_run() {
    local mode_label="$1"; shift
    local mode_args=("$@")

    require_tmux || { echo ">> tmux nicht verfuegbar, breche ab."; return 1; }

    if [ "$EUID" -ne 0 ]; then
        echo ">> FEHLER: Hintergrund-Modus benoetigt Root-Rechte (fuer Log-Verzeichnis & Backup)."
        return 1
    fi

    # Mutex zusaetzlich zur tmux-Session pruefen: verhindert Race zwischen
    # Cron-Trigger und manuellem Start
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo ">> Es läuft bereits ein Backup im Hintergrund (Session: $TMUX_SESSION)."
        echo ">> Verbinden mit: sudo $0 -A"
        return 1
    fi

    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_DIR"
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    local logfile="$LOG_DIR/backup-${ts}.log"
    touch "$logfile"
    ln -sf "$logfile" "$LOG_DIR/latest.log"

    echo ">> Starte Backup im Hintergrund: $mode_label (Log: $logfile)"

    # tmux fuehrt den eigentlichen Backup-Lauf direkt aus (kein interaktives
    # bash danach) -- die Session endet von selbst, sobald restic fertig ist.
    # Das ist die gemeinsame Grundlage fuer manuelle UND Cron-Laeufe: egal
    # woher der Start kam, das Reconnect (-A) findet dieselbe Session/Logdatei.
    # Jede Zeile bekommt einen Zeitstempel vorangestellt (read -r Schleife,
    # || [ -n "$line" ] fängt eine letzte Zeile ohne Zeilenumbruch mit ab).
    local cmd
    cmd="'$SCRIPT_PATH' ${mode_args[*]} 2>&1 | "
    cmd+='while IFS= read -r line || [ -n "$line" ]; do '
    cmd+='printf "[%s] %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$line"; '
    cmd+="done > '$logfile'"
    tmux new-session -d -s "$TMUX_SESSION" "$cmd"

    # Ohne Terminal (z.B. Cron/systemd) keine UI oeffnen -- nur starten und fertig
    if [ ! -t 1 ]; then
        echo ">> Nicht-interaktiv gestartet, Backup laeuft im Hintergrund weiter."
        return 0
    fi

    view_background_job "$logfile"
}

# ==========================================
# Live-Ansicht des Hintergrund-Jobs: normales Terminal,
# einfach "tail -f" auf die Log-Datei. Ein Observer im
# Hintergrund beendet die Anzeige automatisch, sobald der
# tmux-Worker fertig ist. Strg+C beendet NUR die Anzeige
# (tail) -- das Skript selbst läuft weiter (zurück ins Menü),
# das Backup im Hintergrund ist davon nicht betroffen.
# ==========================================
view_background_job() {
    local logfile="$1"
    clear
    echo ">> Live-Log: $logfile"
    echo ">> (Strg+C beendet nur die Anzeige — das Backup läuft im Hintergrund weiter)"
    echo "------------------------------------------"

    # tail laeuft als eigener Hintergrund-Prozess (nicht als Vordergrund-
    # Kommando des Skripts) -- so bekommt NUR tail ein SIGINT vom Terminal,
    # nicht das ganze Skript. "wait" darauf ist per SIGINT unterbrechbar,
    # der Trap darunter faengt genau dieses SIGINT ab, killt tail explizit
    # und kehrt sauber aus der Funktion zurueck (kein Haengenbleiben).
    tail -n 50 -f "$logfile" &
    local tail_pid=$!

    # Observer: pollt ob die tmux-Session noch lebt und beendet die
    # tail-Anzeige automatisch, sobald der Backup-Lauf fertig ist.
    (
        while tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do
            sleep 1
        done
        kill "$tail_pid" 2>/dev/null
    ) &
    local observer_pid=$!

    local interrupted=false
    trap 'interrupted=true; kill "$tail_pid" 2>/dev/null' SIGINT
    wait "$tail_pid" 2>/dev/null
    trap - SIGINT

    kill "$observer_pid" 2>/dev/null || true
    wait "$observer_pid" 2>/dev/null || true

    echo ""
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo ">> Log-Ansicht getrennt. Backup läuft im Hintergrund weiter."
        echo ">> Wieder verbinden: sudo $0 -A"
    else
        echo ">> Backup-Vorgang beendet."
    fi
}

attach_daemon() {
    require_tmux || { echo ">> tmux nicht verfuegbar."; return 1; }

    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo ">> Verbinde mit laufendem Backup..."
        local logfile; logfile=$(readlink -f "$LOG_DIR/latest.log" 2>/dev/null)
        if [ -n "$logfile" ] && [ -f "$logfile" ]; then
            view_background_job "$logfile"
        else
            # Fallback falls kein Logfile ermittelbar: klassisches tmux attach
            tmux attach -t "$TMUX_SESSION"
        fi
    else
        echo ">> Kein Backup läuft aktuell im Hintergrund."
        if [ -f "$LOG_DIR/latest.log" ]; then
            echo ">> Letztes Log (letzte 80 Zeilen):"
            echo "------------------------------------------"
            tail -n 80 "$LOG_DIR/latest.log"
        else
            echo ">> Es wurde noch kein Hintergrund-Backup ausgeführt."
        fi
    fi
}

# ==========================================
# Systemd-Service-Management
# ==========================================
install_systemd_automatic() {
    cat > "$SYSTEMD_DIR/$SERVICE_NAME" << EOF
[Unit]
Description=Restic Backup Service (startet Hintergrund-Job via tmux)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH -f
StandardOutput=journal
StandardError=journal
Environment="HOME=/root"
# WICHTIG: der eigentliche Backup-Prozess laeuft in einer eigenstaendigen
# tmux-Session weiter, auch nachdem dieser oneshot-Unit "fertig" ist.
# KillMode=none verhindert, dass systemd beim Beenden dieses Units die
# tmux-Session (die im selben Cgroup haengt) mit-killt.
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
    echo ">> Auto-Backup Service installiert."
    echo ">> Läuft täglich um 02:00 Uhr (+ bis 5 Min. Zufallsverzögerung)."
    echo ">> Läuft, egal ob per Cron oder manuell gestartet, immer über dieselbe"
    echo ">> Hintergrund-Session — Logs/Reconnect jederzeit mit: sudo $0 -A"
    sleep 2
}

update_timer_settings() {
    clear
    echo "--- Timer-Zeitplan anpassen ---"
    echo ""
    echo "   Beispiele für OnCalendar-Ausdrücke:"
    echo "   *-*-* 02:00:00       Täglich um 02:00 Uhr"
    echo "   Mon *-*-* 03:00:00   Jeden Montag um 03:00 Uhr"
    echo "   *-*-1 00:00:00       Monatlich am 1. um Mitternacht"
    echo "   Sat,Sun *-*-* 04:00  Wochenende um 04:00 Uhr"
    echo ""

    if [ ! -f "$SYSTEMD_DIR/$TIMER_NAME" ]; then
        echo ">> FEHLER: Service nicht installiert. Bitte zuerst Option 8 nutzen."
        sleep 2; return
    fi

    local current_sched; current_sched=$(grep "OnCalendar" "$SYSTEMD_DIR/$TIMER_NAME" | cut -d'=' -f2)
    tui_input "Neuer Zeitplan" "$current_sched" "Systemd OnCalendar Ausdruck"
    local new_sched="$TUI_RESULT"

    sed -i "s|OnCalendar=.*|OnCalendar=$new_sched|" "$SYSTEMD_DIR/$TIMER_NAME"
    systemctl daemon-reload
    systemctl restart "$TIMER_NAME"
    echo ">> Zeitplan aktualisiert: $new_sched"
    sleep 2
}

# ==========================================
# Backup-Modus-Auswahlmenue
# ==========================================
menu_run_vorgang() {
    clear
    echo "=========================================="
    echo "          BACKUP VORGANG STARTEN          "
    echo "  (läuft immer im Hintergrund via tmux —"
    echo "   überlebt Verbindungsabbruch)"
    echo "=========================================="
    echo "  1) Standard       Nice 10 | auto-Komp. | SFTP x8"
    echo "  2) Vollgas (-f)   Alle CPUs | Prio -15 | SFTP x16"
    echo "  3) Sparmodus (-e) 1 CPU | Idle I/O | SFTP x2"
    echo "  4) Dry-Run        Testlauf, KEINE echten Änderungen"
    echo "  5) Vollgas o.K.   Wie Vollgas, keine Komprimierung"
    echo "  0) Zurück"
    echo "=========================================="
    read -rp "  Auswahl: " vchoice

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
    start_daemon_run "Hintergrund-Backup" "${MODE_ARGS[@]}"
    [[ -t 0 ]] && read -rp "Drücke Enter..."
}

# ==========================================
# TUI: Ntfy-Benachrichtigungen verwalten
# Zugänglich direkt aus dem Hauptmenü (N)
# Funktioniert auch ohne bestehende Config
# ==========================================
menu_ntfy_settings() {
    require_jq

    # Falls noch keine Config existiert: minimale Ntfy-Sektion anlegen
    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${C_YELLOW}  >> Noch keine Hauptkonfiguration vorhanden.${C_RESET}\n"
        if tui_confirm "Nur Ntfy-Konfiguration erstellen (ohne vollständiges Setup)?" "j"; then
            jq -n '{
                host: "",
                compression: "auto",
                retry_lock: "5m",
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
        [ "$ntfy_en" = "true" ] && en_str="$(col_ok 'Aktiv')" \
                                 || en_str="$(col_warn '- Inaktiv')"

        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║    NTFY PUSH-BENACHRICHTIGUNGEN          ║${C_RESET}\n"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"
        printf "  ${C_BOLD}%-16s${C_RESET} %b\n"  "Status:"    "$en_str"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "Server:"    "$(col_info "$ntfy_url")"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "Topic:"     "$(col_info "${ntfy_topic:-<nicht gesetzt>}")"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "Benutzer:"  "${ntfy_user:-<keiner>}"
        printf "  ${C_BOLD}%-16s${C_RESET} %s\n"  "Passwort:"  "****"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}1)${C_RESET}  Aktivieren/Deaktivieren umschalten\n"
        printf "  ${C_BOLD}2)${C_RESET}  Server-URL ändern\n"
        printf "  ${C_DIM}       z.B. https://ntfy.sh oder selbst gehostet${C_RESET}\n"
        printf "  ${C_BOLD}3)${C_RESET}  Topic setzen\n"
        printf "  ${C_DIM}       Name des Topics in der ntfy-App${C_RESET}\n"
        printf "  ${C_BOLD}4)${C_RESET}  Benutzer setzen  ${C_DIM}(leer = kein Auth)${C_RESET}\n"
        printf "  ${C_BOLD}5)${C_RESET}  Passwort setzen\n"
        if [ "$ntfy_en" = "true" ] && [ -n "$ntfy_topic" ]; then
            printf "  ${C_BOLD}${C_GREEN}6)${C_RESET}  Test-Nachricht senden\n"
        fi
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}0)${C_RESET}  Zurück\n"
        printf "${C_DIM}  ──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Auswahl: " nchoice

        case $nchoice in
            1)
                if [ "$ntfy_en" = "true" ]; then
                    config_set '.notifications.ntfy.enabled = false'
                    printf "${C_YELLOW}  >> Ntfy deaktiviert.${C_RESET}\n"
                else
                    config_set '.notifications.ntfy.enabled = true'
                    printf "${C_GREEN}  >> Ntfy aktiviert.${C_RESET}\n"
                fi
                sleep 1 ;;
            2)
                echo ""
                echo "  ntfy-Server Optionen:"
                printf "  ${C_DIM}• Öffentlich:     https://ntfy.sh${C_RESET}\n"
                printf "  ${C_DIM}• Selbst gehostet: https://ntfy.deine.domain${C_RESET}\n"
                tui_input "Server-URL" "$ntfy_url" ""
                config_set_arg '.notifications.ntfy.url = $val' "$TUI_RESULT" ;;
            3)
                echo ""
                printf "  ${C_DIM}Das Topic ist ein eindeutiger Name (z.B. 'mein-server-alerts').${C_RESET}\n"
                printf "  ${C_DIM}Du abonnierst dieses Topic in der ntfy-App.${C_RESET}\n"
                tui_input "Topic" "$ntfy_topic" ""
                config_set_arg '.notifications.ntfy.topic = $val' "$TUI_RESULT" ;;
            4)
                echo ""
                printf "  ${C_DIM}Nur nötig bei geschützten/selbst gehosteten Servern.${C_RESET}\n"
                tui_input "Benutzer" "$ntfy_user" "Leer lassen wenn kein Login benötigt"
                config_set_arg '.notifications.ntfy.username = $val' "$TUI_RESULT" ;;
            5)
                tui_input "Passwort" "" "Ntfy Login-Passwort" "true"
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
# Haupt-Einstellungsmenue
# ==========================================
menu_settings() {
    if [ "$EUID" -ne 0 ]; then
        printf "${C_RED}>> FEHLER: Root-Rechte benötigt.${C_RESET}\n"
        echo ">> Bitte ausführen mit: sudo $0 -s"
        exit 1
    fi

    require_jq
    migrate_env_to_json

    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${C_YELLOW}>> Keine Konfiguration gefunden. Starte Ersteinrichtung...${C_RESET}\n"
        sleep 1
        do_setup_wizard
    fi

    while true; do
        clear

        # ── Status sammeln ────────────────────────────────────────────────────
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

        # Aktive Copy-Repos zählen
        local enabled_copies=0
        for _i in $(seq 0 $((copy_count - 1))); do
            [ "$(jq_bool ".copies[$_i].enabled" "$CONFIG_FILE")" = "true" ] \
                && enabled_copies=$((enabled_copies + 1))
        done

        # ── Farbige Status-Strings ────────────────────────────────────────────
        local tmr_str ntfy_str comp_str

        if $timer_active; then
            tmr_str="$(col_ok "Aktiv") $(col_info "[$current_sched]")"
        elif $svc_ok; then
            tmr_str="$(col_warn 'Pausiert')"
        else
            tmr_str="$(col_err 'Nicht eingerichtet')"
        fi

        if [ "$ntfy_active" = "true" ]; then
            ntfy_str="$(col_ok 'An')"
            [ -n "$ntfy_topic" ] && ntfy_str+=" $(col_info "(Topic: $ntfy_topic)")"
        else
            ntfy_str="$(col_warn '- Aus')"
        fi

        case "$r_comp" in
            auto) comp_str="$(col_ok 'auto')" ;;
            max)  comp_str="$(col_warn 'max')" ;;
            off)  comp_str="$(col_err 'off')" ;;
            *)    comp_str="$r_comp" ;;
        esac

        local main_str copy_str
        if [ "$main_type" = "?" ] || [ -z "$main_type" ]; then
            main_str="$(col_err 'Nicht konfiguriert')"
        else
            main_str="$(col_ok "$main_type")"
            [ -n "$main_host" ] && main_str+=" $(col_info "-> $main_host")"
        fi

        if [ "$copy_count" -eq 0 ]; then
            copy_str="$(col_dim '- keine')"
        else
            copy_str="$(col_ok "$enabled_copies") von $(col_info "$copy_count") aktiv"
        fi

        # ── Header ───────────────────────────────────────────────────────────
        printf "${C_BOLD}╔══════════════════════════════════════════╗${C_RESET}\n"
        printf "${C_BOLD}║    RESTIC BACKUP MANAGER  v%-4s          ║${C_RESET}\n" "$SCRIPT_VERSION"
        printf "${C_BOLD}╚══════════════════════════════════════════╝${C_RESET}\n"

        # ── Status-Panel ─────────────────────────────────────────────────────
        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Host:"        "$(col_info "$r_host")"

        local restic_ver_str restic_lock_warn=""
        restic_ver_str=$(get_restic_version)
        restic_supports_retry_lock || restic_lock_warn=" $(col_warn '(Update empfohlen)')"
        printf "  ${C_BOLD}%-14s${C_RESET} %s%s\n" "Restic:" "$(col_info "$restic_ver_str")" "$restic_lock_warn"

        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Kompression:" "$comp_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Main-Repo:"   "$main_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %s\n"  "Copy-Repos:"  "$copy_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %b\n"  "Ntfy:"        "$ntfy_str"
        printf "  ${C_BOLD}%-14s${C_RESET} %b\n"  "Auto-Backup:" "$tmr_str"

        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"

        # ── Menü ─────────────────────────────────────────────────────────────
        printf "  ${C_BOLD}${C_GREEN}B)${C_RESET}  Backup-Vorgang starten\n"
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            printf "  ${C_BOLD}${C_GREEN}A)${C_RESET}  Mit laufendem Backup verbinden / Logs\n"
        fi
        printf "${C_DIM}  ── Snapshots & Wartung ───────────────────${C_RESET}\n"
        printf "  ${C_BOLD}1)${C_RESET}  Snapshots dieses Computers\n"
        printf "  ${C_BOLD}2)${C_RESET}  Snapshots ${C_BOLD}ALLER${C_RESET} Computer\n"
        printf "  ${C_BOLD}3)${C_RESET}  Repositories entsperren\n"
        printf "  ${C_BOLD}F)${C_RESET}  Repository Force-Unlock\n"
        printf "  ${C_BOLD}4)${C_RESET}  Repository-Init prüfen\n"
        printf "  ${C_BOLD}C)${C_RESET}  Cleanup / Prune\n"
        printf "  ${C_BOLD}R)${C_RESET}  Restic updaten\n"
        printf "${C_DIM}  ── Konfiguration ─────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}5)${C_RESET}  Konfiguration bearbeiten\n"
        printf "  ${C_BOLD}6)${C_RESET}  Ersteinrichtung neu starten\n"
        printf "  ${C_BOLD}7)${C_RESET}  Copy-Repos verwalten\n"
        printf "  ${C_BOLD}8)${C_RESET}  Neues Copy-Repository hinzufügen\n"
        printf "  ${C_BOLD}E)${C_RESET}  Ordner-Ausschlüsse bearbeiten\n"
        printf "  ${C_BOLD}N)${C_RESET}  Ntfy-Benachrichtigungen\n"
        printf "${C_DIM}  ── Auto-Backup ───────────────────────────${C_RESET}\n"
        if $svc_ok; then
            printf "  ${C_BOLD}9)${C_RESET}  Zeitplan anpassen\n"
            if $timer_active; then
                printf " ${C_BOLD}10)${C_RESET}  Pausieren\n"
            else
                printf " ${C_BOLD}10)${C_RESET}  Aktivieren\n"
            fi
            printf " ${C_BOLD}11)${C_RESET}  Entfernen\n"
        else
            printf "  ${C_BOLD}9)${C_RESET}  Einrichten\n"
        fi
        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
        printf "  ${C_BOLD}0)${C_RESET}  Beenden\n"
        printf "${C_DIM}──────────────────────────────────────────${C_RESET}\n"
        read -rp "  Auswahl: " schoice

        case $schoice in
            [Bb]) menu_run_vorgang ;;
            [Aa]) attach_daemon ;;
            1)    run_action_all_repos "snapshots" ;;
            2)    run_action_all_repos "snapshots_all" ;;
            3)    run_action_all_repos "unlock" ;;
            [Ff]) force_unlock_repo ;;
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
                        printf "${C_YELLOW}>> Auto-Backup pausiert.${C_RESET}\n"
                    else
                        systemctl enable --now "$TIMER_NAME"
                        printf "${C_GREEN}>> Auto-Backup gestartet.${C_RESET}\n"
                    fi
                    sleep 1
                fi ;;
            11)
                if $svc_ok && tui_confirm "Service wirklich komplett entfernen?" "n"; then
                    systemctl disable --now "$TIMER_NAME" 2>/dev/null || true
                    rm -f "$SYSTEMD_DIR/$SERVICE_NAME" "$SYSTEMD_DIR/$TIMER_NAME"
                    systemctl daemon-reload
                    printf "${C_GREEN}>> Service entfernt.${C_RESET}\n"
                    sleep 1
                fi ;;
            0) exit 0 ;;
        esac
    done
}

# ==========================================
# Skript systemweit installieren (-i)
# ==========================================
install_script() {
    if [ "$EUID" -ne 0 ]; then
        echo ">> FEHLER: Bitte mit 'sudo $0 -i' ausführen, um das Skript zu installieren."
        exit 1
    fi

    local target="/usr/local/bin/restic-backup"

    echo ">> Installiere Skript nach $target ..."
    cp "$SCRIPT_PATH" "$target"
    chmod +x "$target"

    # Kopiere bestehende Konfigurationen, falls vorhanden
    if [ -f "$CONFIG_FILE" ]; then
        echo ">> Kopiere bestehende Konfiguration nach /etc/restic_backup.json ..."
        cp "$CONFIG_FILE" "/etc/restic_backup.json"
        chmod 600 "/etc/restic_backup.json"
    fi

    # Falls noch eine ganz alte .env Datei existiert
    if [ -f "$OLD_CONFIG_FILE" ]; then
        echo ">> Kopiere alte .env Konfiguration nach /etc/restic_backup.env ..."
        cp "$OLD_CONFIG_FILE" "/etc/restic_backup.env"
        chmod 600 "/etc/restic_backup.env"
    fi

    # Passe den Speicherort der Config in der installierten Datei auf /etc an
    sed -i 's|CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.json"|CONFIG_FILE="/etc/restic_backup.json"|' "$target"
    sed -i 's|OLD_CONFIG_FILE="$(dirname "$SCRIPT_PATH")/.restic_backup.env"|OLD_CONFIG_FILE="/etc/restic_backup.env"|' "$target"

    echo ">> Installation erfolgreich!"
    echo ">> Du kannst das Backup-Tool ab sofort von überall mit dem Befehl 'restic-backup' starten."
    echo ">> Die Konfigurationsdatei wird fortan unter '/etc/restic_backup.json' gespeichert."

    # Alias-Option
    echo ""
    read -rp ">> Möchtest du einen zusätzlichen Alias-Befehl einrichten? (leer = nein): " alias_name
    if [ -n "$alias_name" ]; then
        local alias_target="/usr/local/bin/$alias_name"
        if [ -e "$alias_target" ]; then
            echo ">> WARNUNG: '$alias_target' existiert bereits und wird nicht überschrieben."
        else
            ln -s "$target" "$alias_target"
            echo ">> Alias '$alias_name' -> '$target' eingerichtet."
            echo ">> Du kannst das Tool nun auch mit '$alias_name' starten."
        fi
    fi
    exit 0
}

# ==========================================
# Hilfe
# ==========================================
show_help() {
    local S; S=$(basename "$0")
    local CFG; CFG="$(dirname "$(realpath "$0")")/.restic_backup.json"
    cat << HELPEOF

══════════════════════════════════════════════════════════
  Restic Multi-Repo Backup Manager  v$SCRIPT_VERSION
  Verschlüsseltes System-Backup — mehrere Backup-Ziele
══════════════════════════════════════════════════════════

NUTZUNG:  $S [FLAGS]    (Flags kombinierbar)

── BACKUP-MODI ────────────────────────────────────────────
  -r   Standard-Backup
         nice 10 | auto-Kompression | SFTP: 8 Verbindungen
         Empfohlen für systemd-Timer / täglichen Betrieb

  -f   Vollgas-Modus
         Alle CPU-Kerne | Priorität -15 | SFTP: 16 Verbindungen
         Schnellstes Backup, hohe Systemlast

  -e   Sparmodus
         1 Kern | Priorität 19 | Idle I/O | SFTP: 2 Verbindungen
         Läuft unsichtbar im Hintergrund

  -n   Ohne Komprimierung   (kombinierbar mit -f / -e)
         Sinnvoll für bereits komprimierte Daten:
         Videos, JPEGs, ZIP-Archive, verschlüsselte Dateien

  -x   Großes Pack-Format   (kombinierbar)
         --pack-size 128 -> weniger, größere Pack-Dateien
         Besser für HDDs / langsame Verbindungen

  -d   Dry-Run / Testlauf
         Zeigt was passieren würde — ändert absolut nichts
         Kein Datentransfer, keine Snapshot-Erstellung

── HINTERGRUND ─────────────────────────────────────────────
  Jeder Backup-Start (-r/-f/-e/-n/-x/-d) läuft automatisch im
  Hintergrund (tmux-Session) — überlebt Logout & Verbindungs-
  abbruch, egal ob manuell oder vom Auto-Backup-Timer gestartet.
  Benötigt root und tmux (wird bei Bedarf installiert)
  (-b bleibt aus Kompatibilitätsgründen als Flag gültig, ist aber
   ohne Wirkung — Hintergrund ist jetzt immer an)

  -A   Mit laufendem Backup verbinden / Logs ansehen
         Funktioniert unabhängig davon, ob der Lauf von dir
         manuell oder vom Auto-Backup-Timer gestartet wurde.
         Zeigt die Live-Logs im normalen Terminal (tail -f);
         Strg+C beendet nur die Anzeige, das Backup läuft weiter.
         Ohne laufenden Job wird stattdessen das letzte Log gezeigt.

── SNAPSHOT-ANZEIGE ───────────────────────────────────────
  -l   Snapshots dieses Computers
  -L   Snapshots ALLER Computer

── WARTUNG ────────────────────────────────────────────────
  -u   Repositories entsperren
         Entfernt Sperrdateien nach Absturz / Kill

  -U   Repository Force-Unlock (--remove-all)
         Entfernt ALLE Locks, auch solche die restic selbst
         nicht als "stale" erkennt (z.B. bei REST-Server-Repos
         mit Zugriff von mehreren Hosts). Nur nutzen, wenn
         sicher kein Backup gerade läuft!

  -I   Repository initialisieren / prüfen

  -C   Cleanup / Prune (TUI-Menü: Vorschau, Ausführen, Nur-Prune,
         lokalen restic-Cache aufräumen)
         Nutzt die in den Einstellungen konfigurierten
         Aufbewahrungsregeln (keep-daily/-weekly/-monthly/...)

── SYSTEM ─────────────────────────────────────────────────
  -i   Skript systemweit installieren
         Kopiert das Skript nach /usr/local/bin/restic-backup

  -s   TUI-Einstellungsmenü  (benötigt sudo)

  -h   Diese Hilfe anzeigen

── KOMBINATIONSBEISPIELE ──────────────────────────────────
  $S -r            Normales tägliches Backup (läuft im Hintergrund)
  $S -f -n         Vollgas, Daten bereits komprimiert
  $S -e -d         Sparmodus-Testlauf ohne Änderungen
  $S -l            Snapshots dieses Hosts anzeigen
  $S -u            Nach Absturz: Repos entsperren
  $S -U            Notfall: Repo zwangsweise entsperren
  sudo $S -s       TUI-Menü für Einrichtung & Verwaltung
  sudo $S -A       Mit laufendem Backup verbinden (Cron oder manuell)

── SFTP-VERBINDUNGEN ──────────────────────────────────────
  Modus       Verbindungen   Nice   CPU-Kerne   I/O-Klasse
  Standard     8             10     alle        normal
  Vollgas     16            -15     alle        normal
  Sparmodus    2             19     1           Idle (3)

  SFTP->SFTP-Kopie (Main + Copy beide SFTP):
  • Main-Repo:  sshpass -e  (SSHPASS Umgebungsvariable)
  • Copy-Repo:  sshpass -f <tmpfile>  (kein Env-Konflikt)
  • Benötigt restic ≥ 0.14 für --from-option

── AUFBEWAHRUNGSREGELN (nach jedem Backup automatisch) ────
  Standardwerte (einstellbar in den TUI-Einstellungen):
  --keep-daily   31   letzter Monat: täglich
  --keep-weekly   4   letzte 4 Wochen: wöchentlich
  --keep-monthly  6   letzte 6 Monate: monatlich
  Ältere Snapshots werden gelöscht, danach optional --prune
  Gilt für Main-Repo und alle aktiven Copy-Repos
  Manuell mit Vorschau ausführen: $S -C  (oder TUI: C)

── KONFIGURATIONSDATEI ────────────────────────────────────
  Pfad:          $CFG
  Berechtigung:  600 (nur root lesbar, Passwörter sicher)
  Format:        JSON (jq-verarbeitet)
  Bearbeiten:    sudo $S -s  -> "Konfiguration bearbeiten"

── VORAUSSETZUNGEN ────────────────────────────────────────
  Pflicht:   restic ≥ 0.14, jq, curl
  Für SFTP:  sshpass
  Für Push:  curl (ntfy.sh Benachrichtigungen)
  Setup:     sudo $S -s  (installiert fehlende Tools)

══════════════════════════════════════════════════════════

HELPEOF
    exit 0
}

# ==========================================
# CLI Einstiegspunkt
# ==========================================

RUN_BACKUP=false
SHOW_SETTINGS=false
INIT_REPO=false
INTERNAL_WORKER=false

# Kein Argument -> Hilfe anzeigen
if [ $# -eq 0 ]; then
    show_help
fi

# getopts string anpassen: 'i' für Install, 'I' für Init, 'b' für Hintergrund (Default, siehe unten),
# 'A' für Attach, 'U' für Force-Unlock, 'C' für Cleanup, 'Z' interner Worker-Marker (nicht dokumentiert)
while getopts "hsfexrdnuIiLlbAUCZ" opt; do
    case $opt in
        h) show_help ;;
        s) SHOW_SETTINGS=true; RUN_BACKUP=false ;;
        I) INIT_REPO=true;     RUN_BACKUP=false ;; # Großes I für Init
        i) install_script ;;                       # Kleines i für Install (ruft die neue Funktion auf)
        r) RUN_BACKUP=true ;;
        f) FULL_RESOURCES=true;  RUN_BACKUP=true ;;
        e) ECONOMY_MODE=true;    RUN_BACKUP=true ;;
        x) EXTRA_RESOURCES=true; RUN_BACKUP=true ;;
        d) DRY_RUN_FLAG="--dry-run"; RUN_BACKUP=true ;;
        n) NO_COMPRESSION=true ;;
        b) : ;;  # -b ist jetzt Default-Verhalten, Flag bleibt aus Kompatibilitätsgründen gültig
        A) attach_daemon; exit 0 ;;
        u) run_action_all_repos "unlock";        exit 0 ;;
        U) require_jq; migrate_env_to_json; force_unlock_repo; exit 0 ;;
        C) run_manual_cleanup; exit 0 ;;
        l) run_action_all_repos "snapshots";     exit 0 ;;
        L) run_action_all_repos "snapshots_all"; exit 0 ;;
        Z) INTERNAL_WORKER=true ;;  # intern: von start_daemon_run innerhalb tmux gesetzt
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

# Jeder Backup-Start läuft jetzt immer im Hintergrund (tmux) -- außer es
# ist bereits der interne Worker-Aufruf, der innerhalb der tmux-Session läuft.
if $RUN_BACKUP && ! $INTERNAL_WORKER; then
    build_mode_args
    start_daemon_run "CLI-Hintergrund-Modus" "${MODE_ARGS[@]}"
    exit $?
fi

if $RUN_BACKUP; then
    run_backup "CLI-Modus"
    exit 0
fi

show_help