#!/usr/bin/env bash
# boot-chain.sh — build and boot the Arm64 industry boot chain on QEMU:
#   TF-A (BL1 -> BL2 -> BL31)  ->  U-Boot (BL33)  ->  Linux  ->  BusyBox shell
#
# Tested on Ubuntu 24.04 (x86_64 cross build). On an Apple-Silicon Ubuntu VM
# (aarch64) the same script builds natively — no cross compiler needed.
#
# Usage:
#   ./boot-chain.sh deps      # install packages (once, needs sudo)
#   ./boot-chain.sh fetch     # clone pinned source versions (~2.5 GB)
#   ./boot-chain.sh build     # build all four pieces (~5-15 min)
#   ./boot-chain.sh stage1    # QEMU -> Linux directly           (no firmware)
#   ./boot-chain.sh stage2    # QEMU -> U-Boot -> Linux          (no TF-A)
#   ./boot-chain.sh stage3    # QEMU -> TF-A -> U-Boot -> Linux  (full chain, starts at EL3)
#   ./boot-chain.sh debug     # stage3 frozen at reset, GDB stub on :1234
#   ./boot-chain.sh all       # deps + fetch + build + stage3
#
# Leave QEMU's console with:  Ctrl-a  then  x

set -euo pipefail

WORK="${WORK:-$HOME/chain}"
JOBS="$(nproc)"

# Native build on an arm64 host, cross build everywhere else.
if [ "$(uname -m)" = "aarch64" ]; then CROSS=""; else CROSS="aarch64-linux-gnu-"; fi

# Pinned versions — these exact versions were tested together.
TFA_TAG=v2.12.0
UBOOT_TAG=v2025.01
LINUX_TAG=v6.12
BUSYBOX_TAG=1_36_1

TFA_OUT="$WORK/tf-a/build/qemu/debug"
KERNEL="$WORK/linux/arch/arm64/boot/Image"

# Same virtual board for every stage; only the first thing that runs changes.
QEMU_COMMON=(-cpu cortex-a53 -smp 2 -m 1024M -nographic)
DISK_ARGS=(-drive if=none,file="$WORK/disk.img",format=raw,id=hd0
           -device virtio-blk-device,drive=hd0)

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

deps() {
  log "Installing build dependencies"
  local cross_pkgs=""
  [ -n "$CROSS" ] && cross_pkgs="gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu"
  sudo apt-get update
  sudo apt-get install -y build-essential git bison flex bc cpio \
    libssl-dev libncurses-dev libgnutls28-dev python3-dev python3-setuptools swig \
    device-tree-compiler u-boot-tools dosfstools mtools fdisk \
    qemu-system-arm gdb-multiarch $cross_pkgs
}

fetch() {
  log "Cloning sources into $WORK"
  mkdir -p "$WORK" && cd "$WORK"
  [ -d tf-a ]    || git clone --depth 1 -b "$TFA_TAG"     https://github.com/ARM-software/arm-trusted-firmware tf-a
  [ -d u-boot ]  || git clone --depth 1 -b "$UBOOT_TAG"   https://github.com/u-boot/u-boot u-boot
  [ -d linux ]   || git clone --depth 1 -b "$LINUX_TAG"   https://github.com/torvalds/linux linux
  [ -d busybox ] || git clone --depth 1 -b "$BUSYBOX_TAG" https://github.com/mirror/busybox busybox
}

build_linux() {
  log "Linux: minimal arm64 kernel for the QEMU 'virt' board"
  # Start from nothing (allnoconfig) and switch on only what this board needs,
  # so every option is one you can explain. Builds in minutes, not an hour.
  cat > "$WORK/kernel.fragment" <<'EOF'
CONFIG_PRINTK=y
CONFIG_BUG=y
CONFIG_SMP=y
CONFIG_NR_CPUS=4
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_TTY=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_SERIAL_EARLYCON=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_FUTEX=y
CONFIG_POSIX_TIMERS=y
CONFIG_MULTIUSER=y
CONFIG_ARM_PSCI_FW=y
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_PL031=y
CONFIG_KALLSYMS=y
EOF
  cd "$WORK/linux"
  make ARCH=arm64 CROSS_COMPILE="$CROSS" allnoconfig >/dev/null
  scripts/kconfig/merge_config.sh -m .config "$WORK/kernel.fragment" >/dev/null
  make ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig >/dev/null
  make ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image
}

build_rootfs() {
  log "BusyBox: static userspace packed as an initramfs"
  cd "$WORK/busybox"
  make defconfig >/dev/null
  sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
  # 'tc' does not build against newer kernel headers; it isn't needed here.
  sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
  make CROSS_COMPILE="$CROSS" -j"$JOBS"
  rm -rf "$WORK/rootfs"
  make CROSS_COMPILE="$CROSS" CONFIG_PREFIX="$WORK/rootfs" install >/dev/null

  cd "$WORK/rootfs"
  mkdir -p proc sys dev tmp etc
  cat > init <<'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo
echo "=== Userspace reached: $(uname -sr), $(grep -c ^processor /proc/cpuinfo) CPUs online ==="
exec /bin/sh
EOF
  chmod +x init
  find . | cpio -o -H newc 2>/dev/null | gzip > "$WORK/initramfs.cpio.gz"
}

build_uboot() {
  log "U-Boot: qemu_arm64_defconfig"
  cd "$WORK/u-boot"
  make CROSS_COMPILE="$CROSS" qemu_arm64_defconfig >/dev/null
  make CROSS_COMPILE="$CROSS" -j"$JOBS"
}

build_disk() {
  log "Boot disk: FAT partition holding Image, initramfs and boot.scr"
  cd "$WORK"
  # The script U-Boot finds on the disk and runs (its "boot instructions").
  cat > boot.cmd <<'EOF'
echo ">>> boot.scr: loading kernel + initramfs from virtio disk"
load virtio 0:1 ${kernel_addr_r} Image
load virtio 0:1 ${ramdisk_addr_r} initramfs.cpio.gz
setenv bootargs "console=ttyAMA0 rdinit=/init"
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdtcontroladdr}
EOF
  u-boot/tools/mkimage -A arm64 -T script -C none -d boot.cmd boot.scr >/dev/null
  rm -f disk.img && truncate -s 64M disk.img
  echo 'start=2048, type=c' | sfdisk -q disk.img          # one FAT partition at 1 MiB
  mkfs.vfat --offset 2048 -n BOOT disk.img >/dev/null
  mcopy -i disk.img@@1M "$KERNEL" initramfs.cpio.gz boot.scr ::/
}

build_tfa() {
  log "TF-A: BL1 + BL2 + BL31, with U-Boot packed in as BL33"
  cd "$WORK/tf-a"
  # DEBUG=1 + LOG_LEVEL=40 prints every load and handoff (INFO level).
  make CROSS_COMPILE="$CROSS" PLAT=qemu DEBUG=1 LOG_LEVEL=40 \
       BL33="$WORK/u-boot/u-boot.bin" all fip -j"$JOBS"
  # Output: qemu_fw.bios = BL1 at offset 0 + FIP (BL2, BL31, BL33) after it.
}

build() { build_linux; build_rootfs; build_uboot; build_disk; build_tfa; log "Build done"; }

stage1() {
  log "Stage 1: QEMU loads Linux directly (no firmware at all)"
  qemu-system-aarch64 -M virt "${QEMU_COMMON[@]}" \
    -kernel "$KERNEL" -initrd "$WORK/initramfs.cpio.gz" \
    -append "console=ttyAMA0 earlycon rdinit=/init"
}

stage2() {
  log "Stage 2: QEMU -> U-Boot -> Linux (QEMU itself plays the PSCI firmware)"
  qemu-system-aarch64 -M virt "${QEMU_COMMON[@]}" \
    -bios "$WORK/u-boot/u-boot.bin" "${DISK_ARGS[@]}"
}

stage3() {
  log "Stage 3: QEMU -> TF-A (EL3) -> U-Boot -> Linux"
  # secure=on gives the CPU EL3 and secure memory, so TF-A can run.
  # Add ,virtualization=on to give it EL2 as well (U-Boot then starts at EL2).
  qemu-system-aarch64 -M virt,secure=on "${QEMU_COMMON[@]}" \
    -bios "$TFA_OUT/qemu_fw.bios" "${DISK_ARGS[@]}"
}

debug() {
  log "Stage 3 frozen at reset. In a second terminal run:"
  cat <<EOF
  gdb-multiarch -q \\
    -ex "target remote :1234" \\
    -ex "add-symbol-file $TFA_OUT/bl1/bl1.elf" \\
    -ex "add-symbol-file $TFA_OUT/bl2/bl2.elf" \\
    -ex "add-symbol-file $TFA_OUT/bl31/bl31.elf" \\
    -ex "hbreak bl1_main" -ex "hbreak bl2_main" -ex "hbreak bl31_main" -ex "hbreak *0x60000000"
  At each stop:  printf "EL=%d\\n", (\$cpsr>>2)&3     then  continue
EOF
  qemu-system-aarch64 -M virt,secure=on "${QEMU_COMMON[@]}" -smp 1 -S -s \
    -bios "$TFA_OUT/qemu_fw.bios" "${DISK_ARGS[@]}"
}

case "${1:-}" in
  deps|fetch|build|stage1|stage2|stage3|debug) "$1" ;;
  all) deps; fetch; build; stage3 ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac