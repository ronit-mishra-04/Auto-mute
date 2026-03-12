#!/bin/bash
# ============================================================================
# Auto-Mute: WiFi-Based Speaker Muting for macOS
# Monitors WiFi and mutes MacBook speakers when connected to target networks.
#
# Supports two detection methods:
#   1. DNS domain matching (via scutil) — no special permissions needed
#   2. WiFi name matching (via macOS Shortcuts) — needs a Shortcut set up
#
# Supports multiple networks — any match triggers muting.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.txt"
STATE_FILE="$HOME/.auto_mute_state"
DNS_STATE_FILE="$HOME/.auto_mute_last_dns"
WIFI_STATE_FILE="$HOME/.auto_mute_last_wifi"
LOG_FILE="/tmp/auto_mute.log"

# Max log size ~100KB — rotate if exceeded
MAX_LOG_SIZE=102400

# ---------- Logging ----------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') — $1" >> "$LOG_FILE"
}

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if (( size > MAX_LOG_SIZE )); then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "Log rotated"
        fi
    fi
}

# ---------- Read config ----------
# Reads DNS: and WIFI: entries into arrays
DNS_TARGETS=()
WIFI_TARGETS=()

read_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR: Config file not found at $CONFIG_FILE"
        exit 1
    fi

    DNS_TARGETS=()
    WIFI_TARGETS=()

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        if [[ "$line" == DNS:* ]]; then
            local val="${line#DNS:}"
            val=$(echo "$val" | xargs)  # trim
            [[ -n "$val" ]] && DNS_TARGETS+=("$val")
        elif [[ "$line" == WIFI:* ]]; then
            local val="${line#WIFI:}"
            val=$(echo "$val" | xargs)  # trim
            [[ -n "$val" ]] && WIFI_TARGETS+=("$val")
        fi
    done < "$CONFIG_FILE"

    if [[ ${#DNS_TARGETS[@]} -eq 0 && ${#WIFI_TARGETS[@]} -eq 0 ]]; then
        log "ERROR: No DNS: or WIFI: entries in $CONFIG_FILE"
        exit 1
    fi
}

# ---------- Get current network DNS domain ----------
get_dns_domain() {
    echo "show State:/Network/Global/DNS" | scutil 2>/dev/null \
        | grep "SearchDomains" -A 5 \
        | grep -oE '[0-9]+ : .+' \
        | awk -F' : ' '{print $2}' \
        | tr '\n' ' ' \
        | xargs
}

# ---------- Get current WiFi name via Shortcut ----------
get_wifi_name() {
    shortcuts run "Get-WiFi-Name" 2>/dev/null | tr -d '\n'
}

# ---------- Check if connected to any target network ----------
check_target_network() {
    # Method 1: DNS domain matching (always safe to run, no popups)
    local domains
    domains=$(get_dns_domain)
    
    if [[ ${#DNS_TARGETS[@]} -gt 0 && -n "$domains" ]]; then
        for target in "${DNS_TARGETS[@]}"; do
            if [[ "$domains" == *"$target"* ]]; then
                echo "DNS:$target"
                return 0
            fi
        done
    fi

    # Method 2: WiFi name matching (via Shortcut)
    # WARNING: This causes a background process flash. 
    # To minimize this, we only poll Shortcuts if the DNS domain has CHANGED
    # since our last check.
    if [[ ${#WIFI_TARGETS[@]} -gt 0 ]]; then
        local last_dns=""
        local cached_wifi=""
        
        [[ -f "$DNS_STATE_FILE" ]] && last_dns=$(cat "$DNS_STATE_FILE")
        [[ -f "$WIFI_STATE_FILE" ]] && cached_wifi=$(cat "$WIFI_STATE_FILE")

        local wifi_name="$cached_wifi"

        # If DNS domain changed (or this is the first run), we must poll Shortcuts
        if [[ "$domains" != "$last_dns" || -z "$cached_wifi" ]]; then
            wifi_name=$(get_wifi_name)
            echo "$domains" > "$DNS_STATE_FILE"
            echo "$wifi_name" > "$WIFI_STATE_FILE"
        fi

        if [[ -n "$wifi_name" ]]; then
            for target in "${WIFI_TARGETS[@]}"; do
                if [[ "$wifi_name" == "$target" ]]; then
                    echo "WIFI:$target"
                    return 0
                fi
            done
        fi
    fi

    return 1
}

# ---------- Audio controls ----------
mute_speakers() {
    osascript -e 'set volume with output muted' 2>/dev/null
}

unmute_speakers() {
    osascript -e 'set volume without output muted' 2>/dev/null
}

# ---------- State management ----------
set_state() {
    echo "$1" > "$STATE_FILE"
}

get_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo "unmuted"
    fi
}

# ---------- Main logic ----------
main() {
    rotate_log
    read_config

    local state
    state=$(get_state)

    local matched
    matched=$(check_target_network)

    if [[ -n "$matched" ]]; then
        # Connected to a target network → mute if not already muted by us
        if [[ "$state" != "muted_by_auto_mute" ]]; then
            mute_speakers
            set_state "muted_by_auto_mute"
            log "MUTED — Matched '$matched'"
        fi
    else
        # Not on any target network → unmute only if WE muted
        if [[ "$state" == "muted_by_auto_mute" ]]; then
            unmute_speakers
            set_state "unmuted"
            log "UNMUTED — No target network matched"
        fi
    fi
}

main
