#!/bin/bash
# disk-watchdog installer
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/radrob/disk-watchdog/main"

echo "========================================"
echo "  disk-watchdog installer"
echo "========================================"
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This installer must be run as root (sudo)."
    exit 1
fi

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
curl -fsSL "$REPO_URL/disk-watchdog.sh" -o /usr/local/bin/disk-watchdog
chmod +x /usr/local/bin/disk-watchdog
echo "    Installed /usr/local/bin/disk-watchdog"

curl -fsSL "$REPO_URL/disk-watchdog.service" -o /etc/systemd/system/disk-watchdog.service
echo "    Installed /etc/systemd/system/disk-watchdog.service"

# Install config if not exists
echo ""
echo "[3/4] Configuring..."
if [[ ! -f /etc/disk-watchdog.conf ]]; then
    curl -fsSL "$REPO_URL/disk-watchdog.conf" -o /etc/disk-watchdog.conf

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
