# Native Debian Porting Guide for Samsung r8q

[English](porting-guide.en.md) · [한국어](porting-guide.ko.md) · [README](../README.md)

Document date: October 15, 2026 · Device work recorded on October 7–8, 2026

This guide describes rebuilding the LineageOS kernel for the Galaxy S20 FE 5G (`r8q`), replacing the ramdisk in its Android boot image with a BusyBox initramfs, and booting Debian 13 arm64 directly from internal `userdata`, with systemd as PID 1. Establish a working boot and USB connection first, then apply the optional USB NCM performance changes.

The resulting boot sequence is:

```text
Samsung bootloader
  → Android boot image v2 in the boot partition
  → LineageOS-based Linux 4.19 kernel and the original DTB
  → BusyBox /init
  → USB RNDIS initialization
  → Mount userdata ext4 at /newroot
  → switch_root /newroot /sbin/init
  → Debian systemd
  → Optional switch to USB NCM 20 seconds after boot
```

This boot path does not require UEFI or GRUB. The `r8q-arch` and Mu-Silicium approach is a separate port. Do not mix its kernel, DTB, or boot images with this procedure.

### Contents

- [1 Scope and recorded results](#port-1)
- [2 Check the starting environment and make backups](#port-2)
- [3 Pin the kernel source and toolchain](#port-3)
- [4 Build the baseline and native kernels](#port-4)
- [5 Prepare the initramfs](#port-5)
- [6 Repack and verify the boot image](#port-6)
- [7 Verify the USB rescue boot before changing storage](#port-7)
- [8 Prepare the Debian rootfs](#port-8)
- [9 Prepare ARM64 installation tools and preserve firmware](#port-9)
- [10 Format userdata and restore the rootfs](#port-10)
- [11 Configure the first Debian boot](#port-11)
- [12 Verify native boot completion](#port-12)
- [13 Download packages over USB](#port-13)
- [14 USB NCM transmit aggregation patch](#port-14)
- [15 Turn off the boot display](#port-15)
- [16 Wi-Fi porting progress and unresolved issues](#port-16)
- [17 Package and rootfs integrity](#port-17)
- [18 Recovery and diagnosis](#port-18)
- [19 Completion checks and artifacts to retain](#port-19)
- [20 References](#port-20)

<a id="port-1"></a>

## 1 Scope and recorded results

| Item | Recorded result |
|---|---|
| Device | Samsung Galaxy S20 FE 5G, `r8q`; tested model `SM-G781N`, 6 GB RAM |
| Starting environment | Rooted LineageOS `23.0-20251206-NIGHTLY-r8q` with an existing Debian chroot |
| Kernel source | `LineageOS/android_kernel_samsung_sm8250` |
| Base commit | `29f575b64b2d2beb802d3e549fdf2837c50deaff` |
| Compiler | Android `clang-r547379`, Clang 20.0.0, LLD 20.0.0 |
| Build host | Debian 13, x86_64 |
| Boot image | Header v2, page size 4096; the recorded full boot-partition image was 64 MiB |
| Kernel input | Uncompressed `arch/arm64/boot/Image` used for repacking |
| Root filesystem | ext4 on `userdata`, `/dev/sda36` on the tested device |
| Native OS boot | Debian 13 trixie, with `/sbin/init` running systemd as PID 1 |
| Container prerequisites | Additional namespaces enabled; cgroup v2 `cpu io memory pids` observed; an ARM64 Debian LXC container booted during testing |
| USB | RNDIS boot worked; switching to NCM after Debian started worked, including an automatic switch after reboot |
| NCM throughput | Approximately 2.26 Gbps device receive and 1.30 Gbps device transmit in one 10-second measurement |
| Display | Display turned off after `modetest` set a DRM mode and exited |
| Wi-Fi | `wlan0` was not brought up; porting remains incomplete |
| GPU and video acceleration | Device nodes observed only; accelerated operation under Debian was not established |

### 1.1 Evidence and execution context

**Recorded success** means the result was confirmed by device output or an observed result during the original work. **Adapted procedure** means commands have been consolidated or turned into reusable templates; these exact templates have not been retested on the device. **Alternative procedure** means a way to prepare new inputs without copying an existing personal chroot; it requires validation on the target device. See [PROVENANCE.md](../PROVENANCE.md) for the evidence scope and the origin of the included files.

Commands are labeled by their execution environment: `PC`, `Android`, `Recovery`, `initramfs`, or `Debian`. Do not concatenate commands for different environments into one shell session. The example working directory is `~/r8q-linux`. The USB addresses are `192.168.77.1/30` for the device and `192.168.77.2/30` for the PC. If this subnet conflicts with an existing network, change both addresses and every related template consistently.

PC commands assume Bash on Debian. Build the kernel and prepare image files on the PC, but run the extracted ARM64 BusyBox and magiskboot binaries on the phone in Android or Recovery.

### 1.2 Required inputs and reproducibility limits

This repository includes documentation, adapted templates, the NCM patch, and three related source snapshots: `f_ncm.c`, `u_ether.c`, and `u_ether.h`. **It is not a complete kernel source tree or a ready-to-flash installation image.** Obtain the following inputs from your own device or build environment.

| Input | How to obtain it and why it is needed |
|---|---|
| Baseline `running.config` | Export `/proc/config.gz` from the working device to retain its board and driver configuration |
| Original `boot` image | Back up the entire partition to preserve its header, command line, DTB, and a recovery copy |
| Working recovery | Retain a recovery that provides a root ADB shell |
| `busybox-arm64` | A statically linked ARM64 BusyBox; the recorded procedure used the copy installed by Magisk |
| `magiskboot-arm64` | Extract it from the installed Magisk version; record its version and hash |
| Debian arm64 rootfs | A fresh rootfs without personal settings, or an existing rootfs that has been cleaned for this purpose |
| Board firmware | The device's existing firmware, DSP, and persist partitions, plus any required vendor files |

The baseline `.config`, original boot image and DTB, tool binaries, and Debian rootfs are not included. The repository alone therefore cannot reproduce the original images byte for byte. This guide explains how to obtain those inputs and reproduce the same boot architecture. Verify partition numbers and panel details on the actual device, even for another `r8q` variant.

### 1.3 Prepare the repository examples

From the root of the cloned or extracted repository—the directory containing `templates/`, `patches/`, `reference/`, and `sources/`—copy the examples to the working directory used by this guide. These commands prepare PC files and do not change the device.

```bash
mkdir -p ~/r8q-linux
cp -a templates ~/r8q-linux/
cp patches/r8q-ncm-tx-aggregation.patch ~/r8q-linux/
```

Sections 1–12 cover the basic boot path. Section 14 covers optional NCM improvements, section 15 covers the display, and section 16 documents incomplete Wi-Fi work. Keep the recorded working path distinct from the alternative fresh-rootfs procedure.

<a id="port-2"></a>

## 2 Check the starting environment and make backups

This procedure starts with an already unlocked bootloader, working LineageOS, and root access. Bootloader unlocking and the initial LineageOS installation were not reproduced as part of this porting work.

**PC**

```bash
mkdir -p ~/r8q-linux/{backup,debug-native}
cd ~/r8q-linux
adb devices
adb shell getprop ro.product.device
adb shell getprop ro.lineage.version
adb shell uname -r
adb shell su -c 'ls -l /dev/block/by-name/boot /dev/block/by-name/userdata'
```

Record the device name `r8q`, the baseline kernel suffix `g29f575b64b2d`, and the partition symlink targets. If the installed version differs, first identify a matching kernel source and boot-image combination.

**Export the Android kernel configuration and boot image from the PC**

```bash
adb exec-out su -c 'cat /proc/config.gz' > running-config.gz
gzip -t running-config.gz
gzip -dc running-config.gz > running.config
adb exec-out su -c 'cat /dev/block/by-name/boot' > backup/boot-current.img
adb shell su -c 'blockdev --getsize64 /dev/block/by-name/boot'
stat -c '%s' backup/boot-current.img
sha256sum backup/boot-current.img running.config
adb shell su -c 'sha256sum /dev/block/by-name/boot'
adb shell su -c 'cat /proc/cmdline' > backup/cmdline-current.txt
```

The device's boot-partition size must match the PC image size, and the boot-image hashes must match on both sides. The recorded size was 67,108,864 bytes. Keep the recovery image and any other required recovery artifacts outside the phone as well. After formatting `userdata`, restoring the boot image alone cannot restore Android data or the original chroot stored there.

The full `/proc/cmdline` may contain the device serial number and other identifiers. Retain it locally for reproduction, but do not publish it unchanged.

<a id="port-3"></a>

## 3 Pin the kernel source and toolchain

**PC**

```bash
sudo apt update
sudo apt install git build-essential bc bison flex libssl-dev libelf-dev \
  libncurses-dev device-tree-compiler \
  dwarves cpio rsync unzip xz-utils file binutils-aarch64-linux-gnu \
  gcc-aarch64-linux-gnu adb python3 wget
cd ~/r8q-linux
git clone --single-branch --branch lineage-23.0 \
  https://github.com/LineageOS/android_kernel_samsung_sm8250.git kernel
cd kernel
git switch -c r8q-debian 29f575b64b2d2beb802d3e549fdf2837c50deaff
git rev-parse HEAD
git status --short
```

Use the pinned commit as the build reference. A branch tip can change, so verify that the required commit is available and that `git rev-parse HEAD` returns it. A `--depth 1` kernel clone may omit this older commit; the kernel clone above is deliberately not shallow.

**Fetch Android Clang on the PC**

```bash
cd ~/r8q-linux
git clone --depth 1 --filter=blob:none --sparse \
  --branch android16-release \
  https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
  android-clang
git -C android-clang sparse-checkout set clang-r547379
android-clang/clang-r547379/bin/clang --version
android-clang/clang-r547379/bin/ld.lld --version
git -C android-clang rev-parse HEAD > backup/toolchain-commit.txt
```

The recorded compiler string includes Android build number `13290119` and LLVM commit `b718bcaf8c198c82f3021447d943401e3ab5bd54`. The original prebuilt-toolchain repository commit was not recorded, so compare the directory name and version output, then retain the commit of the toolchain you obtain. Preserve the source tree's LTO and CFI settings when reproducing the build; do not substitute a system Clang without validating that change.

<a id="port-4"></a>

## 4 Build the baseline and native kernels

### 4.1 Build the unchanged baseline

**PC**

```bash
cd ~/r8q-linux/kernel
export PATH="$HOME/r8q-linux/android-clang/clang-r547379/bin:$PATH"
mkdir -p ../out-baseline
cp ../running.config ../out-baseline/.config
make O="$HOME/r8q-linux/out-baseline" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
set -o pipefail
make -j6 O="$HOME/r8q-linux/out-baseline" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
  Image Image.gz dtbs modules 2>&1 | tee ../build-baseline.log
```

Run the build only after `olddefconfig` succeeds. The original baseline build used `-j4`; later modified builds used `-j6`. This option sets the number of parallel jobs on the PC. The baseline was confirmed to compile. The subsequent kernel with LXC namespace options was the one confirmed to boot on the device.

### 4.2 Enable native-boot and namespace options

The recorded work first added namespace options in `out-lxc`, then added devtmpfs in `out-native`. The following adapted procedure consolidates those two configuration steps.

**PC**

```bash
cd ~/r8q-linux/kernel
mkdir -p ../out-native
cp ../out-baseline/.config ../out-native/.config
scripts/config --file ../out-native/.config \
  --enable SYSVIPC --enable IPC_NS --enable PID_NS --enable USER_NS \
  --enable CGROUP_DEVICE --enable CGROUP_PIDS --enable FHANDLE \
  --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
  --set-str LOCALVERSION '-perf-native'
make O="$HOME/r8q-linux/out-native" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
set -o pipefail
make -j6 O="$HOME/r8q-linux/out-native" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
  Image Image.gz dtbs modules 2>&1 | tee ../build-native.log
cat ../out-native/include/config/kernel.release
```

Check the resulting configuration:

```bash
grep -E '^CONFIG_(SYSVIPC|IPC_NS|PID_NS|USER_NS|CGROUP_DEVICE|CGROUP_PIDS|FHANDLE|DEVTMPFS|DEVTMPFS_MOUNT)=' ../out-native/.config
grep -E '^CONFIG_(BLK_DEV_INITRD|RD_GZIP|SCSI|BLK_DEV_SD|SCSI_UFSHCD|SCSI_UFSHCD_PLATFORM|SCSI_UFS_QCOM|EXT4_FS|PROC_FS|SYSFS|TMPFS|CONFIGFS_FS|USB_GADGET|USB_CONFIGFS|USB_CONFIGFS_RNDIS|USB_DWC3|USB_DWC3_MSM)=' ../out-native/.config
```

This procedure expects the storage, ext4, and USB features needed for early boot to be built into the kernel as `=y`. Changing them to `=m` requires matching modules in the initramfs and an appropriate load order. The recorded builds that ended with `MODPOST 0 modules` did not produce separate `.ko` modules.

`SYSVIPC` is a prerequisite for selecting `IPC_NS`. `USER_NS` and the cgroup settings provide container prerequisites; actual access restrictions and networking still require functional tests. Retain the original `NET_NS`, cgroups, BPF, and seccomp support, and check the following options as well:

```bash
grep -E '^CONFIG_(NAMESPACES|UTS_NS|NET_NS|CGROUPS|CGROUP_BPF|BPF|BPF_SYSCALL|SECCOMP|SECCOMP_FILTER|VETH|BRIDGE)=' ../out-native/.config
```

The recorded kernel release was `4.19.325-cip124-st8-perf-native-g29f575b64b2d`. Source changes may add a `-dirty` suffix, indicating uncommitted changes in the source worktree rather than a build failure. Retain the final `.config` and `git diff` with your build artifacts.

The baseline enabled `CONFIG_MODVERSIONS=y` and mandatory module signatures. Without the original LineageOS signing key, do not assume that existing vendor `.ko` files will load into the rebuilt kernel. If your configuration needs modules, build them with matching source, configuration, and signing conditions.

<a id="port-5"></a>

## 5 Prepare the initramfs

### 5.1 Obtain static ARM64 BusyBox and magiskboot binaries

**PC, while Android is running on the phone**

```bash
cd ~/r8q-linux
adb shell "su -c 'cp /data/adb/magisk/busybox /data/local/tmp/r8q-busybox && chown shell:shell /data/local/tmp/r8q-busybox && chmod 755 /data/local/tmp/r8q-busybox && restorecon /data/local/tmp/r8q-busybox'"
adb pull /data/local/tmp/r8q-busybox busybox-arm64
adb shell "su -c 'cp /data/adb/magisk/magiskboot /data/local/tmp/r8q-magiskboot && chown shell:shell /data/local/tmp/r8q-magiskboot && chmod 755 /data/local/tmp/r8q-magiskboot && restorecon /data/local/tmp/r8q-magiskboot'"
adb pull /data/local/tmp/r8q-magiskboot magiskboot-arm64
file busybox-arm64 magiskboot-arm64
aarch64-linux-gnu-readelf -l busybox-arm64 | grep INTERP
sha256sum busybox-arm64 magiskboot-arm64 > backup/native-tools.sha256
```

BusyBox must be a static ARM64 binary for this procedure. An `INTERP` entry indicates that it requires a dynamic loader and libraries to run. Do not run these ARM64 binaries directly on the x86_64 PC; use them later in Recovery or an ARM64 shell on the device.

### 5.2 Create the early device nodes

**PC**

```bash
cd ~/r8q-linux
mkdir -p native-root/{bin,dev,proc,sys,run,config,etc}
cp busybox-arm64 native-root/bin/busybox
chmod 755 native-root/bin/busybox
ln -sfn busybox native-root/bin/sh
sudo mknod -m 666 native-root/dev/null c 1 3
sudo mknod -m 600 native-root/dev/console c 5 1
sudo mknod -m 600 native-root/dev/kmsg c 1 11
```

If a node already exists, check that it is a character device with the correct major and minor numbers rather than deleting or replacing it. **With the Magisk BusyBox used in the recorded work, `/dev/null` must be present in the initramfs before devtmpfs is mounted.** USB did not appear when the initial device nodes were missing; after adding them, `/init` and RNDIS function creation progressed. Precreate `/dev/kmsg` as well so the script can log before its first mounts.

### 5.3 RNDIS initialization

The repository's [`templates/initramfs/init-rndis.sh`](../templates/initramfs/init-rndis.sh) consolidates the `/init` behavior established during porting. After copying the templates in section 1.3, install it as `~/r8q-linux/native-root/init`.

**PC**

```bash
cd ~/r8q-linux
cp templates/initramfs/init-rndis.sh native-root/init
```

The default `BOOT_STAGE=rescue` starts a USB shell in RAM without mounting persistent storage. Setting `BOOT_STAGE=debian` switches to Debian after initializing USB. Keep `rescue` for this stage.

The required initialization order is:

1. Write early logs through the precreated `/dev/kmsg`.
2. Install the BusyBox applets and mount proc, sysfs, devtmpfs, tmpfs, and devpts.
3. Mount configfs at `/config`.
4. Wait for the `a600000.dwc3` UDC to appear.
5. Create the RNDIS function and set its MAC addresses.
6. Link the function into the USB configuration and bind it to `UDC`.
7. **After binding**, read `functions/rndis.usb0/ifname` and wait for the corresponding `/sys/class/net/<interface>` entry.
8. Assign `192.168.77.1/30` to the device interface.

Reading `ifname` before the UDC is bound can return `(unnamed net_device)`, as observed during testing. Attempting to configure an IP address using that value leaves USB networking unavailable.

The examples retain the test VID/PID `1d6b:0104`, device MAC `02:77:00:00:00:01`, and host MAC `02:77:00:00:00:02`. Use distinct serial numbers and MAC addresses if connecting multiple devices with these examples at the same time. `MaxPower=250` is a USB descriptor value, not a charging-current setting or guarantee.

The basic configfs function and UDC-binding structure is documented in the [Linux USB gadget documentation](https://www.kernel.org/doc/html/v5.10/usb/gadget_configfs.html).

### 5.4 Build the newc ramdisk

**PC**

```bash
cd ~/r8q-linux
# Run after copying the initramfs template.
chmod 755 native-root/init
bash -n native-root/init
(
  set -o pipefail
  cd native-root
  find . -print0 | cpio --null -o --format=newc --owner=0:0 \
    > ../native-rescue.cpio
)
cpio -itv < native-rescue.cpio
```

The archive must contain `init`, `bin/busybox`, `bin/sh`, `dev/null`, `dev/console`, and `dev/kmsg`. Check the executable bits on `init` and BusyBox, the `bin/sh` symlink, and the character-device type of all three nodes. This creates an uncompressed newc archive; boot-image repacking applies the original ramdisk compression format. `bash -n` checks syntax only and does not establish that the script will run successfully on ARM64 hardware.

<a id="port-6"></a>

## 6 Repack and verify the boot image

### 6.1 Work in Recovery

From Android, use `adb reboot recovery`. In Lineage Recovery, select **Advanced → Enable ADB**. This enabled root ADB access in the recorded environment. Use the root shell, not the ADB sideload screen.

**PC**

```bash
adb devices
adb root
adb shell id
adb shell ls -l /dev/block/by-name/boot
adb shell mkdir -p /tmp/r8q-pack
adb push magiskboot-arm64 /tmp/magiskboot
adb shell chmod 755 /tmp/magiskboot
adb push backup/boot-current.img /tmp/r8q-pack/boot-base.img
adb push out-native/arch/arm64/boot/Image /tmp/r8q-pack/kernel-new
adb push native-rescue.cpio /tmp/r8q-pack/ramdisk-new
adb shell 'cd /tmp/r8q-pack && /tmp/magiskboot unpack -h boot-base.img'
adb shell cat /tmp/r8q-pack/header
```

`magiskboot unpack -h` extracts the header and image components. Repacking against the original image preserves its format and configuration. See the [official Magisk tools documentation](https://topjohnwu.github.io/Magisk/tools.html) for the tool's behavior.

The original image had the following properties. Check these fields in your own image before continuing.

| Field | Recorded value | Required handling |
|---|---|---|
| `HEADER_VER` | `2` | Preserve the Android boot image v2 structure |
| `PAGESIZE` | `4096` | Preserve the original page size |
| `KERNEL_FMT` | `raw` | Replace the kernel with the uncompressed `Image` in this procedure |
| `RAMDISK_FMT` | `gzip` | Preserve the original compression format after repacking |
| `DTB_SZ` | `1415391` | DTB extracted as a separate file; preserve the original `dtb` |
| `OS_VERSION` / `OS_PATCH_LEVEL` | `16.0.0` / `2025-11` | Preserve the original header's version metadata |

If the DTB is appended to the kernel or the header structure differs, inspect that image layout before applying this example. A `VBMETA` message alone does not establish a need for additional AVB changes. The recorded boot succeeded with the existing unlocked state and a repacked image preserving the original structure.

### 6.2 Preserve the command line and original DTB

Append only **`rdinit=/init enforcing=0`** to the existing `cmdline=` value in `header`. Preserve the existing board, storage, and firmware options. Use the repository's [`templates/append-boot-cmdline.py`](../templates/append-boot-cmdline.py) on a local header copy, or carefully edit that one line before uploading it again.

The header uses `key=value` lines such as `name=`, `cmdline=`, `os_version=`, and `os_patch_level=`. Do not replace its command line with the entire runtime `/proc/cmdline`. The runtime string can include device identifiers added by the bootloader and flags indicating a Recovery boot. Add only the early-init and SELinux options to the `cmdline=` line extracted from the original image.

```bash
adb pull /tmp/r8q-pack/header boot-header.txt
python3 templates/append-boot-cmdline.py boot-header.txt
adb push boot-header.txt /tmp/r8q-pack/header
```

`templates/append-boot-cmdline.py` is the helper copied in section 1.3. It stops rather than silently replacing a conflicting existing `rdinit=` or `enforcing=` value.

`enforcing=0` selects permissive mode and was used to avoid SELinux restrictions in the downstream Android kernel during bring-up. This port has not been validated in SELinux enforcing mode. The existing boot command line already included `lpm_levels.sleep_disabled=1`; retain it. It is separate from idle-workaround services used by other mainline ports.

**Repack and verify through Recovery from the PC**

```bash
adb shell 'cd /tmp/r8q-pack && cp kernel-new kernel && cp ramdisk-new ramdisk.cpio && /tmp/magiskboot repack boot-base.img /tmp/boot-native-rescue.img'
adb pull /tmp/boot-native-rescue.img boot-native-rescue.img
adb shell mkdir -p /tmp/r8q-verify
adb shell 'cd /tmp/r8q-verify && /tmp/magiskboot unpack -h /tmp/boot-native-rescue.img'
adb shell 'sha256sum /tmp/r8q-pack/kernel-new /tmp/r8q-verify/kernel'
adb shell 'sha256sum /tmp/r8q-pack/ramdisk-new /tmp/r8q-verify/ramdisk.cpio'
adb shell 'sha256sum /tmp/r8q-pack/dtb /tmp/r8q-verify/dtb'
adb shell cat /tmp/r8q-verify/header
```

Each kernel, ramdisk, and DTB hash pair must match. Use the **raw `Image`** for `kernel` and retain the `dtb` extracted from the original boot image. The recorded output showed `KERNEL_FMT [raw]` and `RAMDISK_FMT [gzip]`. Confirm that the resulting image does not exceed the boot partition's size.

```bash
stat -c '%s' boot-native-rescue.img
adb shell blockdev --getsize64 /dev/block/by-name/boot
```

Although the kernel build produces `dtbs`, this procedure does not replace the original DTB with one of those outputs. The recorded working path retained the DTB from the working boot image and the existing `dtbo` partition.

### 6.3 Write the boot partition

The following command replaces the boot partition. It does not target the recovery partition.

**PC using Recovery's root ADB shell**

```bash
adb shell 'dd if=/tmp/boot-native-rescue.img of=/dev/block/by-name/boot bs=1048576 && sync'
sha256sum boot-native-rescue.img
adb shell sha256sum /dev/block/by-name/boot
```

The recorded image occupied the entire 64 MiB partition, so its hash could be compared with the full partition hash. If your tool produces a shorter image, the full partition hash may differ. Check the sizes and compare a readback of exactly the number of bytes written. Do not repeat the flash merely because a full-partition hash differs from a shorter image.

Select **Reboot system now** in the device's Recovery menu. In the recorded work, `adb reboot` sometimes returned to Recovery. An ADB connection to Recovery is not evidence that the new native kernel booted successfully.

<a id="port-7"></a>

## 7 Verify the USB rescue boot before changing storage

**PC**

```bash
lsusb
ip -br link
sudo dmesg | tail -n 40
```

Look for a `1d6b:0104` device and a new USB network interface. Its recorded host-side name was `enx027700000002`; the name can differ between hosts.

```bash
USB_IF=enx027700000002
sudo ip link set "$USB_IF" up
sudo ip addr replace 192.168.77.2/30 dev "$USB_IF"
ping -c 3 -W 2 192.168.77.1
sudo apt install inetutils-telnet
telnet 192.168.77.1
```

Set `USB_IF` to the interface that actually appeared. If NetworkManager or another manager removes the temporary address after reconnection, adjust management of that USB interface or register the address with the host's existing network manager. Do not copy settings from an unrelated LAN interface.

**initramfs shell**

```sh
echo READY
uname -r
tr '\0' ' ' < /proc/1/cmdline
echo
cat /proc/mounts
cat /sys/class/block/sda36/uevent
cat /sys/class/block/sda36/size
```

The recorded PID 1 command line was `/bin/sh /init`, the kernel release contained `-perf-native`, and `sda36` reported `PARTNAME=userdata`. Also confirm that `userdata` is not mounted in `BOOT_STAGE=rescue`. Complete this test before proceeding to format `userdata`.

Use Telnet only for temporary installation and recovery. Normal Debian access uses SSH. The rescue shell binds to the static USB address; bridging that USB link into another LAN later changes who can reach it.

<a id="port-8"></a>

## 8 Prepare the Debian root filesystem

### 8.1 Migrate an existing rootfs

The verified installation migrated an existing Debian 13 arm64 chroot: GNU tar created the backup, which was then restored to userdata. The original archive was named `debian13-with-lxc.tar` and was about 6.5 GiB. That archive is not distributed with this repository. See [PROVENANCE.md](../PROVENANCE.md) for the evidence behind the verified path and the alternatives below.

The rootfs must provide `/sbin/init`, systemd, udev, OpenSSH, iproute2, util-linux, e2fsprogs, GNU tar, and their ARM64 runtime libraries. If migrating your own installation, review its contents before publishing an archive that may contain services, credentials, or container data.

The following commands back up a chroot already installed under Android. Change `ROOTFS_PATH` to its actual location. Stop workloads using that rootfs before creating the archive, and exclude virtual filesystems such as proc, sys, dev, and run.

**PC: back up the Android chroot**

```bash
ROOTFS_PATH=/data/local/debian13
adb shell "su -c 'chroot $ROOTFS_PATH /usr/bin/tar --one-file-system --numeric-owner --acls --xattrs --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp -C / -cpf /tmp/debian-rootfs.tar .'"
# The adb shell account could not read the file inside the chroot directly.
adb shell "su -c 'cp $ROOTFS_PATH/tmp/debian-rootfs.tar /data/local/tmp/debian-rootfs.tar && chown shell:shell /data/local/tmp/debian-rootfs.tar && chmod 600 /data/local/tmp/debian-rootfs.tar && restorecon /data/local/tmp/debian-rootfs.tar'"
adb pull /data/local/tmp/debian-rootfs.tar backup/debian-rootfs.tar
tar -tf backup/debian-rootfs.tar > /dev/null
sha256sum backup/debian-rootfs.tar
```

Check the backup output for errors and omissions. `--one-file-system` does not necessarily exclude bind mounts backed by the same filesystem, so the explicit exclusions are required. Review any additional mounts whose contents need separate handling.

An early attempt using `adb exec-out` produced a 134-byte error message rather than a tar archive. **A file's existence does not establish that the backup succeeded.** Verify that tar can list it, inspect its size, calculate its hash, and retain a readable copy on the PC before formatting userdata.

### 8.2 Create a clean rootfs: unverified alternative

This is an **alternative that has not been validated by booting it on the device**. The successful installation used the migrated chroot described above. To prepare an independent rootfs without inheriting that installation's settings, the following procedure completes both debootstrap stages on an x86_64 Debian PC using QEMU's ARM64 execution support. See Debian's [cross-debootstrap guidance](https://wiki.debian.org/EmDebian/CrossDebootstrap) and the [debootstrap manual](https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html).

**PC**

```bash
sudo apt install debootstrap debian-archive-keyring qemu-user qemu-user-binfmt
cd ~/r8q-linux
sudo debootstrap --arch=arm64 --foreign \
  --include=systemd-sysv,udev,openssh-server,iproute2,util-linux,e2fsprogs,tar,ca-certificates,passwd \
  trixie clean-rootfs https://deb.debian.org/debian
printf '#!/bin/sh\nexit 101\n' | sudo tee clean-rootfs/usr/sbin/policy-rc.d > /dev/null
sudo chmod 755 clean-rootfs/usr/sbin/policy-rc.d
sudo chroot clean-rootfs /debootstrap/debootstrap --second-stage
sudo chroot clean-rootfs dpkg --print-architecture
sudo chroot clean-rootfs dpkg --audit
```

If the second stage fails with `Exec format error` when executing ARM64 programs, fix QEMU binfmt registration and complete the second stage. A rootfs that has completed only the foreign first stage is not a finished Debian installation. An ARM64 Linux PC does not need QEMU. Review both stages' results and `/debootstrap/debootstrap.log`.

The `policy-rc.d` file prevents package installation inside the chroot from starting services. Once the second stage succeeds, remove **only the temporary file created above**. Unmount any additional virtual filesystems you mounted in the rootfs before archiving it.

```bash
sudo rm clean-rootfs/usr/sbin/policy-rc.d
sudo tar --numeric-owner --acls --xattrs -cpf backup/debian-rootfs.tar \
  -C clean-rootfs .
tar -tf backup/debian-rootfs.tar > /dev/null
sha256sum backup/debian-rootfs.tar
```

This completed rootfs can supply the installation tools and ARM64 libraries in [section 9](#port-9). If its e2fsprogs and libext2fs versions differ from the historical package version below, use the clean-rootfs tool collection method in that section to keep the tools and libraries consistent.

If `/etc/apt/sources.list` is empty, populate it with the standard Debian repositories:

```text
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://security.debian.org/debian-security trixie-security main
```

The root account in a new rootfs may be locked. After installing the public key in [section 11](#port-11), check the account state and SSH access policy. Prepare a suitable administrator account or set a local account password as appropriate for your access policy. The clean-rootfs alternative still requires its own first-boot validation on r8q.

Package versions change over time. Record the ARM64 rootfs package inventory with `dpkg-query` and retain the archive hash. Do not install a Debian distribution kernel or GRUB for this procedure: the port uses the separately built r8q kernel in an Android boot image.

<a id="port-9"></a>

## 9 Prepare ARM64 installation tools and preserve firmware

### 9.1 Build a dynamically linked ARM64 tool bundle

A BusyBox-only initramfs needs Debian's mke2fs to create ext4 and GNU tar to restore ownership, ACLs, and extended attributes. The migrated rootfs contained the ext4 libraries but lacked the mke2fs executable. The working procedure extracted mke2fs and its configuration from an ARM64 e2fsprogs package, then obtained the loader, libraries, and GNU tar from the existing ARM64 rootfs archive. Do not substitute the x86_64 PC's executables or libraries.

In the commands below, `backup/debian-rootfs.tar` is an archive of a **completed ARM64 installation**. Its historical filename was `backup/debian13-with-lxc.tar`. If using the clean-rootfs alternative, complete its tool bundle separately as described below.

**PC: obtain the e2fsprogs package used by the verified installation**

```bash
cd ~/r8q-linux
mkdir -p native-tools
wget -O e2fsprogs-arm64.deb \
  'https://deb.debian.org/debian/pool/main/e/e2fsprogs/e2fsprogs_1.47.2-3+b12_arm64.deb'
echo 'ebd315c483853fafe877e39c1f49bf725834d7af7249a98b727f2ef4fe01a5c4  e2fsprogs-arm64.deb' | \
  sha256sum -c -
dpkg-deb -x e2fsprogs-arm64.deb native-tools
```

This URL and hash identify the specific historical package. If it is no longer available at that location, or you choose a different version, verify the replacement's source, hash, and library compatibility. Keep mke2fs and libext2fs at the same version.

**PC: add the ARM64 loader, shared libraries, and GNU tar**

```bash
tar -xf backup/debian-rootfs.tar \
  -C native-tools --no-same-owner --wildcards \
  './usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1' \
  './usr/lib/aarch64-linux-gnu/libc.so.6' \
  './usr/lib/aarch64-linux-gnu/libext2fs.so.*' \
  './usr/lib/aarch64-linux-gnu/libcom_err.so.*' \
  './usr/lib/aarch64-linux-gnu/libe2p.so.*' \
  './usr/lib/aarch64-linux-gnu/libuuid.so.*' \
  './usr/lib/aarch64-linux-gnu/libblkid.so.*'
tar -xf backup/debian-rootfs.tar \
  -C native-tools --no-same-owner --wildcards \
  './usr/bin/tar' \
  './usr/lib/aarch64-linux-gnu/libacl.so.*' \
  './usr/lib/aarch64-linux-gnu/libselinux.so.*' \
  './usr/lib/aarch64-linux-gnu/libpcre2-8.so.*'
aarch64-linux-gnu-readelf -d native-tools/usr/sbin/mke2fs | grep NEEDED
aarch64-linux-gnu-readelf -d native-tools/usr/bin/tar | grep NEEDED
ls -l native-tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
  native-tools/usr/sbin/mke2fs native-tools/usr/bin/tar \
  native-tools/etc/mke2fs.conf
tar -cf native-tools-restore.tar -C native-tools .
sha256sum native-tools-restore.tar
python3 -m http.server 8000 --bind 192.168.77.2 --directory "$PWD"
```

The original procedure transferred an mke2fs bundle first, then added GNU tar and its libraries in a second transfer. The commands above assemble both into one bundle. Confirm that the archive uses the expected `./usr/...` paths. With a different rootfs version, check `DT_NEEDED` entries and transitive dependencies as well. Preserve both symbolic links and their target files.

Keep the HTTP server running in that PC terminal during the transfer.

**initramfs**

```sh
wget -O /run/native-tools-restore.tar http://192.168.77.2:8000/native-tools-restore.tar
sha256sum /run/native-tools-restore.tar
mkdir -p /tools
tar -xf /run/native-tools-restore.tar -C /tools
/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
  --library-path /tools/usr/lib/aarch64-linux-gnu \
  /tools/usr/sbin/mke2fs -V
/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
  --library-path /tools/usr/lib/aarch64-linux-gnu \
  /tools/usr/bin/tar --version
```

The hashes calculated before and after transfer must match. The observed versions were mke2fs 1.47.2 and GNU tar 1.35. The explicit loader path, `/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1`, points to the loader included in this bundle; the initramfs does not provide the standard interpreter path required by ordinary Debian executables. The formatting commands below also set `MKE2FS_CONFIG=/tools/etc/mke2fs.conf`.

### Collect tools from a clean rootfs

Instead of combining the historical package with the migrated rootfs libraries, collect the tools and libraries from the same `clean-rootfs` after completing both stages in section 8.2. This is an **alternative procedure**. Do not mix its assembly commands with those for `native-tools` above.

**PC**

```bash
cd ~/r8q-linux
mkdir -p native-tools-clean/usr/sbin native-tools-clean/usr/bin \
  native-tools-clean/usr/lib native-tools-clean/etc
sudo cp -a clean-rootfs/usr/lib/aarch64-linux-gnu native-tools-clean/usr/lib/
sudo cp -a clean-rootfs/usr/sbin/mke2fs native-tools-clean/usr/sbin/
sudo cp -a clean-rootfs/usr/bin/tar native-tools-clean/usr/bin/
sudo cp -a clean-rootfs/etc/mke2fs.conf native-tools-clean/etc/
aarch64-linux-gnu-readelf -d native-tools-clean/usr/sbin/mke2fs | grep NEEDED
aarch64-linux-gnu-readelf -d native-tools-clean/usr/bin/tar | grep NEEDED
sudo tar -cf native-tools-restore.tar -C native-tools-clean .
sha256sum native-tools-restore.tar
```

Copying the library directory preserves its symbolic links and dependencies. Add any required dependencies outside that directory. Test the tools on the device using the same `/tools` loader path shown above. Check the resulting archive size and available RAM in `/run` before transferring it.

### 9.2 Identify and preserve existing partitions

These device paths were observed on the installation used for this port. **Verify each partition's `PARTNAME` on your device rather than relying on the numbers alone.**

| Partition | Observed device | Use |
|---|---|---|
| userdata | `/dev/sda36` | Reformat as the Debian ext4 root filesystem |
| apnhlos | `/dev/sda19` | Reference when identifying vendor firmware images |
| modem | `/dev/sda20` | Mount read-only at `/vendor/firmware_mnt`; vfat |
| dsp | `/dev/sda21` | Mount read-only at `/vendor/dsp`; ext4 with `noload` |
| persist | `/dev/sda8` | Mount read-only at `/mnt/vendor/persist`; ext4 with `noload` |

Do not format the firmware, DSP, or persist partitions. Before erasing userdata, the verified procedure archived the files from these three partitions to the PC.

**initramfs**

```sh
mkdir -p /mnt/firmware /mnt/dsp /mnt/persist
mount -t vfat -o ro /dev/sda20 /mnt/firmware
mount -t ext4 -o ro,noload /dev/sda21 /mnt/dsp
mount -t ext4 -o ro,noload /dev/sda8 /mnt/persist
tar -cf /run/r8q-firmware.tar -C /mnt firmware persist dsp
sha256sum /run/r8q-firmware.tar
busybox httpd -p 192.168.77.1:8001 -h /run
```

**Separate PC terminal**

```bash
cd ~/r8q-linux
wget -O backup/r8q-firmware.tar http://192.168.77.1:8001/r8q-firmware.tar
tar -tf backup/r8q-firmware.tar > /dev/null
sha256sum backup/r8q-firmware.tar
```

Use the hashes to verify transfer between your device and PC. An archive from a different device is not expected to match a historical hash. Keep the device's own persist data; it contains calibration information that should not be replaced with another device's copy.

<a id="port-10"></a>

## 10 Format userdata and restore the rootfs

**This step erases Android userdata.** First retain readable boot, rootfs, and firmware backups on an external PC. Run this section from the booted rescue initramfs.

### 10.1 Verify the target

**initramfs**

```sh
cat /sys/class/block/sda36/uevent
cat /sys/class/block/sda36/size
cat /proc/mounts
```

The observed userdata partition reported `PARTNAME=userdata` and `224819160` sectors of 512 bytes each. If it is already mounted, inspect the current installation state first. Do not run the commands below if `/dev/sda36` is not your userdata partition.

### 10.2 Create ext4

First use `-n` to check the parameters without creating the filesystem:

```sh
MKE2FS_CONFIG=/tools/etc/mke2fs.conf \
/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
  --library-path /tools/usr/lib/aarch64-linux-gnu \
  /tools/usr/sbin/mke2fs -n -t ext4 -b 4096 -m 1 \
  -L debian-root -O ^orphan_file,^metadata_csum_seed /dev/sda36
```

For the kernel and e2fsprogs combination used here, disable `orphan_file` and `metadata_csum_seed` as in the verified installation. A newer host tool's default feature set may exceed what the older device kernel supports.

**Format after verifying the target and backups**

```sh
MKE2FS_CONFIG=/tools/etc/mke2fs.conf \
/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
  --library-path /tools/usr/lib/aarch64-linux-gnu \
  /tools/usr/sbin/mke2fs -F -t ext4 -b 4096 -m 1 \
  -L debian-root -O ^orphan_file,^metadata_csum_seed \
  -E nodiscard /dev/sda36
echo "mke2fs exit: $?"
mkdir -p /newroot
mount -t ext4 /dev/sda36 /newroot
blkid /dev/sda36
df -h /newroot
```

Require a zero mke2fs exit status, a successful ext4 mount, and a newly generated UUID. The verified installation created the filesystem across the full partition, reported as about 105 GiB, from the outset. There was no separate small root-image expansion step. Use the UUID generated on your device in fstab.

### 10.3 Transfer and restore with GNU tar

Download a large rootfs archive, such as the 6.5 GiB migration archive, onto userdata rather than the RAM-backed `/run` filesystem.

**initramfs**

```sh
wget -O /newroot/.debian-restore.tar http://192.168.77.2:8000/backup/debian-rootfs.tar
sha256sum /newroot/.debian-restore.tar
```

Restore only after its hash matches `backup/debian-rootfs.tar` on the PC.

```sh
/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
  --library-path /tools/usr/lib/aarch64-linux-gnu \
  /tools/usr/bin/tar --numeric-owner --same-owner --same-permissions \
  --acls --xattrs --xattrs-include='user.*' \
  --xattrs-include='security.capability' \
  -xpf /newroot/.debian-restore.tar -C /newroot
echo "rootfs restore exit: $?"
mkdir -p /newroot/dev /newroot/proc /newroot/sys \
  /newroot/run /newroot/tmp /newroot/config
chmod 1777 /newroot/tmp
sync
cat /newroot/etc/os-release
ls -l /newroot/sbin/init /newroot/usr/lib/systemd/systemd
df -h /newroot
```

List the directories explicitly as above for BusyBox sh. GNU tar must return zero, and `/sbin/init` must resolve to an executable systemd.

If Telnet stops accepting input, **do not repeat the format**. Open another PC terminal and check the USB interface address and ping. USB re-enumeration previously removed the host's temporary `192.168.77.2/30` address. After reconnecting, inspect `ps`, `/proc/mounts`, `blkid`, and the downloaded file to determine the current state before continuing.

<a id="port-11"></a>

## 11 Configure the first Debian boot

### 11.1 Bind virtual filesystems for chroot

**initramfs**

```sh
mount -o bind /dev /newroot/dev
mount -o bind /proc /newroot/proc
mount -o bind /sys /newroot/sys
ls -l /newroot/dev/null /newroot/dev/urandom
```

Without `/dev`, `ssh-keygen` and `sshd -t` fail with `Couldn't open /dev/null`, as observed during installation. These bind mounts support the installation checks below. If using section 8.2, finish the QEMU-assisted debootstrap second stage on the PC before archiving the rootfs. On subsequent device boots, the initramfs moves its mounts into the Debian root.

### 11.2 Configure fstab

Replace `ROOT_UUID` with the value just obtained from `blkid`.

```sh
ROOT_UUID='YOUR_USERDATA_EXT4_UUID'
mkdir -p /newroot/vendor/firmware_mnt /newroot/vendor/dsp /newroot/mnt/vendor/persist
cat > /newroot/etc/fstab <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime,errors=remount-ro 0 0
/dev/sda20 /vendor/firmware_mnt vfat ro,nofail 0 0
/dev/sda21 /vendor/dsp ext4 ro,noload,nofail 0 0
/dev/sda8 /mnt/vendor/persist ext4 ro,noload,nofail 0 0
EOF
```

The read-only mounts preserve the board paths used by the installation. If reducing the configuration by omitting Wi-Fi or remote-processor support, verify each driver's actual dependencies first. Because `nofail` permits boot to continue after a mount failure, check these mounts after the first boot. The root entry's fsck pass value of `0` also follows the verified configuration; choose an automatic filesystem-check policy separately for production use.

### 11.3 Configure the USB address and udev

**initramfs**

```sh
mkdir -p /newroot/etc/systemd/network
cat > /newroot/etc/systemd/network/10-r8q-usb.network <<'EOF'
[Match]
MACAddress=02:77:00:00:00:01

[Network]
Address=192.168.77.1/30
DHCP=no
LinkLocalAddressing=no
EOF
```

Using the same device MAC for the RNDIS and NCM functions allows this file to retain the static management address across either mode. LAN bridges and DHCP for a particular deployment are outside this baseline configuration.

The migrated chroot **did not have the udev package installed**. `systemd-networkd` was running, but the `udevadm` and `systemd-udevd` executables and the service unit were absent. Communication still worked through the address left by initramfs, while networkd reported the USB interface as `pending` with `Network File: n/a`. Starting or unmasking a service alone cannot fix missing package files.

Include udev while preparing the rootfs where possible. After migrating an existing rootfs, check it on the first native boot:

```bash
dpkg-query -W -f='${Package}: ${Status}\n' udev
ls -l /usr/bin/udevadm /usr/lib/systemd/systemd-udevd
systemctl is-active systemd-networkd systemd-udevd
systemctl status systemd-udevd.service --no-pager -l
networkctl status usb0 --no-pager
```

If udev is absent, establish the temporary USB Internet connection in [section 13](#port-13), then install it:

```bash
apt-get update
apt-get install udev
systemctl start systemd-udevd.service
udevadm trigger --action=add --subsystem-match=net
udevadm settle --timeout=15
networkctl reload
networkctl reconfigure usb0
networkctl status usb0 --no-pager
ip -4 -br addr show usb0
```

If APT cannot reach the Internet through that route, use an SSH reverse SOCKS tunnel. The following example connects an Internet-connected PC directly to the device over USB.

**Separate terminal on the Internet-connected PC**

```bash
ssh -i ~/.ssh/r8q-port-test -o ExitOnForwardFailure=yes \
  -R 127.0.0.1:1080 root@192.168.77.1
```

**Debian shell opened by that connection**

```bash
apt-get -o Acquire::http::Proxy=socks5h://127.0.0.1:1080 update && \
apt-get -o Acquire::http::Proxy=socks5h://127.0.0.1:1080 install udev
systemctl start systemd-udevd.service
udevadm trigger --action=add --subsystem-match=net
udevadm settle --timeout=15
networkctl reload
networkctl reconfigure usb0
networkctl status usb0 --no-pager
```

The proxy option applies only to these APT invocations. After installation and network-device initialization, the observed interface used its `.network` file and reached `configured / online`. Substitute the actual interface name if it is not `usb0`. If a service is independently masked, diagnose that separately from a missing package.

### 11.4 Prepare the first SSH login

Key authentication provides the first-boot access path for the headless device. Generate a key for this installation and restrict the SSH listener to the USB management address.

**PC**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/r8q-port-test
cp ~/.ssh/r8q-port-test.pub ~/r8q-linux/r8q-port-test.pub
```

**initramfs**

```sh
wget -O /run/r8q-port-test.pub http://192.168.77.2:8000/r8q-port-test.pub
mkdir -p /newroot/root/.ssh
cat /run/r8q-port-test.pub >> /newroot/root/.ssh/authorized_keys
chmod 700 /newroot/root/.ssh
chmod 600 /newroot/root/.ssh/authorized_keys
chown -R 0:0 /newroot/root/.ssh
```

Download the repository's [SSH configuration](../templates/debian/sshd_config.r8q) and [service unit](../templates/debian/r8q-ssh.service) from the PC's HTTP server into the new rootfs.

**initramfs**

```sh
mkdir -p /newroot/etc/ssh /newroot/etc/systemd/system
wget -O /newroot/etc/ssh/sshd_config.r8q \
  http://192.168.77.2:8000/templates/debian/sshd_config.r8q
wget -O /newroot/etc/systemd/system/r8q-ssh.service \
  http://192.168.77.2:8000/templates/debian/r8q-ssh.service
```

This configuration listens on the static USB address and disables password authentication. Enable one SSH startup method so that the existing `ssh.service` or `ssh.socket` does not conflict with it.

```sh
mkdir -p /newroot/run/sshd
chroot /newroot /usr/bin/ssh-keygen -A
chroot /newroot /usr/sbin/sshd -t -f /etc/ssh/sshd_config.r8q
chroot /newroot /usr/bin/systemctl --root=/ disable ssh.service
if [ -f /newroot/usr/lib/systemd/system/ssh.socket ]; then
    chroot /newroot /usr/bin/systemctl --root=/ disable ssh.socket
fi
chroot /newroot /usr/bin/systemctl --root=/ enable systemd-networkd.service r8q-ssh.service
chroot /newroot /usr/bin/systemctl --root=/ set-default multi-user.target
```

The conditional skips `ssh.socket` when that unit is absent. Require a zero exit status from the SSH configuration check. If a locked root account also prevents public-key login, prepare an appropriate administrator account or review the root account's state. Keep the intended key-authentication policy rather than enabling SSH password authentication as a workaround.

### 11.5 Build and flash the Debian-transition ramdisk

On the **PC**, change `BOOT_STAGE=rescue` to `BOOT_STAGE=debian` in `native-root/init`. Verify that the template's `ROOT_DEVICE=/dev/sda36` identifies userdata on your device. These variables are provided by the repository template; the original implementation replaced the Telnet wait loop after the working USB initialization with the Debian transition code. Build `native-debian.cpio` using the same procedure as section 5.4:

```bash
cd ~/r8q-linux
bash -n native-root/init
(
  set -o pipefail
  cd native-root
  find . -print0 | cpio --null -o --format=newc --owner=0:0 > ../native-debian.cpio
)
```

The successful installation **repacked the image with MagiskBoot from the running USB rescue shell**. Preserve the kernel and DTB from the verified rescue boot image and replace only its ramdisk. The commands below use this guide's `boot-native-rescue.img` name; the corresponding historical image was named `boot-native-debug3.img`.

**initramfs**

```sh
mkdir -p /run/r8q-debian-work
wget -O /run/magiskboot http://192.168.77.2:8000/magiskboot-arm64
chmod 755 /run/magiskboot
wget -O /run/r8q-debian-work/boot-base.img \
  http://192.168.77.2:8000/boot-native-rescue.img
wget -O /run/r8q-debian-work/ramdisk-new \
  http://192.168.77.2:8000/native-debian.cpio
cd /run/r8q-debian-work
/run/magiskboot unpack -h boot-base.img
cp ramdisk.cpio ramdisk-original.cpio
cp kernel kernel-original
cp dtb dtb-original
cp ramdisk-new ramdisk.cpio
/run/magiskboot repack boot-base.img /run/boot-debian.img
mkdir -p verify
cd verify
/run/magiskboot unpack -h /run/boot-debian.img
cmp ../kernel-original kernel
cmp ../dtb-original dtb
cmp ../ramdisk-new ramdisk.cpio
sha256sum /run/boot-debian.img
```

Re-extracting the result applies section 6's validation to the ramdisk replacement. Do not flash if any `cmp` fails. This device's base image exposes the DTB as a separate file during unpacking.

Retain the new image on the PC as well. Serve `/run` explicitly to avoid downloading from an HTTP server with the wrong document root, which previously produced a 404 response and an empty destination file.

**initramfs**

```sh
chmod 644 /run/boot-debian.img
busybox httpd -p 192.168.77.1:8002 -h /run
```

**Separate PC terminal**

```bash
cd ~/r8q-linux
wget -O boot-debian.img http://192.168.77.1:8002/boot-debian.img
ls -lh boot-debian.img
sha256sum boot-debian.img
```

Verify that the device and PC copies have matching sizes and hashes, then perform the partition identity and size checks in section 6 before writing. If the boot image is padded to the full partition size, the full partition hash can also be compared with the image hash.

**initramfs: write boot and perform the first reboot**

```sh
# First verify that /dev/sda23 is the boot partition on your device.
grep -qx 'PARTNAME=boot' /sys/class/block/sda23/uevent && \
dd if=/run/boot-debian.img of=/dev/sda23 bs=1048576 && sync
sha256sum /run/boot-debian.img /dev/sda23
```

Unmount the rootfs only after those two hashes match and the write verification is complete:

```sh
cd /
sync
umount /newroot/dev && \
umount /newroot/proc && \
umount /newroot/sys && \
umount /newroot && sync
```

After successful unmounting, reboot from the rescue shell. Debian systemd is not yet running, so this first reboot uses the SysRq method from the verified installation:

```sh
echo b > /proc/sysrq-trigger
```

Once Debian is running, use `systemctl reboot` for subsequent reboots.

The essential Debian transition is:

```sh
mount -t ext4 -o rw,noatime /dev/sda36 /newroot
mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/run /newroot/config
mount -o move /dev /newroot/dev
mount -o move /proc /newroot/proc
mount -o move /sys /newroot/sys
mount -o move /run /newroot/run
mount -o move /config /newroot/config
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec /bin/switch_root /newroot /sbin/init
```

The complete template also checks the root mount and `/sbin/init` and enters rescue mode on failure. Do not use the excerpt as a complete ramdisk init script. Moving `/config` retains the USB gadget's configfs state after switching to Debian.

<a id="port-12"></a>

## 12 Verify native Debian boot

**PC**

```bash
sudo ip link set enx027700000002 up
sudo ip addr replace 192.168.77.2/30 dev enx027700000002
ping -c 3 -W 2 192.168.77.1
ssh -i ~/.ssh/r8q-port-test root@192.168.77.1
```

Replace the interface name with the PC's actual USB NIC. Verify the SSH host key generated by your installation; another installation's fingerprint is not an acceptance criterion.

**Debian**

```bash
uname -a
ps -p 1 -o pid,comm,args
cat /etc/os-release
findmnt /
findmnt -t cgroup,cgroup2
cat /sys/fs/cgroup/cgroup.controllers
systemctl is-system-running
systemctl list-jobs --no-pager
systemctl --failed --no-pager
for r8q_mountpoint in /vendor/firmware_mnt /vendor/dsp /mnt/vendor/persist; do
  findmnt --mountpoint "$r8q_mountpoint"
done
ip -4 -br addr
```

A successful boot has Debian systemd as PID 1, an ext4 root filesystem on userdata, working SSH over USB, and no unfinished expected boot jobs. A `starting` status alone is not a completed boot. The first observed result was `starting` with zero failed units; the following check reported `No jobs running`.

The observed cgroup v2 controllers were `cpu io memory pids`. Check `/proc/config.gz` or the `.config` used for the kernel build when validating kernel features. Deployment-specific container names, bridges, convenience commands, and autostart settings are outside the porting procedure.

<a id="port-13"></a>

## 13 Download packages over USB

Wi-Fi support remains incomplete. Use the PC's Internet connection over USB while installing packages for the port. The management path in this procedure is `device 192.168.77.1 → PC 192.168.77.2 → upstream network`.

### 13.1 Temporary Internet sharing from a Linux PC

The verified temporary connection used IPv4 forwarding and NAT for the USB subnet. If an existing network manager already provides this route, use that configuration. The following rules are for temporary validation; do not add duplicate copies by repeatedly running them.

**PC**

```bash
R8Q_USB_IF=enx027700000002
sudo apt install iptables
sudo sysctl -w net.ipv4.ip_forward=1
r8q_uplink=$(ip -4 route get 1.1.1.1 | \
  awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
# Verify that this is the PC upstream interface.
printf '%s\n' "$r8q_uplink"
sudo iptables -I FORWARD 1 \
  -i "$R8Q_USB_IF" -o "$r8q_uplink" -s 192.168.77.0/30 -j ACCEPT
sudo iptables -I FORWARD 1 \
  -i "$r8q_uplink" -o "$R8Q_USB_IF" -d 192.168.77.0/30 \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -t nat -A POSTROUTING \
  -s 192.168.77.0/30 -o "$r8q_uplink" -j MASQUERADE
```

Set `R8Q_USB_IF` to the actual USB interface name on the PC. Check the host's existing firewall and forwarding policy. Persisting these settings for a production server is a separate deployment task.

**Debian: temporary default route**

```bash
USB_DEV=usb0
ip route replace default via 192.168.77.2 dev "$USB_DEV"
ip route
```

The interface name may change when switching to NCM. For a permanent route through the same USB host, add `Gateway=192.168.77.2` to the USB `.network` file's `[Network]` section. Identify the link by MAC address rather than relying on its name.

### 13.2 DNS and device time

Use a resolver available on the connected network. If `/etc/resolv.conf` points to a systemd-resolved stub while that service is not running, correct the resolver configuration to match the service you actually use.

The device clock previously returned to an old date, causing APT TLS certificate verification to fail. Set an initial time from an accurately synchronized PC before retrying.

**PC**

```bash
ssh -i ~/.ssh/r8q-port-test root@192.168.77.1 \
  "date -u -s '@$(date +%s)'"
```

**Debian**

```bash
date -Is
getent ahostsv4 deb.debian.org
apt update
```

Package downloads succeeded after correcting the clock. Keep TLS certificate verification enabled. If package installation does not start services after native boot, also check for a leftover chroot policy file:

```bash
cat /usr/sbin/policy-rc.d
```

The observed file contained only `#!/bin/sh` and `exit 101`, a restriction used during chroot installation. If yours is the same temporary file, preserve a copy, remove it from the active path, and start the required services:

```bash
if [ -f /usr/sbin/policy-rc.d ]; then
    mv /usr/sbin/policy-rc.d /root/policy-rc.d.before-native
fi
apt install systemd-timesyncd
systemctl enable --now systemd-timesyncd.service
```

If `policy-rc.d` contains another policy, review that policy before changing it. If udev is missing, follow section 11.3 to install it and retrigger network-device initialization.

<a id="port-14"></a>

## 14 USB NCM transmit aggregation

Apply this after native Debian boot and basic USB access work. Keep a known-good RNDIS boot image on the host PC so that USB access can be restored.

### 14.1 What the patch changes

The included [r8q-ncm-tx-aggregation.patch](../patches/r8q-ncm-tx-aggregation.patch) modifies only `drivers/usb/gadget/function/f_ncm.c`. It collects multiple outgoing Ethernet frames into one NCM Transfer Block (NTB) and submits the block when the datagram limit or host-negotiated transfer-size limit is reached. The datagram limit is 32. For sparse traffic, a 300µs timer requests a flush of the pending aggregate. This timer is not an upper bound on total USB transfer time or round-trip latency. The `u_ether.c` and `u_ether.h` snapshots document the existing multiframe and flush support; the patch does not modify them.

The `sources` directory contains the three original files, and `patches` contains the patch. Both `patch --dry-run -p1` and `git apply --check` passed against these snapshots. These checks establish applicability to the supplied files, not a successful full kernel build or device stability.

Historical device testing used a transmit-aggregation patch with the same filename. Its complete diff and SHA256 were not retained, so byte-for-byte identity with the patch currently included here cannot be established. The performance figures below are **historical measurements of that aggregation-enabled kernel**. They are not results from a fresh device test of the patch in this repository. See [provenance and validation scope](../PROVENANCE.md).

### 14.2 Apply and build

Copy the patch from `patches` to `~/r8q-linux/r8q-ncm-tx-aggregation.patch`. Use the pinned kernel source, toolchain, and existing `out-native/.config` from the preceding sections.

**Host PC**

```bash
cd ~/r8q-linux/kernel
mkdir -p ../backup
cp -a drivers/usb/gadget/function/f_ncm.c \
  ../backup/f_ncm.c.before-tx-aggregation
git apply --check ../r8q-ncm-tx-aggregation.patch
git apply ../r8q-ncm-tx-aggregation.patch
git diff --check
git diff --stat
grep -E '^CONFIG_USB_(F_NCM|CONFIGFS_NCM|CONFIGFS_RNDIS)=' \
  ../out-native/.config
set -o pipefail
make -j6 O="$HOME/r8q-linux/out-native" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
  Image Image.gz 2>&1 | tee ../build-ncm.log
```

All three USB options were `=y` in the tested configuration. If they differ, enable `USB_CONFIGFS_NCM`, run `olddefconfig`, and verify its `USB_F_NCM` dependency and the RNDIS recovery path.

The historical build printed `secgetspf: No such file or directory` but continued to produce `Image`. Judge success by the build exit status, the new kernel output, and comparison with the kernel re-extracted from the boot image. The `pipefail` setting prevents a successful `tee` process from hiding a failed build.

Put the new kernel into a **known-good RNDIS Debian boot image**. Keep its RNDIS ramdisk. Follow [section 6](#port-6) to replace only `kernel`, then re-extract the image and confirm that the DTB and ramdisk still match the originals.

### 14.3 Switch to NCM manually

The script at [templates/debian/r8q-usb-mode.sh](../templates/debian/r8q-usb-mode.sh) is based on the tested switching script, with installation paths and basic USB access settings prepared for this guide. Install it as `/usr/local/sbin/r8q-usb-mode` and make it executable.

**Transfer the templates from the host PC**

```bash
cd ~/r8q-linux
scp -i ~/.ssh/r8q-port-test templates/debian/r8q-usb-mode.sh \
  root@192.168.77.1:/usr/local/sbin/r8q-usb-mode
scp -i ~/.ssh/r8q-port-test templates/debian/r8q-usb-ncm.service \
  templates/debian/r8q-usb-ncm.timer root@192.168.77.1:/etc/systemd/system/
```

The script copies the fixed RNDIS MAC addresses to the NCM function, unbinds the UDC, replaces the USB function link, and binds the UDC again. USB re-enumeration can disconnect SSH. Run the switch as a systemd service so that it can finish independently of the SSH session. First schedule a return to RNDIS after 120 seconds.

**Debian**

```bash
chmod 755 /usr/local/sbin/r8q-usb-mode
sh -n /usr/local/sbin/r8q-usb-mode
systemd-run --unit=r8q-ncm-rollback --on-active=120s \
  /usr/local/sbin/r8q-usb-mode rndis
systemd-run --unit=r8q-ncm-switch --collect \
  /usr/local/sbin/r8q-usb-mode ncm
```

**Host PC — after USB re-enumeration**

```bash
lsusb -t
ip -br link
sudo ip link set enx027700000002 up
sudo ip addr replace 192.168.77.2/30 dev enx027700000002
ping -c 3 -W 2 192.168.77.1
ssh -i ~/.ssh/r8q-port-test root@192.168.77.1
```

Check for `cdc_ncm` and the actual link speed. The tested USB 3 port and cable negotiated `5000M`; another PC port negotiated `480M`. After confirming the switch and reconnecting, cancel the rollback timer on **Debian**.

```bash
systemctl stop r8q-ncm-rollback.timer
```

One test did not start because the script lacked executable permission: `test -x` failed and skipped the remaining commands, including timer creation. A `timer not loaded` message alone does not show that an automatic rollback has happened. Check permissions, the USB configuration symlink, and the host driver.

### 14.4 Switch automatically after boot

**A boot image that configured NCM directly in initramfs did not enumerate over USB.** Its logs reached the new kernel, `/init`, and the transition to Debian. That failure alone does not establish a kernel panic or a defect in the aggregation patch.

The successful path kept the RNDIS ramdisk, booted Debian, and then switched to NCM. Install [r8q-usb-ncm.service](../templates/debian/r8q-usb-ncm.service) and [r8q-usb-ncm.timer](../templates/debian/r8q-usb-ncm.timer) under `/etc/systemd/system`. The service calls `/usr/local/sbin/r8q-usb-mode`, and the timer uses the tested `OnBootSec=20s` delay.

**Debian**

```bash
systemctl daemon-reload
systemctl enable r8q-usb-ncm.timer
sync
systemctl reboot
```

After about 30 seconds, check the host USB driver and ping the device. Reconnect and inspect the service result.

```bash
systemctl status r8q-usb-ncm.service --no-pager -l
journalctl -b -u r8q-usb-ncm.service --no-pager
```

The historical reboot test confirmed `cdc_ncm, 5000M` and ping with no packet loss. Repeated-boot and long-duration stability tests were not recorded.

To disable automatic switching:

```bash
systemctl disable --now r8q-usb-ncm.timer
```

Stopping the timer leaves an existing NCM connection in place. Use the manual switching service to return to RNDIS immediately. With the timer disabled, the next boot stays on RNDIS.

### 14.5 Measure both directions

**Debian**

```bash
iperf3 -s -B 192.168.77.1
```

**Host PC or USB-connected Linux host**

```bash
iperf3 -c 192.168.77.1
iperf3 -c 192.168.77.1 -R
```

The first command sends from the host to the device, measuring **device receive** throughput. `-R` measures **device transmit** throughput. Historical SuperSpeed results were:

| Configuration | Device receive | Device transmit |
|---|---:|---:|
| NCM before aggregation changes | 2.24Gbps | 744Mbps |
| Historically tested aggregation-enabled NCM | 2.26Gbps | 1.30Gbps |

Transmit figures use the receiver's reported rate. The modified-kernel transmit test reported zero retransmissions. These were 10-second measurements, not a guarantee of performance across hosts or cables or of long-term stability.

Moving the USB IRQ to CPU4 produced 718Mbps transmit throughput without a clear improvement. IRQ affinity changes, CPU governor changes, and parallelizing the DWC3 workqueue are not required steps in the successful port.

<a id="port-15"></a>

## 15 Turn off the boot display

The boot logo remained visible without Android's display userspace. Backlight, framebuffer blanking, and DPMS writes did not turn it off in the recorded tests. Setting a DRM mode and then allowing the program to exit did. Turning the screen off automatically is optional and is not required to boot Debian.

**Debian**

```bash
apt install libdrm-tests
modetest -M msm_drm -c
```

Query the connector ID and modes on the device. The tested connector was `DSI-1` with ID `29`, and this command turned the display off:

```bash
modetest -M msm_drm -s '29:1080x2400x60x185024cmdHS' </dev/null
```

Connector IDs are not a fixed interface, so verify the current values before automating this command. Although the mode name contains `60`, `modetest` reported a calculated refresh rate of `28.19Hz`. This test does not establish 60Hz display operation or GPU acceleration. The tested driver name was `msm_drm`; `msm` could not open the device.

<a id="port-16"></a>

## 16 Wi-Fi progress and unresolved issues

Wi-Fi is optional and is not a prerequisite for booting Debian over USB. The recorded work did not create `wlan0` or establish a wireless connection. This section reproduces the firmware, service, and driver initialization work up to that unresolved state.

### 16.1 Extract vendor firmware from the original super partition

The QCA6390 files were obtained from the logical `vendor` partition inside Android's `super` image after they were not found in the modem firmware partition. Read the original block device into a host-side backup, then extract vendor from that copy. This procedure does not write to the device's `super` partition.

The recorded `super` device was `/dev/sda29`. Check the partition name and size on the target device rather than assuming the same numbering. The host needs space for both the full backup and the extracted image.

**Host PC**

```bash
cd ~/r8q-linux
mkdir -p backup vendor-extract
ssh -i ~/.ssh/r8q-port-test root@192.168.77.1 \
  'cat /sys/class/block/sda29/uevent; blockdev --getsize64 /dev/sda29'
df -h .
ssh -T -i ~/.ssh/r8q-port-test root@192.168.77.1 \
  'dd if=/dev/sda29 bs=4194304 status=none' \
  > backup/super-current.img.part &&
mv backup/super-current.img.part backup/super-current.img
stat -c '%s bytes' backup/super-current.img
sha256sum backup/super-current.img
```

Verify `PARTNAME=super` and compare the copied file size with the block device size. The historical backup was `10,292,822,016` bytes. That is not an expected size for every storage variant.

The extraction used `extract_utils.lp.LpImage` from LineageOS extract-utils:

```bash
git clone --depth 1 \
  https://github.com/LineageOS/android_tools_extract-utils.git extract-utils
git -C extract-utils rev-parse HEAD > backup/extract-utils-commit.txt
PYTHONPATH="$PWD/extract-utils" python3 - <<'PY'
from extract_utils.lp import LpImage
with open("backup/super-current.img", "rb") as source:
    image = LpImage(source)
    image.extract_partition("vendor", "vendor-extract/vendor.img")
print("vendor 추출 완료")
PY
```

The exact historical extract-utils commit and Python dependency versions were not recorded. This code uses the API demonstrated by that extraction. If the API or dependencies have changed, consult the requirements of the version you use. Record its commit using the command above.

The extracted vendor filesystem was **EROFS**. An earlier attempt using the ext4-specific `noload` option failed. This read-only mount succeeded:

```bash
mkdir -p vendor-extract/mnt
sudo mount -t erofs -o loop,ro \
  vendor-extract/vendor.img vendor-extract/mnt
ls -lh vendor-extract/mnt/firmware/qca6390/
ls -lh vendor-extract/mnt/etc/wifi/WCNSS_qcom_cfg.ini
```

The firmware directory contained `amss20.bin`, `bdwlan.elf`, `bdwlan.elf1`, `bdwlan.elf2`, `m3.bin`, and `regdb.bin`. The configuration file was `etc/wifi/WCNSS_qcom_cfg.ini`. The vendor image and these firmware files are not included in this repository and must be obtained separately.

### 16.2 Connect the firmware request paths in Debian

**Host PC**

```bash
ssh -i ~/.ssh/r8q-port-test root@192.168.77.1 \
  'mkdir -p /vendor/firmware /vendor/etc/wifi'
scp -i ~/.ssh/r8q-port-test -r \
  vendor-extract/mnt/firmware/qca6390 \
  root@192.168.77.1:/vendor/firmware/
scp -i ~/.ssh/r8q-port-test \
  vendor-extract/mnt/etc/wifi/WCNSS_qcom_cfg.ini \
  root@192.168.77.1:/vendor/etc/wifi/
```

**Debian**

```bash
mkdir -p /lib/firmware/wlan/qca_cld
mkdir -p /data/vendor/conn /data/vendor/wifi
ln -sfn /vendor/firmware/qca6390 /lib/firmware/qca6390
ln -sfn /vendor/etc/wifi/WCNSS_qcom_cfg.ini \
  /lib/firmware/WCNSS_qcom_cfg.ini
ln -sfn /vendor/etc/wifi/WCNSS_qcom_cfg.ini \
  /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini
cat /sys/module/firmware_class/parameters/path
cat /sys/module/wlan/parameters/fwpath
ls -l /lib/firmware/qca6390/amss20.bin \
  /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini
```

The tested configuration had `firmware_class.path=/vendor/firmware_mnt/image` and an empty WLAN `fwpath`. The symlinks above exposed the actual QCA6390 files and configuration through the standard firmware search paths. A mounted modem firmware partition alone did not supply the required QCA6390 files.

After copying the files, unmount the host-side vendor image:

```bash
sudo umount vendor-extract/mnt
```

### 16.3 QRTR name service and inherited chroot service restrictions

The recorded Debian package version of `qrtr-tools` was `1.1-2+b1`. An inherited `policy-rc.d` returned 101 and blocked service startup during installation. Only the `qrtr_rx` kernel thread was running; it does not replace the `qrtr-ns` userspace service.

**Debian**

```bash
apt install qrtr-tools
dpkg -L qrtr-tools | grep -E 'qrtr-ns|service$'
systemctl list-unit-files '*qrtr*' --no-pager
pgrep -a qrtr
```

If the rootfs still has a chroot service-start restriction, inspect it. The tested repair moved that file to a backup path and started the service:

```bash
if [ -f /usr/sbin/policy-rc.d ]; then
  cat /usr/sbin/policy-rc.d
  mv /usr/sbin/policy-rc.d /root/policy-rc.d.before-native-qrtr
fi
systemctl enable --now qrtr-ns.service
systemctl status qrtr-ns.service --no-pager -l
timeout 5s qrtr-lookup
journalctl -k -b --no-pager |
  grep -iE 'wlan|cnss|qmi|qrtr|firmware|bdwlan|error|fail'
```

Recorded output confirmed `qrtr-ns.service` as `active (running)`, running `/usr/bin/qrtr-ns -f 1`. A WLAN firmware service lookup and QMI WLFW connection were also observed. This did not produce `wlan0`. For a test already stuck in a CNSS timeout or recovery state, the service was prepared before rebooting and trying again.

### 16.4 Change the CNSS Android-daemon wait bit

The historical change cleared only `ENABLE_DAEMON_SUPPORT` in `cnss_init_control_params`, in `drivers/net/wireless/cnss2/main.c`. It changed the condition that requested two clients, including the Android daemon. This is a **reference excerpt** of the recorded diff:

```diff
-               plat_priv->ctrl_params.quirks |= BIT(ENABLE_DAEMON_SUPPORT);
+               plat_priv->ctrl_params.quirks &= ~BIT(ENABLE_DAEMON_SUPPORT);
```

The statement is inside the `of_property_read_bool(..., "cnss-daemon-support")` condition. The change does not clear all other CNSS quirks or bypass driver probe checks. See [the CNSS reference note](../reference/cnss-daemon-support.md); it is not a completed Wi-Fi patch.

The CNSS source file is not among the three NCM snapshots, so applicability of this change was not checked against those files. Verify the code in the pinned kernel, retain the diff, and test it separately using the preceding build, kernel-replacement, and recovery procedures. It is not required for basic USB boot.

### 16.5 Confirmed failure and limits of the diagnosis

This kernel used `/dev/wlan` as its WLAN control device. The control code reads three input bytes, so the test wrote `ON\n`, including the newline:

```bash
printf 'ON\n' > /dev/wlan
echo "활성화 종료 코드: $?"
dmesg |
  grep -E 'R8Q-WIFI:|Failed to probe host driver|Number of clients'
ip -br link
```

The recorded result was:

```text
printf: write error: Invalid argument
활성화 종료 코드: 1
cnss: Number of clients is 1
R8Q-WIFI: sync_create ret=0
R8Q-WIFI: qdf_ctx ret=-14
cnss: Failed to probe host driver, err = -14
```

No `wlan0` appeared. The `R8Q-WIFI:` messages came from temporary diagnostic source changes and should not be expected from an unmodified kernel.

The retained `hdd_init_qdf_ctx` body returns `-EINVAL` when the QDF context is absent and `-EFAULT` when `cds_smmu_mem_map_setup(qdf_dev, ucfg_ipa_is_present())` fails. This supports tracing `qdf_ctx ret=-14` to the SMMU initialization failure path.

A more specific **WLAN/IPA SMMU state mismatch** was proposed during diagnosis, but the additional source excerpt used for that analysis was not preserved in the available evidence. The exact mismatch cannot be independently confirmed from this repository. Some claims about firmware-ready completion also depend on unavailable logs. They must be distinguished from the directly retained observations of one client and host probe error `-14`. See [the evidence limits](../PROVENANCE.md).

Wi-Fi work stopped at this point. The complete diagnostic diff and firmware are missing, so the historical `-dirty` kernel cannot be reconstructed in full from these materials alone. Further work should check firmware request paths, QRTR connectivity, CNSS readiness, QDF initialization, and netdev creation in that order. Firmware file presence or the exit status of a `/dev/wlan` write alone is not a success criterion.

<a id="port-17"></a>

## 17 Package and rootfs integrity

When reusing a chroot, incomplete rootfs files can resemble porting failures. In the recorded case, `/usr/sbin/groupadd` was an executable one-byte file. It returned zero without creating the group, causing `iperf3` package configuration to fail.

Check command resolution, package file integrity, and unfinished configuration:

```bash
type -a groupadd addgroup getent
ls -lh /usr/sbin/groupadd
dpkg -V passwd
dpkg --audit
getent group iperf3
```

Reinstalling `passwd` restored the account-management programs to normal-sized executables. After `dpkg --configure -a`, `dpkg --audit` reported no unfinished packages, and the `iperf3` group and account existed.

```bash
apt-get install --reinstall passwd
dpkg --configure -a
dpkg --audit
getent group iperf3
getent passwd iperf3
```

Repair files and packages for which damage is confirmed. The evidence does not establish which earlier operation created the one-byte file. This repair is not a required step for a fresh rootfs.

The missing `udev` package was also a rootfs configuration issue. If `systemd-udevd` is absent or the USB interface remains `pending`, follow the package and device-initialization checks in [section 11](#port-11).

<a id="port-18"></a>

## 18 Recovery and diagnosis

### 18.1 Restore a working boot image

Return to root ADB in recovery and restore a **known-good Debian RNDIS or native rescue boot image** stored on the host PC. Select an image appropriate for the stage being recovered, not merely a filename that looks familiar. The original Android boot backup from section 2 and a Debian RNDIS boot image serve different purposes.

**Host PC — replace the path with the chosen known-good image.**

```bash
adb root
sha256sum backup/boot-good-rndis.img
adb push backup/boot-good-rndis.img /tmp/boot-restore.img
adb shell 'readlink -f /dev/block/by-name/boot'
adb shell 'dd if=/tmp/boot-restore.img of=/dev/block/by-name/boot bs=1048576 && sync'
adb shell sha256sum /dev/block/by-name/boot
```

Before writing, verify the target partition and image size as described in [section 6](#port-6). After writing, compare the boot partition hash with the chosen image hash. Restoring boot does not recover Android data already removed by formatting userdata. After Debian installation, use a known-good `boot-native-rescue.img` or RNDIS `boot-debian.img` to restore access.

One recovery attempt returned to recovery after `adb reboot`. In that case, select `Reboot system now` in recovery and verify an actual system boot. A connectivity failure alone is not a reason to format userdata again.

### 18.2 Read last_kmsg

**Host PC — connected to recovery over ADB**

```bash
mkdir -p ~/r8q-linux/debug-native
adb exec-out cat /proc/last_kmsg > ~/r8q-linux/debug-native/last_kmsg.txt
grep -aEn 'Linux version|Kernel command line|R8Q-NATIVE:|Failed to execute|No working init|not syncing|BUG:|Oops:|panic' \
  ~/r8q-linux/debug-native/last_kmsg.txt
```

The `/init` template writes `R8Q-NATIVE:` markers to `/dev/kmsg`. Use them with the kernel build identifier to locate progress through kernel startup, USB initialization, and the transition to Debian.

The recorded `last_kmsg` contained multiple boots and bootloader messages. Identify one boot interval before drawing conclusions. If `last_kmsg` is unavailable, check other logging facilities provided by the kernel, such as pstore.

### 18.3 First checks by symptom

| Symptom | First checks |
|---|---|
| An old uname appears in recovery | It may describe recovery's own kernel. Boot the system image before judging the result. |
| No USB device appears | Check `/init` markers, the initial `/dev/null` node, UDC presence and binding, raw Image, and DTB. |
| `ifname` is unnamed | Check that the script waits for the network interface after binding the UDC. |
| The host sees a NIC but ping fails | Check whether re-enumeration removed the host IPv4 address, then verify MAC and IP addresses at both ends. |
| SSH fails but rescue access works | Check rootfs init, sshd settings, keys and accounts, udev, and networkd. |
| networkd leaves USB pending | Check udev startup and triggers, the `.network` MAC match, and earlier matching files. |
| Only direct NCM boot fails | Return to the known-good RNDIS ramdisk and test delayed switching after Debian starts. |
| ext4 cannot be mounted | Verify userdata identity, mke2fs completion and exit status, and compatibility between ext4 features and the kernel. |
| The boot logo remains visible | Query the DRM connector and mode, then use the modetest procedure in section 15. |
| CNSS progresses but wlan0 is absent | Check QDF probe error `-14` and its SMMU initialization path. The exact IPA/WLAN mismatch remains unconfirmed. |

<a id="port-19"></a>

## 19 Completion checks and retained artifacts

- [ ] Record the pinned kernel commit and toolchain version.
- [ ] Keep the original boot image, kernel configuration, and DTB on the host PC and verify their hashes.
- [ ] Verify standalone RNDIS rescue boot before changing userdata.
- [ ] Verify userdata PARTNAME, size, and mount state.
- [ ] Verify ext4 features and completed formatting, the transferred rootfs hash, and tar exit status.
- [ ] Confirm systemd as PID 1, ext4 as the root filesystem, and working SSH, udev, and networkd.
- [ ] Verify USB access after reboot.
- [ ] If using NCM, verify delayed switching from RNDIS and traffic in both directions.
- [ ] Record Wi-Fi, GPU acceleration, and video acceleration as incomplete or unverified where appropriate.

Keep these artifacts together:

```text
Kernel commit / toolchain commit and version
running.config / final out-native/.config
Complete git diff / build logs
Original boot / rescue boot / Debian RNDIS boot
Final kernel and DTB / ramdisk cpio / original init
BusyBox and magiskboot versions and hashes
Debian rootfs hash and package inventory
Partition table and root UUID
Final udev, network, SSH, and NCM unit configuration
```

**Host PC — example**

```bash
cd ~/r8q-linux/kernel
git rev-parse HEAD > ../backup/kernel-commit.txt
git diff --binary > ../backup/native-kernel-changes.patch
cp ../out-native/.config ../backup/native.config
cd ..
sha256sum boot-native-rescue.img boot-debian.img \
  busybox-arm64 magiskboot-arm64 > backup/final-artifacts.sha256
```

`git diff` does not include untracked files. Retain new source and configuration files separately and record them in an inventory. Preserve versions and hashes for the toolchain, firmware, binaries, and rootfs as well.

**Debian — package inventory**

```bash
dpkg-query -W -f='${binary:Package}\t${Version}\n' > /root/port-package-versions.tsv
```

Personal hostnames, DNS settings, LAN bridges, shell aliases, container administration, log-retention limits, and an 80% charging policy are outside the requirements for reproducing the basic port.

<a id="port-20"></a>

## 20 References

[PROVENANCE.md](../PROVENANCE.md) describes the source snapshots, artifact checks, historical device observations, and missing evidence. Historical measurements and source-based diagnoses are distinguished from validation performed on the files in this repository.

- [LineageOS kernel repository](https://github.com/LineageOS/android_kernel_samsung_sm8250) — kernel source used by the port. Use the pinned commit specified in this guide rather than the current branch tip.
- [Magisk Tools](https://topjohnwu.github.io/Magisk/tools.html) — boot unpack/repack and cpio command formats.
- [Linux USB gadget configfs](https://www.kernel.org/doc/html/v5.10/usb/gadget_configfs.html) — USB gadget configuration and UDC binding.
- [Debian debootstrap](https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html) — an alternative way to create a fresh Debian rootfs.
