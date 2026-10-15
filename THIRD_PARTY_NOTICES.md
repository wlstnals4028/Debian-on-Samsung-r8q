# Third-party notices

## Kernel source excerpts

The three files under `sources/drivers/usb/gadget/function/` retain their original `SPDX-License-Identifier: GPL-2.0+` notices. This identifier means GNU GPL version 2 or later under the [Linux kernel licensing rules](https://www.kernel.org/doc/html/latest/process/license-rules.html).

The preserved file headers credit Nokia Corporation, David Brownell, Robert Schwebel, and Benedikt Spranger, as applicable to each file. Original contact and copyright lines are left unchanged. These excerpts were supplied with the porting materials; the recorded full-kernel baseline is [LineageOS/android_kernel_samsung_sm8250](https://github.com/LineageOS/android_kernel_samsung_sm8250), commit `29f575b64b2d2beb802d3e549fdf2837c50deaff`.

`patches/r8q-ncm-tx-aggregation.patch` is the unchanged supplied modification to `f_ncm.c`. It is not attributed to the upstream authors as their modification. No new author identity has been invented for the supplied patch. See [provenance](PROVENANCE.md) for hashes and verification limits.

The GPL v2 text is included in [LICENSES/GPL-2.0.txt](LICENSES/GPL-2.0.txt), copied from the [Linux kernel license-text file](https://raw.githubusercontent.com/torvalds/linux/master/LICENSES/preferred/GPL-2.0). Its SPDX metadata covers both the version-2-only and version-2-or-later identifiers. The included file notices determine the applicable option; the metadata does not replace those notices.

This package does not assign a new repository-wide license to documentation and helper files or override existing file-specific licenses.

## External projects

The guides reference Debian, LineageOS, Magisk, Android's Clang prebuilts, QEMU, and Linux USB gadget documentation. Referenced repositories and download links do not imply endorsement by those projects. Their binaries, firmware, rootfs images, and complete source trees are not bundled here.

## 한국어 안내

포함한 커널 소스 세 파일의 `GPL-2.0+` SPDX 표시와 원저작권·연락처 주석을 보존했습니다. 파일별 원저작자는 해당 파일 헤더에 표시되어 있습니다. GPL v2 본문은 `LICENSES/GPL-2.0.txt`에 포함했습니다.

NCM 패치는 제공된 파일 그대로이며 upstream 원저작자가 작성한 수정이라고 표시하지 않습니다. 제공 자료에서 확인할 수 없는 새 작성자 이름도 만들지 않았습니다. 원본 해시와 검증 범위는 [한국어 출처 문서](PROVENANCE.ko.md)에 있습니다.

문서·도우미를 포함한 저장소 전체에 새 라이선스를 임의로 부여하거나 기존 파일별 라이선스를 바꾸지 않았습니다. 외부 프로젝트의 바이너리·펌웨어·rootfs·전체 소스는 포함하지 않았습니다.
