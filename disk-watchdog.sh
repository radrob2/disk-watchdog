#!/bin/bash
#
# disk-watchdog - Adaptive disk space monitor
# https://github.com/radrob/disk-watchdog
#
# Monitors disk space with adaptive check intervals and automatically
# stops heavy disk writers before your disk fills up.
#
# Features:
#   - Adaptive check frequency (5min when healthy, 2sec when critical)
#   - Smart writer detection (kills actual heavy writers, not just a list)
#   - Rate detection (warns if disk filling fast)
#   - SIGSTOP support (pause processes, resume later)
#   - Desktop notifications + wall messages
#   - Dry-run mode for testing
#

set -uo pipefail

readonly VERSION="1.1.0"
readonly SCRIPT_NAME="disk-watchdog"

# =============================================================================
# CONFIGURATION
# =============================================================================

CONFIG_FILE="${DISK_WATCHDOG_CONFIG:-/etc/disk-watchdog.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # Security check: warn if config is world-writable (potential code injection vector)
    if [[ -w "$CONFIG_FILE" ]] && [[ "$(stat -c %a "$CONFIG_FILE" 2>/dev/null)" =~ [2367]$ ]]; then
        echo "[SECURITY WARNING] Config file $CONFIG_FILE is world-writable. Fix with: chmod 644 $CONFIG_FILE" >&2
    fi
    source "$CONFIG_FILE"
fi

# Paths
MOUNT_POINT="${DISK_WATCHDOG_MOUNT:-/}"
LOG_FILE="${DISK_WATCHDOG_LOG:-/var/log/disk-watchdog.log}"
STATE_DIR="${DISK_WATCHDOG_STATE_DIR:-/var/lib/disk-watchdog}"
STATE_FILE="${STATE_DIR}/state"
RATE_FILE="${STATE_DIR}/rate"
WRITERS_FILE="${STATE_DIR}/known_writers"
PID_FILE="${DISK_WATCHDOG_PID:-/run/disk-watchdog.pid}"

# User whose processes to manage (empty = all users, which is safer for catching any runaway process)
TARGET_USER="${DISK_WATCHDOG_USER:-}"

# Thresholds - can be set explicitly or auto-calculated based on disk size
# Upper thresholds (notice/warn/harsh) scale with disk size
# Lower thresholds (pause/stop/kill) have hard maximums for safety
THRESH_NOTICE="${DISK_WATCHDOG_THRESH_NOTICE:-auto}"
THRESH_WARN="${DISK_WATCHDOG_THRESH_WARN:-auto}"
THRESH_HARSH="${DISK_WATCHDOG_THRESH_HARSH:-auto}"
THRESH_PAUSE="${DISK_WATCHDOG_THRESH_PAUSE:-auto}"
THRESH_STOP="${DISK_WATCHDOG_THRESH_STOP:-auto}"
THRESH_KILL="${DISK_WATCHDOG_THRESH_KILL:-auto}"

# Hard maximums for critical thresholds (never go above these regardless of disk size)
MAX_THRESH_PAUSE=30
MAX_THRESH_STOP=15
MAX_THRESH_KILL=5

# Rate threshold: warn if losing more than X GB per minute (only when below notice threshold)
RATE_WARN_GB_PER_MIN="${DISK_WATCHDOG_RATE_WARN:-2}"

# Rate-aware escalation: if time_until_full < this many minutes, escalate one level
RATE_ESCALATE_MINUTES="${DISK_WATCHDOG_RATE_ESCALATE:-10}"

# Smart mode: detect and kill actual heavy writers (vs predefined list)
SMART_MODE="${DISK_WATCHDOG_SMART:-true}"

# biotop command for eBPF-based I/O detection (required)
BIOTOP_CMD="${DISK_WATCHDOG_BIOTOP_CMD:-biotop-bpfcc}"

# Minimum bytes written to consider a process a "heavy writer" (default 100MB for /proc, 1MB for biotop)
HEAVY_WRITER_THRESHOLD="${DISK_WATCHDOG_HEAVY_THRESHOLD:-104857600}"
BIOTOP_THRESHOLD_KB="${DISK_WATCHDOG_BIOTOP_THRESHOLD:-1024}"

# Fallback process patterns if smart mode fails
PROC_PATTERNS="${DISK_WATCHDOG_PROCS:-fastp|kraken|dustmasker|bwa|spades|megahit|rsync|photorec|dd|cp|mv}"

# Processes to never kill (pipe-separated regex patterns)
# This list is comprehensive because we monitor ALL users by default
PROTECTED_PROCS="${DISK_WATCHDOG_PROTECTED:-systemd.*|init|sshd|Xorg|Xwayland|cinnamon|gnome-shell|gnome-session|plasmashell|kde.*|dbus.*|lightdm|gdm|sddm|login|agetty|getty|polkit.*|udisks.*|NetworkManager|wpa_supplicant|dhclient|journald|rsyslogd|syslog.*|auditd|cron|atd|anacron|apt.*|dpkg|dnf|yum|pacman|packagekit.*|snapd|flatpak|pulseaudio|pipewire.*|wireplumber|bluetooth.*|cups.*|avahi.*|colord|accounts-daemon|rtkit.*|upower.*|thermald|fwupd|bolt|gvfs.*|tracker.*|evolution.*|gnome-keyring.*|ssh-agent|gpg-agent|at-spi.*|ibus.*|fcitx.*|disk-watchdog}"

# Notifications
ENABLE_DESKTOP="${DISK_WATCHDOG_DESKTOP:-true}"
ENABLE_WALL="${DISK_WATCHDOG_WALL:-true}"

# Email notifications (requires mail/sendmail)
ENABLE_EMAIL="${DISK_WATCHDOG_EMAIL:-false}"
EMAIL_TO="${DISK_WATCHDOG_EMAIL_TO:-}"
EMAIL_FROM="${DISK_WATCHDOG_EMAIL_FROM:-disk-watchdog@$(hostname)}"

# Webhook notifications (for Slack, Discord, ntfy.sh, etc.)
ENABLE_WEBHOOK="${DISK_WATCHDOG_WEBHOOK:-false}"
WEBHOOK_URL="${DISK_WATCHDOG_WEBHOOK_URL:-}"

# Rate limiting: minimum seconds between notifications of same level
NOTIFY_COOLDOWN="${DISK_WATCHDOG_NOTIFY_COOLDOWN:-300}"

# Dry run mode (log but don't kill)
DRY_RUN="${DISK_WATCHDOG_DRY_RUN:-false}"

# Max log file size in bytes (default 10MB)
MAX_LOG_SIZE="${DISK_WATCHDOG_MAX_LOG:-10485760}"

# Auto-resume settings
AUTO_RESUME="${DISK_WATCHDOG_AUTO_RESUME:-true}"
# Resume threshold: hysteresis - only resume when free space is above this
# Default: 50GB or THRESH_HARSH (whichever is smaller), ensuring we're well above pause threshold
RESUME_THRESH="${DISK_WATCHDOG_RESUME_THRESH:-auto}"
# Minimum seconds a process must be paused before auto-resume (prevents rapid cycling)
RESUME_COOLDOWN="${DISK_WATCHDOG_RESUME_COOLDOWN:-300}"
# Max pause strikes per hour - if a process gets paused this many times, leave it paused
RESUME_MAX_STRIKES="${DISK_WATCHDOG_RESUME_MAX_STRIKES:-3}"

# State files for auto-resume
PAUSED_PIDS_FILE="${STATE_DIR}/paused_pids"

# =============================================================================
# CONFIG VALIDATION
# =============================================================================

# Validate a config value is either "auto" or a positive integer
validate_threshold() {
    local name="$1"
    local value="$2"
    if [[ "$value" != "auto" ]] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
        die "Invalid config: $name must be 'auto' or a positive integer, got '$value'"
    fi
}

# Validate all config values
validate_config() {
    validate_threshold "THRESH_NOTICE" "$THRESH_NOTICE"
    validate_threshold "THRESH_WARN" "$THRESH_WARN"
    validate_threshold "THRESH_HARSH" "$THRESH_HARSH"
    validate_threshold "THRESH_PAUSE" "$THRESH_PAUSE"
    validate_threshold "THRESH_STOP" "$THRESH_STOP"
    validate_threshold "THRESH_KILL" "$THRESH_KILL"
    validate_threshold "RESUME_THRESH" "$RESUME_THRESH"

    # Validate other numeric configs
    if ! [[ "$RATE_WARN_GB_PER_MIN" =~ ^[0-9]+$ ]]; then
        die "Invalid config: RATE_WARN must be a positive integer, got '$RATE_WARN_GB_PER_MIN'"
    fi
    if ! [[ "$NOTIFY_COOLDOWN" =~ ^[0-9]+$ ]]; then
        die "Invalid config: NOTIFY_COOLDOWN must be a positive integer, got '$NOTIFY_COOLDOWN'"
    fi
    if ! [[ "$RESUME_COOLDOWN" =~ ^[0-9]+$ ]]; then
        die "Invalid config: RESUME_COOLDOWN must be a positive integer, got '$RESUME_COOLDOWN'"
    fi
    if ! [[ "$RESUME_MAX_STRIKES" =~ ^[0-9]+$ ]]; then
        die "Invalid config: RESUME_MAX_STRIKES must be a positive integer, got '$RESUME_MAX_STRIKES'"
    fi
}

# =============================================================================
# THRESHOLD CALCULATION
# =============================================================================

# Get total disk size in GB
get_disk_size_gb() {
    local total_kb
    total_kb=$(df -k "$MOUNT_POINT" 2>/dev/null | awk 'NR==2 {print $2}')
    echo $(( total_kb / 1024 / 1024 ))
}

# Calculate thresholds based on disk size
# Upper thresholds (notice/warn/harsh): percentage of disk
# Lower thresholds (pause/stop/kill): percentage but capped at hard maximums
calculate_thresholds() {
    local disk_size
    disk_size=$(get_disk_size_gb)

    # Default percentages
    # Notice: 10% of disk
    # Warn: 7% of disk
    # Harsh: 4% of disk
    # Pause: 2% of disk (max 30GB)
    # Stop: 1% of disk (max 15GB)
    # Kill: 0.5% of disk (max 5GB)

    if [[ "$THRESH_NOTICE" == "auto" ]]; then
        THRESH_NOTICE=$(( disk_size * 10 / 100 ))
        (( THRESH_NOTICE < 10 )) && THRESH_NOTICE=10  # minimum 10GB
    fi

    if [[ "$THRESH_WARN" == "auto" ]]; then
        THRESH_WARN=$(( disk_size * 7 / 100 ))
        (( THRESH_WARN < 5 )) && THRESH_WARN=5  # minimum 5GB
    fi

    if [[ "$THRESH_HARSH" == "auto" ]]; then
        THRESH_HARSH=$(( disk_size * 4 / 100 ))
        (( THRESH_HARSH < 3 )) && THRESH_HARSH=3  # minimum 3GB
    fi

    if [[ "$THRESH_PAUSE" == "auto" ]]; then
        THRESH_PAUSE=$(( disk_size * 2 / 100 ))
        (( THRESH_PAUSE > MAX_THRESH_PAUSE )) && THRESH_PAUSE=$MAX_THRESH_PAUSE
        (( THRESH_PAUSE < 2 )) && THRESH_PAUSE=2  # minimum 2GB
    fi

    if [[ "$THRESH_STOP" == "auto" ]]; then
        THRESH_STOP=$(( disk_size * 1 / 100 ))
        (( THRESH_STOP > MAX_THRESH_STOP )) && THRESH_STOP=$MAX_THRESH_STOP
        (( THRESH_STOP < 1 )) && THRESH_STOP=1  # minimum 1GB
    fi

    if [[ "$THRESH_KILL" == "auto" ]]; then
        THRESH_KILL=$(( disk_size * 5 / 1000 ))  # 0.5%
        (( THRESH_KILL > MAX_THRESH_KILL )) && THRESH_KILL=$MAX_THRESH_KILL
        (( THRESH_KILL < 1 )) && THRESH_KILL=1  # minimum 1GB
    fi

    # Resume threshold: must be well above pause threshold to prevent cycling
    # Default: THRESH_HARSH (4%) or 50GB, whichever is smaller
    if [[ "$RESUME_THRESH" == "auto" ]]; then
        RESUME_THRESH=$THRESH_HARSH
        (( RESUME_THRESH > 50 )) && RESUME_THRESH=50
        # Ensure it's at least 2x the pause threshold
        (( RESUME_THRESH < THRESH_PAUSE * 2 )) && RESUME_THRESH=$(( THRESH_PAUSE * 2 ))
    fi
}

# Initialize thresholds (call this before using threshold values)
init_thresholds() {
    validate_config
    calculate_thresholds
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

die() {
    echo "[FATAL] $1" >&2
    log_msg "FATAL" "$1"
    exit 1
}

log_msg() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_rotate() {
    [[ ! -f "$LOG_FILE" ]] && return
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > MAX_LOG_SIZE )); then
        mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
        log_msg "INFO" "Log rotated (was ${size} bytes)"
    fi
}

notify_desktop() {
    [[ "$ENABLE_DESKTOP" != "true" ]] && return 0
    local urgency="$1"
    local title="$2"
    local msg="$3"

    # Determine which user to notify
    local notify_user="$TARGET_USER"
    if [[ -z "$notify_user" ]]; then
        # Find logged-in GUI user (first user with a display or Wayland session)
        notify_user=$(who | awk '/:/ {print $1; exit}')
        # Fallback: check for any logged-in user with a session
        if [[ -z "$notify_user" ]]; then
            notify_user=$(loginctl list-users --no-legend 2>/dev/null | awk 'NR==1 {print $2}')
        fi
    fi

    [[ -z "$notify_user" ]] && return 0

    # Get user's runtime dir for Wayland
    local user_uid
    user_uid=$(id -u "$notify_user" 2>/dev/null) || return 0
    local runtime_dir="/run/user/$user_uid"

    # Use runuser with explicit arguments to avoid shell injection
    # Arguments are passed directly to notify-send, not through shell interpolation
    if [[ -d "$runtime_dir" ]]; then
        # Wayland - use env to set XDG_RUNTIME_DIR safely
        runuser -u "$notify_user" -- env "XDG_RUNTIME_DIR=$runtime_dir" \
            notify-send -u "$urgency" -- "$title" "$msg" 2>/dev/null && return 0
    fi

    # X11 fallback
    for display in :0 :1; do
        runuser -u "$notify_user" -- env "DISPLAY=$display" \
            notify-send -u "$urgency" -- "$title" "$msg" 2>/dev/null && return 0
    done

    return 1
}

notify_wall() {
    [[ "$ENABLE_WALL" != "true" ]] && return 0
    echo "$1" | wall 2>/dev/null || true
}

notify_email() {
    [[ "$ENABLE_EMAIL" != "true" ]] && return 0
    [[ -z "$EMAIL_TO" ]] && return 0

    local subject="$1"
    local body="$2"

    # Try different mail commands
    if command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$EMAIL_TO" 2>/dev/null || true
    elif command -v sendmail &>/dev/null; then
        {
            echo "To: $EMAIL_TO"
            echo "From: $EMAIL_FROM"
            echo "Subject: $subject"
            echo ""
            echo "$body"
        } | sendmail -t 2>/dev/null || true
    elif command -v msmtp &>/dev/null; then
        {
            echo "To: $EMAIL_TO"
            echo "From: $EMAIL_FROM"
            echo "Subject: $subject"
            echo ""
            echo "$body"
        } | msmtp "$EMAIL_TO" 2>/dev/null || true
    else
        log_msg "WARN" "Email enabled but no mail command found (mail/sendmail/msmtp)"
    fi
}

notify_webhook() {
    [[ "$ENABLE_WEBHOOK" != "true" ]] && return 0
    [[ -z "$WEBHOOK_URL" ]] && return 0

    local title="$1"
    local msg="$2"
    local hostname
    hostname=$(hostname)

    # Escape special characters for JSON (prevent injection)
    json_escape() {
        local str="$1"
        str="${str//\\/\\\\}"  # backslash first
        str="${str//\"/\\\"}"  # double quotes
        str="${str//$'\n'/\\n}" # newlines
        str="${str//$'\r'/\\r}" # carriage returns
        str="${str//$'\t'/\\t}" # tabs
        echo "$str"
    }

    title=$(json_escape "$title")
    msg=$(json_escape "$msg")
    hostname=$(json_escape "$hostname")

    # Detect webhook type from URL and format accordingly
    if [[ "$WEBHOOK_URL" == *"hooks.slack.com"* ]]; then
        # Slack format
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"*${title}* (${hostname})\\n${msg}\"}" \
            "$WEBHOOK_URL" &>/dev/null || true
    elif [[ "$WEBHOOK_URL" == *"discord.com/api/webhooks"* ]]; then
        # Discord format
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"content\":\"**${title}** (${hostname})\\n${msg}\"}" \
            "$WEBHOOK_URL" &>/dev/null || true
    elif [[ "$WEBHOOK_URL" == *"ntfy"* ]]; then
        # ntfy.sh format (not JSON, but sanitize anyway)
        curl -s -X POST \
            -H "Title: ${title}" \
            -H "Priority: high" \
            -d "${msg} (${hostname})" \
            "$WEBHOOK_URL" &>/dev/null || true
    else
        # Generic POST with JSON
        curl -s -X POST -H 'Content-type: application/json' \
            --data "{\"title\":\"${title}\",\"message\":\"${msg}\",\"hostname\":\"${hostname}\"}" \
            "$WEBHOOK_URL" &>/dev/null || true
    fi
}

can_notify() {
    local level="$1"
    local now last_time
    now=$(date +%s)
    local cooldown_file="${STATE_DIR}/notify_${level}"

    if [[ -f "$cooldown_file" ]]; then
        last_time=$(cat "$cooldown_file" 2>/dev/null || echo 0)
        if (( now - last_time < NOTIFY_COOLDOWN )); then
            return 1
        fi
    fi

    echo "$now" > "$cooldown_file"
    return 0
}

get_free_gb() {
    local free_kb
    free_kb=$(df -k "$MOUNT_POINT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -z "$free_kb" || "$free_kb" == "0" ]]; then
        echo ""
        return 1
    fi
    echo $(( free_kb / 1024 / 1024 ))
}

get_free_bytes() {
    df -B1 "$MOUNT_POINT" 2>/dev/null | awk 'NR==2 {print $4}'
}

get_check_interval() {
    local free="$1"
    # Adaptive intervals: more frequent as disk fills up
    # At critical levels, check very frequently to catch rapid filling
    if   (( free > THRESH_NOTICE )); then echo 300   # 5 min - all good
    elif (( free > THRESH_WARN ));   then echo 60    # 1 min - getting lower
    elif (( free > THRESH_HARSH ));  then echo 30    # 30 sec - warning zone
    elif (( free > THRESH_PAUSE ));  then echo 10    # 10 sec - danger zone
    elif (( free > THRESH_STOP ));   then echo 3     # 3 sec - critical
    elif (( free > THRESH_KILL ));   then echo 1     # 1 sec - emergency
    else                                  echo 1     # 1 sec - extreme emergency
    fi
}

get_level() {
    local free="$1"
    local rate="${2:-0}"  # Optional: GB/min fill rate

    # Base level from free space
    local level
    if   (( free < THRESH_KILL ));   then level="kill"
    elif (( free < THRESH_STOP ));   then level="stop"
    elif (( free < THRESH_PAUSE ));  then level="pause"
    elif (( free < THRESH_HARSH ));  then level="harsh"
    elif (( free < THRESH_WARN ));   then level="warn"
    elif (( free < THRESH_NOTICE )); then level="notice"
    else                                  level="ok"
    fi

    # Rate-aware escalation: if we'll hit next threshold in < RATE_ESCALATE_MINUTES, escalate now
    if (( rate > 0 && RATE_ESCALATE_MINUTES > 0 )); then
        local minutes_to_next=999

        case "$level" in
            ok)
                # Minutes until notice threshold
                (( rate > 0 )) && minutes_to_next=$(( (free - THRESH_NOTICE) / rate ))
                (( minutes_to_next < RATE_ESCALATE_MINUTES )) && level="notice"
                ;;
            notice)
                (( rate > 0 )) && minutes_to_next=$(( (free - THRESH_WARN) / rate ))
                (( minutes_to_next < RATE_ESCALATE_MINUTES )) && level="warn"
                ;;
            warn)
                (( rate > 0 )) && minutes_to_next=$(( (free - THRESH_HARSH) / rate ))
                (( minutes_to_next < RATE_ESCALATE_MINUTES )) && level="harsh"
                ;;
            harsh)
                (( rate > 0 )) && minutes_to_next=$(( (free - THRESH_PAUSE) / rate ))
                (( minutes_to_next < RATE_ESCALATE_MINUTES )) && level="pause"
                ;;
            pause)
                (( rate > 0 )) && minutes_to_next=$(( (free - THRESH_STOP) / rate ))
                (( minutes_to_next < RATE_ESCALATE_MINUTES )) && level="stop"
                ;;
            stop)
                (( rate > 0 )) && minutes_to_next=$(( (free - THRESH_KILL) / rate ))
                (( minutes_to_next < RATE_ESCALATE_MINUTES )) && level="kill"
                ;;
        esac
    fi

    echo "$level"
}

read_state() {
    cat "$STATE_FILE" 2>/dev/null || echo "ok"
}

write_state() {
    echo "$1" > "$STATE_FILE" 2>/dev/null || true
}

# =============================================================================
# PERSISTENT HEAVY WRITER TRACKING
# =============================================================================

# Add a process to known heavy writers list
# Uses TAB delimiter to handle process names with colons
track_writer() {
    local pid="$1"
    local comm="$2"
    local bytes="$3"
    local timestamp
    timestamp=$(date +%s)

    # Format: pid<TAB>comm<TAB>bytes<TAB>first_seen<TAB>last_seen
    # Update if exists, add if new
    if [[ -f "$WRITERS_FILE" ]] && grep -q "^${pid}	" "$WRITERS_FILE" 2>/dev/null; then
        # Update existing entry (preserve first_seen, update bytes and last_seen)
        sed -i "s/^${pid}	[^	]*	[^	]*	\([^	]*\)	.*/${pid}	${comm}	${bytes}	\1	${timestamp}/" "$WRITERS_FILE" 2>/dev/null || true
    else
        printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$comm" "$bytes" "$timestamp" "$timestamp" >> "$WRITERS_FILE" 2>/dev/null || true
    fi
}

# Get known heavy writers that are still running
get_tracked_writers() {
    [[ ! -f "$WRITERS_FILE" ]] && return

    while IFS=$'\t' read -r pid comm bytes first_seen last_seen; do
        [[ -z "$pid" ]] && continue
        # Check if process still exists
        if [[ -d "/proc/$pid" ]]; then
            # Check if it's the same process (comm matches)
            local current_comm
            current_comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
            if [[ "$current_comm" == "$comm" ]]; then
                echo "${bytes}:${pid}:${comm}"
            fi
        fi
    done < "$WRITERS_FILE" 2>/dev/null
}

# Clean up dead processes from tracking file
cleanup_tracked_writers() {
    [[ ! -f "$WRITERS_FILE" ]] && return

    local temp_file="${WRITERS_FILE}.tmp"
    > "$temp_file"

    while IFS=$'\t' read -r pid comm bytes first_seen last_seen; do
        [[ -z "$pid" ]] && continue
        if [[ -d "/proc/$pid" ]]; then
            local current_comm
            current_comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
            if [[ "$current_comm" == "$comm" ]]; then
                printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$comm" "$bytes" "$first_seen" "$last_seen" >> "$temp_file"
            fi
        fi
    done < "$WRITERS_FILE" 2>/dev/null

    mv "$temp_file" "$WRITERS_FILE" 2>/dev/null || true
}

# =============================================================================
# AUTO-RESUME PAUSED PROCESSES
# =============================================================================

# Record a paused process for auto-resume tracking
# Format: pid<TAB>comm<TAB>pause_time<TAB>strikes (TAB delimiter handles colons in names)
record_paused_pid() {
    local pid="$1"
    local comm="$2"
    local now
    now=$(date +%s)

    [[ "$AUTO_RESUME" != "true" ]] && return

    # Check if this process was recently paused (within the hour) - increment strikes
    local strikes=1
    if [[ -f "$PAUSED_PIDS_FILE" ]]; then
        local old_entry
        old_entry=$(grep "^${pid}	${comm}	" "$PAUSED_PIDS_FILE" 2>/dev/null | tail -1)
        if [[ -n "$old_entry" ]]; then
            local old_time old_strikes
            old_time=$(echo "$old_entry" | cut -f3)
            old_strikes=$(echo "$old_entry" | cut -f4)
            # If paused within last hour, increment strikes
            if (( now - old_time < 3600 )); then
                strikes=$(( old_strikes + 1 ))
            fi
            # Remove old entry
            sed -i "/^${pid}	${comm}	/d" "$PAUSED_PIDS_FILE" 2>/dev/null || true
        fi
    fi

    printf '%s\t%s\t%s\t%s\n' "$pid" "$comm" "$now" "$strikes" >> "$PAUSED_PIDS_FILE" 2>/dev/null || true

    if (( strikes >= RESUME_MAX_STRIKES )); then
        log_msg "WARN" "Process $comm (PID $pid) paused $strikes times in an hour - will NOT auto-resume"
    fi
}

# Check if a process is stopped (state T)
is_process_stopped() {
    local pid="$1"
    local state
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
    [[ "$state" == "T" ]]
}

# Check if we should resume processes and do it
check_auto_resume() {
    [[ "$AUTO_RESUME" != "true" ]] && return
    [[ ! -f "$PAUSED_PIDS_FILE" ]] && return

    local free="$1"
    local now
    now=$(date +%s)

    # Only resume if we're well above the pause threshold (hysteresis)
    (( free < RESUME_THRESH )) && return

    local temp_file="${PAUSED_PIDS_FILE}.tmp"
    local resumed_names=()
    > "$temp_file"

    while IFS=$'\t' read -r pid comm pause_time strikes; do
        [[ -z "$pid" ]] && continue

        # Check if process still exists
        if [[ ! -d "/proc/$pid" ]]; then
            log_msg "DEBUG" "Paused process $comm (PID $pid) no longer exists, removing from list"
            continue
        fi

        # Verify it's still the same process
        local current_comm
        current_comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
        if [[ "$current_comm" != "$comm" ]]; then
            log_msg "DEBUG" "PID $pid is now $current_comm (was $comm), removing from list"
            continue
        fi

        # Check if process is actually stopped
        if ! is_process_stopped "$pid"; then
            log_msg "DEBUG" "Process $comm (PID $pid) is not stopped, removing from list"
            continue
        fi

        # Check strike limit
        if (( strikes >= RESUME_MAX_STRIKES )); then
            log_msg "DEBUG" "Process $comm (PID $pid) has $strikes strikes, keeping paused"
            printf '%s\t%s\t%s\t%s\n' "$pid" "$comm" "$pause_time" "$strikes" >> "$temp_file"
            continue
        fi

        # Check cooldown
        local paused_seconds=$(( now - pause_time ))
        if (( paused_seconds < RESUME_COOLDOWN )); then
            local remaining=$(( RESUME_COOLDOWN - paused_seconds ))
            log_msg "DEBUG" "Process $comm (PID $pid) in cooldown, ${remaining}s remaining"
            printf '%s\t%s\t%s\t%s\n' "$pid" "$comm" "$pause_time" "$strikes" >> "$temp_file"
            continue
        fi

        # All checks passed - resume the process
        if [[ "$DRY_RUN" == "true" ]]; then
            log_msg "DRY-RUN" "Would resume $comm (PID $pid) - disk space recovered to ${free}GB"
            resumed_names+=("$comm")
        else
            if kill -CONT "$pid" 2>/dev/null; then
                log_msg "RESUME" "Auto-resumed $comm (PID $pid) - disk space recovered to ${free}GB"
                resumed_names+=("$comm")
            else
                log_msg "WARN" "Failed to resume $comm (PID $pid)"
            fi
        fi
        # Don't keep in list after resume (if it fills disk again, it'll be re-paused and re-tracked)
    done < "$PAUSED_PIDS_FILE" 2>/dev/null

    mv "$temp_file" "$PAUSED_PIDS_FILE" 2>/dev/null || true

    # Notify if we resumed anything
    if (( ${#resumed_names[@]} > 0 )); then
        local msg="Disk recovered to ${free}GB. Resumed: ${resumed_names[*]}"
        notify_desktop "normal" "Processes Resumed" "$msg"
        notify_webhook "Processes Resumed" "$msg"
    fi
}

# Clean up stale entries from paused pids file
cleanup_paused_pids() {
    [[ ! -f "$PAUSED_PIDS_FILE" ]] && return

    local temp_file="${PAUSED_PIDS_FILE}.tmp"
    local now
    now=$(date +%s)
    > "$temp_file"

    while IFS=$'\t' read -r pid comm pause_time strikes; do
        [[ -z "$pid" ]] && continue

        # Remove entries for dead processes
        [[ ! -d "/proc/$pid" ]] && continue

        # Remove entries older than 2 hours (stale)
        (( now - pause_time > 7200 )) && continue

        # Verify same process
        local current_comm
        current_comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
        [[ "$current_comm" != "$comm" ]] && continue

        printf '%s\t%s\t%s\t%s\n' "$pid" "$comm" "$pause_time" "$strikes" >> "$temp_file"
    done < "$PAUSED_PIDS_FILE" 2>/dev/null

    mv "$temp_file" "$PAUSED_PIDS_FILE" 2>/dev/null || true
}

# =============================================================================
# RATE DETECTION
# =============================================================================

calculate_rate() {
    local current_bytes="$1"
    local current_time
    current_time=$(date +%s)
    local gb_per_min=0

    if [[ -f "$RATE_FILE" ]]; then
        local prev_bytes prev_time
        read -r prev_bytes prev_time < "$RATE_FILE" 2>/dev/null || true

        if [[ -n "$prev_bytes" && -n "$prev_time" ]]; then
            local bytes_diff=$(( current_bytes - prev_bytes ))
            local time_diff=$(( current_time - prev_time ))

            if (( time_diff > 0 && bytes_diff < 0 )); then
                # Disk is filling (free space decreased)
                # Use awk for floating point to avoid losing rates < 1GB/min
                gb_per_min=$(awk -v diff="$bytes_diff" -v tdiff="$time_diff" \
                    'BEGIN { printf "%d", (-diff / tdiff * 60) / (1024*1024*1024) }')
            fi
        fi
    fi

    # Always update rate file for next calculation
    echo "$current_bytes $current_time" > "$RATE_FILE" 2>/dev/null || true

    # Only report if above warning threshold
    if (( gb_per_min >= RATE_WARN_GB_PER_MIN )); then
        echo "$gb_per_min"
    else
        echo "0"
    fi
}

# =============================================================================
# SMART WRITER DETECTION
# =============================================================================

# Check if biotop is available
has_biotop() {
    command -v "$BIOTOP_CMD" &>/dev/null
}

# Require biotop - fail fast if not available
require_biotop() {
    if ! has_biotop; then
        die "biotop not found ($BIOTOP_CMD). Install with: sudo apt install bpfcc-tools"
    fi
}

# Get the device name for a mount point (e.g., / -> nvme1n1)
get_mount_device() {
    local mount="$1"
    # Remove /dev/, partition number, and trailing 'p' for nvme devices
    df "$mount" 2>/dev/null | awk 'NR==2 {print $1}' | sed 's|/dev/||' | sed 's/p\?[0-9]*$//'
}

# Get heavy writers using biotop (eBPF) - real-time, accurate
get_heavy_writers_biotop() {
    local device
    device=$(get_mount_device "$MOUNT_POINT")

    # Run biotop for 1 second, get 1 sample
    # Filter: writes only (W), to our disk, above threshold
    "$BIOTOP_CMD" -C 1 1 2>/dev/null | \
        awk -v dev="$device" -v thresh="$BIOTOP_THRESHOLD_KB" '
        NF >= 8 && $3 == "W" && $6 ~ dev && $7 >= thresh {
            pid = $1
            comm = $2
            kbytes = $7
            # Skip header line
            if (pid ~ /^[0-9]+$/) {
                print kbytes * 1024 ":" pid ":" comm
            }
        }
        ' | while IFS=: read -r bytes pid comm; do
            [[ -z "$pid" ]] && continue

            # Filter by user if TARGET_USER is set
            if [[ -n "$TARGET_USER" ]]; then
                local proc_user
                proc_user=$(stat -c %U "/proc/$pid" 2>/dev/null) || continue
                [[ "$proc_user" != "$TARGET_USER" ]] && continue
            fi

            # Skip protected processes
            if echo "$comm" | grep -qE "^($PROTECTED_PROCS)$"; then
                continue
            fi

            echo "$bytes:$pid:$comm"
        done | sort -t: -k1 -rn | head -10
}

# Get heavy writers using /proc/pid/io (fallback - cumulative, less accurate)
get_heavy_writers_proc() {
    local user_filter=""
    [[ -n "$TARGET_USER" ]] && user_filter="$TARGET_USER"

    local writers=()

    while IFS= read -r proc_dir; do
        [[ -r "$proc_dir/io" && -r "$proc_dir/comm" && -r "$proc_dir/cmdline" ]] || continue

        local pid="${proc_dir##*/}"

        # Check user ownership
        local proc_user
        proc_user=$(stat -c %U "$proc_dir" 2>/dev/null) || continue
        [[ -n "$user_filter" && "$proc_user" != "$user_filter" ]] && continue

        # Get process name
        local comm
        comm=$(tr -d '\0' < "$proc_dir/comm" 2>/dev/null) || continue

        # Skip protected processes
        if echo "$comm" | grep -qE "^($PROTECTED_PROCS)$"; then
            continue
        fi

        # Skip ourselves
        [[ "$pid" == "$$" ]] && continue

        # Get write bytes
        local write_bytes
        write_bytes=$(awk -F': ' '/^write_bytes:/{print $2; exit}' "$proc_dir/io" 2>/dev/null) || continue
        [[ -z "$write_bytes" ]] && continue

        if (( write_bytes > HEAVY_WRITER_THRESHOLD )); then
            writers+=("$write_bytes:$pid:$comm")
        fi
    done < <(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null)

    # Sort by write bytes descending and return top 10
    printf '%s\n' "${writers[@]}" 2>/dev/null | sort -t: -k1 -rn | head -10
}

# Main function to get heavy writers - combines real-time biotop + tracked writers
get_heavy_writers() {
    # Get current writers from biotop
    local current_writers
    current_writers=$(get_heavy_writers_biotop)

    # Track any new writers we find
    while IFS=: read -r bytes pid comm; do
        [[ -z "$pid" ]] && continue
        track_writer "$pid" "$comm" "$bytes"
    done <<< "$current_writers"

    # Merge current writers with tracked writers (in case biotop missed some)
    {
        echo "$current_writers"
        get_tracked_writers
    } | sort -t: -k1 -rn | awk -F: '!seen[$2]++' | head -10
}

format_bytes() {
    local bytes="$1"
    local result
    # Force C locale for consistent decimal point
    if (( bytes >= 1073741824 )); then
        result=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")
        echo "${result}GB"
    elif (( bytes >= 1048576 )); then
        result=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $bytes/1048576}")
        echo "${result}MB"
    else
        result=$(LC_ALL=C awk "BEGIN {printf \"%.1f\", $bytes/1024}")
        echo "${result}KB"
    fi
}

# =============================================================================
# PROCESS CONTROL
# =============================================================================

kill_heavy_writers() {
    local signal="$1"
    local max_count="${2:-5}"
    local track_for_resume="${3:-false}"  # If true, record PIDs for auto-resume
    local killed=0
    local killed_names=()

    if [[ "$SMART_MODE" == "true" ]]; then
        # Smart mode: detect and kill actual heavy writers
        while IFS=: read -r bytes pid comm; do
            [[ -z "$pid" ]] && continue

            local bytes_fmt
            bytes_fmt=$(format_bytes "$bytes")

            if [[ "$DRY_RUN" == "true" ]]; then
                log_msg "DRY-RUN" "Would send $signal to $comm (PID $pid, wrote $bytes_fmt)"
                killed_names+=("$comm($bytes_fmt)")
                [[ "$track_for_resume" == "true" ]] && record_paused_pid "$pid" "$comm"
            else
                if kill "$signal" "$pid" 2>/dev/null; then
                    log_msg "ACTION" "Sent $signal to $comm (PID $pid, wrote $bytes_fmt)"
                    killed_names+=("$comm($bytes_fmt)")
                    [[ "$track_for_resume" == "true" ]] && record_paused_pid "$pid" "$comm"
                    (( killed++ ))
                fi
            fi

            (( killed >= max_count )) && break
        done < <(get_heavy_writers)
    else
        # Fallback: use predefined patterns
        local pids
        if [[ -n "$TARGET_USER" ]]; then
            pids=$(pgrep -u "$TARGET_USER" -f "$PROC_PATTERNS" 2>/dev/null)
        else
            pids=$(pgrep -f "$PROC_PATTERNS" 2>/dev/null)
        fi

        for pid in $pids; do
            local comm
            comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue

            # Skip protected
            echo "$comm" | grep -qE "^($PROTECTED_PROCS)$" && continue

            if [[ "$DRY_RUN" == "true" ]]; then
                log_msg "DRY-RUN" "Would send $signal to $comm (PID $pid)"
                killed_names+=("$comm")
                [[ "$track_for_resume" == "true" ]] && record_paused_pid "$pid" "$comm"
            else
                if kill "$signal" "$pid" 2>/dev/null; then
                    log_msg "ACTION" "Sent $signal to $comm (PID $pid)"
                    killed_names+=("$comm")
                    [[ "$track_for_resume" == "true" ]] && record_paused_pid "$pid" "$comm"
                    (( killed++ ))
                fi
            fi

            (( killed >= max_count )) && break
        done
    fi

    if (( ${#killed_names[@]} > 0 )); then
        echo "${killed_names[*]}"
    fi
}

# =============================================================================
# MAIN ACTIONS
# =============================================================================

action_kill() {
    local free="$1"
    log_msg "EMERGENCY" "${free}GB free - sending SIGKILL"

    local killed
    killed=$(kill_heavy_writers "-KILL" 10)

    local msg
    if [[ -n "$killed" ]]; then
        msg="${free}GB free! KILLED: $killed"
    else
        msg="${free}GB free! No heavy writers found to kill."
    fi

    notify_desktop "critical" "DISK EMERGENCY" "$msg"
    notify_wall "DISK EMERGENCY: $msg"
    notify_email "[EMERGENCY] Disk Space Critical" "disk-watchdog emergency on $(hostname):\n\n$msg\n\nMount: $MOUNT_POINT\nTime: $(date)"
    notify_webhook "DISK EMERGENCY" "$msg"
}

action_stop() {
    local free="$1"
    log_msg "CRITICAL" "${free}GB free - sending SIGTERM"

    local stopped
    stopped=$(kill_heavy_writers "-TERM" 5)

    if [[ -n "$stopped" ]]; then
        local msg="${free}GB free! Stopped: $stopped"
        notify_desktop "critical" "DISK CRITICAL" "$msg"
        notify_wall "DISK CRITICAL: $msg"
        notify_email "[CRITICAL] Disk Space Low - Processes Stopped" "disk-watchdog critical on $(hostname):\n\n$msg\n\nMount: $MOUNT_POINT\nTime: $(date)"
        notify_webhook "DISK CRITICAL" "$msg"
    fi
}

action_pause() {
    local free="$1"
    log_msg "WARNING" "${free}GB free - sending SIGSTOP (pause)"

    local paused
    # Pass true to track_for_resume so we can auto-resume these later
    paused=$(kill_heavy_writers "-STOP" 5 true)

    if [[ -n "$paused" ]]; then
        local resume_hint
        if [[ "$AUTO_RESUME" == "true" ]]; then
            resume_hint="Will auto-resume when disk recovers to ${RESUME_THRESH}GB+"
        else
            resume_hint="Resume with: kill -CONT <PID>"
            [[ -n "$TARGET_USER" ]] && resume_hint="Resume with: pkill -CONT -u $TARGET_USER"
        fi
        local msg="${free}GB free! PAUSED: $paused"
        notify_desktop "critical" "DISK LOW" "$msg - $resume_hint"
        notify_wall "DISK LOW: $msg - $resume_hint"
        notify_email "[WARNING] Disk Space Low - Processes Paused" "disk-watchdog warning on $(hostname):\n\n$msg\n\n$resume_hint\n\nMount: $MOUNT_POINT\nTime: $(date)"
        notify_webhook "DISK LOW - Paused" "$msg"
    fi
}

action_harsh_warn() {
    local free="$1"
    local rate="$2"

    if can_notify "harsh"; then
        log_msg "WARNING" "${free}GB free"

        local writers_info=""
        if [[ "$SMART_MODE" == "true" ]]; then
            local top_writer
            top_writer=$(get_heavy_writers | head -1)
            if [[ -n "$top_writer" ]]; then
                local bytes comm
                IFS=: read -r bytes _ comm <<< "$top_writer"
                writers_info=" Top writer: $comm ($(format_bytes "$bytes"))"
            fi
        fi

        local rate_info=""
        (( rate > 0 )) && rate_info=" Filling at ~${rate}GB/min!"

        local msg="${free}GB free.${rate_info}${writers_info}"
        notify_desktop "critical" "Disk Space Low" "$msg"
        notify_wall "DISK WARNING: $msg"
        notify_email "[WARNING] Disk Space Getting Low" "disk-watchdog warning on $(hostname):\n\n$msg\n\nMount: $MOUNT_POINT\nTime: $(date)\n\nNo action taken yet - this is an early warning."
        notify_webhook "Disk Space Low" "$msg"
    fi
}

action_warn() {
    local free="$1"

    if can_notify "warn"; then
        log_msg "NOTICE" "${free}GB free"
        notify_desktop "normal" "Disk Space Notice" "${free}GB free on $MOUNT_POINT"
    fi
}

action_recover() {
    local free="$1"
    log_msg "INFO" "Recovered to ${free}GB free"
    notify_desktop "normal" "Disk Space OK" "Recovered to ${free}GB free"

    # Clear notification cooldowns
    rm -f "${STATE_DIR}"/notify_* 2>/dev/null || true
}

# =============================================================================
# COMMANDS
# =============================================================================

cmd_status() {
    # Initialize thresholds based on disk size
    init_thresholds

    local free
    free=$(get_free_gb) || die "Cannot read disk space for $MOUNT_POINT"

    local level interval state
    level=$(get_level "$free")
    interval=$(get_check_interval "$free")
    state=$(read_state)

    local biotop_status="not found"
    has_biotop && biotop_status="$BIOTOP_CMD"

    local device disk_size
    device=$(get_mount_device "$MOUNT_POINT")
    disk_size=$(get_disk_size_gb)

    echo "disk-watchdog v${VERSION}"
    echo ""
    echo "Mount point:     $MOUNT_POINT ($device)"
    echo "Disk size:       ${disk_size}GB"
    local pct=0
    (( disk_size > 0 )) && pct=$(( free * 100 / disk_size ))
    echo "Free space:      ${free}GB (${pct}%)"
    echo "Current level:   $level"
    echo "Saved state:     $state"
    echo "Check interval:  ${interval}s"
    echo "Target:          ${TARGET_USER:-all users}"
    echo "I/O detection:   $biotop_status (eBPF real-time)"
    echo "Dry run:         $DRY_RUN"
    echo ""
    echo "Thresholds (auto-calculated for ${disk_size}GB disk):"
    echo "  Notice: <${THRESH_NOTICE}GB (10%)"
    echo "  Warn:   <${THRESH_WARN}GB (7%)"
    echo "  Harsh:  <${THRESH_HARSH}GB (4%)"
    echo "  Pause:  <${THRESH_PAUSE}GB (2%, max ${MAX_THRESH_PAUSE}GB) - freeze processes"
    echo "  Stop:   <${THRESH_STOP}GB (1%, max ${MAX_THRESH_STOP}GB) - graceful stop"
    echo "  Kill:   <${THRESH_KILL}GB (0.5%, max ${MAX_THRESH_KILL}GB) - force kill"
    echo ""
    echo "Auto-resume: $AUTO_RESUME"
    if [[ "$AUTO_RESUME" == "true" ]]; then
        echo "  Resume when:  >${RESUME_THRESH}GB free (hysteresis)"
        echo "  Cooldown:     ${RESUME_COOLDOWN}s minimum paused"
        echo "  Max strikes:  ${RESUME_MAX_STRIKES} pauses/hour before giving up"
        if [[ -f "$PAUSED_PIDS_FILE" ]] && [[ -s "$PAUSED_PIDS_FILE" ]]; then
            echo ""
            echo "Currently paused processes:"
            while IFS=$'\t' read -r pid comm pause_time strikes; do
                [[ -z "$pid" ]] && continue
                [[ ! -d "/proc/$pid" ]] && continue
                local paused_ago=$(( $(date +%s) - pause_time ))
                local mins=$(( paused_ago / 60 ))
                local secs=$(( paused_ago % 60 ))
                printf "  PID %s (%s) - paused %dm%ds ago, %d strike(s)\n" "$pid" "$comm" "$mins" "$secs" "$strikes"
            done < "$PAUSED_PIDS_FILE"
        fi
    fi
    echo ""
    echo "Currently writing to $device (real-time via eBPF):"

    if ! has_biotop; then
        echo "  (biotop not available - install bpfcc-tools)"
        return 0
    fi

    local count=0
    while IFS=: read -r bytes pid comm; do
        [[ -z "$pid" ]] && continue
        printf "  %10s/s - %s (PID %s)\n" "$(format_bytes "$bytes")" "$comm" "$pid"
        (( ++count >= 5 )) && break
    done < <(get_heavy_writers)
    [[ $count -eq 0 ]] && echo "  (no active writers detected)"
    return 0
}

cmd_check() {
    init_thresholds

    local free
    free=$(get_free_gb) || die "Cannot read disk space for $MOUNT_POINT"

    local level
    level=$(get_level "$free")

    echo "Free: ${free}GB, Level: $level"

    case "$level" in
        kill|stop|pause|harsh)
            exit 1
            ;;
        *)
            exit 0
            ;;
    esac
}

cmd_writers() {
    echo "Heavy disk writers (${TARGET_USER:-all users}):"
    echo ""

    local count=0
    while IFS=: read -r bytes pid comm; do
        [[ -z "$pid" ]] && continue
        printf "%12s  %s (PID %s)\n" "$(format_bytes "$bytes")" "$comm" "$pid"
        (( ++count ))
    done < <(get_heavy_writers)

    [[ $count -eq 0 ]] && echo "(none detected above threshold)"
    return 0
}

cmd_test() {
    init_thresholds

    echo "disk-watchdog test mode"
    echo "======================="
    echo ""
    echo "This will test notifications at each level WITHOUT taking any action."
    echo "No processes will be paused/stopped/killed."
    echo ""

    local test_level="${1:-all}"
    local free
    free=$(get_free_gb) || die "Cannot read disk space"

    echo "Current free space: ${free}GB"
    echo "Current level: $(get_level "$free" 0)"
    echo ""

    # Determine which user to notify
    local notify_user="$TARGET_USER"
    if [[ -z "$notify_user" ]]; then
        notify_user=$(who | awk '/:/ {print $1; exit}')
    fi
    echo "Notifications will go to: ${notify_user:-nobody (no GUI user found)}"
    echo ""

    if [[ "$test_level" == "all" || "$test_level" == "notice" ]]; then
        echo "Testing NOTICE level..."
        notify_desktop "low" "TEST: Disk Notice" "This is a test notification (notice level)"
        echo "  Desktop notification sent"
    fi

    if [[ "$test_level" == "all" || "$test_level" == "warn" ]]; then
        echo "Testing WARN level..."
        notify_desktop "normal" "TEST: Disk Warning" "This is a test notification (warn level)"
        echo "  Desktop notification sent"
    fi

    if [[ "$test_level" == "all" || "$test_level" == "harsh" ]]; then
        echo "Testing HARSH level..."
        notify_desktop "critical" "TEST: Disk Space Low" "This is a test notification (harsh level)"
        if [[ "$ENABLE_WALL" == "true" ]]; then
            notify_wall "TEST: disk-watchdog harsh warning test"
            echo "  Wall message sent"
        fi
        echo "  Desktop notification sent"
    fi

    if [[ "$test_level" == "all" || "$test_level" == "pause" ]]; then
        echo "Testing PAUSE level..."
        notify_desktop "critical" "TEST: DISK LOW" "This is a test (pause level) - processes would be paused"
        notify_wall "TEST: disk-watchdog PAUSE test - no processes affected"
        echo "  Desktop + wall sent"
    fi

    if [[ "$test_level" == "all" || "$test_level" == "critical" ]]; then
        echo "Testing CRITICAL levels (stop/kill)..."
        notify_desktop "critical" "TEST: DISK CRITICAL" "This is a test (stop/kill level) - processes would be stopped"
        notify_wall "TEST: disk-watchdog CRITICAL test - no processes affected"
        echo "  Desktop + wall sent"
    fi

    # Test email if enabled
    if [[ "$ENABLE_EMAIL" == "true" && -n "$EMAIL_TO" ]]; then
        echo ""
        echo "Testing EMAIL notification to $EMAIL_TO..."
        notify_email "[TEST] disk-watchdog" "This is a test email from disk-watchdog on $(hostname).\n\nIf you receive this, email notifications are working."
        echo "  Email sent (check inbox)"
    elif [[ "$ENABLE_EMAIL" == "true" ]]; then
        echo ""
        echo "Email enabled but EMAIL_TO not set - skipping"
    fi

    # Test webhook if enabled
    if [[ "$ENABLE_WEBHOOK" == "true" && -n "$WEBHOOK_URL" ]]; then
        echo ""
        echo "Testing WEBHOOK notification..."
        notify_webhook "TEST: disk-watchdog" "This is a test from $(hostname). If you see this, webhooks are working."
        echo "  Webhook sent"
    elif [[ "$ENABLE_WEBHOOK" == "true" ]]; then
        echo ""
        echo "Webhook enabled but WEBHOOK_URL not set - skipping"
    fi

    echo ""
    echo "Test complete. Check your notifications."
    echo ""
    echo "To test what would be targeted (dry-run):"
    echo "  sudo disk-watchdog --dry-run run"
}

cmd_run() {
    # Validate mount point exists and is accessible
    if ! df "$MOUNT_POINT" &>/dev/null; then
        die "Mount point '$MOUNT_POINT' is not accessible or doesn't exist"
    fi

    # Initialize thresholds based on disk size
    init_thresholds

    # Require biotop
    require_biotop

    # Setup directories with restrictive permissions
    mkdir -p "$STATE_DIR" 2>/dev/null || die "Cannot create state directory: $STATE_DIR"
    chmod 0700 "$STATE_DIR" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || die "Cannot write to log file: $LOG_FILE"
    chmod 0600 "$LOG_FILE" 2>/dev/null || true

    # Acquire exclusive lock (prevents race condition)
    exec 200>"$PID_FILE"
    if ! flock -n 200; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        die "Already running (PID ${old_pid:-unknown}). Use 'disk-watchdog stop' first."
    fi
    echo $$ > "$PID_FILE"

    # Signal handlers
    trap 'log_msg "INFO" "Received SIGTERM, shutting down"; rm -f "$PID_FILE"; exit 0' SIGTERM
    trap 'log_msg "INFO" "Received SIGINT, shutting down"; rm -f "$PID_FILE"; exit 0' SIGINT
    trap 'log_msg "INFO" "Received SIGHUP, reloading config"; [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; validate_config && init_thresholds || log_msg "ERROR" "Config validation failed after reload"' SIGHUP

    log_msg "INFO" "$SCRIPT_NAME v${VERSION} started (PID $$)"
    log_msg "INFO" "Config: mount=$MOUNT_POINT user=${TARGET_USER:-any} smart=$SMART_MODE dry_run=$DRY_RUN"
    log_msg "INFO" "Thresholds: kill=${THRESH_KILL}GB stop=${THRESH_STOP}GB pause=${THRESH_PAUSE}GB"

    local last_level
    last_level=$(read_state)

    local last_cleanup=0

    # Main loop
    while true; do
        # Rotate logs if needed
        log_rotate

        # Get current state
        local free free_bytes rate
        free=$(get_free_gb)

        if [[ -z "$free" ]]; then
            log_msg "ERROR" "Cannot read free space for $MOUNT_POINT"
            sleep 60
            continue
        fi

        free_bytes=$(get_free_bytes)
        rate=$(calculate_rate "$free_bytes")

        local level interval
        level=$(get_level "$free" "$rate")  # Pass rate for rate-aware escalation
        interval=$(get_check_interval "$free")

        # Periodically clean up tracked writers and paused pids (every 60s, not every loop)
        local now
        now=$(date +%s)
        if (( now - last_cleanup >= 60 )); then
            cleanup_tracked_writers
            cleanup_paused_pids
            last_cleanup=$now
        fi

        # Check if we should auto-resume paused processes
        check_auto_resume "$free"

        # Log rate warnings
        if (( rate > 0 )); then
            log_msg "RATE" "Disk filling at ~${rate}GB/min (${free}GB free)"
            # Log if rate caused escalation
            local base_level
            base_level=$(get_level "$free" 0)
            if [[ "$level" != "$base_level" ]]; then
                log_msg "ESCALATE" "Rate-aware escalation: $base_level -> $level (filling too fast)"
            fi
        fi

        # Take action based on level transitions
        case "$level" in
            kill)
                if [[ "$last_level" != "kill" ]]; then
                    action_kill "$free"
                    write_state "kill"
                    last_level="kill"
                fi
                ;;
            stop)
                if [[ "$last_level" != "stop" && "$last_level" != "kill" ]]; then
                    action_stop "$free"
                    write_state "stop"
                    last_level="stop"
                fi
                ;;
            pause)
                if [[ "$last_level" != "pause" && "$last_level" != "stop" && "$last_level" != "kill" ]]; then
                    action_pause "$free"
                    write_state "pause"
                    last_level="pause"
                fi
                ;;
            harsh)
                if [[ "$last_level" == "ok" || "$last_level" == "notice" || "$last_level" == "warn" ]]; then
                    action_harsh_warn "$free" "$rate"
                    write_state "harsh"
                    last_level="harsh"
                fi
                ;;
            warn)
                if [[ "$last_level" == "ok" || "$last_level" == "notice" ]]; then
                    action_warn "$free"
                    write_state "warn"
                    last_level="warn"
                fi
                ;;
            notice)
                if [[ "$last_level" == "ok" ]]; then
                    log_msg "NOTICE" "${free}GB free - monitoring"
                    write_state "notice"
                    last_level="notice"
                fi
                ;;
            ok)
                if [[ "$last_level" != "ok" ]]; then
                    action_recover "$free"
                    write_state "ok"
                    last_level="ok"
                fi
                ;;
        esac

        # Notify systemd watchdog if configured
        [[ -n "${WATCHDOG_USEC:-}" ]] && systemd-notify WATCHDOG=1 2>/dev/null || true

        sleep "$interval"
    done
}

cmd_stop() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "Stopping disk-watchdog (PID $pid)..."
            kill "$pid" 2>/dev/null
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            rm -f "$PID_FILE"
            echo "Stopped."
        else
            echo "Not running (stale PID file)."
            rm -f "$PID_FILE"
        fi
    else
        echo "Not running (no PID file)."
    fi
}

cmd_resume() {
    init_thresholds

    if [[ ! -f "$PAUSED_PIDS_FILE" ]] || [[ ! -s "$PAUSED_PIDS_FILE" ]]; then
        echo "No paused processes tracked."
        return 0
    fi

    echo "Resuming all paused processes..."
    local resumed=0

    while IFS=$'\t' read -r pid comm pause_time strikes; do
        [[ -z "$pid" ]] && continue
        [[ ! -d "/proc/$pid" ]] && continue

        if is_process_stopped "$pid"; then
            if kill -CONT "$pid" 2>/dev/null; then
                echo "  Resumed $comm (PID $pid)"
                log_msg "RESUME" "Manually resumed $comm (PID $pid)"
                (( resumed++ ))
            else
                echo "  Failed to resume $comm (PID $pid)"
            fi
        fi
    done < "$PAUSED_PIDS_FILE"

    # Clear the paused pids file
    > "$PAUSED_PIDS_FILE"

    if (( resumed > 0 )); then
        echo "Resumed $resumed process(es)."
    else
        echo "No stopped processes found to resume."
    fi
}

cmd_uninstall() {
    echo "Uninstalling disk-watchdog..."

    # Stop service if running
    if systemctl is-active disk-watchdog &>/dev/null; then
        echo "  Stopping service..."
        systemctl stop disk-watchdog
    fi

    # Disable service
    if systemctl is-enabled disk-watchdog &>/dev/null; then
        echo "  Disabling service..."
        systemctl disable disk-watchdog
    fi

    # Remove files
    echo "  Removing files..."
    rm -f /usr/local/bin/disk-watchdog
    rm -f /etc/systemd/system/disk-watchdog.service
    rm -f /run/disk-watchdog.pid

    # Reload systemd
    systemctl daemon-reload 2>/dev/null || true

    echo ""
    echo "Uninstalled. Config and logs preserved:"
    echo "  /etc/disk-watchdog.conf"
    echo "  /var/log/disk-watchdog.log"
    echo "  /var/lib/disk-watchdog/"
    echo ""
    echo "To fully remove: rm -rf /etc/disk-watchdog.conf /var/log/disk-watchdog.log /var/lib/disk-watchdog"
}

cmd_help() {
    cat << 'EOF'
disk-watchdog - Adaptive disk space monitor with eBPF-based I/O detection

USAGE:
    disk-watchdog [COMMAND] [OPTIONS]

COMMANDS:
    run         Start monitoring (default if no command given)
    stop        Stop the running daemon
    status      Show current disk status, thresholds, and top writers
    check       Quick check - exits 0 if OK, 1 if warning/critical
    writers     Show top disk writers (real-time via eBPF)
    resume      Manually resume all paused processes
    test        Test notifications without taking action
    uninstall   Remove disk-watchdog (preserves config/logs)
    help        Show this help

OPTIONS:
    -c, --config FILE    Config file (default: /etc/disk-watchdog.conf)
    -m, --mount PATH     Mount point to monitor (default: /)
    -u, --user USER      Only manage this user's processes (default: all)
    -n, --dry-run        Log actions but don't kill processes
    -v, --version        Show version
    -h, --help           Show this help

QUICK START:
    # One-liner install
    curl -fsSL https://raw.githubusercontent.com/radrob2/disk-watchdog/master/install.sh | sudo bash

    # Or manual
    sudo cp disk-watchdog.sh /usr/local/bin/disk-watchdog
    sudo systemctl enable --now disk-watchdog

    # Test
    sudo disk-watchdog status
    sudo disk-watchdog --dry-run run

THRESHOLDS:
    Auto-calculated based on disk size. Critical thresholds capped:
      Pause: 2% of disk (max 30GB) - freezes processes, auto-resumes
      Stop:  1% of disk (max 15GB) - graceful shutdown
      Kill:  0.5% of disk (max 5GB) - force kill, last resort

    Run 'disk-watchdog status' to see calculated values for your disk.

AUTO-RESUME:
    Paused processes are automatically resumed when disk space recovers.
    Anti-thrashing protection:
      - Hysteresis: only resume when well above pause threshold
      - Cooldown: processes must stay paused for 5 minutes minimum
      - Strike limit: if paused 3x in an hour, stays paused (manual resume needed)

    Manual resume: disk-watchdog resume

SMART MODE (default):
    Uses biotop (eBPF) to detect which processes are actively writing
    to disk in real-time, then targets those. Much more accurate than
    pattern matching.

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local cmd="run"

    local test_level=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            run|stop|status|check|writers|resume|uninstall|help)
                cmd="$1"
                shift
                ;;
            test)
                cmd="test"
                shift
                # Optional: test level (notice, warn, harsh, pause, critical, all)
                [[ $# -gt 0 && "$1" != -* ]] && { test_level="$1"; shift; }
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
                shift 2
                ;;
            -m|--mount)
                MOUNT_POINT="$2"
                shift 2
                ;;
            -u|--user)
                TARGET_USER="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -v|--version)
                echo "$SCRIPT_NAME v${VERSION}"
                exit 0
                ;;
            -h|--help)
                cmd_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Try 'disk-watchdog help' for usage." >&2
                exit 1
                ;;
        esac
    done

    case "$cmd" in
        run)       cmd_run ;;
        stop)      cmd_stop ;;
        status)    cmd_status ;;
        check)     cmd_check ;;
        writers)   cmd_writers ;;
        resume)    cmd_resume ;;
        uninstall) cmd_uninstall ;;
        test)      cmd_test "$test_level" ;;
        help)      cmd_help ;;
    esac
}

main "$@"
