#!/bin/bash
#==============================================================
# B860AV2.1-A WiFi Connection Helper
#
# Usage:
#   wifi-connect.sh scan          - Scan for available networks
#   wifi-connect.sh "SSID"        - Connect to open network
#   wifi-connect.sh "SSID" "PASS" - Connect to WPA network
#   wifi-connect.sh status        - Show WiFi connection status
#   wifi-connect.sh disconnect    - Disconnect from current network
#==============================================================

show_help() {
    echo "B860AV2.1-A WiFi Connection Helper"
    echo ""
    echo "Usage:"
    echo "  $0 scan            - Scan for available WiFi networks"
    echo "  $0 status          - Show current WiFi connection status"
    echo "  $0 disconnect      - Disconnect from current WiFi network"
    echo "  $0 <SSID>          - Connect to open network"
    echo "  $0 <SSID> <PASS>   - Connect to WPA/WPA2 network"
    echo "  $0 hidden <SSID> <PASS> - Connect to hidden network"
    echo ""
    echo "Examples:"
    echo "  $0 scan"
    echo "  $0 \"MyWiFi\" \"mypassword\""
    echo ""
}

# Check if WiFi interface exists
check_wifi() {
    local iface=$(ip link show 2>/dev/null | grep -oP 'wlan\d+' | head -1)
    if [ -z "$iface" ]; then
        echo "ERROR: No WiFi interface found!"
        echo "Run 'wifi-setup.sh' to detect WiFi hardware,"
        echo "or check if this device has WiFi hardware (NW variant has no WiFi)."
        exit 1
    fi
    echo "$iface"
}

# Scan for networks
do_scan() {
    local iface=$(check_wifi)
    echo "Scanning for WiFi networks on $iface..."
    echo ""
    nmcli device wifi list --rescan yes 2>/dev/null || {
        echo "nmcli not available, trying iw..."
        iw dev "$iface" scan 2>/dev/null | grep -E "SSID:|signal:|security:" | head -30
    }
}

# Show status
do_status() {
    local iface=$(check_wifi)
    echo "=== WiFi Status ==="
    nmcli device show "$iface" 2>/dev/null || {
        echo "Interface: $iface"
        ip addr show "$iface" 2>/dev/null
        iw dev "$iface" link 2>/dev/null
    }
}

# Connect to network
do_connect() {
    local ssid="$1"
    local pass="$2"
    local hidden="$3"

    local iface=$(check_wifi)

    if [ -z "$ssid" ]; then
        echo "ERROR: SSID required"
        show_help
        exit 1
    fi

    echo "Connecting to '$ssid' on $iface..."

    # V6.4.1 fix: 正确处理隐藏开放网络 (hidden + 无密码)
    if [ -n "$pass" ]; then
        if [ "$hidden" = "hidden" ]; then
            nmcli device wifi connect "$ssid" password "$pass" hidden yes 2>/dev/null
        else
            nmcli device wifi connect "$ssid" password "$pass" 2>/dev/null
        fi
    else
        if [ "$hidden" = "hidden" ]; then
            nmcli device wifi connect "$ssid" hidden yes 2>/dev/null
        else
            nmcli device wifi connect "$ssid" 2>/dev/null
        fi
    fi

    if [ $? -eq 0 ]; then
        echo ""
        echo "SUCCESS: Connected to '$ssid'"
        echo ""
        echo "Connection details:"
        nmcli connection show --active 2>/dev/null
        echo ""
        echo "IP address:"
        ip addr show "$iface" 2>/dev/null | grep "inet "
    else
        echo ""
        echo "FAILED: Could not connect to '$ssid'"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check if the SSID is correct: $0 scan"
        echo "  2. Check WiFi is up: ip link show $iface"
        echo "  3. Check logs: journalctl -u NetworkManager --no-pager -n 20"
        echo "  4. Try manually: nmtui"
    fi
}

# Disconnect
do_disconnect() {
    local iface=$(check_wifi)
    echo "Disconnecting from WiFi..."
    nmcli device disconnect "$iface" 2>/dev/null
    echo "Disconnected."
}

# Main
case "${1:-}" in
    scan)
        do_scan
        ;;
    status)
        do_status
        ;;
    disconnect)
        do_disconnect
        ;;
    hidden)
        do_connect "$2" "$3" "hidden"
        ;;
    help|-h|--help)
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        do_connect "$1" "$2"
        ;;
esac
