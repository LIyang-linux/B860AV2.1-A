#!/bin/bash
#
# gpu-setup.sh - Mali-450 GPU (lima) 驱动加载与验证脚本
#
# 功能:
#   1. 加载 lima 内核模块 (Mali-450 GPU)
#   2. 验证 DRM/GPU 设备节点
#   3. 检查 Mesa 用户空间驱动 (lima_dri.so + libglapi.so)
#   4. 设置 LIBGL_DRIVERS_PATH 环境变量
#   5. 记录 GPU 状态到日志
#
# Lima 是 Mali-450 (Utgard 架构) 的开源 DRM 驱动
# Mesa lima 驱动提供 OpenGL ES 2.0 / OpenGL 2.1 用户空间支持
# 参考: https://docs.mesa3d.org/drivers/lima.html
#

LOG="/var/log/gpu-setup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"
}

log "=== GPU (Mali-450 / lima) setup started ==="

# 0. 确保依赖模块已加载 (lima 依赖 drm 和 meson-drm)
for mod in drm meson-drm; do
    if ! lsmod | grep -q "^$mod"; then
        modprobe "$mod" 2>/dev/null && log "Loaded dependency: $mod" || true
    fi
done

# 1. 加载 lima 内核模块
if lsmod | grep -q lima; then
    log "lima module already loaded"
else
    log "Loading lima kernel module..."
    modprobe lima 2>/dev/null
    if lsmod | grep -q lima; then
        log "lima module loaded successfully"
    else
        log "WARNING: Failed to load lima module via modprobe"
        # 检查模块文件是否存在
        KVER=$(uname -r)
        LIMA_KO=$(find /lib/modules/$KVER -name "lima.ko" 2>/dev/null | head -1)
        if [ -n "$LIMA_KO" ]; then
            log "  lima.ko found at: $LIMA_KO"
            log "  Trying insmod..."
            # lima 依赖 drm 模块, 先确保 drm 已加载
            modprobe drm 2>/dev/null || true
            insmod "$LIMA_KO" 2>/dev/null && log "  insmod succeeded" || log "  insmod failed"
        else
            log "  ERROR: lima.ko not found in /lib/modules/$KVER"
            log "  The kernel may not include CONFIG_DRM_LIMA support"
            log "  Check kernel config with: zcat /proc/config.gz | grep LIMA"
        fi
    fi
fi

# 2. 验证 DRM 设备节点
log "--- DRM device nodes ---"
if [ -d /dev/dri ]; then
    for dev in /dev/dri/*; do
        log "  $(basename $dev): present"
    done
    # 检查 renderD128 (GPU 渲染节点)
    if [ -e /dev/dri/renderD128 ]; then
        log "  renderD128 (GPU render node) available"
        # 设置权限确保普通用户可访问
        chmod 666 /dev/dri/renderD128 2>/dev/null || true
    fi
else
    log "  WARNING: /dev/dri not found"
    log "  This may indicate DRM subsystem or display driver issues"
fi

# 3. 检查 lima DRM 设备
log "--- lima driver status ---"
if [ -d /sys/module/lima ]; then
    log "  lima kernel module is loaded"
    # 检查 dmesg 中的 lima 探测信息
    LIMA_DMESG=$(dmesg 2>/dev/null | grep -i "lima.*mali" | tail -5)
    if [ -n "$LIMA_DMESG" ]; then
        echo "$LIMA_DMESG" | while read line; do log "  dmesg: $line"; done
    fi
else
    log "  WARNING: lima kernel module not loaded"
fi

# 4. 检查 Mesa 用户空间驱动
log "--- Mesa userspace driver ---"
# 确保动态库链接缓存是最新的 (CI 构建时可能未运行 ldconfig)
ldconfig 2>/dev/null || true

# 检查 lima_dri.so (Mesa gallium 驱动)
LIMA_DRI=$(find /usr/lib -name "lima_dri.so" 2>/dev/null | head -1)
if [ -n "$LIMA_DRI" ]; then
    log "  Mesa lima DRI driver found: $LIMA_DRI"
else
    log "  WARNING: Mesa lima_dri.so not found"
    log "  GPU acceleration will not work without Mesa"
    log "  Install with: apt install libgl1-mesa-dri"
fi

# 检查 libglapi.so (Mesa DRI 驱动的关键依赖)
GLAPI_LIB=$(find /usr/lib -name "libglapi.so*" 2>/dev/null | head -1)
if [ -n "$GLAPI_LIB" ]; then
    log "  libglapi.so found: $GLAPI_LIB"
else
    log "  WARNING: libglapi.so not found"
    log "  Mesa DRI drivers require libglapi-mesa package"
    log "  Install with: apt install libglapi-mesa"
fi

# V6.4.1: 检查 libLLVM (Mesa 23.x gallium 驱动的运行时依赖)
LLVM_LIB=$(find /usr/lib -name "libLLVM-*.so*" 2>/dev/null | head -1)
if [ -n "$LLVM_LIB" ]; then
    log "  libLLVM found: $LLVM_LIB"
else
    log "  WARNING: libLLVM not found"
    log "  Mesa gallium drivers (including lima) require libllvm15 at runtime"
    log "  GPU acceleration will NOT work without LLVM"
    log "  Install with: apt install libllvm15"
fi

# V6.4.1: 检查 libzstd (Mesa 运行时依赖)
ZSTD_LIB=$(find /usr/lib -name "libzstd.so*" 2>/dev/null | head -1)
if [ -n "$ZSTD_LIB" ]; then
    log "  libzstd found: $ZSTD_LIB"
else
    log "  WARNING: libzstd not found"
    log "  Mesa may require libzstd1 for compressed shader cache"
fi

# 5. 设置 LIBGL_DRIVERS_PATH (确保 Mesa 能找到 DRI 驱动)
# V6.4.1 fix: 仅在 LIMA_DRI 非空时设置 DRI_DIR, 避免 dirname "" 返回 "." 误通过检查
if [ -n "$LIMA_DRI" ]; then
    DRI_DIR=$(dirname "$LIMA_DRI")
    if [ -n "$DRI_DIR" ] && [ -d "$DRI_DIR" ]; then
        # 写入环境变量配置文件
        echo "LIBGL_DRIVERS_PATH=$DRI_DIR" > /etc/profile.d/gpu-lima.sh
        echo "export LIBGL_DRIVERS_PATH" >> /etc/profile.d/gpu-lima.sh
        chmod 644 /etc/profile.d/gpu-lima.sh
        log "  LIBGL_DRIVERS_PATH set to: $DRI_DIR"
        # 列出 DRI 目录中的驱动
        DRI_COUNT=$(ls "$DRI_DIR"/*_dri.so 2>/dev/null | wc -l)
        log "  DRI drivers available: $DRI_COUNT"
    fi
else
    log "  LIBGL_DRIVERS_PATH not set (lima_dri.so not found)"
fi

# 6. 检查设备树 GPU 节点
log "--- Device tree ---"
if [ -d /proc/device-tree/gpu ]; then
    GPU_COMPAT=$(tr '\0' '\n' < /proc/device-tree/gpu/compatible 2>/dev/null | head -2 | tr '\n' ' ')
    log "  GPU node: $GPU_COMPAT"
    # 检查 GPU 状态 (如果 DTB 中有 status 属性)
    if [ -f /proc/device-tree/gpu/status ]; then
        GPU_STATUS=$(tr '\0' '\n' < /proc/device-tree/gpu/status 2>/dev/null)
        log "  GPU status: ${GPU_STATUS:-okay}"
    else
        log "  GPU status: okay (no status property = enabled)"
    fi
else
    log "  WARNING: /proc/device-tree/gpu not found"
    log "  The DTB may not include GPU node - lima driver won't probe"
fi

# 7. 验证 OpenGL renderer (如果 mesa-utils 已安装且有显示)
if command -v glxinfo &>/dev/null; then
    log "--- OpenGL verification ---"
    RENDERER=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1)
    if [ -n "$RENDERER" ]; then
        log "  $RENDERER"
    else
        log "  glxinfo could not get renderer info (needs X11/Wayland display)"
        log "  For headless testing: apt install weston && weston --backend=drm-backend.so"
    fi
else
    log "  glxinfo not installed (apt install mesa-utils to verify)"
fi

# 8. 总结
log "--- Summary ---"
LIMA_LOADED=$(lsmod | grep -c "^lima")
DRI_PRESENT=$([ -d /dev/dri ] && echo "yes" || echo "no")
MESA_PRESENT=$([ -n "$LIMA_DRI" ] && echo "yes" || echo "no")
GLAPI_PRESENT=$([ -n "$GLAPI_LIB" ] && echo "yes" || echo "no")
LLVM_PRESENT=$([ -n "$LLVM_LIB" ] && echo "yes" || echo "no")

log "  Kernel lima module: $([ $LIMA_LOADED -gt 0 ] && echo 'LOADED' || echo 'NOT LOADED')"
log "  DRM device nodes: $DRI_PRESENT"
log "  Mesa lima_dri.so: $MESA_PRESENT"
log "  Mesa libglapi.so: $GLAPI_PRESENT"
log "  libLLVM (runtime): $LLVM_PRESENT"

if [ $LIMA_LOADED -gt 0 ] && [ "$DRI_PRESENT" = "yes" ] && [ "$MESA_PRESENT" = "yes" ] && [ "$GLAPI_PRESENT" = "yes" ] && [ "$LLVM_PRESENT" = "yes" ]; then
    log "  >>> GPU acceleration is READY <<<"
    log "  Install a desktop (apt install xfce4) to use GPU-accelerated rendering"
else
    log "  >>> GPU acceleration NOT fully configured <<<"
    log "  Missing components need to be resolved"
fi

log "=== GPU setup complete ==="
