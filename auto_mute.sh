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

umask 077

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.txt}"
STATE_FILE="${STATE_FILE:-$HOME/.auto_mute_state}"
DNS_STATE_FILE="${DNS_STATE_FILE:-$HOME/.auto_mute_last_dns}"
IPV4_STATE_FILE="${IPV4_STATE_FILE:-$HOME/.auto_mute_last_ipv4}"
WIFI_STATE_FILE="${WIFI_STATE_FILE:-$HOME/.auto_mute_last_wifi}"
WIFI_TIMESTAMP_FILE="${WIFI_TIMESTAMP_FILE:-$HOME/.auto_mute_wifi_ts}"
NETWORK_KEY_FILE="${NETWORK_KEY_FILE:-$HOME/.auto_mute_last_network_key}"
CHECK_LOCK_FILE="${CHECK_LOCK_FILE:-$HOME/.auto_mute.lock}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/Auto-Mute/auto_mute.log}"
COMMAND_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS:-10}"
WIFI_CACHE_TTL=60  # Re-poll WiFi name at least every 60 seconds
DAEMON_POLL_SECONDS=15

# Max log size ~100KB — rotate if exceeded
MAX_LOG_SIZE=102400

# ---------- Logging ----------
run_with_timeout() {
    /usr/bin/perl -e '
        use POSIX ();
        use Errno qw(EINTR);
        my $seconds = shift;
        my $pid = fork;
        defined $pid or exit 125;
        if (!$pid) {
            defined POSIX::setpgid(0, 0) or POSIX::_exit(125);
            POSIX::close(9);
            exec { $ARGV[0] } @ARGV;
            POSIX::_exit(127);
        }
        POSIX::setpgid($pid, $pid);
        my $timed_out = 0;
        local $SIG{ALRM} = sub { local ($!, $?); $timed_out = 1; kill 9, -$pid; kill 9, $pid };
        alarm $seconds;
        my $waited;
        do { $waited = waitpid($pid, 0) } while ($waited < 0 && $! == EINTR);
        my $status = $?;
        alarm 0;
        kill 9, -$pid;
        exit 125 if $waited < 0;
        exit 124 if $timed_out;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
    ' "$COMMAND_TIMEOUT_SECONDS" "$@"
}

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 1
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

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

read_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR: Config file not found at $CONFIG_FILE"
        return 1
    fi

    DNS_TARGETS=()
    WIFI_TARGETS=()

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" == DNS:* ]]; then
            local val="${line#DNS:}"
            val=$(trim "$val")
            [[ -n "$val" ]] && DNS_TARGETS+=("$val")
        elif [[ "$line" == WIFI:* ]]; then
            local val="${line#WIFI:}"
            val=$(trim "$val")
            [[ -n "$val" ]] && WIFI_TARGETS+=("$val")
        fi
    done < "$CONFIG_FILE"
}

# ---------- Get current network DNS domain ----------
get_dns_domain() {
    local state
    state=$(echo "show State:/Network/Global/DNS" | run_with_timeout scutil 2>/dev/null) || return 1
    printf '%s\n' "$state" \
        | grep "SearchDomains" -A 5 \
        | grep -oE '[0-9]+ : .+' \
        | awk -F' : ' '{print $2}' \
        | tr '\n' ' ' \
        | xargs
}

get_ipv4_fingerprint() {
    local state
    state=$(echo "show State:/Network/Global/IPv4" | run_with_timeout scutil 2>/dev/null) || return 1
    printf '%s\n' "$state" \
        | awk '/PrimaryInterface|PrimaryService|Router|Addresses/{print}' \
        | tr '\n' ' ' \
        | xargs
}

# ---------- Get current WiFi name via Shortcut ----------
get_wifi_name() {
    local name
    name=$(run_with_timeout shortcuts run "Get-WiFi-Name" 2>/dev/null) || return 1
    printf '%s' "${name//$'\n'/}"
}

# ---------- Check if connected to any target network ----------
check_target_network() {
    CURRENT_MATCH_RESULT=""

    # Method 1: DNS domain matching (always safe to run, no popups)
    local domains ipv4_fingerprint
    if ! domains=$(get_dns_domain) || ! ipv4_fingerprint=$(get_ipv4_fingerprint); then
        log "ERROR: Could not read network state; keeping the current audio state"
        return 2
    fi
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
            if [[ "$last_ts" =~ ^[0-9]+$ ]]; then
                local now
                now=$(date +%s)
                cache_age=$(( now - last_ts ))
                (( cache_age < 0 )) && cache_age=999999
            fi
        fi

        wifi_name="$cached_wifi"

        # Re-poll Shortcut if network identity changed, cache is empty, or cache is stale.
        if [[ "$domains" != "$last_dns" || "$ipv4_fingerprint" != "$last_ipv4" || -z "$cached_wifi" || $cache_age -ge $WIFI_CACHE_TTL ]]; then
            if ! wifi_name=$(get_wifi_name); then
                log "ERROR: Could not read the WiFi name; keeping the current audio state"
                return 2
            fi
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

    local matched="" target domain

    if [[ ${#DNS_TARGETS[@]} -gt 0 && -n "$domains" ]]; then
        for target in "${DNS_TARGETS[@]}"; do
            for domain in $domains; do
                if [[ "$domain" == "$target" || "$domain" == *."$target" ]]; then
                    matched="DNS:$target"
                    break 2
                fi
            done
        done
    fi

    if [[ -z "$matched" && ${#WIFI_TARGETS[@]} -gt 0 ]]; then
        if [[ -n "$wifi_name" ]]; then
            for target in "${WIFI_TARGETS[@]}"; do
                if [[ "$wifi_name" == "$target" ]]; then
                    matched="WIFI:$target"
                    break
                fi
            done
        fi
    fi

    CURRENT_MATCH_RESULT="$matched"
    CURRENT_NETWORK_KEY="dns:${domains:-<none>}|ipv4:${ipv4_fingerprint:-<none>}|wifi:${wifi_name:-<none>}|match:${matched:-<none>}"
    [[ -n "$matched" ]] && echo "$matched"
    [[ -n "$matched" ]]
}

# ---------- Audio output detection ----------
# Returns "transport|name" for the current default output device.
get_output_device() {
    local audio device
    audio=$(run_with_timeout system_profiler SPAudioDataType 2>/dev/null) || return 1
    device=$(printf '%s\n' "$audio" | awk '
        match($0, /[^[:space:]]/) == 9 && /:$/ {
            name=$0
            sub(/^[[:space:]]*/, "", name)
            sub(/:$/, "", name)
        }
        /Default Output Device: Yes/ { found=1 }
        found && /Transport:/ {
            if ($2 != "" && name != "") print $2 "|" name
            exit
        }
    ')
    [[ -n "$device" ]] || return 1
    printf '%s\n' "$device"
}

# ---------- State management ----------
atomic_write() {
    local path="$1" value="$2" tmp
    tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$value" > "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
}

set_state() {
    atomic_write "$STATE_FILE" "$1"
}

get_state() {
    [[ ! -e "$STATE_FILE" && ! -L "$STATE_FILE" ]] && { echo "unmuted"; return; }
    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 1

    local state
    state=$(cat "$STATE_FILE") || return 1
    case "$state" in
        unmuted|muted_by_auto_mute|manual_unmuted_on_target|pending_mute|pending_unmute)
            printf '%s\n' "$state"
            ;;
        *) return 1 ;;
    esac
}

set_last_network_key() {
    atomic_write "$NETWORK_KEY_FILE" "$1"
}

get_last_network_key() {
    [[ ! -e "$NETWORK_KEY_FILE" && ! -L "$NETWORK_KEY_FILE" ]] && return 0
    [[ -f "$NETWORK_KEY_FILE" && ! -L "$NETWORK_KEY_FILE" ]] || return 1
    cat "$NETWORK_KEY_FILE"
}

# Revalidates the route and the resulting mute state around each audio change.
# Returns 0 when verified, 1 when verified unchanged, and 2 when ambiguous.
set_builtin_mute_state() {
    local expected="$1" before after actual script
    before=$(get_output_device) || return 2
    [[ "$before" == Built-in\|*Speakers ]] || return 2
    [[ "$expected" == "true" ]] && script='set volume with output muted' || script='set volume without output muted'

    run_with_timeout osascript -e "$script" >/dev/null 2>&1 || true

    after=$(get_output_device) || return 2
    [[ "$after" == "$before" ]] || return 2
    actual=$(run_with_timeout osascript -e 'output muted of (get volume settings)' 2>/dev/null) || return 2
    [[ "$actual" == "true" || "$actual" == "false" ]] || return 2
    [[ "$actual" == "$expected" ]]
}

# ---------- Main logic ----------
main() {
    rotate_log
    read_config || return 1

    local state
    if ! state=$(get_state); then
        log "ERROR: Invalid or unreadable ownership state; keeping the current audio state"
        return 1
    fi

    local matched="" match_status
    if check_target_network >/dev/null; then
        match_status=0
        matched="$CURRENT_MATCH_RESULT"
    else
        match_status=$?
    fi
    (( match_status > 1 )) && return 1

    local output_device output_transport output_name
    if ! output_device=$(get_output_device); then
        log "ERROR: Could not identify the current audio output; keeping the current audio state"
        return 1
    fi
    IFS='|' read -r output_transport output_name <<< "$output_device"
    local builtin_speakers=0
    [[ "$output_transport" == "Built-in" && "$output_name" == *Speakers ]] && builtin_speakers=1

    local current_network_key
    current_network_key="$CURRENT_NETWORK_KEY|output:$output_device"

    local last_network_key
    if ! last_network_key=$(get_last_network_key); then
        log "ERROR: Invalid or unreadable decision state; keeping the current audio state"
        return 1
    fi

    local last_network_identity="${last_network_key%%|output:*}"
    local network_changed=0 output_changed=0
    [[ -z "$last_network_key" || "$CURRENT_NETWORK_KEY" != "$last_network_identity" ]] && network_changed=1
    [[ "$current_network_key" != "$last_network_key" ]] && output_changed=1

    local actually_muted=""
    if (( builtin_speakers )); then
        if ! actually_muted=$(run_with_timeout osascript -e 'output muted of (get volume settings)' 2>/dev/null) ||
            [[ "$actually_muted" != "true" && "$actually_muted" != "false" ]]; then
            log "ERROR: Could not read the mute state; keeping the current audio state"
            return 1
        fi
    fi

    if [[ "$state" == "pending_mute" || "$state" == "pending_unmute" ]]; then
        if (( ! builtin_speakers )); then
            log "PENDING — Waiting for built-in speakers to reconcile an interrupted audio change"
            return 1
        fi
        if [[ "$actually_muted" == "true" ]]; then
            log "PENDING — Audio ownership is ambiguous; leaving the current mute untouched"
            return 1
        else
            state="unmuted"
        fi
        if ! set_state "$state"; then
            log "ERROR: Could not reconcile interrupted audio ownership"
            return 1
        fi
    fi

    # Only apply mute/unmute decisions when the network fingerprint changes.
    # If user manually unmutes while staying on the same matched network,
    # keep it unmuted until a later network change.
    if (( network_changed == 0 && output_changed == 0 )); then
        if (( builtin_speakers )) && [[ -n "$matched" && "$state" == "muted_by_auto_mute" && "$actually_muted" != "true" ]]; then
            if ! set_state "manual_unmuted_on_target"; then
                log "ERROR: Could not save the manual override"
                return 1
            fi
            log "MANUAL OVERRIDE — User unmuted on '$matched', waiting for network change"
        fi
        return 0
    fi

    if [[ -n "$matched" ]]; then
        if (( ! builtin_speakers )); then
            if [[ "$state" == "manual_unmuted_on_target" && $network_changed -eq 1 ]]; then
                if ! set_state "unmuted"; then
                    log "ERROR: Could not clear the manual override after a network change"
                    return 1
                fi
                state="unmuted"
            elif [[ "$state" == "muted_by_auto_mute" ]]; then
                log "PAUSED — External output (${output_name:-$output_transport}); built-in mute ownership retained"
            fi
        elif [[ "$state" == "manual_unmuted_on_target" && $network_changed -eq 0 ]]; then
            :
        elif [[ "$state" != "muted_by_auto_mute" && "$actually_muted" != "true" ]]; then
            local previous_state="$state" audio_status
            if ! set_state "pending_mute"; then
                log "ERROR: Could not reserve mute ownership; speakers were not changed"
                return 1
            fi
            set_builtin_mute_state "true"
            audio_status=$?
            if (( audio_status == 1 )); then
                set_state "$previous_state" || log "ERROR: Could not clear the pending mute state"
                log "ERROR: Failed to mute speakers; will retry"
                return 1
            elif (( audio_status != 0 )); then
                log "ERROR: Mute result was ambiguous; pending ownership was retained"
                return 1
            elif ! set_state "muted_by_auto_mute"; then
                log "ERROR: Speakers muted; pending ownership was retained for recovery"
                return 1
            fi
            log "MUTED — Matched '$matched'"
        fi
    else
        # Not on any target network → unmute only if WE muted
        if [[ "$state" == "muted_by_auto_mute" ]]; then
            if (( builtin_speakers )); then
                if ! set_state "pending_unmute"; then
                    log "ERROR: Could not reserve the unmute transition; speakers were not changed"
                    return 1
                fi
                local audio_status
                set_builtin_mute_state "false"
                audio_status=$?
                if (( audio_status == 1 )); then
                    set_state "muted_by_auto_mute" || log "ERROR: Could not restore mute ownership state"
                    log "ERROR: Failed to unmute speakers; will retry"
                    return 1
                elif (( audio_status != 0 )); then
                    log "ERROR: Unmute result was ambiguous; pending ownership was retained"
                    return 1
                elif ! set_state "unmuted"; then
                    log "ERROR: Speakers unmuted; pending ownership was retained for recovery"
                    return 1
                fi
                log "UNMUTED — No target network matched"
            else
                log "PENDING — Will restore built-in speakers when they become the active output"
            fi
        else
            if [[ "$state" != "unmuted" ]] && ! set_state "unmuted"; then
                log "ERROR: Could not clear ownership state"
                return 1
            fi
        fi
    fi

    # Commit the decision last so an interrupted audio command is retried.
    if ! set_last_network_key "$current_network_key"; then
        log "ERROR: Could not save the latest decision; will retry"
        return 1
    fi
}

run_check() (
    exec 9>"$CHECK_LOCK_FILE" || return 1
    if ! /usr/bin/lockf -s -t 0 9; then
        log "Check skipped — another Auto-Mute check is still running"
        return 0
    fi

    local state
    if ! state=$(get_state); then
        log "ERROR: Invalid or unreadable ownership state; check skipped"
        return 1
    fi
    if [[ "${1:-}" == "--force" && "$state" != "manual_unmuted_on_target" ]]; then
        rm -f "$NETWORK_KEY_FILE" || return 1
    fi
    main
)

run_daemon() {
    log "Auto-Mute daemon started (polling every ${DAEMON_POLL_SECONDS}s)"

    while true; do
        run_check
        sleep "$DAEMON_POLL_SECONDS"
    done
}

# Only run main when executed directly (not when sourced for testing)
if [[ "${AUTO_MUTE_TESTING:-}" != "1" ]]; then
    if [[ "${1:-}" == "--daemon" ]]; then
        run_daemon
    elif [[ "${1:-}" == "--once" ]]; then
        run_check --force
    else
        run_check
    fi
fi
