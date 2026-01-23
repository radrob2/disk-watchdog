#!/bin/bash
# disk-watchdog installer
# Auto-detects interactive vs non-interactive mode
# Use --interactive or --quick to override
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/radrob2/disk-watchdog/master"

# Colors and formatting
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper functions
header() {
    echo ""
    echo -e "${BOLD}${BLUE}$1${NC}"
    echo -e "${DIM}$(printf '%.0s─' {1..55})${NC}"
}

subheader() {
    echo ""
    echo -e "  ${BOLD}$1${NC}"
}

step() {
    echo -e "  ${CYAN}→${NC} $1"
}

success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

error() {
    echo -e "  ${RED}✗${NC} $1"
}

info() {
    echo -e "  ${DIM}$1${NC}"
}

# Parse arguments
INTERACTIVE=""
for arg in "$@"; do
    case "$arg" in
        --interactive|-i) INTERACTIVE="yes" ;;
        --quick|-q)       INTERACTIVE="no" ;;
    esac
done

# Auto-detect mode if not specified
if [[ -z "$INTERACTIVE" ]]; then
    if [[ -t 0 ]]; then
        INTERACTIVE="yes"
    else
        INTERACTIVE="no"
    fi
fi

# If piped but interactive requested, re-download and exec with terminal access
if [[ ! -t 0 ]] && [[ "$INTERACTIVE" == "yes" ]]; then
    echo -e "${DIM}Downloading installer...${NC}"
    TMPSCRIPT=$(mktemp)
    trap "rm -f '$TMPSCRIPT'" EXIT
    if command -v curl &>/dev/null; then
        curl -fsSL "$REPO_URL/install.sh" -o "$TMPSCRIPT"
    elif command -v wget &>/dev/null; then
        wget -q "$REPO_URL/install.sh" -O "$TMPSCRIPT"
    else
        echo "Error: curl or wget required."
        exit 1
    fi
    chmod +x "$TMPSCRIPT"
    exec bash "$TMPSCRIPT" --interactive </dev/tty
fi

# Banner
echo ""
echo -e "${BOLD}┌───────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│       ${CYAN}disk-watchdog${NC}${BOLD} installer           │${NC}"
if [[ "$INTERACTIVE" == "yes" ]]; then
echo -e "${BOLD}│         ${DIM}interactive mode${NC}${BOLD}                 │${NC}"
fi
echo -e "${BOLD}└───────────────────────────────────────────┘${NC}"

# Show what disk-watchdog does in interactive mode
if [[ "$INTERACTIVE" == "yes" ]]; then
    echo ""
    echo -e "  ${BOLD}What is disk-watchdog?${NC}"
    echo ""
    echo -e "  ${DIM}An adaptive disk space monitor that:${NC}"
    echo -e "  ${DIM}• Checks more frequently as disk fills up${NC}"
    echo -e "  ${DIM}• Detects which processes are writing heavily (via eBPF)${NC}"
    echo -e "  ${DIM}• Pauses or stops runaway processes before disk is full${NC}"
    echo -e "  ${DIM}• Sends notifications so you know what's happening${NC}"
    echo ""
    echo -e "  ${BOLD}How it responds:${NC}"
    echo ""
    echo -e "  ${DIM}  Disk getting full  →  Warning notifications${NC}"
    echo -e "  ${DIM}  Disk very low      →  ${NC}${YELLOW}SIGSTOP${NC}${DIM} (pause processes, resumable)${NC}"
    echo -e "  ${DIM}  Disk critical      →  ${NC}${RED}SIGTERM/SIGKILL${NC}${DIM} (stop processes)${NC}"
    echo ""
    read -p "  Press Enter to continue with installation... " _
fi

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo ""
    error "This installer must be run as root (sudo)."
    exit 1
fi

# Check for curl or wget
if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    step "Installing curl..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y -qq curl
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl
    elif command -v yum &>/dev/null; then
        yum install -y -q curl
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm curl
    else
        error "curl or wget required. Please install manually."
        exit 1
    fi
fi

# Download helper function
download() {
    local url="$1"
    local dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$dest"
    else
        wget -q "$url" -O "$dest"
    fi
}

# Detect package manager
if command -v apt &>/dev/null; then
    PKG_MGR="apt"
    BIOTOP_PKG="bpfcc-tools"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    BIOTOP_PKG="bcc-tools"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
    BIOTOP_PKG="bcc-tools"
elif command -v pacman &>/dev/null; then
    PKG_MGR="pacman"
    BIOTOP_PKG="bcc-tools"
else
    echo ""
    error "Could not detect package manager (apt/dnf/yum/pacman)."
    info "Please install bpfcc-tools (or bcc-tools) manually, then re-run."
    exit 1
fi

# ============================================================
# STEP 1: Dependencies
# ============================================================
header "1/4  Installing dependencies"

if ! command -v biotop-bpfcc &>/dev/null && ! command -v biotop &>/dev/null; then
    step "Installing eBPF tools ($BIOTOP_PKG)..."
    case "$PKG_MGR" in
        apt)    apt update -qq && apt install -y -qq "$BIOTOP_PKG" >/dev/null 2>&1 ;;
        dnf)    dnf install -y -q "$BIOTOP_PKG" >/dev/null 2>&1 ;;
        yum)    yum install -y -q "$BIOTOP_PKG" >/dev/null 2>&1 ;;
        pacman) pacman -Sy --noconfirm "$BIOTOP_PKG" >/dev/null 2>&1 ;;
    esac
    success "Installed $BIOTOP_PKG"
else
    success "eBPF tools already installed"
fi

# Verify biotop works
BIOTOP_CMD=""
if command -v biotop-bpfcc &>/dev/null; then
    BIOTOP_CMD="biotop-bpfcc"
elif command -v biotop &>/dev/null; then
    BIOTOP_CMD="biotop"
else
    error "biotop not found after installation."
    info "Please install bpfcc-tools manually."
    exit 1
fi
info "Using: $BIOTOP_CMD"

# ============================================================
# STEP 2: Download
# ============================================================
header "2/4  Downloading files"

step "Downloading disk-watchdog..."
download "$REPO_URL/disk-watchdog.sh" /usr/local/bin/disk-watchdog
chmod +x /usr/local/bin/disk-watchdog
success "/usr/local/bin/disk-watchdog"

download "$REPO_URL/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
success "/etc/systemd/system/disk-watchdog.service"

# ============================================================
# STEP 3: Configure
# ============================================================
header "3/4  Configuration"

# Track configuration choices for summary
CONFIG_MOUNT="/"
CONFIG_USER="all users"
CONFIG_NOTIFY="none"

if [[ ! -f /etc/disk-watchdog.conf ]]; then
    download "$REPO_URL/disk-watchdog.conf" /etc/disk-watchdog.conf
    sed -i "s|# DISK_WATCHDOG_BIOTOP_CMD=.*|DISK_WATCHDOG_BIOTOP_CMD=$BIOTOP_CMD|" /etc/disk-watchdog.conf
    success "Created /etc/disk-watchdog.conf"

    if [[ "$INTERACTIVE" == "yes" ]]; then

        # --- Mount Point ---
        subheader "Which disk to monitor?"
        echo ""

        # Get mount points into an array
        mapfile -t MOUNTS < <(df -h --output=target,size,avail,pcent -x tmpfs -x devtmpfs -x efivarfs -x overlay 2>/dev/null | tail -n +2 | head -10)

        # Display numbered options
        i=1
        for mount_line in "${MOUNTS[@]}"; do
            mount_path=$(echo "$mount_line" | awk '{print $1}')
            mount_info=$(echo "$mount_line" | awk '{print $2 " total, " $3 " free (" $4 " used)"}')
            if [[ "$mount_path" == "/" ]]; then
                echo -e "    ${CYAN}$i${NC})  $mount_path ${DIM}$mount_info${NC} ${DIM}(default)${NC}"
            else
                echo -e "    ${CYAN}$i${NC})  $mount_path ${DIM}$mount_info${NC}"
            fi
            ((i++))
        done
        echo ""
        read -p "  Choose [1-$((i-1))] (default: 1): " mount_choice

        # Parse selection
        if [[ -n "$mount_choice" ]] && [[ "$mount_choice" =~ ^[0-9]+$ ]] && [[ "$mount_choice" -ge 1 ]] && [[ "$mount_choice" -le "${#MOUNTS[@]}" ]]; then
            selected_mount=$(echo "${MOUNTS[$((mount_choice-1))]}" | awk '{print $1}')
            sed -i "s|^DISK_WATCHDOG_MOUNT=.*|DISK_WATCHDOG_MOUNT=$selected_mount|" /etc/disk-watchdog.conf
            CONFIG_MOUNT="$selected_mount"
            success "Monitoring: $selected_mount"
        else
            success "Monitoring: / (default)"
        fi

        # --- Process Monitoring Scope ---
        subheader "Which processes to manage?"
        echo ""
        echo -e "    ${CYAN}1${NC})  All users ${DIM}(recommended)${NC}"
        echo -e "        ${DIM}Catches any runaway process on the system${NC}"
        echo ""
        echo -e "    ${CYAN}2${NC})  Specific user only"
        echo -e "        ${DIM}Only manages one user's processes${NC}"
        echo ""
        read -p "  Choose [1/2] (default: 1): " monitor_choice

        if [[ "$monitor_choice" == "2" ]]; then
            REAL_USER="${SUDO_USER:-}"
            if [[ -z "$REAL_USER" ]]; then
                read -p "  Enter username: " REAL_USER
            else
                read -p "  Username (default: $REAL_USER): " input_user
                [[ -n "$input_user" ]] && REAL_USER="$input_user"
            fi
            if [[ -n "$REAL_USER" ]]; then
                sed -i "s|^DISK_WATCHDOG_USER=.*|DISK_WATCHDOG_USER=$REAL_USER|" /etc/disk-watchdog.conf
                CONFIG_USER="$REAL_USER"
                success "Managing processes for: $REAL_USER"
            fi
        else
            success "Managing processes for: all users"
        fi

        # --- Push Notifications ---
        subheader "Push notifications to your phone?"
        echo ""
        echo -e "  ${DIM}Get alerts via ntfy.sh (free, no account required)${NC}"
        echo -e "  ${DIM}You'll need to install the ntfy app on your phone${NC}"
        echo ""
        echo -e "    ${CYAN}y${NC})  Yes, set up push notifications ${DIM}(press Enter)${NC}"
        echo -e "    ${CYAN}n${NC})  No, skip this"
        echo ""
        read -p "  Enable push notifications? [Y/n]: " enable_ntfy

        if [[ ! "$enable_ntfy" =~ ^[Nn] ]]; then
            # Topic: dw-hostname-xxxx (identifiable + unique)
            HOSTNAME_SHORT=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -dc 'a-z0-9' | head -c 12)
            RANDOM_SUFFIX=$(head /dev/urandom | tr -dc 'abcdefghijkmnpqrstuvwxyz23456789' | head -c 4)
            NTFY_TOPIC="dw-${HOSTNAME_SHORT}-${RANDOM_SUFFIX}"
            NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"

            sed -i "s|^DISK_WATCHDOG_WEBHOOK=.*|DISK_WATCHDOG_WEBHOOK=true|" /etc/disk-watchdog.conf
            sed -i "s|^# DISK_WATCHDOG_WEBHOOK_URL=https://ntfy.sh/.*|DISK_WATCHDOG_WEBHOOK_URL=${NTFY_URL}|" /etc/disk-watchdog.conf
            CONFIG_NOTIFY="ntfy.sh"

            success "Push notifications enabled"

            # Install qrencode if needed
            if ! command -v qrencode &>/dev/null; then
                step "Installing qrencode..."
                case "$PKG_MGR" in
                    apt)    apt install -y -qq qrencode >/dev/null 2>&1 ;;
                    dnf)    dnf install -y -q qrencode >/dev/null 2>&1 ;;
                    yum)    yum install -y -q qrencode >/dev/null 2>&1 ;;
                    pacman) pacman -S --noconfirm qrencode >/dev/null 2>&1 ;;
                esac
            fi

            if command -v qrencode &>/dev/null; then
                echo ""
                echo -e "  ${BOLD}${CYAN}Step 1:${NC} ${BOLD}Install the ntfy app${NC}"
                echo -e "  ${DIM}Scan this QR code or visit: https://ntfy.sh${NC}"
                echo ""
                qrencode -t ANSIUTF8 "https://ntfy.sh" | sed 's/^/  /'

                echo ""
                echo -e "  ${BOLD}${CYAN}Step 2:${NC} ${BOLD}Subscribe to your alerts${NC}"
                echo -e "  ${DIM}Open the ntfy app, tap ${NC}+${DIM}, and enter this topic:${NC}"
                echo ""
                echo -e "      ${YELLOW}${BOLD}$NTFY_TOPIC${NC}"
                echo ""
                echo -e "  ${DIM}Keep this private - anyone with it can see your alerts${NC}"
                echo ""
                read -p "  Press Enter after subscribing to send a test... " _

                step "Sending test notification..."
                if curl -s -o /dev/null -w "%{http_code}" -d "disk-watchdog installed successfully!" "https://ntfy.sh/${NTFY_TOPIC}" | grep -q "200"; then
                    success "Test sent! Check your phone."
                else
                    error "Failed to send. Check your network."
                fi
            else
                info "To receive notifications:"
                info "1. Install ntfy app: https://ntfy.sh"
                info "2. Subscribe to topic: $NTFY_TOPIC"
            fi
        else
            info "Push notifications skipped"
            info "You can enable later in /etc/disk-watchdog.conf"
        fi
    else
        # Non-interactive: use defaults
        success "Using default configuration"
        info "Mount: /"
        info "Monitoring: all users"
        info "Push notifications: disabled"
        info "For interactive setup, re-run with: --interactive"
    fi
else
    info "Config already exists at /etc/disk-watchdog.conf"
    info "Delete it and re-run to reconfigure"
fi

# Create state directory
mkdir -p /var/lib/disk-watchdog

# ============================================================
# STEP 4: Systemd
# ============================================================
header "4/4  Finishing up"

systemctl daemon-reload
success "Registered systemd service"

# ============================================================
# Summary & Next Steps
# ============================================================
echo ""
echo -e "${GREEN}${BOLD}┌───────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│        Installation complete!             │${NC}"
echo -e "${GREEN}${BOLD}└───────────────────────────────────────────┘${NC}"

if [[ "$INTERACTIVE" == "yes" ]]; then
    echo ""
    echo -e "  ${BOLD}Configuration summary:${NC}"
    echo ""
    echo -e "    Mount point:      ${CYAN}$CONFIG_MOUNT${NC}"
    echo -e "    Monitoring:       ${CYAN}$CONFIG_USER${NC}"
    echo -e "    Push alerts:      ${CYAN}$CONFIG_NOTIFY${NC}"
    echo ""

    # Show thresholds for the monitored mount
    DISK_SIZE=$(df -BG "$CONFIG_MOUNT" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}')
    if [[ -n "$DISK_SIZE" ]] && [[ "$DISK_SIZE" -gt 0 ]]; then
        echo -e "  ${BOLD}Auto-calculated thresholds for ${DISK_SIZE}GB disk:${NC}"
        echo ""
        # Calculate thresholds (matching disk-watchdog.sh logic)
        NOTICE=$((DISK_SIZE * 10 / 100))
        WARN=$((DISK_SIZE * 7 / 100))
        HARSH=$((DISK_SIZE * 4 / 100))
        PAUSE=$((DISK_SIZE * 2 / 100)); [[ $PAUSE -gt 30 ]] && PAUSE=30
        STOP=$((DISK_SIZE * 1 / 100)); [[ $STOP -gt 15 ]] && STOP=15
        KILL=$((DISK_SIZE * 5 / 1000)); [[ $KILL -gt 5 ]] && KILL=5; [[ $KILL -lt 1 ]] && KILL=1

        echo -e "    ${DIM}< ${NOTICE}GB free${NC}  →  Notice (log only)"
        echo -e "    ${DIM}< ${WARN}GB free${NC}  →  Warning (desktop notification)"
        echo -e "    ${DIM}< ${HARSH}GB free${NC}  →  Harsh warning"
        echo -e "    ${YELLOW}< ${PAUSE}GB free${NC}  →  ${YELLOW}SIGSTOP${NC} (pause processes)"
        echo -e "    ${RED}< ${STOP}GB free${NC}  →  ${RED}SIGTERM${NC} (stop processes)"
        echo -e "    ${RED}< ${KILL}GB free${NC}  →  ${RED}SIGKILL${NC} (force kill)"
        echo ""
    fi
fi

echo -e "  ${BOLD}Next steps:${NC}"
echo ""
echo -e "    ${CYAN}1.${NC} Start the service:"
echo -e "       ${DIM}sudo systemctl enable --now disk-watchdog${NC}"
echo ""
echo -e "    ${CYAN}2.${NC} Check current status:"
echo -e "       ${DIM}sudo disk-watchdog status${NC}"
echo ""
echo -e "  ${DIM}Config file: /etc/disk-watchdog.conf${NC}"
echo -e "  ${DIM}Logs: /var/log/disk-watchdog.log${NC}"
echo ""
