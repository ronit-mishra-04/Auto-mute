#!/bin/bash
# ============================================================================
# wakeup.sh — Called by SleepWatcher when the Mac wakes (lid opens)
#
# Waits for WiFi to stabilize, then triggers a single auto-mute network check.
# SleepWatcher invokes ~/.wakeup on every wake event; that file is a symlink
# pointing to the installed copy of this script.
# ============================================================================

umask 077

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
LOG_FILE="$HOME/Library/Logs/Auto-Mute/auto_mute.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Read LID_OPEN_DELAY from installed config (default: 15 seconds)
DELAY=15
CONFIG="$SCRIPT_DIR/config.txt"
if [[ -f "$CONFIG" ]]; then
    val=$(grep -m1 '^LID_OPEN_DELAY:' "$CONFIG" | cut -d: -f2 | xargs)
    [[ -n "$val" && "$val" =~ ^[0-9]+$ ]] && DELAY="$val"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') — WAKE: Lid opened, waiting ${DELAY}s for WiFi..." >> "$LOG_FILE"
sleep "$DELAY"
echo "$(date '+%Y-%m-%d %H:%M:%S') — WAKE: Running network check" >> "$LOG_FILE"

/bin/bash "$SCRIPT_DIR/auto_mute.sh" --once
