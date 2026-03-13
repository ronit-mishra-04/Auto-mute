# Auto-Mute

Auto-Mute is a lightweight macOS utility designed to automatically mute your MacBook's speakers when connected to specific target WiFi networks. This is especially useful for automatically silencing your device in classes, libraries, or offices without manual intervention.

## How it Works

The utility operates by checking your current network against a list of targets specified in the configuration file. It supports two different detection methods:
1. **DNS Domain Matching (`DNS:`)**: Uses `scutil` to find the network's Search Domain. This method is the primary recommendation because it does not require any special permissions.
2. **WiFi Name Matching (`WIFI:`)**: Uses a macOS Shortcut to read the current SSID. This method exists because newer macOS versions (mentioned as "macOS 26" in the code) block command-line tools from securely reading WiFi names without extra permissions and prompts.

## Project Files

- `auto_mute.sh`: The core script that scans your network state and mutes/unmutes the speakers accordingly. It logs activity to `/tmp/auto_mute.log` (rotating automatically) and keeps state via hidden files in your home folder.
- `setup_shortcut.sh`: A helper interactive script you run once to create a macOS Shortcut named "Get-WiFi-Name". This shortcut bypasses the strict terminal restrictions and provides native access to read your WiFi's SSID.
- `config.txt`: The configuration file where you declare the networks that should trigger auto-muting.
- `automute`: Built executable/wrapper for the script.

## Setup Instructions

### 1. Clone the Repository
Open your terminal and clone the code directly from the repository:
```bash
git clone https://github.com/ronit-mishra-04/Auto-mute.git
cd Auto-mute
```

### 2. Configure Target Networks
Edit `config.txt` and add the networks where you want your speakers to be muted. You can mix and match DNS domains and WiFi names. Matches are partial (e.g., `example.edu` will match `client.wireless.example.edu`).
- Example DNS Entry: `DNS: example.edu`
- Example WiFi Entry: `WIFI: Eduroam`

### 3. Setup the macOS Shortcut (Important)
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
  *Tip: The script checks connection status exactly once when executed. For continuous auto-muting functionality, you can schedule it to run every few minutes quietly in the background using `cron` or `launchd`!*

- **Setup Mac Shortcut Helper**:
  ```bash
  ./setup_shortcut.sh
  ```

- **See DNS Search Domains (for configuring DNS: rules)**:
  ```bash
  echo "show State:/Network/Global/DNS" | scutil
  ```

## Using `automute`

The `automute` command is the main way to control Auto-Mute. It handles turning monitoring on/off, managing your network list, and checking status.

| Command | Description |
|---------|-------------|
| `automute on` | Start background monitoring (checks WiFi every 10s) |
| `automute off` | Stop monitoring, unmute speakers, and clean up |
| `automute status` | Show running state, configured networks, and current match |
| `automute add dns <domain>` | Add a DNS domain to monitor |
| `automute add wifi <name>` | Add a WiFi network name to monitor |
| `automute add` | Add a network interactively |
| `automute remove` | Remove a network interactively |
| `automute remove "DNS:example.edu"` | Remove a specific entry directly |
| `automute list` | List all configured networks |
| `automute log` | Show recent log entries |
| `automute help` | Show help |

### Quick Start Example
```bash
# Add your network by DNS domain
automute add dns example.edu or example.com or example.org

# Turn on auto-muting
automute on

# Check if it's working
automute status

# When you no longer need it
automute off
```
