#!/bin/bash
#
# fix-gxl-eth.sh - 修复 Amlogic GXL 内部 PHY LPA Corruption
#
# Amlogic GXL 内部 PHY (ID 0x01814400) 在自动协商时存在已知缺陷:
# 约 1/12 概率 LPA 寄存器值损坏,导致链路建立失败.
# 本脚本在启动时检测并重试自动协商,最终回退到强制 100Mbps.
#
# 参考: Linux kernel drivers/net/phy/meson-gxl.c meson_gxl_read_status()

MAX_RETRIES=6
RETRY_DELAY=2

log() { echo "[fix-gxl-eth] $1"; }

# 等待 eth0 出现
for i in $(seq 1 10); do
    [ -e /sys/class/net/eth0 ] && break
    sleep 1
done

if [ ! -e /sys/class/net/eth0 ]; then
    log "eth0 not found, exiting"
    exit 0
fi

# 检查链路状态
check_link() {
    local state
    state=$(cat /sys/class/net/eth0/operstate 2>/dev/null)
    [ "$state" = "up" ]
}

# 重启自动协商
restart_autoneg() {
    if command -v ethtool >/dev/null 2>&1; then
        ethtool -r eth0 2>/dev/null
    else
        # 无 ethtool 时通过 link down/up 触发 PHY 重置
        ip link set eth0 down 2>/dev/null
        sleep 1
        ip link set eth0 up 2>/dev/null
    fi
}

log "Starting LPA corruption check (max ${MAX_RETRIES} retries)"

for i in $(seq 1 $MAX_RETRIES); do
    if check_link; then
        log "Link established (attempt ${i}/${MAX_RETRIES})"
        exit 0
    fi
    log "Link not ready (attempt ${i}/${MAX_RETRIES}), restarting autoneg..."
    restart_autoneg
    sleep $RETRY_DELAY
done

# 最终回退: 强制 100Mbps 半双工, 然后重新启用自动协商
log "Autoneg failed, trying forced speed fallback..."
if command -v ethtool >/dev/null 2>&1; then
    ethtool -s eth0 speed 100 duplex half autoneg off 2>/dev/null
    sleep 2
    ethtool -s eth0 autoneg on 2>/dev/null
    sleep 3
else
    # 无 ethtool: 多次 link down/up
    for j in 1 2 3; do
        ip link set eth0 down 2>/dev/null
        sleep 1
        ip link set eth0 up 2>/dev/null
        sleep 3
        check_link && break
    done
fi

if check_link; then
    log "Link established after fallback"
else
    log "WARNING: Could not establish ethernet link after all retries"
fi

exit 0
