# Samsung r8q에서 Debian 직접 부팅

[English](README.md) · [한국어](README.ko.md)

**Samsung Galaxy S20 FE 5G `r8q`에서 Debian 13 arm64를 네이티브로 부팅하는 포팅 문서와 소스 발췌, 설정 예제**입니다. LineageOS 커널을 재빌드하고 기존 삼성 부팅 경로를 유지합니다.

작업 기록의 기기는 **SM-G781N, 메모리 6GB**입니다. downstream Linux 4.19 커널을 사용하는 헤드리스 Linux 호스트 구성이며, 다른 r8q 모델에서는 파티션과 하드웨어를 따로 확인해야 합니다.

**[한국어 포팅 가이드](docs/porting-guide.ko.md) 또는 [영어 포팅 가이드](docs/porting-guide.en.md)부터 읽어 주세요.** 백업, 커널 빌드, initramfs, rootfs 설치, USB 접속, 검증과 복구 절차를 다룹니다.

## 부팅 경로

```text
삼성 부트로더
  → boot 파티션의 Android boot image v2
  → 재빌드한 LineageOS 커널과 원본 DTB
  → USB RNDIS를 구성하는 BusyBox initramfs
  → userdata ext4를 /newroot에 마운트
  → switch_root로 Debian systemd 시작
  → 선택적으로 부팅 후 20초에 USB NCM 전환
```

기존 Android boot 이미지 형식을 사용합니다. UEFI와 GRUB은 이 경로에 포함하지 않습니다.

## 기록에서 확인한 상태

| 항목 | 상태 |
|---|---|
| Debian 직접 부팅 | systemd가 PID 1, userdata ext4를 루트로 사용 |
| USB RNDIS | 설치·복구 셸 및 Debian SSH 접속 성공 |
| USB NCM | Debian 시작 후 전환 성공, 재부팅 후 지연 전환도 확인 |
| NCM 성능 | 기록의 10초 시험에서 기기 수신 약 **2.26Gbps**, 송신 약 **1.30Gbps** |
| 컨테이너 기반 기능 | namespace 추가, cgroup v2 `cpu io memory pids`, arm64 Debian LXC 부팅 확인 |
| 화면 | 문서의 `modetest` 모드 설정 방법으로 화면 꺼짐 확인 |
| Wi-Fi | **미완료**. host driver probe `-14` 오류, 정상 `wlan0` 생성 실패 |
| GPU와 영상 가속 | 장치 노드는 확인했지만 Debian에서 가속 동작은 미검증 |

성능 수치는 당시 작업에서 집계 수정을 적용한 커널의 결과입니다. 당시 패치의 정확한 해시가 보존되지 않아, 현재 포함한 패치를 새로 실기기 검증한 결과로 보지는 않습니다. 장기간 안정성도 확정하지 않았습니다. [자료 출처와 검증 범위](PROVENANCE.ko.md)를 참고하세요.

## 기준 환경

| 항목 | 기록의 값 |
|---|---|
| 시작 환경 | 루팅한 LineageOS `23.0-20251206-NIGHTLY-r8q` |
| 커널 저장소 | [LineageOS/android_kernel_samsung_sm8250](https://github.com/LineageOS/android_kernel_samsung_sm8250) |
| 커널 커밋 | `29f575b64b2d2beb802d3e549fdf2837c50deaff` |
| 커널 계열 | `4.19.325-cip124-st8-perf-native` |
| 툴체인 | Android `clang-r547379`, Clang/LLD 20.0.0 |
| 빌드 PC | Debian 13, x86_64 |
| boot 이미지 | header v2, page size 4096, raw `Image`, 원본 별도 DTB, gzip ramdisk |

## 준비할 자료

부트로더 잠금이 해제된 기기, root recovery와 ADB 접근, 외부에 보관한 원래 boot 이미지와 커널 설정, 일치하는 전체 커널 소스와 툴체인, 정적 arm64 BusyBox와 magiskboot, arm64 Debian rootfs가 필요합니다. 기기별 펌웨어와 캘리브레이션 데이터도 보존합니다.

**userdata를 포맷하면 그 안의 chroot를 포함한 Android 사용자 데이터가 삭제됩니다.** 저장소를 바꾸기 전에 RAM에서 동작하는 RNDIS rescue 부팅부터 검증합니다. 문서의 파티션 번호와 UUID는 한 기기의 관찰값이므로 쓰기 전에 자신의 기기에서 확인합니다.

이 저장소의 커널 소스는 세 파일의 발췌본입니다. 전체 커널이나 바로 플래시할 이미지는 포함하지 않습니다. 원본 boot·DTB, 전체 `.config`, rootfs, 펌웨어와 도구 바이너리가 없으므로 저장소만으로 당시 이미지와 바이트 단위로 같은 결과를 만들 수는 없습니다.

## 재현 순서

1. 현재 boot 이미지, 커널 설정, rootfs와 기기별 펌웨어를 백업합니다.
2. 고정한 기준 커널을 빌드하고 native 부팅과 namespace 옵션을 추가합니다.
3. RNDIS rescue initramfs를 부팅해 USB 셸을 확인합니다.
4. userdata를 ext4로 준비하고 Debian을 복원한 뒤 첫 USB SSH 접속을 구성합니다.
5. PID 1 systemd, 루트 저장소, udev, 네트워크와 재부팅 후 USB 재접속을 확인합니다.
6. 필요하면 NCM 패치를 적용합니다. 검증된 RNDIS ramdisk를 유지하고 Debian 시작 후 NCM으로 전환합니다.

새 debootstrap rootfs 제작과 통합 템플릿은 추가 실기기 검증이 필요한 절차로 표시했습니다. 미완료 Wi-Fi 조사는 정상 동작하는 USB 부팅 경로와 분리했습니다. 개인 DNS, LAN 브리지 구성, 셸 별칭, 서비스 배치, 충전 상한 선호는 포팅의 필수 조건이 아닙니다.

## 파일 구성

```text
README.md / README.ko.md       프로젝트 개요
docs/                         한국어와 영어 상세 가이드
PROVENANCE.md / .ko.md         원본 해시와 검증 범위
patches/                      첨부 NCM 송신 집계 패치
sources/drivers/              변경하지 않은 커널 원본 세 파일
templates/initramfs/          RNDIS rescue 및 Debian 전환 init
templates/debian/             USB 주소, SSH, 지연 NCM 서비스
templates/append-boot-cmdline.py
reference/                    미완료 CNSS Wi-Fi 변경 참고
LICENSES/                     포함한 커널 소스의 라이선스 본문
SHA256SUMS                    저장소 파일 체크섬
```

## 포함 파일 확인

Linux PC에서 저장소 루트 기준으로 실행합니다.

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

macOS의 체크섬 명령은 `shasum -a 256 -c SHA256SUMS`입니다. 위 명령은 파일 무결성, 셸 문법과 패치 적용 가능성만 검사하며 커널을 빌드하거나 폰을 조작하지 않습니다.

init 템플릿의 기본값은 `BOOT_STAGE=rescue`입니다. 변경 전에 가이드를 읽고, 기기용 셸 스크립트를 PC에서 실행하지 마세요.

## 업로드와 출처

자신의 GitHub 저장소에 올리는 방법은 [업로드 안내](docs/upload.ko.md)에 있습니다. GitHub에서 개요가 보이도록 `README.md`를 저장소 루트에 둡니다.

포함한 커널 소스의 원저작권과 `GPL-2.0+` SPDX 표시는 유지했습니다. [외부 코드 출처](THIRD_PARTY_NOTICES.md)와 [라이선스 본문](LICENSES/GPL-2.0.txt)을 참고하세요. 펌웨어, 개인 키, boot 이미지와 개인 대화 기록은 배포하지 않습니다.
