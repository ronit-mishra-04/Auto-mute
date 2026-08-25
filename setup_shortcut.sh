#!/bin/bash
# ============================================================================
# Auto-Mute: Setup the "Get WiFi Name" Shortcut
#
# macOS 26 blocks all CLI tools from accessing the WiFi SSID.
# The only way to get it is through a macOS Shortcut, which has
# native WiFi access. This script helps you create it.
# ============================================================================

SHORTCUT_NAME="Get-WiFi-Name"
COMMAND_TIMEOUT_SECONDS=10

run_with_timeout() {
    /usr/bin/perl -e '
        use POSIX ();
        use Errno qw(EINTR);
        my $seconds = shift;
        my $pid = fork;
        defined $pid or exit 125;
        if (!$pid) {
            defined POSIX::setpgid(0, 0) or POSIX::_exit(125);
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

echo "🔧 Auto-Mute: Shortcut Setup"
echo "=============================="
echo ""

# Check if shortcut already exists
if run_with_timeout shortcuts list 2>/dev/null | grep -q "^${SHORTCUT_NAME}$"; then
    echo "✅ Shortcut '${SHORTCUT_NAME}' already exists!"
    echo ""
    echo "Testing it now..."
    result=$(run_with_timeout shortcuts run "${SHORTCUT_NAME}" 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "✅ WiFi Name detected: $result"
    else
        echo "⚠️  Shortcut ran but returned empty. Make sure WiFi is on."
        exit 1
    fi
    exit 0
fi

echo "macOS 26 blocks terminal apps from reading WiFi names."
echo "We need to create a simple Shortcut to do it instead."
echo ""
echo "Please follow these steps:"
echo ""
echo "  1. Open the Shortcuts app (Cmd+Space, type 'Shortcuts')"
echo "  2. Click the '+' button to create a new shortcut"
echo "  3. Name it exactly: ${SHORTCUT_NAME}"
echo "  4. Search for 'Get Current Wi-Fi' action and add it"
echo "  5. Search for 'Get Name from Network' action and add it"
echo "  6. That's it! Close the Shortcuts app"
echo ""
echo "After creating the shortcut, run this script again to test it."
echo ""
read -p "Press Enter after creating the shortcut..."

# Test the shortcut
if run_with_timeout shortcuts list 2>/dev/null | grep -q "^${SHORTCUT_NAME}$"; then
    echo ""
    echo "Testing shortcut..."
    result=$(run_with_timeout shortcuts run "${SHORTCUT_NAME}" 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "✅ WiFi Name detected: $result"
        echo "✅ Setup complete! Auto-Mute will now use this shortcut."
        exit 0
    else
        echo "⚠️  Shortcut ran but returned empty."
        echo "   Make sure the shortcut has these actions in order:"
        echo "   1. 'Get Current Wi-Fi'"
        echo "   2. 'Get Name from Network'"
        exit 1
    fi
else
    echo "❌ Shortcut '${SHORTCUT_NAME}' not found."
    echo "   Please create it following the steps above."
    exit 1
fi
