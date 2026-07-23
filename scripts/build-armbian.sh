#!/bin/bash
#
# B860AV2.1-A Armbian 线刷镜像 - 本地构建脚本
#
# 用法:
#   ./scripts/build-armbian.sh <fip_backup.img> [ophub_image_url] [uboot_version]
#
# 示例:
#   ./scripts/build-armbian.sh fip_backup.img
#   ./scripts/build-armbian.sh fip_backup.img "https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/.../Armbian_xxx_s905l3b_xxx.img.gz"
#   ./scripts/build-armbian.sh fip_backup.img "" v2025.04
#
set -e

FIP_BACKUP="${1:?用法: $0 <fip_backup.img> [ophub_image_url] [uboot_version]}"
OPHUB_URL="${2:-}"
UBOOT_VERSION="${3:-v2025.04}"
OPHUB_SOC="${OPHUB_SOC:-s905l3b}"
WORK_DIR="$(mktemp -d)"
OUTPUT_DIR="${OUTPUT_DIR:-output}"

echo "============================================"
echo " B860AV2.1-A Armbian Burn Image Builder"
echo "============================================"
echo "FIP backup:    $FIP_BACKUP"
echo "U-Boot:        $UBOOT_VERSION"
echo "ophub SoC:     $OPHUB_SOC"
echo "Work dir:      $WORK_DIR"
echo "============================================"
echo ""

cd "$WORK_DIR"

# ---------- 安装依赖 ----------
echo "[1/9] Installing dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    gcc-aarch64-linux-gnu make bc bison flex libssl-dev python3 \
    python3-dev python3-setuptools swig g++ device-tree-compiler git wget cpio \
    libgnutls28-dev qemu-user qemu-user-static \
    mtools dosfstools e2fsprogs parted gzip

# ---------- 工具 ----------
echo "[2/9] Building tools..."

# gxlimg
git clone --depth=1 https://github.com/repk/gxlimg.git
cd gxlimg && make && cd ..
GXLIMG="$WORK_DIR/gxlimg/gxlimg"

# aml_image_v2_packer
wget -q -O aml_image_v2_packer \
    "https://github.com/jethome-ru/jethome-tools/raw/convert/tools/aml_image_v2_packer_new"
chmod +x aml_image_v2_packer

# ---------- 编译 U-Boot ----------
echo "[3/9] Building U-Boot ${UBOOT_VERSION}..."
wget -q -O u-boot.tar.gz "https://github.com/u-boot/u-boot/archive/refs/tags/${UBOOT_VERSION}.tar.gz"
tar xzf u-boot.tar.gz
mv "u-boot-$(echo ${UBOOT_VERSION} | sed 's/v//')" u-boot

cd u-boot
export ARCH=arm
export CROSS_COMPILE=aarch64-linux-gnu-
make p212_defconfig
make -j$(nproc)
cd ..
cp u-boot/u-boot.bin .
echo "U-Boot: $(ls -lh u-boot.bin)"

# ---------- 提取 BL 组件并重打包 FIP ----------
echo "[4/9] Extracting BL components and repacking FIP..."
mkdir -p fip-extracted

cp "$FIP_BACKUP" fip_backup.img
dd if=fip_backup.img of=/tmp/boot_region.bin bs=512 skip=1 2>/dev/null
"$GXLIMG" -t fip -e /tmp/boot_region.bin fip-extracted

# 加密主线 U-Boot 为 BL33
"$GXLIMG" -t bl3x -c u-boot.bin fip-extracted/u-boot.bin.enc

# 重新打包 FIP
"$GXLIMG" -t fip \
    --bl2 fip-extracted/bl2.sign \
    --bl30 fip-extracted/bl30.enc \
    --bl301 fip-extracted/bl301.enc \
    --bl31 fip-extracted/bl31.enc \
    --bl33 fip-extracted/u-boot.bin.enc \
    bootloader.PARTITION
echo "FIP: $(ls -lh bootloader.PARTITION)"

# 原厂 DDR.USB + UBOOT.USB (含线刷协议)
dd if=/tmp/boot_region.bin of=DDR.USB bs=1 count=49152 2>/dev/null
dd if=/tmp/boot_region.bin of=UBOOT.USB bs=1 skip=49152 2>/dev/null
echo "Burn components: $(ls -lh DDR.USB UBOOT.USB)"

# ---------- 下载 ophub 镜像 ----------
echo "[5/9] Downloading ophub ${OPHUB_SOC} image..."
if [ -n "$OPHUB_URL" ]; then
    wget -q --timeout=300 -O ophub.img.gz "$OPHUB_URL"
else
    # 自动查找最新
    URL=$(curl -s "https://api.github.com/repos/ophub/amlogic-s9xxx-armbian/releases?per_page=20" \
        | python3 -c "
import json, sys
soc = '${OPHUB_SOC}'
for rel in json.load(sys.stdin):
    for asset in rel.get('assets', []):
        name = asset.get('name', '')
        if soc in name and name.endswith('.img.gz') and 'server' in name:
            print(asset['browser_download_url'])
            sys.exit(0)
")
    if [ -z "$URL" ]; then
        echo "ERROR: No ophub ${OPHUB_SOC} image found"
        exit 1
    fi
    echo "Found: $URL"
    wget -q --timeout=300 -O ophub.img.gz "$URL" || \
    wget -q --timeout=300 -O ophub.img.gz "https://mirror.ghproxy.com/$URL"
fi
gunzip ophub.img.gz
echo "ophub image: $(ls -lh ophub.img)"

# ---------- 提取 boot 分区 ----------
echo "[6/9] Creating boot.PARTITION (FAT32, 64MB)..."
BOOT_START=$(sfdisk -d ophub.img 2>/dev/null | grep "ophub.img1" | grep -oP 'start=\s*\K\d+')
BOOT_COUNT=$(sfdisk -d ophub.img 2>/dev/null | grep "ophub.img1" | grep -oP 'size=\s*\K\d+')
dd if=ophub.img of=ophub-boot.fat32 bs=512 skip=$BOOT_START count=$BOOT_COUNT 2>/dev/null

mkdir -p ophub-boot-files
mcopy -s -i ophub-boot.fat32 :: ophub-boot-files/

# 创建 64MB FAT32
truncate -s 64M boot.PARTITION
mkfs.vfat -F 32 -n BOOT boot.PARTITION

DIR=ophub-boot-files
mcopy -i boot.PARTITION ${DIR}/zImage ::zImage
mcopy -i boot.PARTITION ${DIR}/uInitrd ::uInitrd
mcopy -i boot.PARTITION ${DIR}/uEnv.txt ::uEnv.txt
mcopy -i boot.PARTITION ${DIR}/boot.ini ::boot.ini
for f in boot.scr boot.cmd emmc_autoscript emmc_autoscript.cmd \
         s905_autoscript s905_autoscript.cmd \
         aml_autoscript aml_autoscript.cmd; do
    [ -f "${DIR}/${f}" ] && mcopy -i boot.PARTITION ${DIR}/${f} ::${f}
done

mmd -i boot.PARTITION ::dtb
mmd -i boot.PARTITION ::dtb/amlogic
for dtb in ${DIR}/dtb/amlogic/meson-gxl-s905l3b-*.dtb \
           ${DIR}/dtb/amlogic/meson-gxl-s905l2-*.dtb \
           ${DIR}/dtb/amlogic/meson-gxl-s905x-p212.dtb; do
    [ -f "$dtb" ] && mcopy -i boot.PARTITION "$dtb" ::dtb/amlogic/$(basename $dtb)
done

# extlinux
mmd -i boot.PARTITION ::extlinux
ROOT_UUID=$(grep -oP 'root=UUID=\K[a-f0-9-]+' ${DIR}/uEnv.txt || echo "9e65a41f-0451-48db-90da-5f7f330f7fe8")
cat > /tmp/extlinux.conf << EOF
label Armbian
    kernel /zImage
    initrd /uInitrd
    fdt /dtb/amlogic/meson-gxl-s905l3b-m302a.dtb
    append root=UUID=${ROOT_UUID} rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 loglevel=1
EOF
mcopy -i boot.PARTITION /tmp/extlinux.conf ::extlinux/extlinux.conf
echo "boot.PARTITION: $(ls -lh boot.PARTITION)"

# ---------- 提取并缩小 rootfs ----------
echo "[7/9] Extracting and shrinking rootfs..."
ROOTFS_START=$(sfdisk -d ophub.img 2>/dev/null | grep "ophub.img2" | grep -oP 'start=\s*\K\d+')
ROOTFS_COUNT=$(sfdisk -d ophub.img 2>/dev/null | grep "ophub.img2" | grep -oP 'size=\s*\K\d+')
dd if=ophub.img of=system.PARTITION bs=512 skip=$ROOTFS_START count=$ROOTFS_COUNT 2>/dev/null

e2fsck -fy system.PARTITION 2>&1 | tail -3
resize2fs -M system.PARTITION 2>&1

BLOCKS=$(dumpe2fs -h system.PARTITION 2>/dev/null | grep 'Block count' | awk '{print $3}')
BLKSIZE=$(dumpe2fs -h system.PARTITION 2>/dev/null | grep 'Block size' | awk '{print $3}')
truncate -s $((BLOCKS * BLKSIZE)) system.PARTITION
echo "system.PARTITION: $(ls -lh system.PARTITION)"

# ---------- 打包线刷镜像 ----------
echo "[8/9] Packing Amlogic burn image..."
mkdir -p burn-image
cp DDR.USB burn-image/
cp UBOOT.USB burn-image/
cp bootloader.PARTITION burn-image/
cp boot.PARTITION burn-image/
cp system.PARTITION burn-image/

cat > burn-image/aml_sdc_burn.ini << 'EOF'
;
;Amlogic sdcard burning configure script
;
[common]
erase_bootloader    = 1
erase_flash         = 1
reboot              = 0

[burn_ex]
package     = aml_upgrade_package.img
EOF

cat > burn-image/platform.conf << 'EOF'
Platform: gxl
DDRLoad: 0xd9000000
DDRRun: 0xd9000030
Uboot_down: 0x10000000
Uboot_decomp: 0x10000000
Uboot_enc_down: 0xd9000000
Uboot_enc_run: 0xd9000030
UbootLoad: 0x10000000
UbootRun: 0x10000000
EOF

cat > burn-image/image.cfg << 'EOF'
[LIST_NORMAL]
file="DDR.USB"			main_type="USB"		sub_type="DDR"
file="UBOOT.USB"		main_type="USB"		sub_type="UBOOT"
file="aml_sdc_burn.ini"		main_type="ini"		sub_type="aml_sdc_burn"
file="platform.conf"		main_type="conf"	sub_type="platform"

[LIST_VERIFY]
file="bootloader.PARTITION"	main_type="PARTITION"	sub_type="bootloader"
file="boot.PARTITION"		main_type="PARTITION"	sub_type="boot"
file="system.PARTITION"		main_type="PARTITION"	sub_type="data"
EOF

qemu-i386 aml_image_v2_packer -r burn-image/image.cfg burn-image b860av21-armbian-burn.img
echo "Burn image: $(ls -lh b860av21-armbian-burn.img)"

# ---------- 压缩输出 ----------
echo "[9/9] Compressing output..."
mkdir -p "$OUTPUT_DIR"
cp b860av21-armbian-burn.img "$OUTPUT_DIR/"
gzip -c b860av21-armbian-burn.img > "$OUTPUT_DIR/b860av21-armbian-burn.img.gz"
gzip -c boot.PARTITION > "$OUTPUT_DIR/boot.fat32.gz"
gzip -c system.PARTITION > "$OUTPUT_DIR/rootfs.ext4.gz"
cp bootloader.PARTITION "$OUTPUT_DIR/"

cd "$OUTPUT_DIR"
md5sum * > checksums.md5

echo ""
echo "============================================"
echo " BUILD COMPLETE"
echo "============================================"
echo "Output in $OUTPUT_DIR/:"
ls -lh
echo ""
echo "线刷镜像: $OUTPUT_DIR/b860av21-armbian-burn.img"
echo "压缩镜像: $OUTPUT_DIR/b860av21-armbian-burn.img.gz"
