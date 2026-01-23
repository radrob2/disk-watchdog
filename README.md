# disk-watchdog

Adaptive disk space monitor that checks more frequently as your disk fills up, and automatically stops runaway processes before you run out of space.

## Why?

- Your pipeline fills the disk at 2am and crashes your system
- `earlyoom` exists for memory, but nothing similar for disk space
- Fixed-interval monitoring is either too slow (miss the problem) or too fast (wasted resources)
- You want processes **paused** (resumable) not killed when possible

## Features

- **Adaptive checking** - every 5 min when healthy, every 1 sec when critical
- **eBPF-based detection** - uses `biotop` for real-time I/O monitoring (not cumulative stats)
- **Smart writer detection** - finds and stops actual heavy disk writers, not just a predefined list
- **Auto-calculated thresholds** - sensible defaults based on your disk size
- **Rate detection** - warns when disk is filling rapidly (e.g., "filling at 2GB/min!")
- **Graduated response** - warn → pause → stop → force kill (only if needed)
- **Pause & resume** - freeze processes without losing work, auto-resume when space is freed
- **Protected processes** - comprehensive list of system-critical processes
- **Monitors all users** - catches any runaway process, not just one user
- **Desktop notifications** - via `notify-send`
- **Dry-run mode** - test what would happen without killing anything
- **Log rotation** - won't fill your disk with logs
- **Notification rate limiting** - won't spam you with alerts
- **Configurable** - thresholds, process patterns, mount points
- **Auto-installs dependencies** - installer handles bpfcc-tools automatically

## Quick Install

```bash
# One-liner install (requires root)
curl -fsSL https://raw.githubusercontent.com/radrob2/disk-watchdog/master/install.sh | sudo bash
```

This installs with sensible defaults (monitors all users, no push notifications).

**Interactive install** (for push notifications setup):
```bash
curl -fsSL https://raw.githubusercontent.com/radrob2/disk-watchdog/master/install.sh | sudo bash -s -- --interactive
```

**Manual install:**
```bash
git clone https://github.com/radrob2/disk-watchdog
cd disk-watchdog
sudo ./install.sh              # auto-detects interactive mode
sudo ./install.sh --quick      # force non-interactive
sudo ./install.sh --interactive # force interactive
```

## Usage

```bash
# Show current status and top disk writers
disk-watchdog status

# Show all heavy disk writers
disk-watchdog writers

# Quick check (exits 0 if OK, 1 if warning/critical)
disk-watchdog check

# Resume all paused processes
disk-watchdog resume

# Test in dry-run mode (logs but doesn't kill)
disk-watchdog --dry-run run

# Run in foreground
disk-watchdog run

# Stop daemon
disk-watchdog stop

# Uninstall (preserves config/logs)
sudo disk-watchdog uninstall
```

## Configuration

Edit `/etc/disk-watchdog.conf`:

```bash
# User whose processes to manage
# Leave empty to monitor ALL users (default, recommended)
# Set to a username to only manage that user's processes
DISK_WATCHDOG_USER=

# Mount point to monitor
DISK_WATCHDOG_MOUNT=/

# Thresholds - auto-calculated by default based on disk size
# Upper thresholds (notice/warn/harsh): percentage of disk
# Lower thresholds (pause/stop/kill): percentage capped at safe maximums
#
# Auto-calculated defaults:
#   Notice: 10% of disk
#   Warn:   7% of disk
#   Harsh:  4% of disk
#   Pause:  2% of disk (max 30GB)
#   Stop:   1% of disk (max 15GB)
#   Kill:   0.5% of disk (max 5GB)
#
# Uncomment to override with fixed values:
# DISK_WATCHDOG_THRESH_NOTICE=150
# DISK_WATCHDOG_THRESH_PAUSE=25

# Smart mode: detect actual heavy writers (recommended)
DISK_WATCHDOG_SMART=true

# Rate warning: alert if disk filling faster than X GB/min
DISK_WATCHDOG_RATE_WARN=2
```

## How It Works

### Adaptive Check Intervals

Check frequency increases as space gets low (thresholds auto-calculated based on disk size):

| Level    | Check Every | Threshold (1.7TB disk example) |
|----------|-------------|-------------------------------|
| OK       | 5 minutes   | > 170 GB free (10%)           |
| Notice   | 1 minute    | > 119 GB free (7%)            |
| Warn     | 30 seconds  | > 68 GB free (4%)             |
| Harsh    | 10 seconds  | > 30 GB free (2%, max 30GB)   |
| Pause    | 3 seconds   | > 15 GB free (1%, max 15GB)   |
| Stop     | 1 second    | > 5 GB free (0.5%, max 5GB)   |
| Kill     | 1 second    | < 5 GB free                   |

### Smart Writer Detection (eBPF)

disk-watchdog uses `biotop` (eBPF-based) to detect which processes are **actively writing right now**, not just cumulative write totals. This catches processes writing in bursts that would be missed by sampling `/proc/pid/io`.

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

Critical thresholds are capped at safe maximums regardless of disk size:

| Free Space     | Action       | What happens |
|----------------|--------------|--------------|
| < 30 GB (2%)   | **Pause**    | Freezes heavy writers - they resume automatically when space recovers |
| < 15 GB (1%)   | **Stop**     | Graceful shutdown - processes get a chance to clean up |
| < 5 GB (0.5%)  | **Force kill** | Last resort - immediate termination to prevent system crash |

### Auto-Resume

When processes are paused, they're frozen but not dead. disk-watchdog **automatically resumes them** when disk space recovers.

**Anti-thrashing protection:**
- **Hysteresis**: Only resumes when free space is well above the pause threshold (e.g., pause at 30GB, resume at 68GB)
- **Cooldown**: Processes must stay paused for 5 minutes minimum before auto-resume
- **Strike limit**: If a process gets paused 3 times in an hour, it stays paused (needs manual intervention)

```bash
# Check status of paused processes
disk-watchdog status

# Manually resume all paused processes
disk-watchdog resume

# Or resume specific process
kill -CONT <PID>
```

**Configuration:**
```bash
# In /etc/disk-watchdog.conf

# Disable auto-resume (manual resume only)
DISK_WATCHDOG_AUTO_RESUME=false

# Resume threshold (default: auto-calculated, ~2x pause threshold)
DISK_WATCHDOG_RESUME_THRESH=50

# Cooldown in seconds (default: 300 = 5 min)
DISK_WATCHDOG_RESUME_COOLDOWN=300

# Max pauses per hour before giving up (default: 3)
DISK_WATCHDOG_RESUME_MAX_STRIKES=3
```

## Push Notifications

Get alerts on your phone via [ntfy.sh](https://ntfy.sh) (free, no account required):

```bash
# Set up during install, or manually:
sudo nano /etc/disk-watchdog.conf

# Add:
DISK_WATCHDOG_WEBHOOK=true
DISK_WATCHDOG_WEBHOOK_URL=https://ntfy.sh/your-unique-topic

# Then subscribe to that topic in the ntfy app
```

Also supports Slack and Discord webhooks.

## Testing

```bash
# Test notifications without taking action
sudo disk-watchdog test

# Test a specific level
sudo disk-watchdog test harsh

# Dry-run mode (logs but doesn't stop processes)
sudo disk-watchdog --dry-run run
```

## Logs

```bash
# View logs
sudo tail -f /var/log/disk-watchdog.log

# Check service status
sudo systemctl status disk-watchdog
```

## How It Compares

| Feature | earlyoom | monit | disk-watchdog |
|---------|----------|-------|---------------|
| Monitors | Memory | Disk/CPU/etc | Disk |
| Adaptive intervals | No | No | **Yes** |
| Real-time I/O (eBPF) | N/A | No | **Yes** |
| SIGSTOP (pause) | No | No | **Yes** |
| Auto-resume | No | No | **Yes** |
| Rate-aware escalation | No | No | **Yes** |
| Push notifications | No | Email | **Yes** |
| Auto thresholds | No | No | **Yes** |

## Troubleshooting

**"Cannot create state directory"** - Run as root or with sudo for the daemon.

**Desktop notifications not working** - The watchdog auto-detects the GUI user. Make sure someone is logged in with a display.

**Processes not being detected** - Run `sudo disk-watchdog writers` to see what biotop detects. Make sure you're writing to the monitored mount point.

## License

MIT

## Contributing

Issues and PRs welcome at https://github.com/radrob2/disk-watchdog
