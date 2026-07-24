#!/bin/bash
#==============================================================
# B860AV2.1-A WiFi Auto-Detection & Setup Script (V6)
#
# Supports WiFi chips found in B860AV2.1 firmware:
#   - SSV6051 / SV6256P  (SDIO, 硅谷数模)
#   - UWE5621DS / UWE5622 (SDIO, 紫光展锐 Unisoc)
#   - MT7601U            (USB,  联发科 MediaTek)
#   - RTL8189ES/FS       (SDIO, 瑞昱 Realtek)
#   - AP6xxx / BCM43455  (SDIO, Broadcom/AMPAK)
#   - RTL8821/8822/8723  (USB,  瑞昱 Realtek)
#
# This script runs at boot to detect WiFi hardware and configure
# NetworkManager automatically. On NW (No WiFi) variants it exits
# silently after detecting no WiFi hardware.
#==============================================================

LOG="/var/log/wifi-setup.log"
FIRMWARE_DIR="/lib/firmware"
SCRIPT_NAME="wifi-setup"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG" 2>/dev/null
    echo "[$SCRIPT_NAME] $1"
}

# =========================================================
# 1. Unblock rfkill (some devices soft-block WiFi at boot)
# =========================================================
unblock_rfkill() {
    if command -v rfkill &>/dev/null; then
        local blocked=$(rfkill list 2>/dev/null | grep -c "Soft blocked: yes")
        if [ "$blocked" -gt 0 ]; then
            log "Unblocking $blocked rfkill-soft-blocked device(s)..."
            rfkill unblock all 2>/dev/null
            log "rfkill unblock done"
        else
            log "No rfkill soft-blocks found"
        fi
    else
        log "rfkill not installed, skipping unblock"
    fi
}

# =========================================================
# 2. Check if WiFi interface already exists
# =========================================================
detect_wifi_interface() {
    local iface=""
    # Check ip link for wlan* interfaces
    iface=$(ip link show 2>/dev/null | grep -oP 'wlan\d+' | head -1)
    if [ -z "$iface" ]; then
        # Check iw for any wireless interface
        iface=$(iw dev 2>/dev/null | grep -oP 'Interface\s+\K\S+' | head -1)
    fi
    if [ -z "$iface" ]; then
        # Check /sys/class/net for wireless type
        for netdev in /sys/class/net/*/wireless; do
            if [ -d "$netdev" ]; then
                iface=$(basename "$(dirname "$netdev")")
                break
            fi
        done
    fi
    echo "$iface"
}

# =========================================================
# 3. Try loading WiFi kernel drivers
# =========================================================
load_wifi_drivers() {
    log "Attempting to load WiFi drivers..."

    # cfg80211 is the core wireless framework — load it first
    modprobe cfg80211 2>/dev/null && log "  Loaded: cfg80211"

    # List of WiFi drivers to try (mainline + common out-of-tree)
    local drivers=(
        # --- Mainline drivers (should be in kernel) ---
        "mt7601u"           # MediaTek MT7601U (USB 2.4GHz)
        "mt7603e"           # MediaTek MT7603
        "mt76x0u"           # MediaTek MT7610U
        "mt76x2u"           # MediaTek MT7612U
        "mt76x2e"           # MediaTek MT7612 PCIe
        "mt7921e"           # MediaTek MT7921
        "brcmfmac"          # Broadcom/AP6xxx (SDIO/USB/PCIe)
        "brcmutil"          # Broadcom utility
        "rtl8xxxu"          # Realtek generic USB (8188/8192/8821/8822)
        "rtw88_8723du"      # Realtek RTL8723DU
        "rtw88_8821cu"      # Realtek RTL8821CU
        "rtw88_8822bu"      # Realtek RTL8822BU
        "rtw88_8822cu"      # Realtek RTL8822CU
        "rtw89_8852be"      # Realtek RTL8852BE
        "ath9k_htc"         # Atheros ATH9K (USB)
        "ath9k"             # Atheros ATH9K (PCIe)
        "ath10k_pci"        # Atheros ATH10K (PCIe)
        "ath10k_sdio"       # Atheros ATH10K (SDIO)
        "ath11k_pci"        # Atheros ATH11K (PCIe)
        "iwlwifi"           # Intel WiFi (PCIe)
        "wl"                # Broadcom proprietary (PCIe)

        # --- Out-of-tree drivers (common in Amlogic/ophub kernels) ---
        "ssv6051"           # SSV6051 / SV6256P (SDIO)
        "ssv6xxx"           # SSV generic (SDIO)
        "ssv6256"           # SSV6256 (SDIO)
        "uwe5622"           # Unisoc UWE5622 (SDIO)
        "uwe5622_wifi"      # Unisoc UWE5622 alternate name
        "sprdwl"            # Spreadtrum/Unisoc wireless
        "sprd_wcn"          # Spreadtrum WCN
        "marlin"            # Unisoc Marlin (BT/WiFi combo)
        "rtl8189es"         # Realtek RTL8189ES (SDIO)
        "rtl8189fs"         # Realtek RTL8189FS (SDIO)
        "8189es"            # Realtek RTL8189ES alternate
        "8189fs"            # Realtek RTL8189FS alternate
        "aic8800_sdio"      # AIC8800 (SDIO)
        "aic8800_fdrv"      # AIC8800 fullmac
        "esp8089"           # Espressif ESP8089 (SDIO)
        "dhd"               # Broadcom DHD (Amlogic variant)
    )

    local loaded_count=0
    for drv in "${drivers[@]}"; do
        if modprobe "$drv" 2>/dev/null; then
            log "  Loaded: $drv"
            ((loaded_count++))
        fi
    done
    log "Driver loading complete: $loaded_count driver(s) loaded"
}

# =========================================================
# 4. Check SDIO bus for WiFi devices
# =========================================================
check_sdio_bus() {
    if [ -d /sys/bus/sdio/devices ]; then
        local sdio_count=$(ls /sys/bus/sdio/devices/ 2>/dev/null | wc -l)
        if [ "$sdio_count" -gt 0 ]; then
            log "SDIO bus has $sdio_count device(s):"
            for dev in /sys/bus/sdio/devices/*; do
                [ -d "$dev" ] || continue
                local vendor=$(cat "$dev/vendor" 2>/dev/null)
                local device=$(cat "$dev/device" 2>/dev/null)
                local modalias=$(cat "$dev/modalias" 2>/dev/null)
                log "  SDIO: vendor=$vendor device=$device modalias=$modalias"
            done
        else
            log "SDIO bus: no devices found"
        fi
    fi
}

# =========================================================
# 5. Check USB bus for WiFi dongles
# =========================================================
check_usb_bus() {
    if lsusb &>/dev/null; then
        local wifi_usb=$(lsusb 2>/dev/null | grep -iE 'wifi|wireless|802\.11|rtl88|rtl87|rtl81|mt76|atheros|broadcom|realtek.*wlan|0bda:.*8|148f:|7392:|0e66:|13b1:|0586:|0846:' | head -5)
        if [ -n "$wifi_usb" ]; then
            log "USB WiFi dongle(s) detected:"
            echo "$wifi_usb" | while read -r line; do
                log "  $line"
            done
        else
            log "No USB WiFi dongle detected"
        fi
    fi
}

# =========================================================
# 6. Configure NetworkManager for WiFi
# =========================================================
configure_networkmanager() {
    local iface="$1"
    if [ -z "$iface" ]; then
        return
    fi

    log "Configuring NetworkManager for $iface..."

    # Bring up the interface
    ip link set "$iface" up 2>/dev/null

    # Set managed by NetworkManager
    if command -v nmcli &>/dev/null; then
        nmcli device set "$iface" managed yes 2>/dev/null
        log "  NetworkManager: $iface set to managed"

        # Trigger a WiFi scan (non-blocking)
        nmcli device wifi rescan 2>/dev/null
        log "  WiFi scan triggered"

        # List available networks
        # V6.4.1 fix: 使用 -f 指定字段而非 cut 解析, 避免SSID含冒号时解析错误
        local networks=$(nmcli -t -f SSID,SIGNAL device wifi list 2>/dev/null | head -10)
        if [ -n "$networks" ]; then
            log "  Available networks:"
            echo "$networks" | while IFS=: read -r ssid signal; do
                log "    SSID: $ssid (signal: $signal)"
            done
        else
            log "  No networks found (may need time to scan)"
        fi
    else
        log "  nmcli not found, using wpa_supplicant directly"

        # Ensure wpa_supplicant is running
        if command -v wpa_supplicant &>/dev/null; then
            if ! pgrep -x wpa_supplicant &>/dev/null; then
                wpa_supplicant -B -i "$iface" -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null
                log "  wpa_supplicant started on $iface"
            fi
        fi
    fi
}

# =========================================================
# 7. Get WiFi device info
# =========================================================
show_wifi_info() {
    local iface="$1"
    if [ -z "$iface" ]; then
        return
    fi

    log "WiFi interface details:"
    local info=$(iw dev "$iface" info 2>/dev/null)
    if [ -n "$info" ]; then
        echo "$info" | while IFS= read -r line; do
            log "  $line"
        done
    fi

    # Show driver info
    local driver=$(ethtool -i "$iface" 2>/dev/null | grep "^driver:" | awk '{print $2}')
    if [ -n "$driver" ]; then
        log "  Driver: $driver"
        local fwinfo=$(ethtool -i "$iface" 2>/dev/null | grep "^firmware:" | awk '{print $2}')
        [ -n "$fwinfo" ] && log "  Firmware: $fwinfo"
    fi

    # Show MAC address
    local mac=$(ip link show "$iface" 2>/dev/null | grep -oP 'link/ether\s+\K\S+')
    [ -n "$mac" ] && log "  MAC: $mac"
}

# =========================================================
# Main
# =========================================================
main() {
    log "========================================"
    log "B860AV2.1-A WiFi Setup (V6) starting..."
    log "========================================"

    # Step 1: Unblock rfkill
    unblock_rfkill

    # Step 2: Check if WiFi already exists
    local wifi_iface=$(detect_wifi_interface)
    if [ -n "$wifi_iface" ]; then
        log "WiFi interface already present: $wifi_iface"
        configure_networkmanager "$wifi_iface"
        show_wifi_info "$wifi_iface"
        log "WiFi setup complete (interface was already present)."
        log "Use 'wifi-connect.sh' or 'nmtui' to connect to a network."
        exit 0
    fi

    log "No WiFi interface found at boot. Attempting driver load..."

    # Step 3: Check SDIO and USB buses before loading
    check_sdio_bus
    check_usb_bus

    # Step 4: Try loading WiFi drivers
    load_wifi_drivers

    # Step 5: Wait for interface to appear
    log "Waiting for WiFi interface to appear..."
    local waited=0
    local max_wait=10
    while [ $waited -lt $max_wait ]; do
        sleep 1
        wifi_iface=$(detect_wifi_interface)
        if [ -n "$wifi_iface" ]; then
            break
        fi
        ((waited++))
    done

    if [ -n "$wifi_iface" ]; then
        log "WiFi interface detected after driver load: $wifi_iface"
        check_sdio_bus
        configure_networkmanager "$wifi_iface"
        show_wifi_info "$wifi_iface"
        log "WiFi setup complete."
        log "Use 'wifi-connect.sh' or 'nmtui' to connect to a network."
    else
        log "No WiFi interface found after loading drivers."
        log "This device may be the NW (No WiFi) variant,"
        log "or the WiFi driver may not be included in this kernel."
        log ""
        log "Supported WiFi chips and their status:"
        log "  MT7601U (USB):     mainline driver mt7601u (kernel >= 4.15)"
        log "  AP6xxx (SDIO):     mainline driver brcmfmac"
        log "  SSV6051 (SDIO):    needs out-of-tree driver ssv6051"
        log "  UWE5622 (SDIO):    needs out-of-tree driver uwe5622"
        log "  RTL8189 (SDIO):    needs out-of-tree driver rtl8189es/fs"
        log ""
        log "Firmware files are pre-installed in /lib/firmware/."
        log "Install the matching kernel module to enable WiFi."
    fi

    log "========================================"
    log "WiFi setup finished."
    log "========================================"
}

main "$@"
