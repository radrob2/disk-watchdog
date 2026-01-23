# disk-watchdog

Adaptive disk space monitor that checks more frequently as your disk fills up, and automatically stops runaway processes before you run out of space.

## Why?

- Your pipeline fills the disk at 2am and crashes your system
- `earlyoom` exists for memory, but nothing similar for disk space
- Fixed-interval monitoring is either too slow (miss the problem) or too fast (wasted resources)
- You want processes **paused** (resumable) not killed when possible

## Features

- **Adaptive checking** - every 5 min when healthy, every 2 sec when critical
- **Smart writer detection** - finds and stops actual heavy disk writers, not just a predefined list
- **Rate detection** - warns when disk is filling rapidly (e.g., "filling at 2GB/min!")
- **Graduated response** - warn → pause (SIGSTOP) → stop (SIGTERM) → kill (SIGKILL)
- **SIGSTOP/SIGCONT support** - pause processes without losing work, resume when space is freed
- **Protected processes** - never kills system-critical processes (systemd, sshd, X11, etc.)
- **Desktop notifications** - via `notify-send`
- **Dry-run mode** - test what would happen without killing anything
- **Log rotation** - won't fill your disk with logs
- **Notification rate limiting** - won't spam you with alerts
- **Configurable** - thresholds, process patterns, mount points
- **Lightweight** - single bash script, no dependencies beyond coreutils

## Quick Install

```bash
# Clone and install
git clone https://github.com/radrob/disk-watchdog
cd disk-watchdog
sudo cp disk-watchdog.sh /usr/local/bin/disk-watchdog
sudo chmod +x /usr/local/bin/disk-watchdog
sudo cp disk-watchdog.conf /etc/
sudo cp disk-watchdog.service /etc/systemd/system/

# Configure (REQUIRED: set your username)
sudo nano /etc/disk-watchdog.conf

# Start
sudo systemctl daemon-reload
sudo systemctl enable --now disk-watchdog
```

## Usage

```bash
# Show current status and top disk writers
disk-watchdog status

# Show all heavy disk writers
disk-watchdog writers

# Quick check (exits 0 if OK, 1 if warning/critical)
disk-watchdog check

# Test in dry-run mode (logs but doesn't kill)
disk-watchdog --dry-run run

# Run in foreground
disk-watchdog run

# Stop daemon
disk-watchdog stop
```

## Configuration

Edit `/etc/disk-watchdog.conf`:

```bash
# User whose processes to manage (REQUIRED!)
DISK_WATCHDOG_USER=myusername

# Mount point to monitor
DISK_WATCHDOG_MOUNT=/

# Thresholds in GB (action when free space drops below)
DISK_WATCHDOG_THRESH_NOTICE=150   # Log only
DISK_WATCHDOG_THRESH_WARN=100     # Desktop notification
DISK_WATCHDOG_THRESH_HARSH=50     # Urgent warning + wall
DISK_WATCHDOG_THRESH_PAUSE=25     # SIGSTOP - pause processes (resumable!)
DISK_WATCHDOG_THRESH_STOP=10      # SIGTERM - graceful stop
DISK_WATCHDOG_THRESH_KILL=5       # SIGKILL - force kill

# Smart mode: detect actual heavy writers (recommended)
DISK_WATCHDOG_SMART=true

# Rate warning: alert if disk filling faster than X GB/min
DISK_WATCHDOG_RATE_WARN=2

# Processes to never kill
DISK_WATCHDOG_PROTECTED="systemd|init|sshd|Xorg|cinnamon|gnome-shell"
```

## How It Works

### Adaptive Check Intervals

| Free Space | Check Every | Why |
|------------|-------------|-----|
| > 150 GB   | 5 minutes   | All good, minimal overhead |
| > 100 GB   | 1 minute    | Getting lower, pay attention |
| > 50 GB    | 30 seconds  | Warning zone |
| > 25 GB    | 10 seconds  | Danger zone |
| > 10 GB    | 5 seconds   | Critical |
| < 10 GB    | 2 seconds   | Emergency, catch it fast |

### Smart Writer Detection

Instead of killing processes based on name patterns, disk-watchdog reads `/proc/[pid]/io` to find which processes have actually written the most data. This means it will stop whatever is actually filling your disk, even if it's an unexpected process.

```bash
# See what it would target
disk-watchdog writers
```

Example output:
```
Heavy disk writers (radrob):
     255.8GB  mv (PID 150688)
     241.6GB  bash (PID 27469)
      63.1GB  rsync (PID 8448)
       2.4GB  kraken2 (PID 194346)
```

### Graduated Response

| Free Space | Signal   | Effect |
|------------|----------|--------|
| < 25 GB    | SIGSTOP  | **Pause** - processes freeze, can resume later |
| < 10 GB    | SIGTERM  | **Stop** - graceful shutdown |
| < 5 GB     | SIGKILL  | **Kill** - force kill, last resort |

### Resuming Paused Processes

When processes are paused with SIGSTOP, they're frozen but not dead. Once you free up space:

```bash
# Resume all stopped processes for your user
pkill -CONT -u $USER

# Or resume specific process
kill -CONT <PID>
```

## Logs

```bash
# View logs
sudo tail -f /var/log/disk-watchdog.log

# Check service status
sudo systemctl status disk-watchdog
```

## How It Compares

| Tool | Monitors | Adaptive | Smart Detection | SIGSTOP |
|------|----------|----------|-----------------|---------|
| `earlyoom` | Memory | No | N/A | No |
| `monit` | Disk/CPU/etc | No | No | No |
| `disk-watchdog` | Disk | **Yes** | **Yes** | **Yes** |

## Troubleshooting

**"Cannot create state directory"** - Run as root or with sudo for the daemon.

**Desktop notifications not working** - Make sure `DISK_WATCHDOG_USER` is set and `notify-send` is installed.

**Processes not being detected** - Check that `DISK_WATCHDOG_USER` matches the user running the processes.

## License

MIT

## Contributing

Issues and PRs welcome at https://github.com/radrob/disk-watchdog
