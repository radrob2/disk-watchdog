# disk-watchdog

Adaptive disk space monitor that checks more frequently as your disk fills up, and automatically stops runaway processes before you run out of space.

## Why?

- Your pipeline fills the disk at 2am and crashes your system
- `earlyoom` exists for memory, but nothing similar for disk space
- Fixed-interval monitoring is either too slow (miss the problem) or too fast (wasted resources)
- You want processes **paused** (resumable) not killed when possible

## Features

- **Adaptive checking** - every 5 min when healthy, every 2 sec when critical
- **Graduated response** - warn → pause (SIGSTOP) → stop (SIGTERM) → kill (SIGKILL)
- **SIGSTOP/SIGCONT support** - pause processes without losing work, resume when space is freed
- **Desktop notifications** - via `notify-send`
- **Configurable** - thresholds, process patterns, mount points
- **Lightweight** - single bash script, no dependencies

## Quick Install

```bash
# Download and install
curl -fsSL https://raw.githubusercontent.com/radrob/disk-watchdog/main/install.sh | sudo bash

# Configure (edit target user and thresholds)
sudo nano /etc/disk-watchdog.conf

# Start
sudo systemctl enable --now disk-watchdog
```

## Manual Install

```bash
sudo cp disk-watchdog.sh /usr/local/bin/disk-watchdog
sudo chmod +x /usr/local/bin/disk-watchdog
sudo cp disk-watchdog.service /etc/systemd/system/
sudo cp disk-watchdog.conf /etc/
sudo systemctl daemon-reload
sudo systemctl enable --now disk-watchdog
```

## Configuration

Edit `/etc/disk-watchdog.conf`:

```bash
# User whose processes to manage
DISK_WATCHDOG_USER=myusername

# Mount point to monitor
DISK_WATCHDOG_MOUNT=/

# Thresholds in GB (action when free space drops below)
DISK_WATCHDOG_THRESH_NOTICE=150   # Log only
DISK_WATCHDOG_THRESH_WARN=100     # Desktop notification
DISK_WATCHDOG_THRESH_HARSH=50     # Urgent warning
DISK_WATCHDOG_THRESH_PAUSE=25     # SIGSTOP - pause processes
DISK_WATCHDOG_THRESH_STOP=10      # SIGTERM - graceful stop
DISK_WATCHDOG_THRESH_KILL=5       # SIGKILL - force kill

# Processes to target (pipe-separated regex)
DISK_WATCHDOG_PROCS="fastp|kraken|rsync|cp|dd"
```

## Adaptive Check Intervals

| Free Space | Check Interval | Why |
|------------|----------------|-----|
| > 150 GB   | 5 minutes      | All good, minimal overhead |
| > 100 GB   | 1 minute       | Getting lower, pay attention |
| > 50 GB    | 30 seconds     | Warning zone |
| > 25 GB    | 10 seconds     | Danger zone |
| > 10 GB    | 5 seconds      | Critical |
| < 10 GB    | 2 seconds      | Emergency, catch it fast |

## Actions

| Free Space | Signal | Effect |
|------------|--------|--------|
| < 25 GB    | SIGSTOP | **Pause** - processes freeze, can resume later |
| < 10 GB    | SIGTERM | **Stop** - graceful shutdown |
| < 5 GB     | SIGKILL | **Kill** - force kill, last resort |

### Resuming Paused Processes

When processes are paused (SIGSTOP), they're frozen but not dead. Once you free up space:

```bash
# Resume specific processes
pkill -CONT -f 'fastp|kraken'

# Or resume all stopped processes for your user
pkill -CONT -u $USER
```

## Testing

```bash
# Single check - shows current status
disk-watchdog --check

# Run in foreground for testing
disk-watchdog --foreground
```

## Logs

```bash
# View logs
sudo tail -f /var/log/disk-watchdog.log

# Check service status
sudo systemctl status disk-watchdog
```

## How It Compares

| Tool | Monitors | Adaptive | Action |
|------|----------|----------|--------|
| `earlyoom` | Memory | No | Kill |
| `monit` | Disk/CPU/etc | No | Configurable |
| `disk-watchdog` | Disk | Yes | Pause/Stop/Kill |

## License

MIT

## Contributing

Issues and PRs welcome!
