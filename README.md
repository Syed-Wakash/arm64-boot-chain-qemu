# arm64-boot-chain-qemu

Build and boot the **real ARM64 (AArch64) industry boot chain** — the same
software stack that starts most Arm phones, servers and dev boards — inside the
QEMU simulator, with no hardware needed.

```
Power-on
   │
   ▼
TF-A  (Trusted Firmware-A)   BL1 → BL2 → BL31     runs at EL3, starts the chip
   │
   ▼
U-Boot  (the bootloader)     BL33                 finds and loads the OS
   │
   ▼
Linux kernel                                     takes over the hardware
   │
   ▼
BusyBox shell                                    you get a "/ #" prompt
```

Everything is driven by one script, `boot-chain.sh`. This README explains what
the script installs, downloads, builds and runs — and *why* each piece exists.

---

## Table of contents

1. [The goal](#1-the-goal)
2. [Background: exception levels](#2-background-exception-levels-el0el3)
3. [The boot stages, one by one](#3-the-boot-stages-one-by-one)
4. [The four source projects](#4-the-four-source-projects)
5. [What every script command does](#5-what-every-script-command-does)
6. [Prerequisites](#6-prerequisites)
7. [How to run it, step by step](#7-how-to-run-it-step-by-step)
8. [Where things end up on disk](#8-where-things-end-up-on-disk)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. The goal

On a real Arm board, Linux does not start by itself. When power comes on, the
CPU runs a tiny piece of trusted code from ROM. That code sets up the chip and
loads the next program, which loads the next, and so on — a **chain** where
each stage prepares the machine and hands control to the next one. Linux is
near the end of that chain, not the start.

This project rebuilds that chain from source and runs it on QEMU's `virt`
board (a generic virtual Arm machine). It does so in **three stages of
increasing realism**, so you can see what each piece adds:

| Stage | What runs first | Chain | What it teaches |
|---|---|---|---|
| `stage1` | Linux | QEMU → Linux | The kernel + root filesystem work on their own |
| `stage2` | U-Boot | QEMU → U-Boot → Linux | What a bootloader does: find the OS on a disk and start it |
| `stage3` | TF-A | QEMU → TF-A → U-Boot → Linux | The full industry chain, starting at the highest privilege level (EL3) |

The **virtual board stays the same** in all three stages (same CPU, RAM, serial
port). Only the first program the CPU runs changes. That makes it easy to
compare them.

---

## 2. Background: exception levels (EL0–EL3)

AArch64 CPUs have four privilege levels, called **Exception Levels**. Higher
number = more power over the machine.

| Level | Typically runs | Can do |
|---|---|---|
| **EL3** | Secure monitor (TF-A's BL31) | Everything, including switching between the Secure and Normal "worlds" |
| **EL2** | Hypervisor (KVM, Xen) | Run and isolate virtual machines |
| **EL1** | OS kernel (Linux) | Manage memory, devices, processes |
| **EL0** | Applications (BusyBox shell) | Only what the kernel allows |

A CPU **resets at its highest implemented level** and can only *lower* its
level by returning from an exception (the `eret` instruction). It can only go
*up* by taking an exception (for example an `smc` call into EL3).

This is why the boot chain looks the way it does: the most trusted code must
run first, because it is the only code that ever gets to run at EL3 freely.
Once it drops down, it can only be re-entered through a controlled door.

In QEMU, EL3 exists only when the board is started with `secure=on`. That is
the key difference between `stage2` and `stage3`.

---

## 3. The boot stages, one by one

### Stage A — TF-A (Trusted Firmware-A): "start the chip"

TF-A is itself split into numbered **Boot Loader stages** (BL). The names are
an Arm convention you will see in every Arm SoC's documentation.

| Stage | Runs at | Lives in | Job |
|---|---|---|---|
| **BL1** | EL3 | Flash/ROM at address 0 (the reset address) | First code after reset. Minimal CPU setup, then loads BL2 into secure RAM and jumps to it. On real chips this is the burned-in "Boot ROM". |
| **BL2** | EL1 (secure) | Secure RAM | "Trusted boot firmware". Sets up memory, then loads the remaining images (BL31, BL33) out of the **FIP** (Firmware Image Package — a container file holding several images). On secure-boot products, this is where signatures are checked. |
| **BL31** | EL3 | Secure RAM, **stays resident forever** | The "EL3 runtime". After boot it keeps living in secure memory and answers requests from the OS, most importantly **PSCI** calls (see below). Then it drops to a lower EL and jumps to BL33. |
| **BL32** | — | — | Optional Secure-world OS (e.g. OP-TEE). **Not used** in this project. |
| **BL33** | EL2 or EL1 (normal) | Normal RAM | "Non-trusted firmware" — here, U-Boot. TF-A does not care what it is; it just loads it and jumps. |

**What is PSCI?** The *Power State Coordination Interface*. Linux can't switch
on a second CPU core or power off the machine by itself on Arm — it asks the
firmware, via an `smc` (secure monitor call) instruction that traps into EL3.
BL31 handles those calls. That is why BL31 must stay in memory after boot, and
why the kernel config enables `CONFIG_ARM_PSCI_FW`.

The build produces one file, `qemu_fw.bios` = BL1 at offset 0, followed by the
FIP (BL2 + BL31 + BL33). QEMU puts this file into the virtual flash at
address 0, so BL1 is exactly where the CPU starts executing.

### Stage B — U-Boot: "find the OS and load it"

U-Boot is the bootloader. It knows how to talk to storage (here, a
**virtio** disk — QEMU's simple paravirtual disk), read a filesystem, load
files into RAM and jump into a kernel.

In this project U-Boot:

1. Starts, scans the virtio disk and finds the FAT partition.
2. Finds `boot.scr` there — a small script, wrapped by the `mkimage` tool so
   U-Boot accepts it — and runs it.
3. `boot.scr` loads `Image` (the kernel) and `initramfs.cpio.gz` (the root
   filesystem) from the disk into RAM, sets the kernel command line, and runs
   `booti` to jump into Linux.

The **device tree** (a data structure describing the board's hardware:
where RAM is, where the serial port is, how many CPUs) is generated by QEMU
and handed to U-Boot. `booti` passes the same one on to Linux via
`${fdtcontroladdr}`.

### Stage C — Linux kernel: "take over the hardware"

Linux reads the device tree, initialises the serial port (PL011 UART, appears
as `ttyAMA0`), brings up the second CPU through PSCI, unpacks the initramfs
into RAM and runs `/init` from it as the first user process (PID 1).

### Stage D — BusyBox shell: "userspace reached"

`/init` is a tiny shell script that mounts `/proc`, `/sys` and `/dev`, prints

```
=== Userspace reached: Linux 6.12.0, 2 CPUs online ===
```

and replaces itself with an interactive shell (`exec /bin/sh`). At that point
the whole chain has worked. The "2 CPUs online" line is a quiet proof that
PSCI worked: the second core was started by the firmware.

---

## 4. The four source projects

All four are cloned at **pinned versions** that were tested together. Newer
versions usually work, but a pinned set means the build is repeatable.

| Project | Version | Repository | Why it is needed |
|---|---|---|---|
| **Trusted Firmware-A** | `v2.12.0` | [ARM-software/arm-trusted-firmware](https://github.com/ARM-software/arm-trusted-firmware) | Arm's reference EL3 firmware. Provides BL1/BL2/BL31: the first code after reset, and the resident PSCI handler Linux relies on. Without it (stage 2), QEMU has to fake those firmware services itself. |
| **U-Boot** | `v2025.01` | [u-boot/u-boot](https://github.com/u-boot/u-boot) | The bootloader (BL33). Bridges "firmware is done" and "kernel is running" by finding the kernel on storage and loading it. Also supplies `mkimage`, used to wrap `boot.scr`. |
| **Linux** | `v6.12` | [torvalds/linux](https://github.com/torvalds/linux) | The operating system kernel. Built **minimal on purpose** (see below). |
| **BusyBox** | `1_36_1` | [mirror/busybox](https://github.com/mirror/busybox) | Hundreds of Unix tools (`sh`, `ls`, `mount`, `cat`…) in one small binary. Gives the kernel something to run, so you get a working shell. |

### Why the kernel is built from `allnoconfig`

A normal `defconfig` arm64 kernel enables thousands of drivers and takes a long
time to build. Instead the script starts from **nothing** (`allnoconfig`) and
switches on only ~25 options, so every option is one you can explain:

| Options | Purpose |
|---|---|
| `PRINTK`, `BUG`, `KALLSYMS` | Kernel can print messages; crash reports show function names |
| `SMP`, `NR_CPUS=4` | Support more than one CPU core |
| `ARM_PSCI_FW` | Talk to firmware (BL31 or QEMU) to start CPUs / power off |
| `TTY`, `SERIAL_AMBA_PL011`, `SERIAL_AMBA_PL011_CONSOLE`, `SERIAL_EARLYCON` | The `virt` board's serial port, used as the console; `earlycon` prints before the full driver is up |
| `BLK_DEV_INITRD`, `RD_GZIP` | Accept a gzip-compressed initramfs as the root filesystem |
| `BINFMT_ELF`, `BINFMT_SCRIPT` | Run ELF programs (BusyBox) and `#!` scripts (`/init`) |
| `DEVTMPFS`, `DEVTMPFS_MOUNT`, `PROC_FS`, `SYSFS`, `TMPFS` | The virtual filesystems `/dev`, `/proc`, `/sys`, `/tmp` |
| `FUTEX`, `POSIX_TIMERS`, `MULTIUSER` | Basic syscalls userspace programs expect |
| `RTC_CLASS`, `RTC_DRV_PL031` | The `virt` board's real-time clock |

### Why BusyBox is built static

`CONFIG_STATIC=y` links the C library *into* the BusyBox binary. The root
filesystem then needs no `/lib` directory and no dynamic loader — the binary
runs on its own. (The `tc` applet is switched off only because it fails to
compile against newer kernel headers; it isn't needed here.)

---

## 5. What every script command does

```
./boot-chain.sh deps | fetch | build | stage1 | stage2 | stage3 | debug | all
```

All work happens in `$WORK`, which defaults to `~/chain`. Override it with
e.g. `WORK=/data/chain ./boot-chain.sh build`.

The script detects your machine: on an **x86_64** PC it cross-compiles with
`aarch64-linux-gnu-gcc`; on an **arm64** machine (e.g. an Ubuntu VM on Apple
Silicon) it builds natively, with no cross compiler.

### `deps` — install the tools (once, uses `sudo`)

Runs `apt-get install` for:

| Package(s) | Used for |
|---|---|
| `build-essential`, `bison`, `flex`, `bc` | Compiler, `make`, and the parser/calculator tools the kernel and U-Boot build systems use |
| `gcc-aarch64-linux-gnu`, `binutils-aarch64-linux-gnu` | **Cross compiler** — produces ARM64 code on an x86 PC (only installed on non-arm64 hosts) |
| `libssl-dev`, `libgnutls28-dev` | Crypto libraries used by host tools that sign/hash images (U-Boot's `mkimage`, TF-A's `fiptool`, kernel build tools) |
| `libncurses-dev` | Text menus for `make menuconfig` (optional, handy for exploring configs) |
| `python3-dev`, `python3-setuptools`, `swig` | U-Boot builds Python-based helper tools (e.g. `libfdt` bindings) |
| `device-tree-compiler` | `dtc`, compiles device tree source files |
| `u-boot-tools` | Host-side U-Boot utilities |
| `cpio` | Packs the root filesystem into an initramfs archive |
| `dosfstools`, `mtools`, `fdisk` | Create the FAT boot disk: `mkfs.vfat`, `mcopy` (copy files in without mounting), `sfdisk` (partition table) |
| `qemu-system-arm` | The emulator; provides `qemu-system-aarch64` |
| `gdb-multiarch` | A debugger that understands ARM64, for `debug` |

### `fetch` — download the sources (~2.5 GB)

`git clone --depth 1` of the four projects at their pinned tags into `$WORK`
(`tf-a/`, `u-boot/`, `linux/`, `busybox/`). `--depth 1` downloads only that
one version, not the full history. Folders that already exist are skipped, so
re-running is safe.

### `build` — compile everything (~5–15 min)

Five steps, in this order (the order matters — later steps use earlier output):

1. **Linux** — `allnoconfig` + the option list above → `linux/arch/arm64/boot/Image`
2. **Root filesystem** — static BusyBox installed into `$WORK/rootfs/`, plus
   the `/init` script, packed as `$WORK/initramfs.cpio.gz`
3. **U-Boot** — `qemu_arm64_defconfig` → `u-boot/u-boot.bin`
4. **Boot disk** — `$WORK/disk.img`, a 64 MB raw disk with one FAT partition
   starting at 1 MiB, containing `Image`, `initramfs.cpio.gz` and `boot.scr`
5. **TF-A** — built for `PLAT=qemu` with `u-boot.bin` packed in as BL33 →
   `tf-a/build/qemu/debug/qemu_fw.bios`. `DEBUG=1 LOG_LEVEL=40` makes TF-A print
   every image it loads and every handoff, so you can watch the chain.

### `stage1` — QEMU → Linux

```
qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2 -m 1024M -nographic \
  -kernel Image -initrd initramfs.cpio.gz -append "console=ttyAMA0 earlycon rdinit=/init"
```

QEMU loads the kernel and initramfs into RAM itself and jumps straight into
Linux — no firmware, no bootloader, no disk. If this fails, the problem is the
kernel or the rootfs, not the boot chain.

### `stage2` — QEMU → U-Boot → Linux

```
qemu-system-aarch64 -M virt ... -bios u-boot.bin  + virtio disk
```

U-Boot is now the first thing the CPU runs. It reads `disk.img` and runs
`boot.scr`, which loads Linux. There is no EL3 here (no `secure=on`), so
**QEMU itself answers Linux's PSCI calls** — a stand-in for the missing
firmware.

### `stage3` — QEMU → TF-A → U-Boot → Linux (the full chain)

```
qemu-system-aarch64 -M virt,secure=on ... -bios qemu_fw.bios  + virtio disk
```

`secure=on` gives the virtual CPU EL3 and secure-only memory, so the CPU now
resets into **BL1 at EL3**, exactly like real silicon. You will see, in order:
TF-A's `BL1`/`BL2`/`BL31` log lines → U-Boot's banner → `>>> boot.scr: ...` →
Linux boot messages → the `=== Userspace reached` line → a `/ #` prompt.

Tip from the script: use `-M virt,secure=on,virtualization=on` to also enable
EL2. BL31 then hands U-Boot control at EL2 instead of EL1.

### `debug` — stage 3 frozen at reset, with GDB

Starts the same machine as `stage3` but with:

- `-S` — freeze the CPU before it executes the first instruction
- `-s` — open a GDB server on TCP port 1234
- `-smp 1` — a single core, so debugging is easier to follow (overrides the earlier `-smp 2`)

It prints the GDB command to paste into a **second terminal**. That command:

- connects to QEMU (`target remote :1234`),
- loads the debug symbols of BL1, BL2 and BL31 (`add-symbol-file ...elf`),
- sets **hardware** breakpoints (`hbreak`) at `bl1_main`, `bl2_main`,
  `bl31_main` and `0x60000000` (the address where TF-A places U-Boot on this
  platform). Hardware breakpoints are used because BL1 runs from read-only
  flash, where a software breakpoint can't be written in.

Type `continue` to run to the next stage. At each stop, the script suggests:

```
printf "EL=%d\n", ($cpsr>>2)&3
```

Bits 3:2 of the processor state hold the **current Exception Level**, so you
can see the privilege level drop as the chain progresses: 3 in BL1, 1 in BL2
(secure EL1), 3 again in BL31, then lower at U-Boot.

### `all`

`deps` + `fetch` + `build` + `stage3` in one go.

### Leaving QEMU

QEMU runs in your terminal (`-nographic`). To quit: press **`Ctrl-a`**,
release, then press **`x`**.

---

## 6. Prerequisites

- **OS:** Ubuntu 24.04 (tested). Other recent Debian/Ubuntu releases will
  likely work; other distros need the package names in `deps` translated.
- **CPU:** x86_64 (cross build) or arm64 (native build).
- **Disk:** ~2.5 GB for the sources, plus room for build output — keep
  around 10 GB free to be comfortable.
- **RAM:** 4 GB+ recommended for building; QEMU itself uses 1 GB.
- **Network:** access to github.com for `fetch`.
- **sudo:** only needed for `deps`.

---

## 7. How to run it, step by step

```bash
# 0. Get the script
git clone https://github.com/Syed-Wakash/arm64-boot-chain-qemu.git
cd arm64-boot-chain-qemu
chmod +x boot-chain.sh          # if not already executable

# 1. Install tools (once)
./boot-chain.sh deps

# 2. Download sources (once, ~2.5 GB)
./boot-chain.sh fetch

# 3. Build everything (~5–15 min)
./boot-chain.sh build

# 4. Boot, from simplest to full chain. Quit each with Ctrl-a then x.
./boot-chain.sh stage1          # Linux only
./boot-chain.sh stage2          # U-Boot -> Linux
./boot-chain.sh stage3          # TF-A -> U-Boot -> Linux

# 5. (Optional) step through the firmware in GDB
./boot-chain.sh debug           # terminal 1: QEMU, frozen
# terminal 2: paste the gdb-multiarch command it printed
```

Doing the stages in order is deliberate: each one adds exactly one new piece,
so if something breaks you know which piece caused it.

**After changing something:** re-run `./boot-chain.sh build` (it rebuilds all
five steps; `make` skips unchanged files, so it's faster the second time).

---

## 8. Where things end up on disk

```
~/chain/                         ($WORK)
├── tf-a/      build/qemu/debug/qemu_fw.bios   ← stage3 firmware (BL1 + FIP)
│              build/qemu/debug/bl{1,2,31}/*.elf  ← symbols for GDB
├── u-boot/    u-boot.bin                      ← stage2 firmware / BL33
│              tools/mkimage
├── linux/     arch/arm64/boot/Image           ← the kernel
├── busybox/
├── rootfs/                                    ← unpacked root filesystem
├── kernel.fragment                            ← the kernel option list
├── initramfs.cpio.gz                          ← packed root filesystem
├── boot.cmd / boot.scr                        ← U-Boot boot script (text / wrapped)
└── disk.img                                   ← 64 MB FAT boot disk
```

To remove everything the script downloaded and built: `rm -rf ~/chain`.
The apt packages from `deps` stay installed; remove them with `apt remove` if
you no longer need them.

---

## 9. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `stage1` panics with `No working init found` | initramfs missing or `/init` not executable — re-run `build` |
| `stage2`/`stage3` sit at the U-Boot prompt (`=>`) | U-Boot didn't find `boot.scr`; check `disk.img` was rebuilt (`build`) |
| `stage3` prints nothing at all | `qemu_fw.bios` missing, or `secure=on` removed |
| Only `1 CPUs online` in stage 2/3 | PSCI path not working; check `CONFIG_ARM_PSCI_FW` is still in the kernel config |
| BusyBox build fails in `networking/tc.c` | the `tc` applet wasn't disabled — the `sed` line in `build_rootfs` handles this |
| Can't exit QEMU | `Ctrl-a`, release both keys, then `x` |
