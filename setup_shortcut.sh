#!/bin/bash
# ============================================================================
# Auto-Mute: Setup the "Get WiFi Name" Shortcut
#
# macOS 26 blocks all CLI tools from accessing the WiFi SSID.
# The only way to get it is through a macOS Shortcut, which has
# native WiFi access. This script helps you create it.
# ============================================================================

SHORTCUT_NAME="Get-WiFi-Name"

echo "🔧 Auto-Mute: Shortcut Setup"
echo "=============================="
echo ""

# Check if shortcut already exists
if shortcuts list 2>/dev/null | grep -q "^${SHORTCUT_NAME}$"; then
    echo "✅ Shortcut '${SHORTCUT_NAME}' already exists!"
    echo ""
    echo "Testing it now..."
    result=$(shortcuts run "${SHORTCUT_NAME}" 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "✅ WiFi Name detected: $result"
    else
        echo "⚠️  Shortcut ran but returned empty. Make sure WiFi is on."
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
if shortcuts list 2>/dev/null | grep -q "^${SHORTCUT_NAME}$"; then
    echo ""
    echo "Testing shortcut..."
    result=$(shortcuts run "${SHORTCUT_NAME}" 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "✅ WiFi Name detected: $result"
        echo "✅ Setup complete! Auto-Mute will now use this shortcut."
    else
        echo "⚠️  Shortcut ran but returned empty."
        echo "   Make sure the shortcut has these actions in order:"
        echo "   1. 'Get Current Wi-Fi'"
        echo "   2. 'Get Name from Network'"
    fi
else
    echo "❌ Shortcut '${SHORTCUT_NAME}' not found."
    echo "   Please create it following the steps above."
fi
