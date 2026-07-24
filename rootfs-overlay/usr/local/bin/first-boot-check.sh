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

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== First boot check started ==="

# 0. 动态检测 boot 和 root 设备 (不再硬编码 /dev/mmcblk0p1/p2)
# 从 /proc/cmdline 提取 root= 参数获取 rootfs 设备
ROOT_DEV=""
CMDLINE_ROOT=$(cat /proc/cmdline 2>/dev/null | grep -oP 'root=\K\S+')
if [ -n "$CMDLINE_ROOT" ]; then
    # root= 可能是 UUID=xxx 或 /dev/xxx
    if echo "$CMDLINE_ROOT" | grep -q '^UUID='; then
        ROOT_UUID_CMDLINE=$(echo "$CMDLINE_ROOT" | sed 's/UUID=//')
        ROOT_DEV=$(blkid -U "$ROOT_UUID_CMDLINE" 2>/dev/null || echo "")
    elif echo "$CMDLINE_ROOT" | grep -q '^/dev/'; then
        ROOT_DEV="$CMDLINE_ROOT"
    fi
fi
# 回退: 尝试 findmnt 获取当前 root 挂载设备
if [ -z "$ROOT_DEV" ]; then
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
fi
# 回退: 扫描 mmcblk0/1 的各分区找 ext4
if [ -z "$ROOT_DEV" ]; then
    for dev in /dev/mmcblk0p2 /dev/mmcblk1p2 /dev/mmcblk0p3 /dev/mmcblk1p3; do
        if [ -b "$dev" ] && blkid "$dev" 2>/dev/null | grep -q ext4; then
            ROOT_DEV="$dev"
            break
        fi
    done
fi

# 检测 boot 分区: root 设备的同盘第一分区 (FAT32/vfat)
BOOT_DEV=""
if [ -n "$ROOT_DEV" ]; then
    # 从 root 设备推导盘符: /dev/mmcblk0p2 → /dev/mmcblk0p1
    BASE_DEV=$(echo "$ROOT_DEV" | sed 's/p[0-9]*$//')
    PART1="${BASE_DEV}p1"
    if [ -b "$PART1" ]; then
        BOOT_DEV="$PART1"
    elif [ -b "${BASE_DEV}1" ]; then
        BOOT_DEV="${BASE_DEV}1"
    fi
fi
# 回退: blkid 找 vfat 分区
if [ -z "$BOOT_DEV" ]; then
    BOOT_DEV=$(blkid -t TYPE=vfat -o device 2>/dev/null | head -1 || echo "")
fi

log "Detected root device: ${ROOT_DEV:-unknown}"
log "Detected boot device: ${BOOT_DEV:-unknown}"

# 1. UUID 一致性检查
ACTUAL_UUID=""
if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
    ACTUAL_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null)
fi
CMDLINE_UUID=$(cat /proc/cmdline 2>/dev/null | grep -oP 'root=UUID=\K[a-f0-9-]+')

log "Actual rootfs UUID: $ACTUAL_UUID"
log "Cmdline root UUID: $CMDLINE_UUID"

if [ -n "$ACTUAL_UUID" ] && [ -n "$CMDLINE_UUID" ] && [ "$ACTUAL_UUID" != "$CMDLINE_UUID" ]; then
    log "WARNING: UUID mismatch detected! Fixing boot config..."
    mkdir -p /tmp/boot-check
    if [ -n "$BOOT_DEV" ] && mount "$BOOT_DEV" /tmp/boot-check 2>/dev/null; then
        for f in /tmp/boot-check/uEnv.txt /tmp/boot-check/extlinux/extlinux.conf; do
            if [ -f "$f" ]; then
                sed -i "s/root=UUID=[a-f0-9-]*/root=UUID=$ACTUAL_UUID/g" "$f"
                log "  Fixed: $f"
            fi
        done
        umount /tmp/boot-check 2>/dev/null
        log "Boot config UUID fixed. Will take effect on next boot."
    else
        log "WARNING: Could not mount boot partition ($BOOT_DEV), skipping UUID fix"
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

# 3. eMMC 健康检查 (动态检测 mmcblk 设备)
for mmcdev in /sys/block/mmcblk*; do
    [ -d "$mmcdev" ] || continue
    devname=$(basename "$mmcdev")
    if [ -f "$mmcdev/device/life_time" ]; then
        log "eMMC life time ($devname): $(cat "$mmcdev/device/life_time" 2>/dev/null)"
    fi
    if [ -f "$mmcdev/device/name" ]; then
        log "eMMC name ($devname): $(cat "$mmcdev/device/name" 2>/dev/null)"
    fi
done

# 4. 文件系统检查
ROOT_ERRORS=$(dmesg 2>/dev/null | grep -i "ext4.*error" | head -5)
if [ -n "$ROOT_ERRORS" ]; then
    log "WARNING: ext4 errors detected in dmesg:"
    echo "$ROOT_ERRORS" | while read line; do log "  $line"; done
    log "Scheduling fsck for next boot..."
    touch /forcefsck 2>/dev/null
fi

# 5. 检查关键服务
for svc in fix-gxl-eth.service eth-monitor.service mac-setup.service wifi-setup.service system-optimization.service gpu-setup.service; do
    if systemctl is-enabled "$svc" &>/dev/null; then
        log "Service $svc: enabled"
    else
        log "WARNING: Service $svc not enabled!"
    fi
done

# 6. 禁用自身 (仅首次运行)
log "=== First boot check complete ==="
systemctl disable first-boot-check.service 2>/dev/null
