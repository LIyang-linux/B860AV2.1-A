#!/bin/bash
#
# B860AV2.1 (S905L3-B / GXL) 主线 U-Boot 救砖镜像编译脚本
#
# 此脚本完成以下工作：
#   1. 从原厂 fip_backup.img 提取 BL2/BL30/BL31
#   2. 编译主线 U-Boot v2025.04 (p212_defconfig, GXL)
#   3. 用 gxlimg 将原厂 BL2/BL30/BL31 + 主线 U-Boot 打包成 FIP
#   4. 用 aml_image_v2_packer 打包成 Amlogic USB Burning Tool 线刷镜像
#
set -e

UBOOT_VERSION="v2025.04"
FIP_BACKUP="${1:-fip_backup.img}"
OUTPUT_DIR="${2:-output}"

echo "============================================"
echo " B860AV2.1 U-Boot Recovery Image Builder"
echo "============================================"

# ---------- 安装依赖 ----------
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y -qq \
    gcc-aarch64-linux-gnu make bc bison flex libssl-dev python3 \
    python3-dev python3-setuptools swig g++ device-tree-compiler git wget cpio \
    libgnutls28-dev qemu-user

# ---------- 下载工具 ----------
echo "[2/7] Downloading tools..."

# gxlimg - GXL FIP 解包/打包工具
if [ ! -d gxlimg ]; then
    git clone --depth=1 https://github.com/repk/gxlimg.git
fi
cd gxlimg && make && cd ..
GXLIMG="$(pwd)/gxlimg/gxlimg"

# amlogic-boot-fip - 备用 FIP blobs (p212, GXL)
if [ ! -d amlogic-boot-fip ]; then
    git clone --depth=1 https://github.com/LibreELEC/amlogic-boot-fip.git
fi

# aml_image_v2_packer - Amlogic 线刷镜像打包工具
if [ ! -f aml_image_v2_packer ]; then
    wget -q -O aml_image_v2_packer \
        "https://github.com/jethome-ru/jethome-tools/raw/convert/tools/aml_image_v2_packer_new"
    chmod +x aml_image_v2_packer
fi

# ---------- 下载并编译 U-Boot ----------
echo "[3/7] Downloading and building U-Boot ${UBOOT_VERSION}..."
if [ ! -d u-boot ]; then
    wget -q -O u-boot.tar.gz "https://github.com/u-boot/u-boot/archive/refs/tags/${UBOOT_VERSION}.tar.gz"
    tar xzf u-boot.tar.gz
    mv "u-boot-$(echo ${UBOOT_VERSION} | sed 's/v//')" u-boot
fi

cd u-boot
export ARCH=arm
export CROSS_COMPILE=aarch64-linux-gnu-
make p212_defconfig
make -j$(nproc)
cd ..

UBOOT_BIN="$(pwd)/u-boot/u-boot.bin"
echo "U-Boot binary: $(ls -lh ${UBOOT_BIN})"

# ---------- 从原厂 fip_backup 提取 BL 组件 ----------
echo "[4/7] Extracting BL components from original fip_backup..."
if [ ! -f "${FIP_BACKUP}" ]; then
    echo "ERROR: fip_backup.img not found!"
    echo "Usage: $0 <fip_backup.img> [output_dir]"
    exit 1
fi

mkdir -p fip-extracted
# fip_backup.img 第1扇区是分区表，跳过
dd if="${FIP_BACKUP}" of=/tmp/boot_region.bin bs=512 skip=1 2>/dev/null
"${GXLIMG}" -t fip -e /tmp/boot_region.bin fip-extracted

echo "Extracted files:"
ls -la fip-extracted/

# ---------- 重新打包 FIP ----------
echo "[5/7] Repacking FIP with mainline U-Boot as BL33..."
# 加密主线 U-Boot 为 BL33
"${GXLIMG}" -t bl3x -c "${UBOOT_BIN}" fip-extracted/u-boot.bin.enc

# 用原厂 BL2/BL30/BL31 + 主线 U-Boot 重新打包
RECOVERY_BIN="$(pwd)/b860av21-uboot-recovery.bin"
"${GXLIMG}" -t fip \
    --bl2 fip-extracted/bl2.sign \
    --bl30 fip-extracted/bl30.enc \
    --bl301 fip-extracted/bl301.enc \
    --bl31 fip-extracted/bl31.enc \
    --bl33 fip-extracted/u-boot.bin.enc \
    "${RECOVERY_BIN}"

echo "Recovery FIP: $(ls -lh ${RECOVERY_BIN})"

# ---------- 生成 USB 烧录组件 ----------
echo "[6/7] Generating USB burn components..."
# GXL FIP 格式: BL2 在 offset 0, TPL 在 offset 49152 (0xC000)
dd if="${RECOVERY_BIN}" of=DDR.USB bs=1 count=49152 2>/dev/null
dd if="${RECOVERY_BIN}" of=UBOOT.USB bs=1 skip=49152 2>/dev/null

# ---------- 打包线刷镜像 ----------
echo "[7/7] Packing Amlogic USB Burning Tool image..."
mkdir -p burn-image
cp DDR.USB burn-image/
cp UBOOT.USB burn-image/
cp "${RECOVERY_BIN}" burn-image/bootloader.PARTITION

cat > burn-image/aml_sdc_burn.ini << 'INIEOF'
;
;Amlogic sdcard burning configure script
;
[common]
erase_bootloader    = 1
erase_flash         = 1
reboot              = 0

[burn_ex]
package     = aml_upgrade_package.img
;media       =
INIEOF

cat > burn-image/platform.conf << 'CONFEOF'
Platform: gxl
DDRLoad: 0xd9000000
DDRRun: 0xd9000030
Uboot_down: 0x10000000
Uboot_decomp: 0x10000000
Uboot_enc_down: 0xd9000000
Uboot_enc_run: 0xd9000030
UbootLoad: 0x10000000
UbootRun: 0x10000000
CONFEOF

cat > burn-image/image.cfg << 'CFGEOF'
[LIST_NORMAL]
file="DDR.USB"			main_type="USB"		sub_type="DDR"
file="UBOOT.USB"		main_type="USB"		sub_type="UBOOT"
file="aml_sdc_burn.ini"		main_type="ini"		sub_type="aml_sdc_burn"
file="platform.conf"		main_type="conf"	sub_type="platform"

[LIST_VERIFY]
file="bootloader.PARTITION"	main_type="PARTITION"	sub_type="bootloader"
CFGEOF

BURN_IMG="$(pwd)/b860av21-uboot-recovery-burn.img"
qemu-i386 aml_image_v2_packer -r burn-image/image.cfg burn-image "${BURN_IMG}"

# ---------- 输出 ----------
echo ""
echo "============================================"
echo " BUILD COMPLETE"
echo "============================================"
mkdir -p "${OUTPUT_DIR}"
cp "${BURN_IMG}" "${OUTPUT_DIR}/"
cp "${RECOVERY_BIN}" "${OUTPUT_DIR}/"
cp "${UBOOT_BIN}" "${OUTPUT_DIR}/u-boot.bin"
cp DDR.USB "${OUTPUT_DIR}/"
cp UBOOT.USB "${OUTPUT_DIR}/"

echo "Output files in ${OUTPUT_DIR}/:"
ls -lh "${OUTPUT_DIR}/"

echo ""
echo "线刷镜像: ${OUTPUT_DIR}/b860av21-uboot-recovery-burn.img"
echo "FIP 镜像: ${OUTPUT_DIR}/b860av21-uboot-recovery.bin"
echo "U-Boot:   ${OUTPUT_DIR}/u-boot.bin"
