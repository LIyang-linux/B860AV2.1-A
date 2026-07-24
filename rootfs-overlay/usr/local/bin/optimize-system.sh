#!/bin/bash
#==============================================================
# optimize-system.sh - B860AV2.1-A 系统优化脚本 (V6.1)
#
# 在启动时自动配置以下优化:
#   1. zram swap (压缩内存交换, 减少 eMMC 写入)
#   2. CPU 调频策略 (ondemand/conservative, 降低功耗和发热)
#   3. tmpfs 挂载 /tmp (减少 eMMC 写入)
#   4. 内核脏页回写优化 (减少 eMMC 写入频率)
#   5. 禁用不必要的日志写入
#
# 适用于: Amlogic S905L3-B, 2GB DDR4, 8GB eMMC
#==============================================================

LOG="/var/log/optimize-system.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG" 2>/dev/null
}

log "========================================"
log "B860AV2.1-A System Optimization starting..."
log "========================================"

# =========================================================
# 1. zram Swap (压缩内存交换, 避免 eMMC 频繁写入)
# =========================================================
setup_zram() {
    log "Setting up zram swap..."

    # 检查 zram 模块是否可用
    if ! modprobe zram 2>/dev/null; then
        log "  zram module not available, skipping"
        return 1
    fi

    # 检查是否已有 zram swap
    if swapon --show 2>/dev/null | grep -q zram; then
        log "  zram swap already active, skipping"
        return 0
    fi

    # 查找空闲的 zram 设备
    local zram_dev=""
    for i in 0 1 2 3; do
        if [ ! -e "/sys/block/zram${i}/disksize" ] || \
           [ "$(cat /sys/block/zram${i}/disksize 2>/dev/null)" = "0" ]; then
            zram_dev="/dev/zram${i}"
            break
        fi
    done

    if [ -z "$zram_dev" ]; then
        log "  No free zram device found, skipping"
        return 1
    fi

    # 设置 zram 大小为内存的 50% (2GB → 1GB 压缩 swap)
    local mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local zram_size_kb=$((mem_total_kb / 2))

    # 使用 lz4 压缩 (比 lzo 更快, S905L3-B 支持)
    echo lz4 > "/sys/block/$(basename $zram_dev)/comp_algorithm" 2>/dev/null || \
    echo lzo > "/sys/block/$(basename $zram_dev)/comp_algorithm" 2>/dev/null

    echo "${zram_size_kb}K" > "/sys/block/$(basename $zram_dev)/disksize" 2>/dev/null
    if [ $? -ne 0 ]; then
        log "  Failed to set zram disksize, skipping"
        return 1
    fi

    mkswap "$zram_dev" 2>/dev/null
    swapon -p 100 "$zram_dev" 2>/dev/null

    if swapon --show 2>/dev/null | grep -q zram; then
        log "  zram swap active: ${zram_dev} ($(( zram_size_kb / 1024 ))MB, $(cat /sys/block/$(basename $zram_dev)/comp_algorithm 2>/dev/null))"
        # 降低 swap 倾向 (zram 优先, 磁盘 swap 次之)
        echo 60 > /proc/sys/vm/swappiness 2>/dev/null
        log "  swappiness set to 60 (zram-friendly)"
    else
        log "  WARNING: zram swap activation failed"
        return 1
    fi
}

# =========================================================
# 2. CPU 调频策略 (ondemand 优先, 降低功耗)
# =========================================================
setup_cpu_governor() {
    log "Setting CPU governor..."

    # S905L3-B 有 4 个 A55 核心
    local governors_available=""
    local set_count=0

    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] || continue
        if [ -z "$governors_available" ]; then
            governors_available=$(cat "$(dirname $cpu)/scaling_available_governors" 2>/dev/null)
        fi

        # 优先使用 ondemand (平衡性能和功耗)
        # 备选 conservative (更激进省电), schedutil (6.1 内核推荐)
        local gov="ondemand"
        if ! echo "$governors_available" | grep -qw ondemand; then
            if echo "$governors_available" | grep -qw schedutil; then
                gov="schedutil"
            elif echo "$governors_available" | grep -qw conservative; then
                gov="conservative"
            elif echo "$governors_available" | grep -qw powersave; then
                gov="powersave"
            else
                log "  No suitable governor available: $governors_available"
                return 1
            fi
        fi

        echo "$gov" > "$cpu" 2>/dev/null && ((set_count++))
    done

    if [ "$set_count" -gt 0 ]; then
        local active_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        log "  CPU governor: $active_gov (set on $set_count core(s))"

        # 设置 ondemand 采样速率 (更快响应负载变化)
        if [ "$active_gov" = "ondemand" ]; then
            local sampling_rate=$(cat /sys/devices/system/cpu/cpufreq/ondemand/sampling_rate_min 2>/dev/null)
            if [ -n "$sampling_rate" ]; then
                echo "$sampling_rate" > /sys/devices/system/cpu/cpufreq/ondemand/sampling_rate 2>/dev/null
                log "  ondemand sampling_rate: ${sampling_rate}us"
            fi
            # up_threshold: 负载超过 50% 时升频 (默认 95% 太保守)
            echo 50 > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold 2>/dev/null
            log "  ondemand up_threshold: 50%"
        fi
    else
        log "  WARNING: Could not set CPU governor"
    fi
}

# =========================================================
# 3. tmpfs for /tmp (减少 eMMC 写入)
# =========================================================
setup_tmpfs() {
    log "Setting up tmpfs for /tmp..."

    # 检查 /tmp 是否已经是 tmpfs
    if mount | grep -q 'on /tmp type tmpfs'; then
        log "  /tmp already mounted as tmpfs"
        return 0
    fi

    # 检查 fstab 是否已有 tmp 配置
    if grep -q '/tmp' /etc/fstab 2>/dev/null; then
        log "  /tmp entry found in fstab, attempting mount..."
        mount /tmp 2>/dev/null && log "  /tmp mounted from fstab" || log "  WARNING: mount /tmp failed"
        return 0
    fi

    # 临时挂载 tmpfs (256MB, 足够编译和临时文件)
    mount -t tmpfs -o size=256M,mode=1777 tmpfs /tmp 2>/dev/null
    if [ $? -eq 0 ]; then
        log "  /tmp mounted as tmpfs (256MB)"
        # 持久化到 fstab
        if ! grep -q 'tmpfs.* /tmp' /etc/fstab 2>/dev/null; then
            echo 'tmpfs /tmp tmpfs defaults,size=256M,mode=1777 0 0' >> /etc/fstab
            log "  Added /tmp to fstab for persistence"
        fi
    else
        log "  WARNING: Failed to mount tmpfs on /tmp"
    fi
}

# =========================================================
# 4. 内核脏页回写优化 (减少 eMMC 写入频率)
# =========================================================
setup_writeback_optimization() {
    log "Setting up writeback optimization..."

    # vm.dirty_background_ratio: 脏页占内存 5% 时开始后台回写 (默认 10%)
    echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
    # vm.dirty_ratio: 脏页占内存 15% 时同步回写 (默认 20%)
    echo 15 > /proc/sys/vm/dirty_ratio 2>/dev/null
    # vm.dirty_expire_centisecs: 脏数据 30 秒后过期回写 (默认 3000 = 30秒)
    echo 3000 > /proc/sys/vm/dirty_expire_centisecs 2>/dev/null
    # vm.dirty_writeback_centisecs: 每 60 秒周期性回写 (默认 500 = 5秒)
    echo 6000 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null
    # vm.vfs_cache_pressure: 减少 inode/dentry 回收压力 (默认 100)
    echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null

    log "  dirty_background_ratio=5, dirty_ratio=15"
    log "  dirty_writeback=60s, vfs_cache_pressure=50"

    # 持久化到 sysctl.conf (避免每次启动重新设置)
    local sysctl_file="/etc/sysctl.d/99-eMMC-protect.conf"
    cat > "$sysctl_file" << 'EOF'
# B860AV2.1-A eMMC 写入保护优化
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 6000
vm.vfs_cache_pressure = 50
# V6.4.1 fix: 持久化 swappiness (zram 优先, 磁盘 swap 次之)
vm.swappiness = 60
EOF
    log "  Persisted to $sysctl_file"
}

# =========================================================
# 5. 禁用不必要的内核日志输出到 eMMC
# =========================================================
setup_log_optimization() {
    log "Setting up log optimization..."

    # 降低内核日志级别 (减少 dmesg 写入)
    echo "3 3 3 3" > /proc/sys/kernel/printk 2>/dev/null
    log "  kernel printk level set to 3"

    # 如果 journald 存在, 限制日志大小和持久化
    if [ -d /etc/systemd/journald.conf.d ]; then
        cat > /etc/systemd/journald.conf.d/99-size-limit.conf << 'EOF'
[Journal]
# 限制日志最大 50MB (8GB eMMC 需要节省空间)
SystemMaxUse=50M
SystemMaxFileSize=10M
# 不持久化日志到 eMMC (重启后清空)
Storage=volatile
RuntimeMaxUse=20M
RuntimeMaxFileSize=5M
EOF
        log "  journald: volatile storage, 50M max"
        # V6.4.1 fix: 使用 reload 而非 restart, 避免启动期间重启 journald 导致日志丢失
        # restart 会中断当前所有日志流, reload 只重新加载配置
        systemctl reload systemd-journald 2>/dev/null || true
    fi
}

# =========================================================
# Main
# =========================================================
main() {
    setup_zram
    setup_cpu_governor
    setup_tmpfs
    setup_writeback_optimization
    setup_log_optimization

    log "========================================"
    log "System optimization complete."
    log "========================================"

    # 打印当前状态摘要
    log "--- Summary ---"
    log "Swap: $(swapon --show --noheadings 2>/dev/null | awk '{print $1, $3}')"
    log "CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
    log "/tmp: $(mount | grep 'on /tmp' | awk '{print $5}' || echo 'disk')"
    log "swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null)"
}

main "$@"
