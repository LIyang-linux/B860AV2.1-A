#!/bin/bash
#
# first-boot-check.sh - 首次启动验证与修复脚本
#
# 在系统启动后自动检查:
# 1. boot 分区中的 UUID 是否与实际 rootfs UUID 匹配
# 2. 网络接口是否可用
# 3. eMMC 健康状态
# 4. 关键服务是否运行
#
# 如发现问题, 自动修复并记录日志
#

LOG="/var/log/first-boot-check.log"
BOOT_DEV="/dev/mmcblk0p1"
ROOT_DEV="/dev/mmcblk0p2"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== First boot check started ==="

# 1. UUID 一致性检查
ACTUAL_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null)
CMDLINE_UUID=$(cat /proc/cmdline 2>/dev/null | grep -oP 'root=UUID=\K[a-f0-9-]+')

log "Actual rootfs UUID: $ACTUAL_UUID"
log "Cmdline root UUID: $CMDLINE_UUID"

if [ -n "$ACTUAL_UUID" ] && [ -n "$CMDLINE_UUID" ] && [ "$ACTUAL_UUID" != "$CMDLINE_UUID" ]; then
    log "WARNING: UUID mismatch detected! Fixing boot config..."
    mkdir -p /tmp/boot-check
    if mount "$BOOT_DEV" /tmp/boot-check 2>/dev/null; then
        for f in /tmp/boot-check/uEnv.txt /tmp/boot-check/extlinux/extlinux.conf; do
            if [ -f "$f" ]; then
                sed -i "s/root=UUID=[a-f0-9-]*/root=UUID=$ACTUAL_UUID/g" "$f"
                log "  Fixed: $f"
            fi
        done
        umount /tmp/boot-check 2>/dev/null
        log "Boot config UUID fixed. Will take effect on next boot."
    fi
fi

# 2. 网络接口检查
sleep 5
if ip link show eth0 &>/dev/null; then
    ETH_STATE=$(cat /sys/class/net/eth0/operstate 2>/dev/null)
    log "eth0 state: $ETH_STATE"
    if [ "$ETH_STATE" != "up" ]; then
        log "eth0 not up, triggering fix-gxl-eth.sh..."
        /usr/local/bin/fix-gxl-eth.sh 2>/dev/null || log "  fix-gxl-eth.sh failed"
    fi
else
    log "WARNING: eth0 interface not found!"
fi

# 3. eMMC 健康检查
if [ -f /sys/block/mmcblk0/device/life_time ]; then
    log "eMMC life time: $(cat /sys/block/mmcblk0/device/life_time 2>/dev/null)"
fi

# 4. 文件系统检查
ROOT_ERRORS=$(dmesg 2>/dev/null | grep -i "ext4.*error" | head -5)
if [ -n "$ROOT_ERRORS" ]; then
    log "WARNING: ext4 errors detected in dmesg:"
    echo "$ROOT_ERRORS" | while read line; do log "  $line"; done
    log "Scheduling fsck for next boot..."
    touch /forcefsck 2>/dev/null
fi

# 5. 检查关键服务
for svc in fix-gxl-eth.service eth-monitor.service mac-setup.service; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        log "Service $svc: enabled"
    else
        log "WARNING: Service $svc not enabled!"
    fi
done

# 6. 禁用自身 (仅首次运行)
log "=== First boot check complete ==="
systemctl disable first-boot-check.service 2>/dev/null
