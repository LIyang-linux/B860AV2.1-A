#!/bin/bash
#
# eth-monitor.sh - 以太网链路持续监控
#
# 持续监控 eth0 链路状态, 当链路断开时自动重启自动协商.
# 作为 fix-gxl-eth.sh 的补充, 处理运行时偶发的 LPA corruption.

INTERVAL=30
MAX_LINK_DOWN_RETRIES=3

log() { echo "[eth-monitor] $(date '+%H:%M:%S') $1"; }

log "Starting eth0 link monitor (interval=${INTERVAL}s)"

while true; do
    if [ -e /sys/class/net/eth0 ]; then
        STATE=$(cat /sys/class/net/eth0/operstate 2>/dev/null)

        if [ "$STATE" = "down" ]; then
            log "eth0 is down, attempting recovery..."

            for retry in $(seq 1 $MAX_LINK_DOWN_RETRIES); do
                if command -v ethtool >/dev/null 2>&1; then
                    ethtool -r eth0 2>/dev/null
                else
                    ip link set eth0 down 2>/dev/null
                    sleep 1
                    ip link set eth0 up 2>/dev/null
                fi
                sleep 5

                STATE=$(cat /sys/class/net/eth0/operstate 2>/dev/null)
                if [ "$STATE" = "up" ]; then
                    log "Link recovered (retry ${retry}/${MAX_LINK_DOWN_RETRIES})"
                    break
                fi
                log "Still down (retry ${retry}/${MAX_LINK_DOWN_RETRIES})"
            done

            # 如果仍然 down, 尝试强制速度回退
            if [ "$STATE" != "up" ] && command -v ethtool >/dev/null 2>&1; then
                log "Forcing 100Mbps half-duplex fallback..."
                ethtool -s eth0 speed 100 duplex half autoneg off 2>/dev/null
                sleep 2
                ethtool -s eth0 autoneg on 2>/dev/null
                sleep 5
            fi
        fi
    fi
    sleep $INTERVAL
done
