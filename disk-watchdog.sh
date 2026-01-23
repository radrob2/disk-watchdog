#!/bin/bash
# disk-watchdog - Adaptive disk space monitor
# https://github.com/radrob/disk-watchdog
#
# Monitors disk space and takes action before your disk fills up.
# Check frequency adapts based on urgency - checks every 5 min when healthy,
# every 2 seconds when critically low.

set -euo pipefail

VERSION="0.1.0"

# =============================================================================
# CONFIGURATION (override via /etc/disk-watchdog.conf or environment)
# =============================================================================

CONFIG_FILE="${DISK_WATCHDOG_CONFIG:-/etc/disk-watchdog.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Paths
MOUNT_POINT="${DISK_WATCHDOG_MOUNT:-/}"
LOG_FILE="${DISK_WATCHDOG_LOG:-/var/log/disk-watchdog.log}"
STATE_FILE="${DISK_WATCHDOG_STATE:-/tmp/disk-watchdog.state}"
PID_FILE="${DISK_WATCHDOG_PID:-/run/disk-watchdog.pid}"

# User whose processes to manage (default: current user or set explicitly)
TARGET_USER="${DISK_WATCHDOG_USER:-}"

# Thresholds in GB (when free space drops below these)
THRESH_NOTICE="${DISK_WATCHDOG_THRESH_NOTICE:-150}"
THRESH_WARN="${DISK_WATCHDOG_THRESH_WARN:-100}"
THRESH_HARSH="${DISK_WATCHDOG_THRESH_HARSH:-50}"
THRESH_PAUSE="${DISK_WATCHDOG_THRESH_PAUSE:-25}"
THRESH_STOP="${DISK_WATCHDOG_THRESH_STOP:-10}"
THRESH_KILL="${DISK_WATCHDOG_THRESH_KILL:-5}"

# Process patterns to target (pipe-separated regex)
PROC_PATTERNS="${DISK_WATCHDOG_PROCS:-fastp|kraken|dustmasker|bwa|spades|megahit|rsync|photorec}"

# Notifications
ENABLE_DESKTOP="${DISK_WATCHDOG_DESKTOP:-true}"
ENABLE_WALL="${DISK_WATCHDOG_WALL:-true}"

# =============================================================================
# FUNCTIONS
# =============================================================================

log_msg() {
    local level="$1"
    local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE"
}

notify_desktop() {
    [[ "$ENABLE_DESKTOP" != "true" ]] && return 0
    local urgency="$1"
    local title="$2"
    local msg="$3"

    # Try to notify via the target user's session
    if [[ -n "$TARGET_USER" ]]; then
        su - "$TARGET_USER" -c "DISPLAY=:0 notify-send -u '$urgency' '$title' '$msg'" 2>/dev/null || true
    fi
}

notify_wall() {
    [[ "$ENABLE_WALL" != "true" ]] && return 0
    wall "$1" 2>/dev/null || true
}

get_free_gb() {
    df -BG "$MOUNT_POINT" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}'
}

get_check_interval() {
    local free="$1"
    if   (( free > THRESH_NOTICE )); then echo 300   # 5 min - all good
    elif (( free > THRESH_WARN ));   then echo 60    # 1 min - noticed
    elif (( free > THRESH_HARSH ));  then echo 30    # 30 sec - warning
    elif (( free > THRESH_PAUSE ));  then echo 10    # 10 sec - concerning
    elif (( free > THRESH_STOP ));   then echo 5     # 5 sec - critical
    else                                  echo 2     # 2 sec - emergency
    fi
}

get_level() {
    local free="$1"
    if   (( free < THRESH_KILL ));   then echo "kill"
    elif (( free < THRESH_STOP ));   then echo "stop"
    elif (( free < THRESH_PAUSE ));  then echo "pause"
    elif (( free < THRESH_HARSH ));  then echo "harsh"
    elif (( free < THRESH_WARN ));   then echo "warn"
    elif (( free < THRESH_NOTICE )); then echo "notice"
    else                                  echo "ok"
    fi
}

kill_procs() {
    local signal="$1"
    local signaled=0

    if [[ -n "$TARGET_USER" ]]; then
        pkill "$signal" -u "$TARGET_USER" -f "$PROC_PATTERNS" 2>/dev/null && signaled=1
    else
        pkill "$signal" -f "$PROC_PATTERNS" 2>/dev/null && signaled=1
    fi

    return $((1 - signaled))
}

read_state() {
    cat "$STATE_FILE" 2>/dev/null || echo "ok"
}

write_state() {
    echo "$1" > "$STATE_FILE"
}

cleanup() {
    log_msg "INFO" "Shutting down disk-watchdog"
    rm -f "$PID_FILE"
    exit 0
}

usage() {
    cat << EOF
disk-watchdog v${VERSION} - Adaptive disk space monitor

USAGE:
    disk-watchdog [OPTIONS]

OPTIONS:
    -h, --help      Show this help message
    -v, --version   Show version
    -c, --config    Path to config file (default: /etc/disk-watchdog.conf)
    -f, --foreground  Run in foreground (don't check for existing instance)
    --check         Run single check and exit (for testing)

CONFIGURATION:
    Create /etc/disk-watchdog.conf or set environment variables:

    DISK_WATCHDOG_MOUNT=/              # Mount point to monitor
    DISK_WATCHDOG_USER=username        # User whose processes to manage
    DISK_WATCHDOG_LOG=/var/log/disk-watchdog.log

    # Thresholds in GB (action when free space drops below)
    DISK_WATCHDOG_THRESH_NOTICE=150    # Light notification
    DISK_WATCHDOG_THRESH_WARN=100      # Warning notification
    DISK_WATCHDOG_THRESH_HARSH=50      # Urgent warning
    DISK_WATCHDOG_THRESH_PAUSE=25      # SIGSTOP (pause processes)
    DISK_WATCHDOG_THRESH_STOP=10       # SIGTERM (graceful stop)
    DISK_WATCHDOG_THRESH_KILL=5        # SIGKILL (force kill)

    # Process patterns (pipe-separated regex)
    DISK_WATCHDOG_PROCS="fastp|rsync|cp"

ADAPTIVE INTERVALS:
    >150GB free: check every 5 minutes
    >100GB free: check every 1 minute
    >50GB free:  check every 30 seconds
    >25GB free:  check every 10 seconds
    >10GB free:  check every 5 seconds
    <10GB free:  check every 2 seconds

SIGNALS:
    At 25GB: SIGSTOP (pause) - resume with: pkill -CONT -f 'pattern'
    At 10GB: SIGTERM (graceful stop)
    At 5GB:  SIGKILL (force kill)

EOF
    exit 0
}

single_check() {
    local free=$(get_free_gb)
    local level=$(get_level "$free")
    local interval=$(get_check_interval "$free")

    echo "Mount: $MOUNT_POINT"
    echo "Free: ${free}GB"
    echo "Level: $level"
    echo "Check interval: ${interval}s"
    echo ""
    echo "Thresholds:"
    echo "  Notice: <${THRESH_NOTICE}GB"
    echo "  Warn:   <${THRESH_WARN}GB"
    echo "  Harsh:  <${THRESH_HARSH}GB"
    echo "  Pause:  <${THRESH_PAUSE}GB (SIGSTOP)"
    echo "  Stop:   <${THRESH_STOP}GB (SIGTERM)"
    echo "  Kill:   <${THRESH_KILL}GB (SIGKILL)"

    exit 0
}

# =============================================================================
# MAIN
# =============================================================================

# Parse arguments
FOREGROUND=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        -v|--version) echo "disk-watchdog v${VERSION}"; exit 0 ;;
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -f|--foreground) FOREGROUND=true; shift ;;
        --check) single_check ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Re-source config if specified
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Check for existing instance
if [[ "$FOREGROUND" != "true" ]] && [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "disk-watchdog already running (PID $OLD_PID)"
        exit 1
    fi
fi

# Setup
trap cleanup SIGTERM SIGINT SIGHUP
echo $$ > "$PID_FILE"
touch "$LOG_FILE"

log_msg "INFO" "disk-watchdog v${VERSION} started (PID $$)"
log_msg "INFO" "Monitoring: $MOUNT_POINT | User: ${TARGET_USER:-any} | Thresholds: ${THRESH_KILL}/${THRESH_STOP}/${THRESH_PAUSE}GB"

LAST_LEVEL=$(read_state)

# Main loop
while true; do
    FREE=$(get_free_gb)

    if [[ -z "$FREE" ]]; then
        log_msg "ERROR" "Could not read free space for $MOUNT_POINT"
        sleep 60
        continue
    fi

    LEVEL=$(get_level "$FREE")
    INTERVAL=$(get_check_interval "$FREE")

    # Only act on transitions to worse states (or recovery)
    case "$LEVEL" in
        kill)
            if [[ "$LAST_LEVEL" != "kill" ]]; then
                log_msg "EMERGENCY" "${FREE}GB free - KILLING processes"
                kill_procs "-KILL" && log_msg "EMERGENCY" "Sent SIGKILL to processes"
                notify_desktop "critical" "DISK EMERGENCY" "${FREE}GB free! Processes KILLED!"
                notify_wall "DISK EMERGENCY: ${FREE}GB free! Processes KILLED!"
                write_state "kill"
                LAST_LEVEL="kill"
            fi
            ;;
        stop)
            if [[ "$LAST_LEVEL" != "stop" && "$LAST_LEVEL" != "kill" ]]; then
                log_msg "CRITICAL" "${FREE}GB free - stopping processes"
                kill_procs "-TERM" && log_msg "CRITICAL" "Sent SIGTERM to processes"
                notify_desktop "critical" "DISK CRITICAL" "${FREE}GB free! Processes stopped."
                notify_wall "DISK CRITICAL: ${FREE}GB free! Processes stopped."
                write_state "stop"
                LAST_LEVEL="stop"
            fi
            ;;
        pause)
            if [[ "$LAST_LEVEL" != "pause" && "$LAST_LEVEL" != "stop" && "$LAST_LEVEL" != "kill" ]]; then
                log_msg "WARNING" "${FREE}GB free - pausing processes"
                kill_procs "-STOP" && log_msg "WARNING" "Sent SIGSTOP to processes"
                notify_desktop "critical" "DISK LOW" "${FREE}GB free! Processes PAUSED."
                notify_wall "DISK LOW: ${FREE}GB free! Processes PAUSED. Resume with: pkill -CONT -f '$PROC_PATTERNS'"
                write_state "pause"
                LAST_LEVEL="pause"
            fi
            ;;
        harsh)
            if [[ "$LAST_LEVEL" == "ok" || "$LAST_LEVEL" == "notice" || "$LAST_LEVEL" == "warn" ]]; then
                log_msg "WARNING" "${FREE}GB free"
                notify_desktop "critical" "Disk Space Low" "${FREE}GB free. Consider stopping jobs."
                notify_wall "DISK WARNING: ${FREE}GB free. Consider stopping jobs!"
                write_state "harsh"
                LAST_LEVEL="harsh"
            fi
            ;;
        warn)
            if [[ "$LAST_LEVEL" == "ok" || "$LAST_LEVEL" == "notice" ]]; then
                log_msg "NOTICE" "${FREE}GB free"
                notify_desktop "normal" "Disk Space Notice" "${FREE}GB free on $MOUNT_POINT"
                write_state "warn"
                LAST_LEVEL="warn"
            fi
            ;;
        notice)
            if [[ "$LAST_LEVEL" == "ok" ]]; then
                log_msg "NOTICE" "${FREE}GB free - monitoring closely"
                write_state "notice"
                LAST_LEVEL="notice"
            fi
            ;;
        ok)
            if [[ "$LAST_LEVEL" != "ok" ]]; then
                log_msg "INFO" "Recovered to ${FREE}GB free"
                notify_desktop "normal" "Disk Space OK" "Recovered to ${FREE}GB free"
                write_state "ok"
                LAST_LEVEL="ok"
            fi
            ;;
    esac

    sleep "$INTERVAL"
done
