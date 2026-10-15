# Provenance and validation

[English](PROVENANCE.md) · [한국어](PROVENANCE.ko.md) · [README](README.md)

Prepared on 15 October 2026 from porting records dated 7–8 October 2026 and the supplied NCM source snapshot and patch. The original records contain personal settings and device identifiers and are not redistributed.

## Evidence levels

| Level | Meaning in this repository |
|---|---|
| Recorded device result | A command output or explicit result confirmation is preserved in the porting record |
| Adapted procedure | Commands or templates consolidated from the working sequence; the consolidated file needs its own device validation |
| Additional procedure | A new route, such as a clean debootstrap/QEMU rootfs; not validated on this device in the record |
| Unresolved diagnosis | An investigation that did not produce a working feature or lacks the underlying diagnostic output |

The recorded native boot used a migrated Debian chroot. The clean rootfs route is an additional procedure. The shared `init-rndis.sh` combines rescue and Debian modes into one template; this exact consolidated file was not flashed during documentation preparation.

## Preserved source files

Two C files and one header are copied without content changes. Their original copyright and SPDX notices remain intact. The supplied NCM patch is also unchanged.

| File | SHA256 |
|---|---|
| `sources/drivers/usb/gadget/function/f_ncm.c` | `79d1d7258ff05c0e053f9d42feeedd33e7105e51ffcf54881cf9bf9e324254f3` |
| `sources/drivers/usb/gadget/function/u_ether.c` | `d14533b85069ef897823b0fc3ce6d4163e2d595d29033a174ff9762f776f559b` |
| `sources/drivers/usb/gadget/function/u_ether.h` | `388379af4f9cfad042fc960080f5afbff5302368276b7fd27d7c0f36468a1632` |
| `patches/r8q-ncm-tx-aggregation.patch` | `4b7a0c392d9d280ba52d5fd41734345dc1e83ffa116994d20663b8fc301f7890` |

The source archive supplied during preparation had SHA256 `8a95ad9dbca0f024f01433b36fde4fe99ba4685ec80f50c3249859c914980f59`. Its three files are expanded under `sources`; the duplicate archive is omitted.

The recorded full-kernel baseline was `LineageOS/android_kernel_samsung_sm8250` at `29f575b64b2d2beb802d3e549fdf2837c50deaff`. That baseline identifier does not reconstruct every later uncommitted Wi-Fi/debug change. The three-file snapshot is not the complete corresponding kernel tree.

## NCM results and limits

The record shows an aggregation-modified kernel building successfully, booting with the working RNDIS ramdisk, and switching to NCM after Debian started. Recorded 10-second tests reached about 2.26 Gbit/s device RX and 1.30 Gbit/s device TX. A delayed NCM switch after reboot was also observed.

The exact patch hash and complete diff from that device session were not preserved. The attached patch therefore cannot be proven byte-identical to the one used for those measurements. No new kernel build, flash, hardware benchmark, or long-duration stability test was performed while preparing this repository.

## Preparation checks

- Source and patch copies match their input hashes.
- `patch --dry-run -p1` and `git apply --check` succeed on the supplied source snapshot.
- The NCM patch changes only `f_ncm.c`.
- Shared shell templates and documented shell blocks pass syntax checks.
- The boot-header helper was checked for syntax, repeated invocation, and rejection of conflicting boot arguments.
- Local document links, public-package contents, and archive checksums were checked before packaging.

These checks do not establish runtime correctness, complete kernel compatibility, or a working clean-rootfs installation.

## Inputs not distributed

The original boot image and DTB, complete baseline and final kernel configurations, full kernel checkout, toolchain checkout, BusyBox/magiskboot binaries, rootfs, firmware, and vendor/super images must be acquired separately. Device-specific calibration data must remain associated with its own device.

The repository does not include personal hostnames, internal DNS servers, LAN bridge layouts, SSH keys, application deployments, container convenience aliases, log-retention preferences, or charging-limit settings.

## Shared-template adjustments

- The init script defaults to `BOOT_STAGE=rescue`; `debian` enables the documented root mount and `switch_root` path.
- The USB switch script is installed as `/usr/local/sbin/r8q-usb-mode`; the NCM service uses that same path.
- The USB network example matches the device MAC and uses only the temporary management subnet.
- The fstab example requires the reader's real userdata UUID and verified partition mapping.
- English and Korean guides share the same executable templates and patch.

The CNSS note documents an incomplete Wi-Fi experiment. Its original source file is not among the three supplied files, so that change has not been applicability-tested here. The direct QDF `-14` failure is recorded; the exact deeper WLAN/IPA SMMU mismatch cannot be independently confirmed without the missing diagnostic output.
