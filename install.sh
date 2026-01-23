#!/bin/bash
# disk-watchdog installer
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/radrob/disk-watchdog/main"

echo "Installing disk-watchdog..."

# Download files
curl -fsSL "$REPO_URL/disk-watchdog.sh" -o /usr/local/bin/disk-watchdog
chmod +x /usr/local/bin/disk-watchdog

curl -fsSL "$REPO_URL/disk-watchdog.service" -o /etc/systemd/system/disk-watchdog.service

# Install config if not exists
if [[ ! -f /etc/disk-watchdog.conf ]]; then
    curl -fsSL "$REPO_URL/disk-watchdog.conf" -o /etc/disk-watchdog.conf
    echo ""
    echo "IMPORTANT: Edit /etc/disk-watchdog.conf and set DISK_WATCHDOG_USER"
    echo ""
fi

# Reload systemd
systemctl daemon-reload

echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Edit config:  sudo nano /etc/disk-watchdog.conf"
echo "  2. Set your username in DISK_WATCHDOG_USER"
echo "  3. Start service: sudo systemctl enable --now disk-watchdog"
echo "  4. Check status:  sudo systemctl status disk-watchdog"
