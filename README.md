# B860AV2.1-A Armbian 线刷救砖镜像

中兴 ZXV10 B860AV2.1-A-NW（福建移动）Amlogic S905L3-B 机顶盒 Armbian 线刷救砖项目。

## 设备信息

| 项目 | 信息 |
|------|------|
| 型号 | 中兴 ZXV10 B860AV2.1-A-NW（福建移动版） |
| SoC | Amlogic S905L3-B（GXL 家族，非 S905X） |
| 内存 | 2GB DDR4 |
| 存储 | 8GB eMMC |
| 接口 | 1x TF 卡槽, 2x USB 2.0（靠近网口为 OTG 线刷口） |
| 以太网 | 100Mbps（Amlogic 内置 PHY，RMII 模式） |
| 救砖方式 | Amlogic USB Burning Tool v2.1.6 |

## 项目结构

```
B860AV2.1-A/
├── bootloader-only/          # 仅恢复 bootloader 的线刷镜像（救砖用）
│   ├── b860av21-uboot-recovery-burn.img   # 线刷镜像（1.9MB）
│   ├── b860av21-uboot-recovery.bin        # FIP（原厂 BL2/BL30/BL31 + 主线 U-Boot）
│   ├── u-boot.bin                         # 主线 U-Boot v2025.04 BL33
│   ├── build-uboot.sh                     # 编译脚本
│   └── .github/workflows/                 # GitHub Actions CI
├── armbian-v2/               # 完整 Armbian 线刷镜像（V2 优化版）
│   ├── boot.fat32             # boot 分区（内核 + initramfs + DTB + 引导脚本）
│   ├── bootloader.PARTITION   # FIP bootloader
│   ├── image.cfg              # 线刷镜像打包配置
│   ├── aml_sdc_burn.ini       # 线刷烧录配置
│   ├── platform.conf          # GXL 平台配置
│   ├── extlinux/extlinux.conf # extlinux 引导配置
│   ├── uEnv.txt               # U-Boot 环境配置
│   ├── boot.ini               # boot.ini 引导脚本
│   ├── boot.cmd               # boot.cmd 引导脚本
│   ├── emmc_autoscript        # eMMC 自动引导脚本
│   ├── s905_autoscript        # S905 自动引导脚本
│   └── aml_autoscript         # Amlogic 自动引导脚本
├── dtb/                      # 设备树文件
│   ├── meson-gxl-s905l3b-m302a.dtb      # S905L3-B M302A（默认）
│   ├── meson-gxl-s905l3b-e900v22e.dtb   # S905L3-B E900V22E
│   ├── meson-gxl-s905l2-x7-5g.dtb       # S905L2 X7-5G（B860AV2.1-A 实测可用）
│   ├── meson-gxl-s905l2-ipbs9505.dtb    # S905L2 IPBS9505（B860AV2.1-A 实测可用）
│   └── meson-gxl-s905x-p212.dtb         # S905X P212（公版参考）
├── tools/                    # 工具
│   ├── aml_image_v2_packer   # Amlogic 线刷镜像打包工具（32-bit）
│   └── gxlimg                # GXL FIP 处理工具
└── README.md
```

## V2 镜像说明

### 线刷镜像结构

| 组件 | 来源 | 写入分区 | 说明 |
|------|------|----------|------|
| DDR.USB | 原厂 fip_backup.img BL2 | - | DDR4 2GB 初始化 |
| UBOOT.USB | 原厂 fip_backup.img TPL | - | 原厂 U-Boot（含线刷协议） |
| bootloader.PARTITION | 主线 U-Boot v2025.04 FIP | bootloader (扇区1) | 目标 bootloader |
| boot.PARTITION | ophub FAT32 (64MB) | boot (p2) | 内核 + initramfs + DTB |
| system.PARTITION | ophub ext4 rootfs (2.9GB) | data (p14) | Armbian rootfs |

### 关键特性

- **内核**: Linux 6.12.95-ophub（ophub 社区内核，含 Amlogic 专用补丁）
- **DTB**: meson-gxl-s905l3b-m302a.dtb（S905L3-B 专用，RMII 100Mbps 以太网）
- **root 挂载**: `root=UUID=xxx rootwait`（UUID 自动匹配，不依赖分区号）
- **initramfs**: ophub uInitrd（含 blkid UUID 扫描）
- **rootfs**: Armbian Trixie arm64（ophub 完整系统）
- **引导脚本**: extlinux + boot.ini + emmc_autoscript + s905_autoscript + aml_autoscript

### 以太网

B860AV2.1-A 使用 Amlogic 内置以太网 PHY:
- MAC: stmmac/dwmac (meson-gxbb-dwmac)
- PHY: 内置 PHY (ethernet-phy-id0181.4400)
- 模式: RMII
- 速率: 100Mbps (max-speed = 100)
- PHY 地址: 0x08

所有 ophub S905L3-B/S905L2 DTB 的以太网配置完全相同，不随 DTB 选择变化。

## 使用方法

### 方法 1: USB Burning Tool 线刷（推荐）

1. 下载 `b860av21-armbian-v2-burn.img`（3GB，见 Releases）
2. 打开 Amlogic USB Burning Tool v2.1.6
3. 文件 → 导入烧录包 → 选择 img 文件
4. 用 USB 线连接盒子 OTG 口（靠近网口）
5. 断电状态下按住复位针（或短接复位点），插入 USB
6. 点击"开始"烧录
7. 烧录完成后拔线，重新通电启动

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

## 构建

参见 `bootloader-only/build-uboot.sh` 和 `bootloader-only/.github/workflows/`。

### 重新打包线刷镜像

```bash
# 需要 qemu-i386 运行 32-bit aml_image_v2_packer
qemu-i386 tools/aml_image_v2_packer -r armbian-v2/image.cfg armbian-v2/ output.img
```

## 致谢

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) - Armbian 镜像及 DTB
- [ophub/kernel](https://github.com/ophub/kernel) - 社区内核
- [7Ji](https://7ji.github.io/) - Amlogic FIP/EPT 技术文档
