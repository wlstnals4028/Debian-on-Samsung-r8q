# Debian on Samsung r8q

[English](README.md) · [한국어](README.ko.md)

Porting notes, source excerpts, and configuration templates for booting **Debian 13 arm64 directly on the Samsung Galaxy S20 FE 5G (`r8q`)**, using a rebuilt LineageOS kernel and the existing Samsung boot chain.

The recorded device was an **SM-G781N with 6 GB RAM**. This is a downstream Linux 4.19 port for a headless Linux host. Other r8q variants need their own partition and hardware checks.

**Start with the [English porting guide](docs/porting-guide.en.md) or the [Korean porting guide](docs/porting-guide.ko.md).** They cover backups, kernel builds, initramfs, rootfs installation, USB access, verification, and recovery.

## Boot path

```text
Samsung bootloader
  → Android boot image v2 in the boot partition
  → rebuilt LineageOS kernel + original DTB
  → BusyBox initramfs with USB RNDIS
  → userdata ext4 mounted as /newroot
  → switch_root into Debian systemd
  → optional USB NCM switch 20 seconds after boot
```

This path uses the existing Android boot image format. UEFI and GRUB are not part of it.

## Recorded status

| Component | Status |
|---|---|
| Native Debian boot | Debian systemd as PID 1, root on userdata ext4 |
| USB RNDIS | Working installation/rescue shell and Debian SSH access |
| USB NCM | Working after Debian starts; delayed switch also observed after reboot |
| NCM throughput | Device RX about **2.26 Gbit/s**, TX about **1.30 Gbit/s** in recorded 10-second tests |
| Container foundations | Namespaces added; cgroup v2 `cpu io memory pids`; an arm64 Debian LXC boot was observed |
| Display | Screen blanking observed with the documented `modetest` mode-setting method |
| Wi-Fi | **Incomplete**; host driver probe fails with `-14`, no working `wlan0` |
| GPU and video acceleration | Device nodes observed; Debian acceleration not validated |

The throughput results belong to the aggregation-modified kernel in the original device session. The exact patch hash from that session was not preserved, so those results are not a fresh hardware validation of the patch included here. Long-term stability has not been established. See [provenance and validation](PROVENANCE.md).

## Baseline

| Item | Recorded value |
|---|---|
| Starting system | Rooted LineageOS `23.0-20251206-NIGHTLY-r8q` |
| Kernel repository | [LineageOS/android_kernel_samsung_sm8250](https://github.com/LineageOS/android_kernel_samsung_sm8250) |
| Kernel commit | `29f575b64b2d2beb802d3e549fdf2837c50deaff` |
| Kernel release family | `4.19.325-cip124-st8-perf-native` |
| Toolchain | Android `clang-r547379`, Clang/LLD 20.0.0 |
| Build host | Debian 13, x86_64 |
| Boot image | Header v2, 4096-byte pages, raw `Image`, original separate DTB, gzip ramdisk |

## What you need

Prepare an unlocked device with working root recovery/ADB access, an external copy of its boot image and kernel configuration, the matching full kernel source and toolchain, static arm64 BusyBox and magiskboot, and an arm64 Debian rootfs. Preserve device-specific firmware and calibration data.

**Formatting userdata erases Android user data, including any chroot stored there.** Validate the RAM-only RNDIS rescue boot before changing storage. Partition numbers and filesystem UUIDs in the guide are observations from one device; verify your own device before writing.

This repository contains three kernel source excerpts, not the full kernel or a ready-to-flash image. Original boot/DTB, the full `.config`, rootfs, firmware, and tool binaries are not included. A byte-identical rebuild of the recorded image is therefore not possible from this repository alone.

## Follow the guide

1. Back up the current boot image, kernel configuration, rootfs, and device-specific firmware.
2. Build the pinned baseline kernel, then add the native boot and namespace options.
3. Boot the RNDIS rescue initramfs and verify USB shell access.
4. Prepare userdata ext4, restore Debian, and configure initial USB SSH access.
5. Verify Debian systemd as PID 1, root storage, udev, networking, and USB reconnection after reboot.
6. Optionally apply the NCM patch, keep the working RNDIS ramdisk, and switch to NCM after Debian starts.

The guide labels the clean debootstrap rootfs route and consolidated templates as additional procedures requiring device validation. Wi-Fi investigation is kept separate from the working USB boot path. Personal DNS, LAN bridge layouts, shell aliases, service deployment, and charging-limit preferences are not required by this port.

## Repository layout

```text
README.md / README.ko.md       Project overview
docs/                         Complete English and Korean guides
PROVENANCE.md / .ko.md         Source hashes and validation boundaries
patches/                      Supplied NCM TX aggregation patch
sources/drivers/              Three unmodified kernel source excerpts
templates/initramfs/          RNDIS rescue / Debian switch_root init
templates/debian/             USB networking, SSH, and delayed NCM units
templates/append-boot-cmdline.py
reference/                    Incomplete CNSS Wi-Fi change notes
LICENSES/                     License text for included kernel excerpts
SHA256SUMS                    Checksums for repository files
```

## Check the included files

From the repository root on a Linux PC:

```sh
sha256sum -c SHA256SUMS
sh -n templates/initramfs/init-rndis.sh
sh -n templates/debian/r8q-usb-mode.sh
(
  cd sources
  patch --dry-run -p1 -i ../patches/r8q-ncm-tx-aggregation.patch
)
git apply --check --directory=sources patches/r8q-ncm-tx-aggregation.patch
```

On macOS, use `shasum -a 256 -c SHA256SUMS` for checksums. These commands check file integrity, shell syntax, and patch applicability. They do not build a kernel or interact with a phone.

The init template defaults to `BOOT_STAGE=rescue`. Read the guide before changing it. Do not run either device-side shell script on your PC.

## Upload and attribution

To publish these files in your own repository, follow [the upload instructions](docs/upload.en.md). Keep `README.md` at the repository root so GitHub displays it automatically.

Included kernel excerpts retain their original copyright notices and `GPL-2.0+` SPDX identifiers. See [third-party notices](THIRD_PARTY_NOTICES.md) and the [license text](LICENSES/GPL-2.0.txt). No firmware, private keys, boot images, or personal conversation logs are distributed here.
