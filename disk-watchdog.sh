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

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="disk-watchdog"

# =============================================================================
# CONFIGURATION
# =============================================================================

CONFIG_FILE="${DISK_WATCHDOG_CONFIG:-/etc/disk-watchdog.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Paths
MOUNT_POINT="${DISK_WATCHDOG_MOUNT:-/}"
LOG_FILE="${DISK_WATCHDOG_LOG:-/var/log/disk-watchdog.log}"
STATE_DIR="${DISK_WATCHDOG_STATE_DIR:-/var/lib/disk-watchdog}"
STATE_FILE="${STATE_DIR}/state"
RATE_FILE="${STATE_DIR}/rate"
PID_FILE="${DISK_WATCHDOG_PID:-/run/disk-watchdog.pid}"

# User whose processes to manage
TARGET_USER="${DISK_WATCHDOG_USER:-}"

# Thresholds in GB
THRESH_NOTICE="${DISK_WATCHDOG_THRESH_NOTICE:-150}"
THRESH_WARN="${DISK_WATCHDOG_THRESH_WARN:-100}"
THRESH_HARSH="${DISK_WATCHDOG_THRESH_HARSH:-50}"
THRESH_PAUSE="${DISK_WATCHDOG_THRESH_PAUSE:-25}"
THRESH_STOP="${DISK_WATCHDOG_THRESH_STOP:-10}"
THRESH_KILL="${DISK_WATCHDOG_THRESH_KILL:-5}"

# Rate threshold: warn if losing more than X GB per minute
RATE_WARN_GB_PER_MIN="${DISK_WATCHDOG_RATE_WARN:-2}"

# Smart mode: detect and kill actual heavy writers (vs predefined list)
SMART_MODE="${DISK_WATCHDOG_SMART:-true}"

# Minimum bytes written to consider a process a "heavy writer" (default 100MB)
HEAVY_WRITER_THRESHOLD="${DISK_WATCHDOG_HEAVY_THRESHOLD:-104857600}"

# Fallback process patterns if smart mode fails
PROC_PATTERNS="${DISK_WATCHDOG_PROCS:-fastp|kraken|dustmasker|bwa|spades|megahit|rsync|photorec|dd|cp|mv}"

# Processes to never kill (pipe-separated)
PROTECTED_PROCS="${DISK_WATCHDOG_PROTECTED:-systemd|init|sshd|Xorg|cinnamon|gnome-shell|kde|dbus}"

# Notifications
ENABLE_DESKTOP="${DISK_WATCHDOG_DESKTOP:-true}"
ENABLE_WALL="${DISK_WATCHDOG_WALL:-true}"

# Rate limiting: minimum seconds between notifications of same level
NOTIFY_COOLDOWN="${DISK_WATCHDOG_NOTIFY_COOLDOWN:-300}"

# Dry run mode (log but don't kill)
DRY_RUN="${DISK_WATCHDOG_DRY_RUN:-false}"

# Max log file size in bytes (default 10MB)
MAX_LOG_SIZE="${DISK_WATCHDOG_MAX_LOG:-10485760}"

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

    if [[ -n "$TARGET_USER" ]]; then
        # Try multiple display methods
        for display in :0 :1; do
            su - "$TARGET_USER" -c "DISPLAY=$display notify-send -u '$urgency' '$title' '$msg'" 2>/dev/null && return 0
        done
        # Try without DISPLAY (wayland)
        su - "$TARGET_USER" -c "notify-send -u '$urgency' '$title' '$msg'" 2>/dev/null || true
    fi
}

notify_wall() {
    [[ "$ENABLE_WALL" != "true" ]] && return 0
    echo "$1" | wall 2>/dev/null || true
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
    if   (( free > THRESH_NOTICE )); then echo 300
    elif (( free > THRESH_WARN ));   then echo 60
    elif (( free > THRESH_HARSH ));  then echo 30
    elif (( free > THRESH_PAUSE ));  then echo 10
    elif (( free > THRESH_STOP ));   then echo 5
    else                                  echo 2
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

read_state() {
    cat "$STATE_FILE" 2>/dev/null || echo "ok"
}

write_state() {
    echo "$1" > "$STATE_FILE" 2>/dev/null || true
}

# =============================================================================
# RATE DETECTION
# =============================================================================

calculate_rate() {
    local current_bytes="$1"
    local current_time
    current_time=$(date +%s)

    if [[ -f "$RATE_FILE" ]]; then
        local prev_bytes prev_time
        read -r prev_bytes prev_time < "$RATE_FILE" 2>/dev/null || return

        if [[ -n "$prev_bytes" && -n "$prev_time" ]]; then
            local bytes_diff=$(( current_bytes - prev_bytes ))
            local time_diff=$(( current_time - prev_time ))

            if (( time_diff > 0 && bytes_diff < 0 )); then
                # Disk is filling (free space decreased)
                local bytes_per_sec=$(( -bytes_diff / time_diff ))
                local gb_per_min=$(( bytes_per_sec * 60 / 1024 / 1024 / 1024 ))

                if (( gb_per_min >= RATE_WARN_GB_PER_MIN )); then
                    echo "$gb_per_min"
                    return
                fi
            fi
        fi
    fi

    echo "$current_bytes $current_time" > "$RATE_FILE" 2>/dev/null || true
    echo "0"
}

# =============================================================================
# SMART WRITER DETECTION
# =============================================================================

get_heavy_writers() {
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
            else
                if kill "$signal" "$pid" 2>/dev/null; then
                    log_msg "ACTION" "Sent $signal to $comm (PID $pid, wrote $bytes_fmt)"
                    killed_names+=("$comm($bytes_fmt)")
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
            else
                if kill "$signal" "$pid" 2>/dev/null; then
                    log_msg "ACTION" "Sent $signal to $comm (PID $pid)"
                    killed_names+=("$comm")
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

    if [[ -n "$killed" ]]; then
        notify_desktop "critical" "DISK EMERGENCY" "${free}GB free! KILLED: $killed"
        notify_wall "DISK EMERGENCY: ${free}GB free! KILLED: $killed"
    else
        notify_desktop "critical" "DISK EMERGENCY" "${free}GB free! No heavy writers found to kill."
        notify_wall "DISK EMERGENCY: ${free}GB free! No heavy writers found."
    fi
}

action_stop() {
    local free="$1"
    log_msg "CRITICAL" "${free}GB free - sending SIGTERM"

    local stopped
    stopped=$(kill_heavy_writers "-TERM" 5)

    if [[ -n "$stopped" ]]; then
        notify_desktop "critical" "DISK CRITICAL" "${free}GB free! Stopped: $stopped"
        notify_wall "DISK CRITICAL: ${free}GB free! Stopped: $stopped"
    fi
}

action_pause() {
    local free="$1"
    log_msg "WARNING" "${free}GB free - sending SIGSTOP (pause)"

    local paused
    paused=$(kill_heavy_writers "-STOP" 5)

    if [[ -n "$paused" ]]; then
        notify_desktop "critical" "DISK LOW" "${free}GB free! PAUSED: $paused - Resume with: pkill -CONT ..."
        notify_wall "DISK LOW: ${free}GB free! PAUSED: $paused - Resume with: pkill -CONT -u $TARGET_USER"
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

        notify_desktop "critical" "Disk Space Low" "${free}GB free.${rate_info}${writers_info}"
        notify_wall "DISK WARNING: ${free}GB free.${rate_info}${writers_info}"
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
    local free
    free=$(get_free_gb) || die "Cannot read disk space for $MOUNT_POINT"

    local level interval state
    level=$(get_level "$free")
    interval=$(get_check_interval "$free")
    state=$(read_state)

    echo "disk-watchdog v${VERSION}"
    echo ""
    echo "Mount point:     $MOUNT_POINT"
    echo "Free space:      ${free}GB"
    echo "Current level:   $level"
    echo "Saved state:     $state"
    echo "Check interval:  ${interval}s"
    echo "Target user:     ${TARGET_USER:-any}"
    echo "Smart mode:      $SMART_MODE"
    echo "Dry run:         $DRY_RUN"
    echo ""
    echo "Thresholds:"
    echo "  Notice: <${THRESH_NOTICE}GB"
    echo "  Warn:   <${THRESH_WARN}GB"
    echo "  Harsh:  <${THRESH_HARSH}GB"
    echo "  Pause:  <${THRESH_PAUSE}GB (SIGSTOP)"
    echo "  Stop:   <${THRESH_STOP}GB (SIGTERM)"
    echo "  Kill:   <${THRESH_KILL}GB (SIGKILL)"
    echo ""

    if [[ "$SMART_MODE" == "true" ]]; then
        echo "Top disk writers (${TARGET_USER:-all users}):"
        local count=0
        while IFS=: read -r bytes pid comm; do
            [[ -z "$pid" ]] && continue
            printf "  %10s - %s (PID %s)\n" "$(format_bytes "$bytes")" "$comm" "$pid"
            (( ++count >= 5 )) && break
        done < <(get_heavy_writers)
        [[ $count -eq 0 ]] && echo "  (none detected)"
    fi
    return 0
}

cmd_check() {
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

cmd_run() {
    # Check for existing instance
    if [[ -f "$PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            die "Already running (PID $old_pid). Use 'disk-watchdog stop' first."
        fi
    fi

    # Setup
    mkdir -p "$STATE_DIR" 2>/dev/null || die "Cannot create state directory: $STATE_DIR"
    touch "$LOG_FILE" 2>/dev/null || die "Cannot write to log file: $LOG_FILE"
    echo $$ > "$PID_FILE" 2>/dev/null || die "Cannot write PID file: $PID_FILE"

    # Signal handlers
    trap 'log_msg "INFO" "Received SIGTERM, shutting down"; rm -f "$PID_FILE"; exit 0' SIGTERM
    trap 'log_msg "INFO" "Received SIGINT, shutting down"; rm -f "$PID_FILE"; exit 0' SIGINT
    trap 'log_msg "INFO" "Received SIGHUP, reloading config"; [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"' SIGHUP

    log_msg "INFO" "$SCRIPT_NAME v${VERSION} started (PID $$)"
    log_msg "INFO" "Config: mount=$MOUNT_POINT user=${TARGET_USER:-any} smart=$SMART_MODE dry_run=$DRY_RUN"
    log_msg "INFO" "Thresholds: kill=${THRESH_KILL}GB stop=${THRESH_STOP}GB pause=${THRESH_PAUSE}GB"

    local last_level
    last_level=$(read_state)

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
        level=$(get_level "$free")
        interval=$(get_check_interval "$free")

        # Log rate warnings
        if (( rate > 0 )); then
            log_msg "RATE" "Disk filling at ~${rate}GB/min (${free}GB free)"
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

cmd_help() {
    cat << 'EOF'
disk-watchdog - Adaptive disk space monitor

USAGE:
    disk-watchdog [COMMAND] [OPTIONS]

COMMANDS:
    run         Start monitoring (default if no command given)
    stop        Stop the running daemon
    status      Show current disk status and top writers
    check       Quick check - exits 0 if OK, 1 if warning/critical
    writers     Show top disk writers
    help        Show this help

OPTIONS:
    -c, --config FILE    Config file (default: /etc/disk-watchdog.conf)
    -m, --mount PATH     Mount point to monitor (default: /)
    -u, --user USER      Only manage this user's processes
    -n, --dry-run        Log actions but don't kill processes
    -v, --version        Show version
    -h, --help           Show this help

QUICK START:
    # Install and configure
    sudo cp disk-watchdog.sh /usr/local/bin/disk-watchdog
    sudo cp disk-watchdog.conf /etc/
    sudo nano /etc/disk-watchdog.conf  # Set DISK_WATCHDOG_USER

    # Test
    disk-watchdog status
    disk-watchdog --dry-run run

    # Run as service
    sudo systemctl enable --now disk-watchdog

THRESHOLDS (configurable):
    <150GB  Notice (log only)
    <100GB  Warning (desktop notification)
    <50GB   Harsh warning (wall message)
    <25GB   PAUSE processes (SIGSTOP - resumable!)
    <10GB   STOP processes (SIGTERM)
    <5GB    KILL processes (SIGKILL)

SMART MODE:
    By default, disk-watchdog detects which processes are actually
    writing heavily to disk and targets those, rather than using
    a predefined list. Disable with DISK_WATCHDOG_SMART=false.

RESUMING PAUSED PROCESSES:
    pkill -CONT -u USERNAME

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local cmd="run"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            run|stop|status|check|writers|help)
                cmd="$1"
                shift
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
        run)     cmd_run ;;
        stop)    cmd_stop ;;
        status)  cmd_status ;;
        check)   cmd_check ;;
        writers) cmd_writers ;;
        help)    cmd_help ;;
    esac
}

main "$@"
