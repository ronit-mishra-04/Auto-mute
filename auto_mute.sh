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

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.txt}"
STATE_FILE="${STATE_FILE:-$HOME/.auto_mute_state}"
DNS_STATE_FILE="${DNS_STATE_FILE:-$HOME/.auto_mute_last_dns}"
IPV4_STATE_FILE="${IPV4_STATE_FILE:-$HOME/.auto_mute_last_ipv4}"
WIFI_STATE_FILE="${WIFI_STATE_FILE:-$HOME/.auto_mute_last_wifi}"
WIFI_TIMESTAMP_FILE="${WIFI_TIMESTAMP_FILE:-$HOME/.auto_mute_wifi_ts}"
NETWORK_KEY_FILE="${NETWORK_KEY_FILE:-$HOME/.auto_mute_last_network_key}"
LOG_FILE="${LOG_FILE:-/tmp/auto_mute.log}"
WIFI_CACHE_TTL=60  # Re-poll WiFi name at least every 60 seconds
DAEMON_POLL_SECONDS=15

# Max log size ~100KB — rotate if exceeded
MAX_LOG_SIZE=102400

# Daemon safety net: if event watching fails, periodically re-check network state.
DAEMON_FALLBACK_POLL_SECONDS=10
DAEMON_FALLBACK_POLL_MAX_SECONDS=60
DAEMON_WATCHER_WARN_EVERY=15

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
CURRENT_NETWORK_KEY=""
CURRENT_MATCH_RESULT=""

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

get_ipv4_fingerprint() {
    echo "show State:/Network/Global/IPv4" | scutil 2>/dev/null \
        | awk '/PrimaryInterface|PrimaryService|Router|Addresses/{print}' \
        | tr '\n' ' ' \
        | xargs
}

# ---------- Get current WiFi name via Shortcut ----------
get_wifi_name() {
    shortcuts run "Get-WiFi-Name" 2>/dev/null | tr -d '\n'
}

# ---------- Check if connected to any target network ----------
check_target_network() {
    CURRENT_MATCH_RESULT=""

    # Method 1: DNS domain matching (always safe to run, no popups)
    local domains
    domains=$(get_dns_domain)
    local ipv4_fingerprint
    ipv4_fingerprint=$(get_ipv4_fingerprint)
    local wifi_name=""
    
    # Method 2: WiFi name matching (via Shortcut)
    # WARNING: This causes a background process flash. 
    # To minimize this, we cache the WiFi name and only re-poll when:
    #   - The DNS domain has changed, OR
    #   - The cache is older than WIFI_CACHE_TTL seconds
    if [[ ${#WIFI_TARGETS[@]} -gt 0 ]]; then
        local last_dns=""
        local last_ipv4=""
        local cached_wifi=""
        local cache_age=999999
        
        [[ -f "$DNS_STATE_FILE" ]] && last_dns=$(cat "$DNS_STATE_FILE")
        [[ -f "$IPV4_STATE_FILE" ]] && last_ipv4=$(cat "$IPV4_STATE_FILE")
        [[ -f "$WIFI_STATE_FILE" ]] && cached_wifi=$(cat "$WIFI_STATE_FILE")

        # Calculate cache age
        if [[ -f "$WIFI_TIMESTAMP_FILE" ]]; then
            local last_ts
            last_ts=$(cat "$WIFI_TIMESTAMP_FILE")
            local now
            now=$(date +%s)
            cache_age=$(( now - last_ts ))
        fi

        wifi_name="$cached_wifi"

        # Re-poll Shortcut if network identity changed, cache is empty, or cache is stale.
        if [[ "$domains" != "$last_dns" || "$ipv4_fingerprint" != "$last_ipv4" || -z "$cached_wifi" || $cache_age -ge $WIFI_CACHE_TTL ]]; then
            wifi_name=$(get_wifi_name)
            echo "$domains" > "$DNS_STATE_FILE"
            echo "$ipv4_fingerprint" > "$IPV4_STATE_FILE"
            echo "$wifi_name" > "$WIFI_STATE_FILE"
            date +%s > "$WIFI_TIMESTAMP_FILE"

            # Log cache refresh when WiFi name changed
            if [[ "$wifi_name" != "$cached_wifi" ]]; then
                log "WiFi name changed: '${cached_wifi:-<empty>}' → '${wifi_name:-<empty>}'"
            fi
        fi

    fi

    CURRENT_NETWORK_KEY="dns:${domains:-<none>}|wifi:${wifi_name:-<none>}"

    if [[ ${#DNS_TARGETS[@]} -gt 0 && -n "$domains" ]]; then
        for target in "${DNS_TARGETS[@]}"; do
            if [[ "$domains" == *"$target"* ]]; then
                CURRENT_MATCH_RESULT="DNS:$target"
                echo "$CURRENT_MATCH_RESULT"
                return 0
            fi
        done
    fi

    if [[ ${#WIFI_TARGETS[@]} -gt 0 ]]; then
        if [[ -n "$wifi_name" ]]; then
            for target in "${WIFI_TARGETS[@]}"; do
                if [[ "$wifi_name" == "$target" ]]; then
                    CURRENT_MATCH_RESULT="WIFI:$target"
                    echo "$CURRENT_MATCH_RESULT"
                    return 0
                fi
            done
        fi
    fi

    return 1
}

# ---------- Audio output detection ----------
# Returns the transport type of the current default output device
# e.g. "Built-in", "Bluetooth", "USB", "Virtual"
get_output_transport() {
    system_profiler SPAudioDataType 2>/dev/null \
        | awk '/Default Output Device: Yes/{found=1} found && /Transport:/{print $2; exit}'
}

# Returns 0 if output is built-in speakers, 1 otherwise
is_builtin_output() {
    local transport
    transport=$(get_output_transport)
    [[ "$transport" == "Built-in" ]]
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

set_last_network_key() {
    echo "$1" > "$NETWORK_KEY_FILE"
}

get_last_network_key() {
    if [[ -f "$NETWORK_KEY_FILE" ]]; then
        cat "$NETWORK_KEY_FILE"
    else
        echo ""
    fi
}

# ---------- Event-driven network watcher ----------
build_network_watch_commands() {
    echo "n.add State:/Network/Global/IPv4"
    echo "n.add State:/Network/Global/DNS"

    # Watch all AirPort dynamic-store keys so WiFi SSID changes trigger a re-check.
    echo "list State:/Network/Interface/.*/AirPort" | scutil 2>/dev/null \
        | awk -F' = ' '/subKey/{print $2}' \
        | while IFS= read -r key; do
            [[ -n "$key" ]] && echo "n.add $key"
        done

    echo "n.watch"
}

wait_for_network_change_event() {
    # Keep stdin open after n.watch so scutil stays in watch mode, even under launchd.
    { build_network_watch_commands; tail -f /dev/null; } \
        | scutil 2>/dev/null \
        | awk 'NF {found=1; exit 0} END {if (!found) exit 1}'
}

# ---------- Main logic ----------
main() {
    rotate_log
    read_config

    local state
    state=$(get_state)

    local matched=""
    if check_target_network >/dev/null; then
        matched="$CURRENT_MATCH_RESULT"
    fi

    local current_network_key
    current_network_key="$CURRENT_NETWORK_KEY"

    local last_network_key
    last_network_key=$(get_last_network_key)

    local network_changed=0
    if [[ -z "$last_network_key" || "$current_network_key" != "$last_network_key" ]]; then
        network_changed=1
    fi

    local actually_muted
    actually_muted=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)

    # Only apply mute/unmute decisions when the network fingerprint changes.
    # If user manually unmutes while staying on the same matched network,
    # keep it unmuted until a later network change.
    if (( network_changed == 0 )); then
        if [[ -n "$matched" && "$state" == "muted_by_auto_mute" && "$actually_muted" != "true" ]]; then
            set_state "manual_unmuted_on_target"
            log "MANUAL OVERRIDE — User unmuted on '$matched', waiting for network change"
        fi
        return 0
    fi

    set_last_network_key "$current_network_key"

    if [[ -n "$matched" ]]; then
        # Only mute if output is built-in speakers (skip Bluetooth, USB, etc.)
        local output_transport
        output_transport=$(get_output_transport)

        if [[ "$output_transport" != "Built-in" ]]; then
            if [[ "$state" == "muted_by_auto_mute" ]]; then
                # We previously muted, but user switched to external audio — unmute and clear state.
                unmute_speakers
                set_state "unmuted"
                log "UNMUTED — Output switched to external (${output_transport:-unknown}), skipping auto-mute"
            elif [[ "$state" == "manual_unmuted_on_target" ]]; then
                set_state "unmuted"
            fi
            return 0
        fi

        # Connected to a target network with built-in speakers → mute
        if [[ "$state" != "muted_by_auto_mute" ]]; then
            if [[ "$actually_muted" != "true" ]]; then
                mute_speakers
            fi
            set_state "muted_by_auto_mute"
            log "MUTED — Matched '$matched'"
        fi
    else
        # Not on any target network → unmute only if WE muted
        if [[ "$state" == "muted_by_auto_mute" ]]; then
            unmute_speakers
            log "UNMUTED — No target network matched"
        fi
        set_state "unmuted"
    fi
}

run_daemon() {
    log "Auto-Mute daemon started (polling every ${DAEMON_POLL_SECONDS}s)"

    while true; do
        main
        sleep "$DAEMON_POLL_SECONDS"
    done
}

# Only run main when executed directly (not when sourced for testing)
if [[ "${AUTO_MUTE_TESTING:-}" != "1" ]]; then
    if [[ "${1:-}" == "--daemon" ]]; then
        run_daemon
    else
        main
    fi
fi
