#!/bin/bash
# disk-watchdog interactive installer
# Prompts for configuration options and sets up push notifications
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/radrob2/disk-watchdog/master"

# If piped (curl|bash), re-download and exec with terminal access
if [[ ! -t 0 ]]; then
    echo "Downloading installer..."
    TMPSCRIPT=$(mktemp)
    trap "rm -f '$TMPSCRIPT'" EXIT
    if command -v curl &>/dev/null; then
        curl -fsSL "$REPO_URL/install-interactive.sh" -o "$TMPSCRIPT"
    elif command -v wget &>/dev/null; then
        wget -q "$REPO_URL/install-interactive.sh" -O "$TMPSCRIPT"
    else
        echo "Error: curl or wget required."
        exit 1
    fi
    echo "Starting interactive installer..."
    chmod +x "$TMPSCRIPT"
    exec bash "$TMPSCRIPT" "$@" </dev/tty
fi

echo "========================================"
echo "  disk-watchdog installer (interactive)"
echo "========================================"
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This installer must be run as root (sudo)."
    exit 1
fi

# Check for curl or wget
if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    echo "Installing curl..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y -qq curl
    elif command -v dnf &>/dev/null; then
        dnf install -y -q curl
    elif command -v yum &>/dev/null; then
        yum install -y -q curl
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm curl
    else
        echo "Error: curl or wget required. Please install manually."
        exit 1
    fi
fi

# Download helper function (supports curl or wget)
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
    echo "Error: Could not detect package manager (apt/dnf/yum/pacman)."
    echo "Please install bpfcc-tools (or bcc-tools) manually, then re-run."
    exit 1
fi

# Install biotop dependency
echo "[1/4] Installing eBPF tools ($BIOTOP_PKG)..."
if ! command -v biotop-bpfcc &>/dev/null && ! command -v biotop &>/dev/null; then
    case "$PKG_MGR" in
        apt)    apt update -qq && apt install -y -qq "$BIOTOP_PKG" ;;
        dnf)    dnf install -y -q "$BIOTOP_PKG" ;;
        yum)    yum install -y -q "$BIOTOP_PKG" ;;
        pacman) pacman -Sy --noconfirm "$BIOTOP_PKG" ;;
    esac
    echo "    Installed $BIOTOP_PKG"
else
    echo "    Already installed"
fi

# Verify biotop works
BIOTOP_CMD=""
if command -v biotop-bpfcc &>/dev/null; then
    BIOTOP_CMD="biotop-bpfcc"
elif command -v biotop &>/dev/null; then
    BIOTOP_CMD="biotop"
else
    echo "Error: biotop not found after installation."
    echo "Please install bpfcc-tools manually."
    exit 1
fi
echo "    Using: $BIOTOP_CMD"

# Download files
echo ""
echo "[2/4] Downloading disk-watchdog..."
download "$REPO_URL/disk-watchdog.sh" /usr/local/bin/disk-watchdog
chmod +x /usr/local/bin/disk-watchdog
echo "    Installed /usr/local/bin/disk-watchdog"

download "$REPO_URL/disk-watchdog.service" /etc/systemd/system/disk-watchdog.service
echo "    Installed /etc/systemd/system/disk-watchdog.service"

# Install config if not exists
echo ""
echo "[3/4] Configuring..."
if [[ ! -f /etc/disk-watchdog.conf ]]; then
    download "$REPO_URL/disk-watchdog.conf" /etc/disk-watchdog.conf

    # Set biotop command
    sed -i "s|# DISK_WATCHDOG_BIOTOP_CMD=.*|DISK_WATCHDOG_BIOTOP_CMD=$BIOTOP_CMD|" /etc/disk-watchdog.conf

    # Ask about monitoring scope
    echo ""
    echo "    Which processes should disk-watchdog monitor?"
    echo ""
    echo "    1) All users (recommended) - catches any runaway process"
    echo "    2) Specific user only - only manages one user's processes"
    echo ""
    read -p "    Choose [1/2] (default: 1): " monitor_choice

    if [[ "$monitor_choice" == "2" ]]; then
        # Get the user who invoked sudo (not root)
        REAL_USER="${SUDO_USER:-}"
        if [[ -z "$REAL_USER" ]]; then
            read -p "    Enter username to monitor: " REAL_USER
        else
            read -p "    Enter username to monitor (default: $REAL_USER): " input_user
            [[ -n "$input_user" ]] && REAL_USER="$input_user"
        fi

        if [[ -n "$REAL_USER" ]]; then
            sed -i "s|^DISK_WATCHDOG_USER=.*|DISK_WATCHDOG_USER=$REAL_USER|" /etc/disk-watchdog.conf
            echo "    Configured to monitor user: $REAL_USER"
        fi
    else
        echo "    Configured to monitor all users"
    fi

    echo "    Created /etc/disk-watchdog.conf"

    # Ask about push notifications
    echo ""
    echo "    Do you want push notifications to your phone?"
    echo "    (Uses ntfy.sh - free, no account required)"
    echo ""
    read -p "    Enable push notifications? [y/N]: " enable_ntfy

    if [[ "$enable_ntfy" =~ ^[Yy] ]]; then
        # Generate random topic name
        NTFY_TOPIC="disk-watchdog-$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"
        NTFY_URL="https://ntfy.sh/${NTFY_TOPIC}"

        # Update config
        sed -i "s|^DISK_WATCHDOG_WEBHOOK=.*|DISK_WATCHDOG_WEBHOOK=true|" /etc/disk-watchdog.conf
        sed -i "s|^# DISK_WATCHDOG_WEBHOOK_URL=https://ntfy.sh/.*|DISK_WATCHDOG_WEBHOOK_URL=${NTFY_URL}|" /etc/disk-watchdog.conf

        echo ""
        echo "    Push notifications enabled!"
        echo "    Topic: $NTFY_TOPIC"
        echo "    URL: $NTFY_URL"
        echo ""

        # Check for qrencode
        if ! command -v qrencode &>/dev/null; then
            echo "    Installing qrencode for QR codes..."
            case "$PKG_MGR" in
                apt)    apt install -y -qq qrencode ;;
                dnf)    dnf install -y -q qrencode ;;
                yum)    yum install -y -q qrencode ;;
                pacman) pacman -S --noconfirm qrencode ;;
            esac
        fi

        if command -v qrencode &>/dev/null; then
            echo ""
            echo "    ┌─────────────────────────────────────────────────────┐"
            echo "    │  STEP 1: Install the ntfy app                       │"
            echo "    │  Scan this QR code or visit: https://ntfy.sh        │"
            echo "    └─────────────────────────────────────────────────────┘"
            echo ""
            qrencode -t ANSIUTF8 "https://ntfy.sh" | sed 's/^/    /'
            echo ""
            echo "    ┌─────────────────────────────────────────────────────┐"
            echo "    │  STEP 2: Subscribe in the ntfy app                  │"
            echo "    │  Add this topic: $NTFY_TOPIC"
            echo "    └─────────────────────────────────────────────────────┘"
            echo ""
            echo "    Keep this topic private - anyone with it can subscribe."
            echo ""
            read -p "    Press Enter after subscribing in the ntfy app... " _
        else
            echo ""
            echo "    To receive notifications:"
            echo "    1. Install ntfy app: https://ntfy.sh"
            echo "    2. Subscribe to topic: $NTFY_TOPIC"
            echo ""
        fi
    fi
else
    echo "    Config already exists, skipping"
fi

# Create state directory
mkdir -p /var/lib/disk-watchdog
echo "    Created /var/lib/disk-watchdog"

# Reload systemd
echo ""
echo "[4/4] Setting up systemd..."
systemctl daemon-reload
echo "    Reloaded systemd"

echo ""
echo "========================================"
echo "  Installation complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Start service: sudo systemctl enable --now disk-watchdog"
echo "  2. Check status:  sudo disk-watchdog status"
echo ""
echo "Optional: Edit /etc/disk-watchdog.conf to customize thresholds"
echo ""
