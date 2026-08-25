# Auto-Mute

Auto-Mute is a lightweight macOS utility designed to automatically mute your MacBook's speakers when connected to specific target WiFi networks. This is especially useful for automatically silencing your device in classes, libraries, or offices without manual intervention.

## Current Updates (August 2026)

- **SleepWatcher lid-open detection**: if SleepWatcher is installed and running, `automute on` adds a wake check after the configurable WiFi stabilization delay. Auto-Mute never replaces another program's wake hook or starts/stops the shared service.
- The existing 15-second polling daemon remains as a fallback for mid-session WiFi changes.
- `automute status` now shows both daemon and SleepWatcher status.
- `is_sleepwatcher_running()` uses `launchctl` instead of `brew services list` for faster checks.
- WiFi matching reliability was improved by combining DNS state, WiFi name, and IPv4 fingerprint changes.
- LaunchAgent startup/shutdown handling was hardened to avoid stale service restarts.
- The `automute` wrapper now resolves symlink paths correctly so it always installs the latest script from the real project directory.

## How it Works

The utility operates by checking your current network against a list of targets specified in the configuration file. It supports two different detection methods:
1. **DNS Domain Matching (`DNS:`)**: Uses `scutil` to find the network's Search Domain. This method is the primary recommendation because it does not require any special permissions.
2. **WiFi Name Matching (`WIFI:`)**: Uses a macOS Shortcut to read the current SSID. This method exists because newer macOS versions (mentioned as "macOS 26" in the code) block command-line tools from securely reading WiFi names without extra permissions and prompts.

## Project Files

- `auto_mute.sh`: The core script that scans your network state and mutes/unmutes the speakers accordingly. It logs activity privately under `~/Library/Logs/Auto-Mute/` (rotating automatically) and keeps state via hidden files in your home folder.
- `wakeup.sh`: Wake-on-lid-open script invoked by SleepWatcher. Waits for WiFi to stabilize (configurable delay), then runs a single network check via `auto_mute.sh --once`.
- `setup_shortcut.sh`: A helper interactive script you run once to create a macOS Shortcut named "Get-WiFi-Name". This shortcut bypasses the strict terminal restrictions and provides native access to read your WiFi's SSID.
- `config.txt`: The configuration file where you declare the networks that should trigger auto-muting, and optional settings like `LID_OPEN_DELAY`.
- `automute`: Built executable/wrapper for the script.

## Setup Instructions

### 1. Clone the Repository

Open your terminal and clone the code directly from the repository:

```bash
git clone https://github.com/ronit-mishra-04/Auto-mute.git
cd Auto-mute
```

### 2. Install the `automute` Command in zsh

From inside the cloned `Auto-mute` folder, run:

```bash
chmod +x automute auto_mute.sh wakeup.sh setup_shortcut.sh
mkdir -p "$HOME/.local/bin"
ln -sfn "$PWD/automute" "$HOME/.local/bin/automute"
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
source "$HOME/.zshrc"
rehash
```

Verify that zsh can find it:

```bash
command -v automute
automute status
```

You can now run `automute` from any directory. Keep the cloned `Auto-mute` folder in the same location because `~/.local/bin/automute` links to it.

### 3. Configure Target Networks

Edit `config.txt` and add the networks where you want your speakers to be muted. DNS entries match the exact domain or a subdomain (for example, `example.edu` matches `client.wireless.example.edu`); WiFi names match exactly.

- Example DNS Entry: `DNS: example.edu`
- Example WiFi Entry: `WIFI: Eduroam`

### 4. Setup the macOS Shortcut (Important)

If you are strictly using `DNS:` matching in your configuration, you do not need this. However, **if you configure any `WIFI:` targets, you must run setup_shortcut.sh**.

macOS aggressively blocks terminal applications from reading WiFi names for privacy reasons. The application works around this by using the official Shortcuts app.

Run this command in the repository folder and follow the instructions:

```bash
./setup_shortcut.sh
```

## Important Commands

- **Run the program**:
  ```bash
  ./auto_mute.sh
  ```
  *Tip: This does a single check and exits. For continuous auto-muting, use `automute on` (daemon mode).*

- **Setup Mac Shortcut Helper**:
  ```bash
  ./setup_shortcut.sh
  ```

- **See DNS Search Domains (for configuring DNS: rules)**:
  ```bash
  echo "show State:/Network/Global/DNS" | scutil
  ```

## Using `automute` from Any Directory

After completing the zsh installation above, use these commands from anywhere:

| Command | Description |
|---------|-------------|
| `automute on` | Start background daemon monitoring (checks network every 15s) |
| `automute off` | Stop monitoring and clean up; unmutes only if Auto-Mute owns the mute |
| `automute status` | Show running state, configured networks, and current match |
| `automute add dns <domain>` | Add a DNS domain to monitor |
| `automute add wifi <name>` | Add a WiFi network name to monitor |
| `automute add` | Add a network interactively |
| `automute remove` | Remove a network interactively |
| `automute remove "DNS:example.edu"` | Remove a specific entry directly |
| `automute list` | List all configured networks |
| `automute log` | Show recent log entries |
| `automute help` | Show help |

If Auto-Mute owns a built-in-speaker mute while headphones or another output are active, `automute off` removes the daemon without touching that external device. Switch back to the built-in speakers and run `automute off` once more to finish restoration.

## How Monitoring Works

Auto-Mute uses a **dual-trigger architecture** for reliable network detection:

### 1. Polling Daemon (always active)
A background daemon checks your network state every 15 seconds. This catches all network changes, including mid-session WiFi switches while the lid is already open.

### 2. SleepWatcher Lid Detection (optional)
If you run `brew install sleepwatcher && brew services start sleepwatcher` before `automute on`, opening the MacBook lid triggers an additional check after the stabilization delay. The daemon remains sufficient on its own.

```
Existing Daemon (always)          SleepWatcher (optional)
┌────────────────────────┐       ┌─────────────────────┐
│ auto_mute.sh --daemon  │       │ sleepwatcher service │
│ polls every 15s        │       │ watches lid events   │
│ catches mid-session    │       │        │             │
│ WiFi changes           │       │   WAKE ▼             │
└────────────────────────┘       │ ~/.wakeup            │
                                 │ → sleep 15s          │
                                 │ → auto_mute.sh --once│
                                 └─────────────────────┘
```

### Configuration

The lid-open delay is configurable in `config.txt`:
```
# Seconds to wait after lid opens before checking network (default: 15)
LID_OPEN_DELAY:15
```

### Quick Start Example
```bash
# Add your network by DNS domain
automute add dns example.edu
automute add dns example.com
automute add dns example.org

# Turn on auto-muting
automute on

# Check if it's working
automute status

# When you no longer need it
automute off
```
