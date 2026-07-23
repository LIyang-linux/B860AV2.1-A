# B860AV2.1-A Armbian 线刷救砖镜像

中兴 ZXV10 B860AV2.1-A-NW（福建移动）Amlogic S905L3-B 机顶盒 Armbian 线刷救砖项目。

全自动 GitHub Actions 构建，从原厂 BL + 主线 U-Boot + ophub Armbian 镜像组装完整线刷包。

## 设备信息

| 项目 | 信息 |
|------|------|
| 型号 | 中兴 ZXV10 B860AV2.1-A-NW（福建移动版） |
| SoC | Amlogic S905L3-B（GXL 家族，4x Cortex-A55） |
| 内存 | 2GB DDR4 |
| 存储 | 8GB eMMC（mafId=0xD6，二线/国产芯片） |
| 接口 | 1x TF 卡槽, 2x USB 2.0（靠近网口为 OTG 线刷口） |
| 以太网 | 100Mbps（Amlogic 内置 PHY，RMII 模式） |
| WiFi | NW 版无 WiFi（固件含 SSV6051/UWE5622/MT7601U 驱动） |
| 救砖方式 | Amlogic USB Burning Tool v2.1.6 |

## 当前版本：V6.1

| 项目 | 信息 |
|------|------|
| 最新构建 | `v6.1.20260723-s905l3b-d88b332` |
| 构建时间 | 2026-07-23 12:52 UTC |
| 内核 | Linux 6.1.y LTS（ophub 社区内核，锁定） |
| U-Boot | v2025.04（主线，p212_defconfig） |
| 默认 DTB | meson-gxl-s905l3b-b860av21.dtb（eMMC 50MHz 定制） |
| rootfs | Armbian bullseye arm64（ophub server 版） |
| Root UUID | 8cba1caa-50b0-4645-963e-3c7a6c4dbe55 |

## 项目结构

```
B860AV2.1-A/
├── .github/workflows/
│   └── build-armbian-burn.yml          # V6.1 全自动构建工作流
├── scripts/
│   └── build-armbian.sh                # 构建辅助脚本
├── rootfs-overlay/                      # 注入 rootfs 的自定义文件
│   ├── etc/
│   │   ├── NetworkManager/conf.d/       # 以太网 + WiFi 管理配置
│   │   ├── sysctl.d/99-gxl-network.conf # 网络性能优化
│   │   ├── logrotate.d/                 # 日志轮转配置
│   │   └── systemd/system/              # systemd 服务
│   │       ├── fix-gxl-eth.service      # GXL PHY LPA 修复
│   │       ├── eth-monitor.service       # 以太网链路监控
│   │       ├── mac-setup.service         # MAC 地址设置
│   │       ├── first-boot-check.service  # 首启验证
│   │       ├── wifi-setup.service        # WiFi 自动检测
│   │       └── system-optimization.service # 系统优化 (zram/CPU/tmpfs)
│   └── usr/local/bin/
│       ├── fix-gxl-eth.sh               # GXL PHY LPA Corruption 修复
│       ├── eth-monitor.sh               # 以太网链路持续监控
│       ├── mac-setup.sh                 # MAC 地址配置
│       ├── first-boot-check.sh          # 首启 UUID/网络/eMMC 验证
│       ├── wifi-setup.sh                # WiFi 硬件自动检测 (30+ 驱动)
│       ├── wifi-connect.sh              # WiFi 连接助手
│       └── optimize-system.sh           # 系统优化 (zram/CPU/tmpfs/eMMC保护)
├── armbian-v2/                          # V2 遗留线刷组件 (手动打包用)
├── bootloader-only/                     # 仅恢复 bootloader 的线刷镜像
├── dtb/                                 # 设备树文件
├── tools/                               # 工具 (aml_image_v2_packer, gxlimg)
└── README.md
```

## 版本演进

| 版本 | 核心改进 |
|------|----------|
| V2 | 基础线刷镜像 (ophub + 主线 U-Boot) |
| V3 | e900v22e DTB + GXL PHY 修复 + 以太网监控 + MAC 设置 |
| V4 | clk_ignore_unused + initrd 地址修正 + tune2fs 优化 + UUID 修复 |
| V5 | 定制 DTB (eMMC 50MHz, 移除 HS200/DDR) 适配国产 eMMC |
| V6 | WiFi 内置适配 (SSV6051 固件 + 自动检测 + 连接助手) |
| V6.1 | 内核锁定 6.1.y LTS + 系统优化 (zram/CPU/tmpfs/logrotate) + 网络改进 |

## 线刷镜像结构

| 组件 | 来源 | 写入位置 | 说明 |
|------|------|----------|------|
| DDR.USB | 原厂 fip_backup.img | - | DDR4 2GB 初始化 |
| UBOOT.USB | 原厂 fip_backup.img | - | 原厂 U-Boot（含线刷协议） |
| bootloader.PARTITION | 原厂 BL2/BL30/BL31 + 主线 U-Boot v2025.04 | bootloader (扇区1) | 混合 FIP |
| boot.PARTITION | ophub FAT32 64MB | boot 分区 | 内核 + initramfs + DTB |
| system.PARTITION | ophub ext4 rootfs | data 分区 | Armbian rootfs + 自定义脚本 |

## 关键技术特性

### 内核 (6.1.y LTS)

锁定 Linux 6.1.y LTS 内核，原因：
- S905L3-B 兼容性最佳，ophub 社区 Issue 最多、修复最完善
- 避免 6.12.y（HDMI NULL pointer 崩溃、网卡驱动缺失）
- 避免 6.18.y（GPU SError）

### DTB 定制 (V5)

针对 mafId=0xD6 二线/国产 eMMC 芯片创建专用 DTB：
- `max-frequency` 从 200MHz 降到 50MHz
- 移除 `mmc-hs200-1_8v` 和 `mmc-ddr-1_8v`（HS200 tuning 裕量差导致首启失败）
- 保留 `cap-mmc-highspeed`（52MHz SDR，几乎所有 eMMC 5.0+ 都支持）

镜像中包含 4 个 DTB 可手动切换：

| DTB | 说明 |
|-----|------|
| meson-gxl-s905l3b-b860av21.dtb | V5 定制 (eMMC 50MHz，默认) |
| meson-gxl-s905l3b-e900v22e.dtb | ophub 通用 (eMMC 200MHz+HS200) |
| meson-gxl-s905l3b-m302a.dtb | M302A 主板备选 |
| meson-gxl-s905x-p212.dtb | P212 参考板基础 |

### 网络可靠性

- **GXL PHY LPA Corruption 修复**: Amlogic GXL 内置 PHY 自动协商约 1/12 概率 LPA 寄存器损坏，`fix-gxl-eth.sh` 在启动时检测并重试，最终回退到 100Mbps full-duplex
- **以太网链路监控**: `eth-monitor.service` 持续监控链路状态，断线自动恢复
- **MAC 地址设置**: `mac-setup.sh` 从 eMMC/CPU 序列号生成稳定 MAC
- **网络性能优化**: sysctl 调优 TCP 缓冲区和连接跟踪

### WiFi 适配 (V6)

内置 3 种 WiFi 芯片固件支持：

| 芯片 | 接口 | 固件来源 | 状态 |
|------|------|----------|------|
| SSV6051 / SV6256P | SDIO | 内置 /lib/firmware/ | 固件已嵌入 |
| UWE5622 | SDIO | ophub 默认包含 | 无需额外操作 |
| MT7601U | USB | ophub 默认包含 | 主线驱动 mt7601u |

- `wifi-setup.sh`: 开机自动加载 30+ 种 WiFi 驱动（主线 + 树外），检测接口，配置 NetworkManager
- `wifi-connect.sh`: 一键扫描/连接/断开 WiFi
- NW（无 WiFi）版本自动跳过，不产生错误
- NetworkManager 禁用 MAC 随机化 + 禁用省电模式（提升稳定性）

### 系统优化 (V6.1)

- **zram swap**: 内存 50% 大小 (1GB)，lz4 压缩，减少 eMMC 写入
- **CPU 调频**: ondemand/schedutil，up_threshold=50%，平衡性能与功耗
- **tmpfs /tmp**: 256MB，减少 eMMC 磨损
- **eMMC 写入保护**: dirty_ratio=15，dirty_writeback=60s，vfs_cache_pressure=50
- **journald**: volatile 存储，限制 50MB，重启后清空
- **logrotate**: 自定义脚本日志每周轮转，最大 1MB

### 启动可靠性

- **UUID 修复**: ophub uEnv.txt 中的 UUID 与实际 ext4 UUID 不匹配 → 构建时自动修正
- **首启验证**: `first-boot-check.sh` 检查 UUID 一致性、网络接口、eMMC 健康、关键服务状态
- **tune2fs 优化**: 禁用 metadata_csum + journal_data_writeback + 禁用定期 fsck
- **clk_ignore_unused**: 防止 GXL 耦合时钟关闭导致 reset
- **initrd 地址修正**: 0x15000000，防止 initramfs 与内核镜像重叠
- **分区动态检测**: first-boot-check.sh 不再硬编码 /dev/mmcblk0p1/p2，通过 cmdline + findmnt + blkid 动态检测

## 下载

从 [Releases](https://github.com/LIyang-linux/B860AV2.1-A/releases) 下载最新构建。

### 文件说明

| 文件 | 大小 | 说明 |
|------|------|------|
| b860av21-armbian-burn-v6.1.YYYYMMDD-s905l3b.img.gz | ~750MB | 完整线刷镜像 (USB Burning Tool) |
| boot.fat32.gz | ~33MB | boot 分区 (手动 dd 用) |
| rootfs.ext4.gz | ~715MB | rootfs 分区 (手动 dd 用) |
| bootloader.PARTITION | ~929KB | FIP bootloader (原厂BL + 主线U-Boot) |
| checksums.md5 | 237B | MD5 校验文件 |

### 最新构建校验 (v6.1.20260723-s905l3b-d88b332)

```
dd1ddc0c8b176f1b9935725965324342  b860av21-armbian-burn-v6.1.20260723-s905l3b.img.gz
640ff44e475326445ea9ee576b35c997  boot.fat32.gz
ce6e11adaf4e7b97853ead953db90582  rootfs.ext4.gz
9681ec5b6900e861120767b88719c515  bootloader.PARTITION
```

## 使用方法

### 方法 1: USB Burning Tool 线刷（推荐）

1. 下载 `b860av21-armbian-burn-v6.1.YYYYMMDD-s905l3b.img.gz` 并 gunzip 解压
2. 打开 Amlogic USB Burning Tool v2.1.6
3. 文件 → 导入烧录包 → 选择解压后的 .img 文件
4. **必须勾选**:
   - Erase Flash（全盘擦除，清除旧固件残留）
   - Verify Flash（写入后 CRC 校验，防止假成功）
5. **不要勾选**:
   - Preserve User Data（保留旧数据会导致分区冲突）
6. 用 USB 线连接盒子 OTG 口（靠近网口）
7. 断电状态下按住复位针（或短接复位点），插入 USB
8. 点击 Start，等待显示 100% 绿色成功
9. 拔线，重新通电启动

### 方法 2: 手动 dd（需 TTL 或已启动 Linux）

```bash
# 写入 bootloader
dd if=bootloader.PARTITION of=/dev/mmcblk0 bs=512 seek=1 conv=fsync
# 写入 boot 分区
dd if=boot.fat32 of=/dev/mmcblk0p2 conv=fsync
# 写入 rootfs
dd if=rootfs.ext4 of=/dev/mmcblk0p14 conv=fsync
sync
```

## 首次启动

- 串口: ttyAML0, 115200, 8N1
- 登录: root / 1234（ophub 默认）
- 首次启动会自动扩展 rootfs 分区

### WiFi 使用

```bash
# 扫描 WiFi 网络
wifi-connect.sh scan

# 连接 WiFi (WPA/WPA2)
wifi-connect.sh "你的WiFi名" "你的密码"

# 连接开放网络 (无密码)
wifi-connect.sh "你的WiFi名"

# 查看连接状态
wifi-connect.sh status

# 断开连接
wifi-connect.sh disconnect

# 或者使用交互式工具
nmtui
```

### 启动后验证

```bash
# 检查 eMMC 实际速度模式
cat /sys/kernel/debug/mmc*/ios 2>/dev/null | grep -E "timing|clock"
mmc extcsd read /dev/mmcblk0 2>/dev/null | grep HS_TIMING

# 检查系统优化状态
swapon --show
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
mount | grep /tmp

# 检查网络
ip addr show eth0
ethtool eth0

# 查看首启日志
cat /var/log/first-boot-check.log
cat /var/log/optimize-system.log
```

### eMMC 速度提升

如果稳定运行后想提升 eMMC 速度，可手动升回 DDR52 (52MHz DDR, 104MB/s)：
修改 DTB 添加 `mmc-ddr-1_8v`，`max-frequency` 改为 `52000000`。

## CI/CD 构建

GitHub Actions 全自动构建，触发条件：
- push 到 main 分支（修改 workflow / rootfs-overlay / image.cfg）
- 手动触发 (Actions → Run workflow)

构建流程：
1. 编译主线 U-Boot v2025.04 (p212_defconfig)
2. 从原厂 fip_backup.img 提取 BL2/BL30/BL31
3. 用 gxlimg 重新打包 FIP (原厂 BL + 主线 U-Boot)
4. 下载 ophub S905L3-B Armbian 镜像 (内核 6.1.y 过滤)
5. 提取 boot 分区，创建 64MB FAT32 boot.PARTITION
6. 创建 B860AV2.1-A 专用 DTB (eMMC 时序修复)
7. 提取并缩小 rootfs，注入自定义脚本和 WiFi 固件
8. tune2fs 优化 + UUID 修正
9. 打包完整 Amlogic 线刷镜像
10. 上传 Artifact 和 Release

### 构建参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| uboot_version | v2025.04 | U-Boot 版本标签 |
| ophub_soc | s905l3b | ophub SoC 类型 |
| ophub_image_url | (空) | 镜像直链 (空则自动查找) |
| kernel_version | 6.1 | 锁定内核版本 |
| create_release | true | 完成后创建 Release |

## 致谢

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) - Armbian 镜像及 DTB
- [ophub/kernel](https://github.com/ophub/kernel) - 社区内核
- [7Ji](https://7ji.github.io/) - Amlogic FIP/EPT 技术文档
- [repk/gxlimg](https://github.com/repk/gxlimg) - GXL FIP 处理工具
- [u-boot/u-boot](https://github.com/u-boot/u-boot) - 主线 U-Boot
