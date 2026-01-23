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
    echo -e "${DIM}$(printf '%.0s─' {1..50})${NC}"
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
echo -e "${BOLD}┌────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│         ${CYAN}disk-watchdog${NC} ${BOLD}installer        │${NC}"
if [[ "$INTERACTIVE" == "yes" ]]; then
echo -e "${BOLD}│            ${DIM}interactive mode${NC}${BOLD}            │${NC}"
fi
echo -e "${BOLD}└────────────────────────────────────────┘${NC}"

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
header "1/4  Dependencies"

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
header "2/4  Download"

step "Downloading disk-watchdog..."
download "$REPO_URL/disk-watchdog.sh" /usr/local/bin/disk-watchdog
chmod +x /usr/local/bin/disk-watchdog
success "Installed /usr/local/bin/disk-watchdog"

download "$REPO_URL/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
success "Installed systemd service"

# ============================================================
# STEP 3: Configure
# ============================================================
header "3/4  Configure"

if [[ ! -f /etc/disk-watchdog.conf ]]; then
    download "$REPO_URL/disk-watchdog.conf" /etc/disk-watchdog.conf
    sed -i "s|# DISK_WATCHDOG_BIOTOP_CMD=.*|DISK_WATCHDOG_BIOTOP_CMD=$BIOTOP_CMD|" /etc/disk-watchdog.conf
    success "Created /etc/disk-watchdog.conf"

    if [[ "$INTERACTIVE" == "yes" ]]; then
        # --- Process Monitoring ---
        echo ""
        echo -e "  ${BOLD}Which processes should disk-watchdog monitor?${NC}"
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
                read -p "  Enter username to monitor: " REAL_USER
            else
                read -p "  Enter username (default: $REAL_USER): " input_user
                [[ -n "$input_user" ]] && REAL_USER="$input_user"
            fi
            if [[ -n "$REAL_USER" ]]; then
                sed -i "s|^DISK_WATCHDOG_USER=.*|DISK_WATCHDOG_USER=$REAL_USER|" /etc/disk-watchdog.conf
                success "Monitoring user: $REAL_USER"
            fi
        else
            success "Monitoring all users"
        fi

        # --- Push Notifications ---
        echo ""
        echo -e "  ${BOLD}Push notifications to your phone?${NC}"
        echo -e "  ${DIM}Uses ntfy.sh - free, no account required${NC}"
        echo ""
        read -p "  Enable push notifications? [y/N]: " enable_ntfy

        if [[ "$enable_ntfy" =~ ^[Yy] ]]; then
            NTFY_TOPIC="disk-watchdog-$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"
            NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"

            sed -i "s|^DISK_WATCHDOG_WEBHOOK=.*|DISK_WATCHDOG_WEBHOOK=true|" /etc/disk-watchdog.conf
            sed -i "s|^# DISK_WATCHDOG_WEBHOOK_URL=https://ntfy.sh/.*|DISK_WATCHDOG_WEBHOOK_URL=${NTFY_URL}|" /etc/disk-watchdog.conf

            success "Push notifications enabled"
            echo ""

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
                # ntfy app install
                echo -e "  ${BOLD}Step 1: Install the ntfy app${NC}"
                echo -e "  ${DIM}Scan this QR code or visit: https://ntfy.sh${NC}"
                echo ""
                qrencode -t ANSIUTF8 "https://ntfy.sh" | sed 's/^/  /'

                # Subscribe
                echo ""
                echo -e "  ${BOLD}Step 2: Subscribe to alerts${NC}"
                echo -e "  ${DIM}Open ntfy app, tap +, and enter this topic:${NC}"
                echo ""
                echo -e "    ${YELLOW}${BOLD}$NTFY_TOPIC${NC}"
                echo ""
                echo -e "  ${DIM}Keep this topic private - anyone with it can see alerts${NC}"
                echo ""
                read -p "  Press Enter after subscribing to send a test notification... " _

                echo ""
                step "Sending test notification..."
                if curl -s -o /dev/null -w "%{http_code}" -d "disk-watchdog installed successfully!" "https://ntfy.sh/${NTFY_TOPIC}" | grep -q "200"; then
                    success "Test notification sent! Check your phone."
                else
                    error "Failed to send. Check your network connection."
                fi
            else
                echo ""
                info "To receive notifications:"
                info "1. Install ntfy app: https://ntfy.sh"
                info "2. Subscribe to topic: $NTFY_TOPIC"
            fi
        else
            info "Push notifications skipped"
        fi
    else
        # Non-interactive: use defaults
        success "Monitoring all users (default)"
        info "For push notifications, re-run with: --interactive"
    fi
else
    info "Config already exists, skipping"
fi

# Create state directory
mkdir -p /var/lib/disk-watchdog

# ============================================================
# STEP 4: Systemd
# ============================================================
header "4/4  Systemd"

systemctl daemon-reload
success "Reloaded systemd"

# ============================================================
# Done!
# ============================================================
echo ""
echo -e "${GREEN}${BOLD}┌────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│         Installation complete!         │${NC}"
echo -e "${GREEN}${BOLD}└────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Start the service:"
echo -e "     ${DIM}sudo systemctl enable --now disk-watchdog${NC}"
echo ""
echo -e "  ${CYAN}2.${NC} Check status:"
echo -e "     ${DIM}sudo disk-watchdog status${NC}"
echo ""
echo -e "${DIM}Config: /etc/disk-watchdog.conf${NC}"
echo ""
