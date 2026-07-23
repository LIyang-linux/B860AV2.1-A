#!/bin/bash
#
# mac-setup.sh - MAC 地址设置
#
# 从 U-Boot env 读取 MAC 地址, 不可用时生成稳定的本地管理地址.
# 基于设备序列号生成, 确保重启后 MAC 一致.

log() { echo "[mac-setup] $1"; }

# 等待 eth0
for i in $(seq 1 10); do
    [ -e /sys/class/net/eth0 ] && break
    sleep 1
done
[ ! -e /sys/class/net/eth0 ] && exit 0

# 获取当前 MAC
CURRENT_MAC=$(cat /sys/class/net/eth0/address 2>/dev/null)

# 尝试从 U-Boot env 读取
if command -v fw_printenv >/dev/null 2>&1; then
    ENV_MAC=$(fw_printenv ethaddr 2>/dev/null | cut -d= -f2 | tr -d ' ')
    if echo "$ENV_MAC" | grep -qE '^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'; then
        if [ "$CURRENT_MAC" != "$ENV_MAC" ]; then
            ip link set eth0 down 2>/dev/null
            ip link set eth0 address "$ENV_MAC" 2>/dev/null
            ip link set eth0 up 2>/dev/null
            log "Set MAC from U-Boot env: $ENV_MAC"
        else
            log "MAC already correct: $CURRENT_MAC"
        fi
        exit 0
    fi
fi

# 检查当前 MAC 是否为无效 (全零或广播)
if [ "$CURRENT_MAC" = "00:00:00:00:00:00" ] || [ -z "$CURRENT_MAC" ]; then
    # 基于设备序列号生成稳定 MAC
    SERIAL=$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\0')
    if [ -n "$SERIAL" ]; then
        # 取序列号哈希的前5字节, 首字节设为 02 (本地管理地址)
        HASH=$(echo "$SERIAL" | md5sum | cut -c1-10)
        MAC="02:$(echo $HASH | sed 's/\(..\)/\1:/g; s/:$//; s/\(..\):\(..\):\(..\):\(..\):\(..\)/\1:\2:\3:\4:\5/')"
    else
        # 随机生成
        MAC=$(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    fi
    ip link set eth0 down 2>/dev/null
    ip link set eth0 address "$MAC" 2>/dev/null
    ip link set eth0 up 2>/dev/null
    log "Generated MAC: $MAC"
else
    log "Using existing MAC: $CURRENT_MAC"
fi

exit 0
