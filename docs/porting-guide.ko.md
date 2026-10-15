# Samsung r8q Debian 네이티브 포팅 가이드

[English](porting-guide.en.md) · [한국어](porting-guide.ko.md) · [README](../README.ko.md)

작성 기준일 2026년 10월 15일 · 작업 기록 2026년 10월 7일부터 8일까지

이 문서는 Galaxy S20 FE 5G r8q의 LineageOS 커널을 재빌드하고, Android boot 이미지의 ramdisk를 BusyBox initramfs로 교체한 다음, 내부 `userdata`에 설치한 Debian 13 arm64를 PID 1 systemd로 직접 부팅하는 절차를 설명한다. 부팅과 USB 접속부터 재현한 뒤 USB NCM 성능 개선을 적용한다.

최종 부팅 순서는 다음과 같다.

```text
삼성 부트로더
  → boot 파티션의 Android boot image v2
  → LineageOS 기반 Linux 4.19 커널과 기존 DTB
  → BusyBox /init
  → USB RNDIS 초기화
  → userdata ext4를 /newroot에 마운트
  → switch_root /newroot /sbin/init
  → Debian systemd
  → 필요하면 부팅 후 20초에 USB NCM으로 전환
```

UEFI와 GRUB은 이 경로에 필요하지 않다. 초기에 검토했던 `r8q-arch`와 Mu-Silicium 설치 방식은 별도의 포팅 경로다. 이 문서의 커널, DTB, 부팅 이미지와 섞어서 사용하지 않는다.

### 문서 찾아보기

- [1 재현 범위와 확인된 결과](#port-1)
- [2 시작 상태 확인과 백업](#port-2)
- [3 커널 소스와 도구 고정](#port-3)
- [4 기준 커널과 네이티브 커널 빌드](#port-4)
- [5 initramfs 준비](#port-5)
- [6 boot 이미지 재패키징과 검증](#port-6)
- [7 저장소 변경 전 USB rescue 부팅 검증](#port-7)
- [8 Debian rootfs 준비](#port-8)
- [9 설치용 ARM64 도구와 펌웨어 보존](#port-9)
- [10 userdata 포맷과 rootfs 복원](#port-10)
- [11 첫 Debian 부팅 설정](#port-11)
- [12 native 부팅 완료 판정](#port-12)
- [13 USB를 통한 패키지 다운로드](#port-13)
- [14 USB NCM 송신 집계 패치](#port-14)
- [15 부팅 화면 끄기](#port-15)
- [16 Wi-Fi 포팅의 진행 상태와 미해결 항목](#port-16)
- [17 패키지와 rootfs 무결성](#port-17)
- [18 복구와 진단](#port-18)
- [19 완료 확인과 보관할 자료](#port-19)
- [20 참고 자료](#port-20)

<a id="port-1"></a>

## 1 재현 범위와 확인된 결과

| 항목 | 기록에서 확인된 내용 |
|---|---|
| 기기 | Samsung Galaxy S20 FE 5G, `r8q`, 기록상 모델 `SM-G781N`, 메모리 6GB |
| 시작 환경 | 루팅한 LineageOS `23.0-20251206-NIGHTLY-r8q`와 기존 Debian chroot |
| 커널 소스 | `LineageOS/android_kernel_samsung_sm8250` |
| 기준 커밋 | `29f575b64b2d2beb802d3e549fdf2837c50deaff` |
| 컴파일러 | Android `clang-r547379`, Clang 20.0.0, LLD 20.0.0 |
| 빌드 PC | Debian 13, x86_64 |
| 부팅 이미지 | header v2, page size 4096, 기록상 boot 파티션 전체 이미지 64MiB |
| 커널 입력 | 최종 재패키징에는 압축하지 않은 `arch/arm64/boot/Image` 사용 |
| 루트 파일시스템 | `userdata`, 해당 기기의 `/dev/sda36`, ext4 |
| OS 직접 부팅 | Debian 13 trixie, `/sbin/init`의 systemd가 PID 1 |
| 컨테이너 기반 기능 | namespaces 추가, cgroup v2 `cpu io memory pids` 확인, 실제 ARM64 Debian LXC 부팅 기록 존재 |
| USB | RNDIS 부팅 성공, Debian 시작 후 NCM 전환 및 재부팅 후 자동 전환 성공 |
| NCM 성능 | 한 번의 10초 측정에서 기기 수신 약 2.26Gbps, 송신 약 1.30Gbps |
| 화면 | DRM 모드를 설정한 `modetest`가 종료된 뒤 화면 꺼짐 확인 |
| Wi-Fi | `wlan0` 생성까지 완료하지 못함. 포팅 미완료 |
| GPU와 영상 가속 | 장치 노드 확인 수준. Debian에서 가속 동작 성공으로 판정하지 않음 |

### 1.1 명령의 상태를 읽는 방법

**기록에서 성공 확인**은 사용자 출력으로 해당 단계의 결과가 확인된 것을 뜻한다. **재현용 정리**는 산재한 명령을 하나의 순서나 템플릿으로 정리한 것으로, 이 문서 작성 과정에서 폰에 실행한 것은 아니다. **대체 절차**는 기존 개인 chroot를 복제하지 않고 필요한 입력을 새로 만드는 방법이며, 해당 기기에서 추가 검증해야 한다.

아래 절차는 실행 위치를 `PC`, `Android`, `Recovery`, `initramfs`, `Debian`으로 구분한다. 서로 다른 위치의 명령을 한 셸에 이어 붙이지 않는다. 예시의 작업 디렉터리는 `~/r8q-linux`이며, USB 주소 `192.168.77.1/30`은 기기, `192.168.77.2/30`은 PC다. 네트워크에서 이 대역을 이미 사용하면 양쪽 주소와 모든 템플릿을 함께 변경한다.

PC의 명령은 Debian의 Bash에서 실행하는 것을 기준으로 한다. 커널 빌드와 이미지 제작은 PC에서 하지만, 추출한 ARM64 BusyBox와 magiskboot는 폰의 Android 또는 Recovery에서 실행한다.

### 1.2 설치 입력과 재현 한계

이 저장소에는 NCM 패치, 관련 원본 소스 파일 3개와 재현용 템플릿이 들어 있다. **전체 커널 소스나 설치 이미지는 포함하지 않는다.** 아래 입력은 자신의 기기에서 확보해야 한다.

| 입력 | 확보 방법과 용도 |
|---|---|
| 기준 `running.config` | 시작 시 기기 `/proc/config.gz`에서 내보내기. DT 및 보드 드라이버 설정 유지 |
| 원래 `boot` 이미지 | 파티션 전체 백업. header, cmdline, DTB와 복구용 원본 보존 |
| recovery | root ADB로 연결할 수 있는 정상 동작 recovery 유지 |
| `busybox-arm64` | 정적으로 링크된 ARM64 BusyBox. 기록에서는 Magisk의 파일 사용 |
| `magiskboot-arm64` | 사용 중인 Magisk에서 추출. 실제 버전과 해시를 함께 기록 |
| Debian arm64 rootfs | 개인 설정이 없는 새 rootfs 또는 정리한 기존 rootfs |
| 보드 펌웨어 | 기기의 기존 펌웨어·DSP·persist 파티션 및 필요한 vendor 파일 |

기준 `.config`, 원본 boot/DTB, 사용한 도구 바이너리와 Debian rootfs가 첨부되어 있지 않으므로, 첨부 파일만으로 당시 이미지와 바이트 단위로 동일한 결과물을 생성할 수는 없다. 이 문서는 해당 입력을 확보하고 동일한 부팅 구조를 재현하는 절차다. 같은 r8q라도 파티션 번호와 패널 정보는 실행 전에 확인한다.

### 1.3 저장소 사용

이 저장소를 clone하거나 ZIP을 해제한 뒤 저장소 루트에서 다음을 실행하면 문서의 작업 경로로 예제를 복사할 수 있다. 이는 PC의 작업 파일 준비이며 기기를 변경하지 않는다.

```bash
mkdir -p ~/r8q-linux
cp -a templates ~/r8q-linux/
cp patches/r8q-ncm-tx-aggregation.patch ~/r8q-linux/
```

1–12장은 기본 부팅, 14장은 선택적 NCM 개선, 15장은 화면 처리, 16장은 미완료 Wi-Fi 조사다. 실제 성공 경로와 새 rootfs 대체 절차를 구분해 읽는다.

<a id="port-2"></a>

## 2 시작 상태 확인과 백업

이 절차는 이미 부트로더 잠금이 해제되어 있고 LineageOS와 root 접근이 동작하는 상태에서 시작한다. 부트로더 잠금 해제와 LineageOS 최초 설치는 작업 기록에서 재현된 단계가 아니다.

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

기기 이름 `r8q`, 기준 커널의 `g29f575b64b2d` 접미사, 파티션 링크를 기록한다. 다른 버전이면 해당 커널 소스와 boot 이미지의 조합부터 확인한다.

**PC에서 Android의 설정과 boot 이미지 내보내기**

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

기기 boot 파티션 크기와 PC의 이미지 크기, 양쪽 해시가 같아야 한다. 기록에서는 67,108,864바이트였다. recovery 등 복구에 필요한 이미지도 외부에 보관한다. `userdata`를 포맷한 뒤에는 Android 데이터와 그 안의 기존 chroot를 boot 복구만으로 되돌릴 수 없다.

원래 `/proc/cmdline` 전체에는 기기 시리얼 등 고유 정보가 포함될 수 있다. 로컬 재현 자료로 보관하고 공개용 문서에 그대로 싣지 않는다.

<a id="port-3"></a>

## 3 커널 소스와 도구 고정

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

브랜치 이름보다 고정 커밋을 기준으로 삼는다. 브랜치의 최신 커밋은 이후 달라질 수 있으므로 위의 커밋이 실제로 존재하는지와 `git rev-parse HEAD` 결과를 확인한다. 커널 저장소를 `--depth 1`로 받으면 과거의 기준 커밋이 포함되지 않을 수 있어 여기서는 얕은 복제를 사용하지 않는다.

**PC에서 Android Clang 받기**

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

기록의 컴파일러 문자열은 Android 빌드 번호 `13290119`, LLVM 커밋 `b718bcaf8c198c82f3021447d943401e3ab5bd54`를 포함한다. 툴체인 저장소의 당시 전체 커밋은 기록되어 있지 않으므로 디렉터리 이름과 버전 문자열을 비교하고 새로 확보한 툴체인 커밋을 보관한다. 소스의 LTO·CFI 옵션을 유지한 상태에서 시스템 Clang으로 임의 교체하지 않는다.

<a id="port-4"></a>

## 4 기준 커널과 네이티브 커널 빌드

### 4.1 변경 없는 기준 빌드

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

`olddefconfig`가 성공했을 때만 다음 빌드를 실행한다. 기록의 기준 빌드는 처음 `-j4`, 이후 수정 빌드는 `-j6`을 사용했다. `-j6`은 PC에서 실행할 병렬 작업 수다. 기준 커널은 컴파일 성공이 확인됐으며, 실제 기기 부팅은 이후 namespace 옵션을 추가한 LXC 커널에서 확인됐다.

### 4.2 네이티브 부팅과 namespace 옵션 추가

실제 작업에서는 `out-lxc`에서 namespace 옵션을 추가한 뒤 `out-native`에 devtmpfs를 추가했다. 다음은 그 두 단계를 하나로 정리한 명령이다.

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

검사한다.

```bash
grep -E '^CONFIG_(SYSVIPC|IPC_NS|PID_NS|USER_NS|CGROUP_DEVICE|CGROUP_PIDS|FHANDLE|DEVTMPFS|DEVTMPFS_MOUNT)=' ../out-native/.config
grep -E '^CONFIG_(BLK_DEV_INITRD|RD_GZIP|SCSI|BLK_DEV_SD|SCSI_UFSHCD|SCSI_UFSHCD_PLATFORM|SCSI_UFS_QCOM|EXT4_FS|PROC_FS|SYSFS|TMPFS|CONFIGFS_FS|USB_GADGET|USB_CONFIGFS|USB_CONFIGFS_RNDIS|USB_DWC3|USB_DWC3_MSM)=' ../out-native/.config
```

초기 부팅에 필요한 저장장치, ext4, USB 기능은 이 절차에서 커널 내장인 `=y`를 기준으로 한다. `=m`으로 바꾸면 initramfs에 맞는 모듈을 넣고 올바른 순서로 불러와야 하므로 추가 작업이 필요하다. 기록에서 `MODPOST 0 modules`로 끝난 빌드는 별도 `.ko` 모듈을 생성하지 않았다.

`SYSVIPC`를 켜야 `IPC_NS`도 선택할 수 있다. `USER_NS`와 cgroup 설정은 컨테이너 실행에 필요한 기반이며, 실제 권한 제한과 네트워크 동작은 별도 시험으로 확인한다. 원본 설정의 `NET_NS`, cgroups, BPF, seccomp를 유지하고 다음 항목도 확인한다.

```bash
grep -E '^CONFIG_(NAMESPACES|UTS_NS|NET_NS|CGROUPS|CGROUP_BPF|BPF|BPF_SYSCALL|SECCOMP|SECCOMP_FILTER|VETH|BRIDGE)=' ../out-native/.config
```

기록상 예상 이름은 `4.19.325-cip124-st8-perf-native-g29f575b64b2d`이며, 소스 변경 후에는 `-dirty`가 붙을 수 있다. 이 접미사는 소스 작업 트리에 커밋되지 않은 변경이 있다는 뜻이며 빌드 실패 표시가 아니다. 재현 자료에는 `.config`와 `git diff`를 함께 보관한다.

원본 설정에는 `CONFIG_MODVERSIONS=y`와 모듈 서명 강제가 활성화되어 있었다. 원래 LineageOS의 서명 키가 없으므로 기존 vendor `.ko` 파일을 새 커널에서 그대로 사용할 수 있다고 가정하지 않는다. 모듈이 필요한 구성을 선택했다면 같은 소스·설정·서명 조건으로 함께 빌드한다.

<a id="port-5"></a>

## 5 initramfs 준비

### 5.1 정적 ARM64 BusyBox와 magiskboot 확보

**PC에서 Android가 동작하는 동안**

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

BusyBox는 ARM64 정적 바이너리여야 한다. `INTERP`가 있으면 필요한 동적 로더와 라이브러리 없이 initramfs에서 실행할 수 없다. x86_64 PC에서 이 ARM64 바이너리를 직접 실행하지 않는다. 이후 recovery 또는 기기 ARM64 셸에서 실행한다.

### 5.2 초기 장치 노드 준비

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

노드가 이미 존재하면 삭제하거나 덮어쓰지 말고 문자 장치인지와 major/minor를 확인한다. **기록의 Magisk BusyBox를 사용할 때 `/dev/null`은 devtmpfs를 마운트하기 전부터 initramfs에 들어 있어야 한다.** 기록에서는 초기 장치 노드가 빠진 상태로 USB가 나타나지 않았고, 추가한 뒤 `/init`과 RNDIS 함수 생성까지 진행됐다. `/dev/kmsg`도 미리 넣어 초기 마운트보다 앞서 실행 로그를 남길 수 있도록 한다.

### 5.3 RNDIS 초기화 코드

이 저장소의 `templates/initramfs/init-rndis.sh`는 기록에서 확인된 `/init`의 동작을 정리한 템플릿이다. 해당 파일을 `~/r8q-linux/native-root/init`으로 복사한다.

**PC**

```bash
cd ~/r8q-linux
cp templates/initramfs/init-rndis.sh native-root/init
```

기본 `BOOT_STAGE=rescue`는 RAM에서 USB 셸만 띄우고 저장소를 마운트하지 않는다. `BOOT_STAGE=debian`으로 바꾸면 USB 초기화 후 Debian으로 전환한다. 이 단계에서는 `rescue`를 유지한다.

필수 순서는 다음과 같다.

1. 미리 만든 `/dev/kmsg`로 초기 로그를 기록한다.
2. BusyBox applet을 설치하고 proc, sysfs, devtmpfs, tmpfs, devpts를 마운트한다.
3. configfs를 `/config`에 마운트한다.
4. `a600000.dwc3` UDC가 나타날 때까지 기다린다.
5. RNDIS function과 고정 MAC 주소를 설정한다.
6. function을 configuration에 연결하고 `UDC`에 bind한다.
7. **bind 이후** `functions/rndis.usb0/ifname`과 실제 `/sys/class/net/이름`을 확인한다.
8. 기기에 `192.168.77.1/30`을 할당한다.

UDC bind 전에 `ifname`을 읽으면 기록에서처럼 `(unnamed net_device)`가 반환될 수 있다. 이 값으로 IP 설정을 시도하면 USB 접속 준비가 끝나지 않는다.

예제 VID/PID `1d6b:0104`, 기기 MAC `02:77:00:00:00:01`, 호스트 MAC `02:77:00:00:00:02`는 기록의 시험 값을 유지했다. 같은 값을 사용하는 여러 기기를 동시에 연결한다면 고유 시리얼과 MAC으로 바꾼다. `MaxPower=250`은 USB descriptor 값이며 실제 충전 전류 설정이나 충전 전류 보장은 아니다.

configfs에서 function을 만들고 UDC에 bind하는 기본 구조는 [Linux USB gadget 문서](https://www.kernel.org/doc/html/v5.10/usb/gadget_configfs.html)에 설명되어 있다.

### 5.4 newc ramdisk 생성

**PC**

```bash
cd ~/r8q-linux
# 재현 자료의 템플릿을 복사한 뒤 실행한다.
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

목록에 `init`, `bin/busybox`, `bin/sh`, `dev/null`, `dev/console`, `dev/kmsg`가 있어야 한다. `init`과 BusyBox의 실행 권한, `bin/sh`의 심볼릭 링크, 장치 3개의 문자 장치 표시도 확인한다. 여기서는 압축되지 않은 newc cpio를 만들고, boot 이미지 재패키징 단계에서 원본 ramdisk 압축 형식을 적용한다. `bash -n`은 문법 검사이며 실제 ARM64 기기에서의 실행 성공을 대신하지 않는다.

<a id="port-6"></a>

## 6 boot 이미지 재패키징과 검증

### 6.1 recovery에서 작업

Android에서 `adb reboot recovery`로 이동한다. Lineage recovery의 메뉴에서 **Advanced → Enable ADB**를 활성화한다. 기록에서는 이 조작 이후 root ADB를 사용할 수 있었다. ADB sideload 화면과 root 셸을 구분한다.

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

`magiskboot unpack -h`는 header와 각 구성 요소를 분리한다. 원본 이미지를 기준으로 재패키징하면 원래 형식과 구성 정보를 유지할 수 있다. 도구 동작은 [Magisk 공식 문서](https://topjohnwu.github.io/Magisk/tools.html)를 참조한다.

기록의 원본 분석 결과는 다음과 같았다. 자신의 원본 이미지에서 같은 항목을 확인한 뒤 다음 단계로 진행한다.

| 항목 | 기록의 값 | 확인할 의미 |
|---|---|---|
| `HEADER_VER` | `2` | 기존 Android boot image v2 구조 유지 |
| `PAGESIZE` | `4096` | 원본의 페이지 크기 유지 |
| `KERNEL_FMT` | `raw` | 이 절차에서는 압축하지 않은 `Image`로 교체 |
| `RAMDISK_FMT` | `gzip` | 재패키징 후 원본의 압축 형식 유지 |
| `DTB_SZ` | `1415391` | DTB가 별도 파일로 추출됨. 원본 `dtb` 보존 |
| `OS_VERSION` / `OS_PATCH_LEVEL` | `16.0.0` / `2025-11` | 기존 헤더의 버전 메타데이터 보존 |

커널에 DTB가 붙어 있거나 헤더 구조가 다르면 이 예제를 그대로 적용하지 않고 해당 원본의 패키징 구조부터 확인한다. `VBMETA` 표시만으로 추가 AVB 조작이 필요하다고 결론 내리지 않는다. 기록에서는 기존 잠금 해제 상태와 원본 이미지 구조를 유지한 재패키징으로 부팅했다.

### 6.2 cmdline과 원본 DTB 유지

`header`의 기존 `cmdline=` 값에 **`rdinit=/init enforcing=0`만 추가**한다. 기존 보드·스토리지·펌웨어 옵션은 보존한다. 재현 자료의 `templates/append-boot-cmdline.py`를 PC에서 header 사본에 사용하거나 직접 한 줄을 편집한 뒤 다시 업로드한다.

`header`는 `name=`, `cmdline=`, `os_version=`, `os_patch_level=` 같은 `키=값` 형식이다. cmdline 전체를 런타임 `/proc/cmdline`의 긴 문자열로 교체하지 않는다. 런타임 문자열에는 부트로더가 붙인 개인 기기 정보와 Recovery 부팅 상태까지 포함될 수 있다. 원본에서 추출한 `cmdline=` 한 줄에 초기 init과 SELinux 옵션만 추가한다.

```bash
adb pull /tmp/r8q-pack/header boot-header.txt
python3 templates/append-boot-cmdline.py boot-header.txt
adb push boot-header.txt /tmp/r8q-pack/header
```

`templates/append-boot-cmdline.py`는 1.3절에서 복사한 도우미다. 기존에 다른 `rdinit=` 또는 `enforcing=` 값이 있으면 자동으로 덮어쓰지 않고 중단한다.

`enforcing=0`은 기록에서 downstream Android 커널의 SELinux 제약을 피하기 위해 사용한 permissive 설정이다. 이 포팅 상태를 SELinux enforcing 환경으로 검증한 기록은 없다. `lpm_levels.sleep_disabled=1`은 기존 boot cmdline에 있었으며 임의로 제거하지 않는다. mainline 포팅의 idle 우회 서비스와 혼동하지 않는다.

**PC에서 recovery 작업과 재패키징**

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

커널·ramdisk·DTB의 해시 쌍이 각각 일치해야 한다. `kernel`에는 **raw `Image`**를 넣고, 원본에서 추출한 `dtb`를 그대로 둔다. 기록의 최종 출력은 `KERNEL_FMT [raw]`, `RAMDISK_FMT [gzip]`였다. 최종 이미지가 boot 파티션 크기를 넘지 않는지 확인한다.

```bash
stat -c '%s' boot-native-rescue.img
adb shell blockdev --getsize64 /dev/block/by-name/boot
```

빌드 과정에서 `dtbs`를 생성했더라도 여기서는 생성된 DTB로 원본을 교체하지 않는다. 이 기록의 성공 경로는 원래 동작하던 boot 이미지의 DTB와 기존 `dtbo` 파티션을 유지하는 방식이다.

### 6.3 boot에 기록

다음 명령은 boot 파티션을 교체한다. recovery 파티션에는 쓰지 않는다.

**PC에서 recovery의 root ADB 사용**

```bash
adb shell 'dd if=/tmp/boot-native-rescue.img of=/dev/block/by-name/boot bs=1048576 && sync'
sha256sum boot-native-rescue.img
adb shell sha256sum /dev/block/by-name/boot
```

기록의 이미지가 파티션 전체 크기인 64MiB였으므로 전체 파티션 해시를 비교할 수 있었다. 새 도구에서 이미지가 더 짧게 생성되면 전체 파티션 해시는 이미지와 같지 않을 수 있다. 이때 크기를 확인하고 기록한 길이만 readback하여 비교한다. 단순히 해시가 다르다고 다시 플래시하지 않는다.

기기의 recovery 메뉴에서 **Reboot system now**를 선택한다. 기록에서는 `adb reboot` 후 다시 recovery로 들어간 사례가 있으므로, recovery ADB에 접속되었다는 사실을 새 native 커널 부팅 성공으로 판정하지 않는다.

<a id="port-7"></a>

## 7 저장소 변경 전 USB rescue 부팅 검증

**PC**

```bash
lsusb
ip -br link
sudo dmesg | tail -n 40
```

`1d6b:0104` 장치와 새 USB NIC를 확인한다. 기록의 호스트 이름은 `enx027700000002`였지만 이름은 호스트 환경에 따라 다를 수 있다.

```bash
USB_IF=enx027700000002
sudo ip link set "$USB_IF" up
sudo ip addr replace 192.168.77.2/30 dev "$USB_IF"
ping -c 3 -W 2 192.168.77.1
sudo apt install inetutils-telnet
telnet 192.168.77.1
```

`USB_IF`에는 실제로 나타난 USB NIC를 넣는다. NetworkManager 등의 관리자가 재연결 때 임시 주소를 지우면 해당 USB 인터페이스의 관리를 조정하거나 호스트의 기존 네트워크 관리 도구에 주소를 등록한다. 다른 LAN 인터페이스 설정을 복사하지 않는다.

**initramfs 셸**

```sh
echo READY
uname -r
tr '\0' ' ' < /proc/1/cmdline
echo
cat /proc/mounts
cat /sys/class/block/sda36/uevent
cat /sys/class/block/sda36/size
```

기록에서 PID 1은 `/bin/sh /init`, 커널은 `-perf-native`, `sda36`은 `PARTNAME=userdata`였다. `BOOT_STAGE=rescue`에서 userdata가 마운트되지 않은 것도 확인한다. 이 단계가 성공하기 전에는 userdata 포맷으로 넘어가지 않는다.

Telnet은 임시 설치·복구용으로만 사용한다. 정상 Debian 부팅에서는 SSH로 접속한다. rescue 셸은 USB의 정적 주소에만 bind하지만, 향후 USB를 다른 LAN에 bridge하면 그 접근 범위도 달라질 수 있다.

<a id="port-8"></a>

## 8 Debian rootfs 준비

### 8.1 기존 rootfs를 사용할 때

기록에서는 기존 Debian 13 arm64 chroot를 GNU tar로 백업한 뒤 userdata에 복원했다. 당시 파일 이름은 `debian13-with-lxc.tar`, 크기는 약 6.5GiB였다. 이 백업은 현재 저장소에 포함되어 있지 않다.

재현용 rootfs에는 `/sbin/init`, systemd, udev, OpenSSH, iproute2, util-linux, e2fsprogs, GNU tar와 기본 ARM64 라이브러리가 있어야 한다. 개인 서비스와 컨테이너 데이터가 들어간 기존 아카이브를 그대로 배포하지 않는다.

기록의 백업 방식은 다음과 같다. 실제 경로가 다른 경우 `ROOTFS_PATH`만 변경한다. 아카이브 전에 기존 rootfs의 실행 중인 작업을 종료하고 proc/sys/dev/run 같은 가상 파일시스템을 제외한다.

**PC에서 Android의 기존 chroot 백업**

```bash
ROOTFS_PATH=/data/local/debian13
adb shell "su -c 'chroot $ROOTFS_PATH /usr/bin/tar --one-file-system --numeric-owner --acls --xattrs --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp -C / -cpf /tmp/debian-rootfs.tar .'"
# chroot 안의 파일은 adb shell 계정으로 직접 읽지 못했던 기록이 있다.
adb shell "su -c 'cp $ROOTFS_PATH/tmp/debian-rootfs.tar /data/local/tmp/debian-rootfs.tar && chown shell:shell /data/local/tmp/debian-rootfs.tar && chmod 600 /data/local/tmp/debian-rootfs.tar && restorecon /data/local/tmp/debian-rootfs.tar'"
adb pull /data/local/tmp/debian-rootfs.tar backup/debian-rootfs.tar
tar -tf backup/debian-rootfs.tar > /dev/null
sha256sum backup/debian-rootfs.tar
```

백업 출력의 오류와 누락 여부를 확인한다. `--one-file-system`만으로 같은 파일시스템을 bind한 모든 가상 마운트가 제외되는 것은 아니므로 명시적인 제외 목록이 필요하다. 별도로 유지할 마운트가 있으면 그 내용도 확인한다.

초기에 `adb exec-out`으로 받은 134바이트짜리 파일은 tar가 아니라 오류 문자열이었다. **파일이 존재하는 것만으로 백업 성공을 판정하지 않는다.** 정상 tar 목록과 충분한 크기, 해시를 확인하고 포맷 전에 외부 PC에 확보한다.

### 8.2 개인 설정이 없는 새 rootfs를 만들 때

다음은 **실기기에서 검증되지 않은 대체 절차**다. 작업 기록에서 성공한 경로는 기존 chroot의 이전이었다. 개인 설정이 없는 재현용 입력은 debootstrap으로 새로 만든다. 아래는 x86_64 Debian PC에서 QEMU의 ARM64 실행 지원을 이용해 두 번째 단계까지 완료하는 방법이다. Debian의 [교차 debootstrap 안내](https://wiki.debian.org/EmDebian/CrossDebootstrap)와 [debootstrap 매뉴얼](https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html)을 참조한다.

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

이 명령이 ARM64 실행 파일의 `Exec format error`로 실패하면 QEMU binfmt 등록을 확인하고 두 번째 단계를 완료한다. 첫 단계만 끝난 rootfs를 완성된 Debian으로 취급하지 않는다. ARM64 Linux PC에서 만드는 경우에는 QEMU가 필요 없다. 첫 단계부터 두 번째 단계까지 작업 결과와 `/debootstrap/debootstrap.log`를 확인한다.

`policy-rc.d`는 설치 chroot에서 서비스를 실제로 시작하지 않도록 만든 임시 파일이다. second stage가 성공하면 **이번에 만든 파일만 제거**하고, 가상 파일시스템을 추가 마운트했다면 해제한 뒤 아카이브를 만든다.

```bash
sudo rm clean-rootfs/usr/sbin/policy-rc.d
sudo tar --numeric-owner --acls --xattrs -cpf backup/debian-rootfs.tar \
  -C clean-rootfs .
tar -tf backup/debian-rootfs.tar > /dev/null
sha256sum backup/debian-rootfs.tar
```

이렇게 완료한 rootfs에서 9장의 설치 도구와 ARM64 라이브러리를 확보할 수 있다. 새 rootfs의 e2fsprogs와 libext2fs가 기록의 특정 버전과 다르면 9장에 설명한 새 rootfs 도구 수집 방법을 사용해 같은 버전으로 맞춘다.

rootfs의 `/etc/apt/sources.list`가 비어 있다면 일반 Debian 저장소만 준비한다. 아래에는 개인 DNS·LAN·서비스 설정을 넣지 않는다.

```text
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://security.debian.org/debian-security trixie-security main
```

새 rootfs의 root 계정은 잠겨 있을 수 있다. 11장에서 키를 등록한 뒤 계정 상태와 SSH 허용 여부를 확인한다. 사용할 관리 계정을 새로 만들거나 로컬에서 계정 암호를 설정하는 등 본인의 접근 정책을 준비해야 하며, 그 계정 설정을 기존 개인 환경에서 복사할 필요는 없다. 이 대체 rootfs의 r8q 첫 부팅 성공은 새로 검증한다.

패키지 버전은 시점에 따라 달라질 수 있으므로 ARM64 rootfs의 `dpkg-query` 목록과 아카이브 해시를 기록한다. Debian 배포판 커널이나 GRUB을 설치하지 않는다. 이 포팅에서는 별도로 빌드한 r8q 커널과 Android boot 이미지를 사용한다.

<a id="port-9"></a>

## 9 설치용 ARM64 도구와 펌웨어 보존

### 9.1 ARM64 동적 도구 묶음

BusyBox만 있는 initramfs에서 ext4를 만들고 소유권·ACL·xattr를 보존하려면 Debian의 mke2fs와 GNU tar가 필요하다. 기록의 기존 rootfs에는 ext4 라이브러리가 있었지만 mke2fs 실행 파일이 없었다. 따라서 ARM64 e2fsprogs 패키지에서 mke2fs와 설정 파일을 꺼내고, 기존 ARM64 rootfs 아카이브에서 로더·라이브러리·GNU tar를 가져왔다. x86_64 PC의 실행 파일이나 라이브러리를 대신 넣지 않는다.

아래의 `backup/debian-rootfs.tar`는 **설치가 완료된 ARM64 rootfs**의 아카이브다. 기록에서는 `backup/debian13-with-lxc.tar`라는 이름을 사용했다. 새 rootfs를 만드는 대체 절차를 선택했다면 설치용 도구를 별도로 완성해야 한다.

**PC: 기록에서 사용한 e2fsprogs 패키지 확보**

```bash
cd ~/r8q-linux
mkdir -p native-tools
wget -O e2fsprogs-arm64.deb \
  'https://deb.debian.org/debian/pool/main/e/e2fsprogs/e2fsprogs_1.47.2-3+b12_arm64.deb'
echo 'ebd315c483853fafe877e39c1f49bf725834d7af7249a98b727f2ef4fe01a5c4  e2fsprogs-arm64.deb' | \
  sha256sum -c -
dpkg-deb -x e2fsprogs-arm64.deb native-tools
```

이 URL과 해시는 작업 기록에 사용한 특정 패키지에 대한 것이다. 저장소에서 파일이 사라졌거나 다른 버전을 선택한다면 그 패키지의 출처·해시와 라이브러리 호환성을 다시 확인한다. mke2fs와 libext2fs는 같은 버전으로 맞춘다.

**PC: ARM64 로더와 공유 라이브러리, GNU tar 추가**

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

원문에서는 mke2fs용 묶음을 먼저 전송한 뒤 GNU tar와 그 라이브러리를 추가한 묶음을 다시 전개했다. 위 명령은 두 묶음을 한 번에 조립한 정리다. 아카이브의 경로가 `./usr/...` 형식인지 먼저 확인하고, 다른 버전의 rootfs를 사용하면 `DT_NEEDED`와 전이 의존성도 확인한다. 심볼릭 링크와 그 대상 파일을 함께 보존해야 한다.

HTTP 서버는 전송 동안 해당 PC 터미널에서 유지한다.

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

전송 전후 해시가 일치해야 한다. 기록에서 확인한 실행 결과는 mke2fs 1.47.2와 GNU tar 1.35였다. 명시적인 동적 로더 경로는 이 도구 묶음에 실제로 들어 있는 `/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1`이며, initramfs에는 일반 Debian 실행 파일이 요구하는 표준 로더 경로가 없다. 뒤의 포맷 명령에서는 `MKE2FS_CONFIG=/tools/etc/mke2fs.conf`도 지정한다.

### 새 rootfs를 쓰는 경우 도구 수집

9.1의 특정 버전 패키지와 기존 rootfs 라이브러리를 사용하는 경로 대신, 8.2에서 두 번째 단계까지 완료한 `clean-rootfs`의 도구와 같은 rootfs의 라이브러리를 함께 수집할 수 있다. 아래는 **대체 절차**이며 앞의 `native-tools` 조립 명령과 섞어 실행하지 않는다.

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

라이브러리 디렉터리를 함께 복사해 심볼릭 링크와 의존성을 보존한다. 누락된 외부 경로의 의존성이 있으면 추가한다. 기기에서는 위와 같은 `/tools` 로더 경로로 실행해 확인한다. 도구 아카이브 크기와 `/run`의 여유 RAM도 확인한다.

### 9.2 기존 파티션 확인과 보존

해당 기기의 기록상 번호는 다음과 같다. **다른 기기에서는 번호만 복사하지 않고 PARTNAME을 확인한다.**

| 파티션 | 기록의 장치 | 사용 방법 |
|---|---|---|
| userdata | `/dev/sda36` | Debian root ext4로 포맷 |
| apnhlos | `/dev/sda19` | vendor firmware 이미지 구분에 참고 |
| modem | `/dev/sda20` | `/vendor/firmware_mnt`, vfat 읽기 전용 |
| dsp | `/dev/sda21` | `/vendor/dsp`, ext4 읽기 전용 `noload` |
| persist | `/dev/sda8` | `/mnt/vendor/persist`, ext4 읽기 전용 `noload` |

펌웨어·DSP·persist는 포맷하지 않는다. 기록에서는 userdata를 지우기 전 이 세 파티션의 파일을 tar로 PC에 보관했다.

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

**PC의 별도 터미널**

```bash
cd ~/r8q-linux
wget -O backup/r8q-firmware.tar http://192.168.77.1:8001/r8q-firmware.tar
tar -tf backup/r8q-firmware.tar > /dev/null
sha256sum backup/r8q-firmware.tar
```

해시는 기기와 PC 사이의 전송 검증에 사용한다. 다른 기기에서 생성한 아카이브를 기록의 해시와 일치시키려 하지 않는다. 캘리브레이션 데이터가 있는 persist를 다른 기기의 복사본으로 교체하지 않는다.

<a id="port-10"></a>

## 10 userdata 포맷과 rootfs 복원

**이 단계는 Android의 userdata 데이터를 삭제한다.** boot·rootfs·펌웨어 백업을 외부 PC에서 읽을 수 있는 상태로 확보한 뒤 실행한다. initramfs의 rescue 부팅에서 진행한다.

### 10.1 대상 확인

**initramfs**

```sh
cat /sys/class/block/sda36/uevent
cat /sys/class/block/sda36/size
cat /proc/mounts
```

기록의 조건은 `PARTNAME=userdata`, `224819160`개의 512바이트 sector였다. 이미 마운트된 파티션이면 먼저 작업 상태를 확인한다. `/dev/sda36`이 userdata가 아닌 경우 아래 명령을 실행하지 않는다.

### 10.2 ext4 생성

먼저 `-n`으로 실제 기록 없이 파라미터를 확인한다.

```sh
MKE2FS_CONFIG=/tools/etc/mke2fs.conf \
/tools/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
  --library-path /tools/usr/lib/aarch64-linux-gnu \
  /tools/usr/sbin/mke2fs -n -t ext4 -b 4096 -m 1 \
  -L debian-root -O ^orphan_file,^metadata_csum_seed /dev/sda36
```

해당 커널과 e2fsprogs 조합에서는 기록에 사용한 것처럼 `orphan_file`과 `metadata_csum_seed`를 비활성화한다. 최신 PC 도구의 기본 feature 집합을 확인하지 않고 그대로 포맷하면 구형 커널의 ext4 지원과 맞지 않을 수 있다.

**대상과 백업 확인 후 실제 포맷**

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

`mke2fs` 종료 코드 0, ext4 마운트 성공, 새 UUID를 확인한다. 기록에서는 처음부터 약 105GiB의 전체 파티션에 파일시스템을 만들었다. 별도의 작은 root 이미지 확대 과정은 확인되지 않는다. 문서의 UUID 예시 대신 실제 생성된 값을 fstab에 넣는다.

### 10.3 rootfs 전송과 GNU tar 복원

6.5GiB 같은 큰 rootfs는 `/run` RAM 디스크에 받지 않고 userdata에 받는다.

**initramfs**

```sh
wget -O /newroot/.debian-restore.tar http://192.168.77.2:8000/backup/debian-rootfs.tar
sha256sum /newroot/.debian-restore.tar
```

PC의 `backup/debian-rootfs.tar`와 해시가 일치하면 복원한다.

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

BusyBox sh에서 실행할 명령은 위처럼 디렉터리를 하나씩 명시한다. tar 종료 코드가 0이고 `/sbin/init`이 실행 가능한 systemd로 연결되어 있어야 한다.

설치 중 Telnet 입력이 멈추면 **포맷을 반복하지 않고** 새 PC 터미널에서 USB 주소와 ping을 확인한다. USB가 재열거되면서 호스트의 임시 `192.168.77.2/30` 주소가 사라진 사례가 있었다. 재접속 후 `ps`, `/proc/mounts`, `blkid`, 다운로드 파일을 확인해 기존 작업 상태부터 판단한다.

<a id="port-11"></a>

## 11 첫 Debian 부팅 설정

### 11.1 chroot용 가상 파일시스템 연결

**initramfs**

```sh
mount -o bind /dev /newroot/dev
mount -o bind /proc /newroot/proc
mount -o bind /sys /newroot/sys
ls -l /newroot/dev/null /newroot/dev/urandom
```

`/dev`가 빠지면 기록처럼 `ssh-keygen`과 `sshd -t`가 `Couldn't open /dev/null`로 실패한다. 다음 부팅에서는 initramfs가 이 마운트들을 Debian 쪽으로 이동한다.

### 11.2 fstab

`ROOT_UUID`는 방금 `blkid`로 얻은 값이다.

```sh
ROOT_UUID='실제_userdata_ext4_UUID'
mkdir -p /newroot/vendor/firmware_mnt /newroot/vendor/dsp /newroot/mnt/vendor/persist
cat > /newroot/etc/fstab <<EOF
UUID=$ROOT_UUID / ext4 defaults,noatime,errors=remount-ro 0 0
/dev/sda20 /vendor/firmware_mnt vfat ro,nofail 0 0
/dev/sda21 /vendor/dsp ext4 ro,noload,nofail 0 0
/dev/sda8 /mnt/vendor/persist ext4 ro,noload,nofail 0 0
EOF
```

뒤의 읽기 전용 마운트는 기록의 보드 경로를 재현한 것이다. Wi-Fi나 원격 프로세서 지원을 제외하고 더 작은 구성으로 만들려면 각 드라이버의 실제 의존성을 검증한 뒤 줄인다. `nofail`은 마운트 실패를 부팅 성공으로 감출 수 있으므로 첫 부팅 후 `findmnt`를 확인한다. root 행의 fsck pass `0`도 기록의 설정이며 자동 파일시스템 점검 정책은 별도의 운영 선택이다.

### 11.3 기본 USB IP와 udev

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

RNDIS와 NCM 양쪽 function에 같은 기기 MAC을 설정하면 이 파일로 기본 정적 주소를 유지할 수 있다. 기록의 이후 LAN bridge·DHCP 구성은 사설망에 맞춘 개인 운영 설정이므로 이 기본 경로에서는 사용하지 않는다.

기록의 기존 chroot에는 **udev 패키지가 설치되어 있지 않았다.** `systemd-networkd`는 실행 중이었지만 `udevadm`과 `systemd-udevd` 실행 파일 및 서비스 unit이 없었다. 이때 USB 주소는 initramfs에서 남겨둔 값으로 통신했고, networkd는 USB NIC를 `pending`, `Network File: n/a`로 표시했다. 단순히 서비스를 시작하거나 마스크를 해제하는 것으로 해결할 상태가 아니었다.

가능하면 rootfs를 만들 때 udev를 포함한다. 기존 rootfs를 재사용했다면 첫 native 부팅 후 다음을 확인한다.

```bash
dpkg-query -W -f='${Package}: ${Status}\n' udev
ls -l /usr/bin/udevadm /usr/lib/systemd/systemd-udevd
systemctl is-active systemd-networkd systemd-udevd
systemctl status systemd-udevd.service --no-pager -l
networkctl status usb0 --no-pager
```

udev가 없으면 13장의 임시 USB 인터넷 경로를 준비한 뒤 설치한다.

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

일반 경로로 APT에 접근할 수 없다면 기록에서 사용한 SSH 역방향 SOCKS 터널을 사용할 수 있다. 아래는 인터넷이 되는 PC와 기기를 USB로 직접 연결한 예다. 원문에 있던 개인 서버 경유 주소는 생략했다.

**인터넷이 되는 PC의 별도 터미널**

```bash
ssh -i ~/.ssh/r8q-port-test -o ExitOnForwardFailure=yes \
  -R 127.0.0.1:1080 root@192.168.77.1
```

**위 연결로 들어간 Debian 셸**

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

프록시는 이 APT 명령에만 적용한다. 원문의 설치 후 결과는 USB 인터페이스에 `.network` 파일이 적용되고 `configured / online`으로 바뀐 것이었다. 해당 기록의 추가 DHCP 주소와 개인망 게이트웨이는 이 문서에 복제하지 않는다. 실제 인터페이스 이름이 `usb0`이 아니면 그 이름으로 바꾼다. 서비스가 별도로 masked되어 있다면 파일이 없는 문제와 구분해서 원인을 확인한다.

### 11.4 SSH 첫 접속

키 인증은 화면이 없는 기기의 부팅 검증에 필요하다. 기존 개인 SSH 설정을 복제하지 않고 시험용 키와 해당 USB 주소만 사용한다.

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

저장소의 SSH 템플릿을 PC의 HTTP 서버에서 받아 배치한다.

**initramfs**

```sh
mkdir -p /newroot/etc/ssh /newroot/etc/systemd/system
wget -O /newroot/etc/ssh/sshd_config.r8q \
  http://192.168.77.2:8000/templates/debian/sshd_config.r8q
wget -O /newroot/etc/systemd/system/r8q-ssh.service \
  http://192.168.77.2:8000/templates/debian/r8q-ssh.service
```

이 설정은 USB 정적 주소에 listen하고 비밀번호 인증을 사용하지 않는다. 기존 `ssh.service`나 `ssh.socket`과 포트가 충돌하지 않도록 하나의 시작 방식만 활성화한다.

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

`ssh.socket`이 없는 rootfs에서는 위 조건문이 해당 단계를 건너뛴다. SSH 설정 검사가 0으로 끝나야 한다. 잠긴 root 계정에서 키 로그인도 거부되는 경우에는 사용할 관리 계정을 준비하거나 root의 계정 상태를 확인한다. 비밀번호 인증을 켜서 우회하지 않는다.

### 11.5 Debian 전환 ramdisk 생성과 기록

**PC**에서 `native-root/init`의 `BOOT_STAGE=rescue`를 `BOOT_STAGE=debian`으로 변경한다. 템플릿의 `ROOT_DEVICE=/dev/sda36`도 실제 userdata인지 확인한다. 이 선택 변수는 저장소의 정리용 템플릿이며, 원문에서는 검증된 USB 초기화 코드 뒤의 Telnet 대기 부분을 Debian 전환 코드로 직접 바꿨다. 그 뒤 5.4절과 같은 명령으로 `native-debian.cpio`를 만든다.

```bash
cd ~/r8q-linux
bash -n native-root/init
(
  set -o pipefail
  cd native-root
  find . -print0 | cpio --null -o --format=newc --owner=0:0 > ../native-debian.cpio
)
```

기록에서 성공한 경로는 **현재 USB rescue 셸 안에서 MagiskBoot로 재패키징**하는 것이다. 기존 검증된 rescue boot 이미지의 커널과 DTB를 유지하고 ramdisk만 교체한다. 아래 다운로드는 이 문서의 `boot-native-rescue.img`를 사용한다. 원문에서 같은 단계의 성공 이미지 이름은 `boot-native-debug3.img`였다.

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

재추출 검사는 6장의 검증을 이 ramdisk 교체에도 적용한 것이다. `cmp` 중 하나라도 실패하면 기록하지 않는다. 기준 이미지에 DTB가 별도 파일로 추출되는 것은 이 기기의 관찰된 형식이다.

기기의 새 이미지를 PC에도 보관한다. 원문에서는 기존 HTTP 서버의 루트가 맞지 않아 404와 빈 파일이 생겼으므로 `/run`을 루트로 하는 새 서버를 열었다.

**initramfs**

```sh
chmod 644 /run/boot-debian.img
busybox httpd -p 192.168.77.1:8002 -h /run
```

**PC의 별도 터미널**

```bash
cd ~/r8q-linux
wget -O boot-debian.img http://192.168.77.1:8002/boot-debian.img
ls -lh boot-debian.img
sha256sum boot-debian.img
```

PC와 기기의 이미지 크기·해시가 일치하는지 확인하고, 6장의 대상 파티션 검사와 크기 검사 후 기록한다. 동일한 크기로 패딩된 boot 이미지라면 전체 파티션 해시도 이미지와 비교할 수 있다.

**initramfs: boot 기록과 첫 재부팅**

```sh
# /dev/sda23이 자신의 boot 파티션인지 먼저 확인한다.
grep -qx 'PARTNAME=boot' /sys/class/block/sda23/uevent && \
dd if=/run/boot-debian.img of=/dev/sda23 bs=1048576 && sync
sha256sum /run/boot-debian.img /dev/sda23
```

위 두 해시가 같고 기록 검사가 끝났을 때만 rootfs를 마운트 해제한다.

```sh
cd /
sync
umount /newroot/dev && \
umount /newroot/proc && \
umount /newroot/sys && \
umount /newroot && sync
```

마운트 해제가 성공한 뒤 rescue 셸에서 재부팅한다. 이 단계에는 Debian systemd가 아직 실행되지 않으므로 기록에서 사용한 SysRq 경로를 사용한다.

```sh
echo b > /proc/sysrq-trigger
```

Debian에 들어온 뒤의 재부팅은 `systemctl reboot`로 수행한다.

Debian 전환 부분의 핵심은 다음과 같다.

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

실제 템플릿은 root mount와 `/sbin/init` 존재 확인, 실패 시 rescue 진입을 포함한다. 위 전환 부분만 따로 ramdisk에 넣지 않는다. `/config`를 옮겨 USB gadget의 configfs 상태를 Debian에서도 유지한다.

<a id="port-12"></a>

## 12 native 부팅 완료 판정

**PC**

```bash
sudo ip link set enx027700000002 up
sudo ip addr replace 192.168.77.2/30 dev enx027700000002
ping -c 3 -W 2 192.168.77.1
ssh -i ~/.ssh/r8q-port-test root@192.168.77.1
```

명령의 인터페이스 이름은 실제 PC의 USB NIC 이름으로 변경한다. SSH 호스트 키는 자신의 설치에서 생성된 값을 확인한다. 원문에 나온 다른 설치의 지문을 그대로 승인 기준으로 사용하지 않는다.

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

성공 기준은 PID 1이 Debian systemd이고, 루트 파일시스템이 userdata의 ext4이며, USB를 통해 SSH에 접속할 수 있고, 예정한 부팅 작업이 끝난 상태다. `starting`만으로 부팅 완료를 판단하지 않는다. 원문 첫 결과는 `starting`, 실패 unit은 0개였으며, 다음 확인에서 `No jobs running`이 출력됐다.

기록에서 확인한 cgroup v2 컨트롤러는 `cpu io memory pids`였다. 커널 기능을 확인해야 한다면 `/proc/config.gz` 또는 실제 빌드에 사용한 `.config`와 대조한다. 기존 컨테이너의 이름, 브리지, 편의 명령과 자동 시작 설정은 포팅 재현 범위에서 제외한다.

<a id="port-13"></a>

## 13 USB를 통한 패키지 다운로드

Wi-Fi는 완성되지 않았으므로, 포팅 중 패키지를 내려받을 때 PC의 인터넷 연결을 USB로 공유할 수 있다. 이 절차의 관리용 주소 관계는 `기기 192.168.77.1 → PC 192.168.77.2 → 외부망`이다. 기록의 개인 LAN 브리지와 내부 주소는 사용하지 않는다.

### 13.1 Linux PC의 임시 인터넷 공유

기록에서 패키지 다운로드에 성공한 임시 구성은 IPv4 forwarding과 USB 구간의 NAT였다. 기존 네트워크 관리 도구로 같은 경로를 제공하고 있다면 그 설정을 사용한다. 아래 규칙은 임시 검증용이며 반복해서 추가하지 않는다.

**PC**

```bash
R8Q_USB_IF=enx027700000002
sudo apt install iptables
sudo sysctl -w net.ipv4.ip_forward=1
r8q_uplink=$(ip -4 route get 1.1.1.1 | \
  awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
# 출력된 인터페이스가 PC의 외부망 인터페이스인지 확인한다.
printf '%s\n' "$r8q_uplink"
sudo iptables -I FORWARD 1 \
  -i "$R8Q_USB_IF" -o "$r8q_uplink" -s 192.168.77.0/30 -j ACCEPT
sudo iptables -I FORWARD 1 \
  -i "$r8q_uplink" -o "$R8Q_USB_IF" -d 192.168.77.0/30 \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -t nat -A POSTROUTING \
  -s 192.168.77.0/30 -o "$r8q_uplink" -j MASQUERADE
```

`R8Q_USB_IF`는 실제 PC USB 인터페이스 이름으로 바꾼다. 호스트의 기존 방화벽과 전달 설정도 확인한다. 위 `ip_forward`와 방화벽 규칙을 영구 서버 설정으로 저장하는 과정은 개인 운영 구성에 해당하므로 여기서 다루지 않는다.

**Debian의 임시 기본 경로**

```bash
USB_DEV=usb0
ip route replace default via 192.168.77.2 dev "$USB_DEV"
ip route
```

NCM으로 바꾼 뒤 인터페이스 이름이 달라질 수 있다. 고정 USB 인터넷 경로를 계속 사용할 때는 USB `.network` 파일의 `[Network]`에 `Gateway=192.168.77.2`를 추가할 수 있다. 인터페이스 대응은 이름보다 MAC 주소로 확인한다.

### 13.2 이름 해석과 기기 시간

DNS는 연결한 네트워크의 이름 해석 서버를 사용한다. `/etc/resolv.conf`가 실행되지 않는 systemd-resolved의 stub으로 연결되어 있다면 실제로 사용할 resolver와 일치시킨다. 기록에 있던 개인 내부 DNS나 도메인은 복사하지 않는다.

기기 시간이 과거로 돌아가 APT의 TLS 인증서 검증이 실패한 사례가 있었다. 인터넷이 되는 PC의 시간을 기준으로 초기 시간을 맞춘 뒤 다시 시도한다.

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

시간 보정 뒤 패키지 다운로드가 성공했다. TLS 검증을 비활성화하지 않는다. native 부팅에서 패키지 서비스가 시작되지 않는다면 기존 chroot의 `/usr/sbin/policy-rc.d`도 확인한다.

```bash
cat /usr/sbin/policy-rc.d
```

기록의 파일은 `#!/bin/sh`와 `exit 101`뿐인 chroot 설치용 제한이었다. 같은 임시 파일이 남아 있는 것이 확인되면 보관한 뒤 제거하고, 필요한 서비스가 시작되는지 확인한다.

```bash
if [ -f /usr/sbin/policy-rc.d ]; then
    mv /usr/sbin/policy-rc.d /root/policy-rc.d.before-native
fi
apt install systemd-timesyncd
systemctl enable --now systemd-timesyncd.service
```

다른 내용의 `policy-rc.d`가 있으면 그 정책을 확인한다. udev가 누락된 경우에는 11.3절의 설치와 네트워크 장치 재등록을 수행한다.

<a id="port-14"></a>

## 14 USB NCM 송신 집계 패치

Debian의 네이티브 부팅과 기본 USB 접속을 확인한 뒤 적용한다. 연결을 복구할 수 있도록 정상 동작한 RNDIS boot 이미지를 외부 PC에 보관한다.

### 14.1 패치의 역할과 첨부 자료

첨부한 `r8q-ncm-tx-aggregation.patch`는 `drivers/usb/gadget/function/f_ncm.c` 한 파일을 수정한다. 기기에서 보내는 Ethernet 프레임 여러 개를 NCM 전송 블록인 NTB 하나에 모으고, 데이터그램 수나 호스트가 협상한 전송 크기 한도에 도달하면 내보낸다. 데이터그램 수의 상한은 32이며, 트래픽이 적을 때는 300µs 타이머가 남은 집계의 전송을 요청한다. 이 타이머 값은 전체 USB 전송 시간이나 왕복 지연의 상한을 뜻하지 않는다. `u_ether.c`와 `u_ether.h`는 기존 다중 프레임·flush 처리의 호환성을 확인하는 원본이며, 첨부 패치는 이 두 파일을 수정하지 않는다.

저장소의 `sources`에는 원본 세 파일, `patches`에는 첨부 패치가 들어 있다. 문서 작성 중 제공된 원본에 `patch --dry-run -p1`과 `git apply --check`를 실행했고 모두 성공했다. 이 결과는 해당 원본에 패치를 적용할 수 있다는 뜻이다. 전체 커널 빌드나 실기기 안정성 검사를 대신하지 않는다.

기록에는 같은 이름의 NCM 집계 패치를 적용한 뒤 빌드와 속도 측정을 수행한 과정이 있다. 그러나 당시 패치의 전체 diff와 SHA256이 없어, 현재 첨부 패치와 당시 적용 패치가 모든 바이트까지 같은지 확인할 수 없다. 따라서 아래 성능은 **기록 당시 집계 수정 커널의 측정값**이며, 현재 첨부 패치를 문서 작성 중 다시 빌드하고 설치해 얻은 결과는 아니다.

### 14.2 적용과 빌드

저장소의 `patches`에서 패치를 `~/r8q-linux/r8q-ncm-tx-aggregation.patch`로 복사한다. 앞에서 고정한 커널 소스·툴체인과 기존 `out-native/.config`를 사용한다.

**PC**

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

기록에서는 위 USB 설정 세 가지가 모두 `=y`였다. 다르면 `USB_CONFIGFS_NCM`을 활성화하고 `olddefconfig`를 실행한 뒤, 의존하는 `USB_F_NCM`과 RNDIS 복구 경로도 확인한다.

기록의 `secgetspf: No such file or directory` 메시지는 그 빌드에서 최종 `Image` 생성을 막지 않았다. 성공 여부는 메시지 하나가 아니라 빌드 종료코드, 새 `Image`의 생성·갱신, boot 이미지에서 다시 추출한 커널의 일치 여부로 판단한다. 위 명령의 `pipefail`은 빌드가 실패해도 `tee`의 성공으로 가려지지 않도록 한다.

새 커널을 **이미 정상 부팅한 RNDIS 기반 Debian boot 이미지**에 넣는다. ramdisk를 NCM용으로 치환하지 않는다. 6장의 방법으로 `kernel`만 바꾸고, 재추출한 DTB와 RNDIS ramdisk가 기존 것과 같은지 확인한다.

### 14.3 NCM 수동 전환

저장소의 `templates/debian/r8q-usb-mode.sh`는 기록의 전환 스크립트를 바탕으로 설치 경로와 기본 USB 접속 설정에 맞춰 정리한 것이다. `/usr/local/sbin/r8q-usb-mode`에 설치하고 `chmod 755`를 실행한다.

**PC에서 템플릿 전송**

```bash
cd ~/r8q-linux
scp -i ~/.ssh/r8q-port-test templates/debian/r8q-usb-mode.sh \
  root@192.168.77.1:/usr/local/sbin/r8q-usb-mode
scp -i ~/.ssh/r8q-port-test templates/debian/r8q-usb-ncm.service \
  templates/debian/r8q-usb-ncm.timer root@192.168.77.1:/etc/systemd/system/
```

스크립트는 RNDIS의 고정 MAC 주소를 NCM 함수로 복사하고, UDC 연결을 해제한 뒤 USB 함수 링크를 교체해 다시 연결한다. 실행 중 USB가 재열거되므로 SSH가 끊길 수 있다. 전환 작업이 SSH 연결과 별개로 완료되도록 systemd 서비스로 실행하고, 먼저 120초 뒤 RNDIS로 돌아갈 타이머를 예약한다.

**Debian**

```bash
chmod 755 /usr/local/sbin/r8q-usb-mode
sh -n /usr/local/sbin/r8q-usb-mode
systemd-run --unit=r8q-ncm-rollback --on-active=120s \
  /usr/local/sbin/r8q-usb-mode rndis
systemd-run --unit=r8q-ncm-switch --collect \
  /usr/local/sbin/r8q-usb-mode ncm
```

**PC — USB가 다시 열거된 뒤**

```bash
lsusb -t
ip -br link
sudo ip link set enx027700000002 up
sudo ip addr replace 192.168.77.2/30 dev enx027700000002
ping -c 3 -W 2 192.168.77.1
ssh -i ~/.ssh/r8q-port-test root@192.168.77.1
```

`cdc_ncm` 드라이버와 실제 USB 연결 속도를 확인한다. 기록의 USB 3 지원 포트·케이블에서는 `5000M`이었고, 다른 PC 포트에서는 `480M`이었다. 전환과 재접속이 성공한 뒤 **Debian**에서 복구 타이머를 중지한다.

```bash
systemctl stop r8q-ncm-rollback.timer
```

기록에는 실행 권한이 없는 스크립트에 `test -x`를 실행해 뒤의 명령이 모두 건너뛰어진 사례가 있다. 그때는 타이머도 생성되지 않았다. `timer not loaded`만 보고 자동 복구가 이미 끝났다고 판단하지 말고, 스크립트의 실행 권한, USB configuration의 심볼릭 링크, 호스트 드라이버를 함께 확인한다.

### 14.4 부팅 후 자동 전환

**initramfs에서 처음부터 NCM을 구성한 이미지는 USB가 열거되지 않아 접속에 실패했다.** 해당 로그에서는 새 커널과 `/init`이 실행되고 Debian으로 전환하는 지점까지 도달했으므로, 이 결과만으로 커널 패닉이나 패치 자체의 실패라고 단정할 수 없다.

최종 성공 경로는 RNDIS ramdisk를 유지한 채 Debian을 부팅하고, 이후 NCM으로 전환하는 방식이었다. 저장소의 `r8q-usb-ncm.service`와 `r8q-usb-ncm.timer`를 `/etc/systemd/system`에 설치한다. 템플릿은 `/usr/local/sbin/r8q-usb-mode`를 호출하며, 기록과 같은 `OnBootSec=20s`를 사용한다.

**Debian**

```bash
systemctl daemon-reload
systemctl enable r8q-usb-ncm.timer
sync
systemctl reboot
```

약 30초 뒤 PC에서 USB 드라이버와 ping을 확인한다. 다시 접속한 뒤에는 서비스 결과를 확인한다.

```bash
systemctl status r8q-usb-ncm.service --no-pager -l
journalctl -b -u r8q-usb-ncm.service --no-pager
```

기록에는 이 구성을 안내한 뒤 재부팅 후 `cdc_ncm, 5000M`과 ping 손실 0%를 확인한 사용자 출력이 있다. 반복 부팅이나 장기간 안정성까지 검증한 기록은 없다.

자동 전환 해제는 다음 명령으로 한다.

```bash
systemctl disable --now r8q-usb-ncm.timer
```

이미 NCM으로 연결된 상태는 타이머를 중지해도 그대로다. 즉시 RNDIS로 돌아가려면 수동 전환 서비스를 실행하고, 타이머를 끈 채 다음 부팅을 하면 RNDIS로 유지된다.

### 14.5 양방향 전송 성능 확인

**Debian**

```bash
iperf3 -s -B 192.168.77.1
```

**PC 또는 USB 연결 호스트**

```bash
iperf3 -c 192.168.77.1
iperf3 -c 192.168.77.1 -R
```

첫 명령은 호스트에서 기기로 보내므로 **기기 수신**, `-R`은 기기에서 호스트로 보내므로 **기기 송신**이다. SuperSpeed 연결에서 기록된 결과는 다음과 같다.

| 상태 | 기기 수신 | 기기 송신 |
|---|---:|---:|
| 집계 수정 전 NCM | 2.24Gbps | 744Mbps |
| 기록 당시 집계 수정 후 NCM | 2.26Gbps | 1.30Gbps |

송신 결과는 receiver 기준이며, 수정 후 송신 재전송은 0이었다. 결과는 10초 측정으로, 모든 케이블·호스트의 속도나 장기간 안정성을 보장하지 않는다. USB IRQ를 CPU4로 옮긴 시험에서는 송신 718Mbps로 뚜렷한 개선이 없었다. IRQ affinity, CPU governor, DWC3 작업 큐의 병렬화 등을 최종 포팅의 필수 변경으로 포함하지 않는다.

<a id="port-15"></a>

## 15 부팅 화면 끄기

Android 화면 관리 프로그램이 없는 상태에서 부팅 로고가 남았다. 기록에서는 backlight, framebuffer blank, DPMS 쓰기만으로 화면을 끄지 못했고, DRM 모드 설정 후 프로그램이 종료되는 방법으로 화면을 껐다. 자동으로 화면을 끄는 정책은 선택 사항이며 Debian 부팅의 필수 조건은 아니다.

**Debian**

```bash
apt install libdrm-tests
modetest -M msm_drm -c
```

실기기에서 커넥터 ID와 모드를 조회한다. 기록에서는 ID `29`, 커넥터 `DSI-1`이었고 다음 명령으로 화면이 꺼졌다는 사용자 보고가 있다.

```bash
modetest -M msm_drm -s '29:1080x2400x60x185024cmdHS' </dev/null
```

커넥터 ID는 고정된 인터페이스가 아니므로 자동 실행을 구성할 때도 대상 기기에서 값을 확인한다. 모드 이름에 `60`이 들어 있지만 당시 `modetest`가 표시한 계산 주사율은 `28.19Hz`였다. 이 시험을 60Hz 화면 동작이나 GPU 가속의 검증으로 해석하지 않는다. 기록에서 드라이버 이름 `msm`은 장치를 열지 못했고 `msm_drm`은 성공했다.

<a id="port-16"></a>

## 16 Wi-Fi 포팅의 진행 상태와 미해결 항목

Wi-Fi는 추가 작업이며 USB를 이용한 Debian 기본 부팅의 전제 조건으로 두지 않는다. 기록에서는 `wlan0` 생성이나 무선 연결에 성공하지 않았다. 아래는 당시 진행한 펌웨어·서비스·드라이버 초기화 과정을 재현하기 위한 선택 절차다.

### 16.1 원본 super에서 vendor 펌웨어 확보

기록의 QCA6390 펌웨어는 modem 펌웨어 파티션에서 찾지 못했고, Android `super` 안의 논리 `vendor` 파티션에서 확보했다. 기기의 `super`를 수정하거나 Debian 루트로 포맷하는 과정이 아니다. 원본 블록을 읽어 외부 PC에 보관한 뒤 복사본에서 vendor를 추출한다.

기록의 `super` 장치는 `/dev/sda29`였다. 대상 기기의 파티션 이름과 크기를 먼저 확인하고, 다른 기기의 번호를 그대로 사용하지 않는다. 외부 PC에는 원본 이미지와 추출 이미지 모두를 저장할 공간이 필요하다.

**PC**

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

`PARTNAME=super`와 장치 크기를 확인하고, 복사한 파일 크기도 그 값과 비교한다. 기록에서 복사본 크기는 `10,292,822,016`바이트였다. 이 수치를 다른 저장소 모델의 기대 크기로 사용하지 않는다.

당시에는 LineageOS의 `extract-utils`에 있는 `extract_utils.lp.LpImage`로 vendor를 추출했다.

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

당시 사용한 extract-utils의 정확한 커밋과 Python 의존성 버전은 기록되지 않았다. 위 코드는 당시 확인된 API 기준이며, 새로 받은 버전에서 API나 의존성이 달라졌다면 그 저장소의 요구사항을 확인한다. 재현 시 실제 사용한 커밋을 위 파일에 기록한다.

추출된 vendor는 **EROFS**였다. ext4용 `noload` 옵션을 사용한 초기 시도는 실패했고, 다음 읽기 전용 마운트가 성공했다.

```bash
mkdir -p vendor-extract/mnt
sudo mount -t erofs -o loop,ro \
  vendor-extract/vendor.img vendor-extract/mnt
ls -lh vendor-extract/mnt/firmware/qca6390/
ls -lh vendor-extract/mnt/etc/wifi/WCNSS_qcom_cfg.ini
```

확인된 펌웨어 파일은 `amss20.bin`, `bdwlan.elf`, `bdwlan.elf1`, `bdwlan.elf2`, `m3.bin`, `regdb.bin`이며, 설정 파일은 `etc/wifi/WCNSS_qcom_cfg.ini`였다. 이번 저장소에는 vendor 이미지나 이 펌웨어가 포함되지 않으므로 별도로 확보해야 한다.

### 16.2 Debian의 펌웨어 요청 경로 연결

**PC**

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

기록에서는 `firmware_class.path`가 `/vendor/firmware_mnt/image`였고 WLAN의 `fwpath`는 비어 있었다. 위 링크는 실제 QCA6390 파일과 설정을 표준 펌웨어 탐색 경로에서도 찾을 수 있도록 한 당시 구성이다. modem용 파티션이 마운트돼 있다는 사실만으로 QCA6390 펌웨어가 준비됐다고 판단하지 않는다.

복사가 끝났으면 PC의 읽기 전용 vendor 마운트를 해제할 수 있다.

```bash
sudo umount vendor-extract/mnt
```

### 16.3 QRTR 이름 서비스와 chroot의 서비스 시작 제한

Debian에 `qrtr-tools`를 설치했다. 기록의 버전은 `1.1-2+b1`이었다. 설치 시 남아 있던 `policy-rc.d`가 종료코드 101로 서비스 자동 시작을 막았고, `qrtr_rx` 커널 스레드만 실행 중이었다. 커널 스레드는 `qrtr-ns` 사용자 공간 서비스를 대신하지 않는다.

**Debian**

```bash
apt install qrtr-tools
dpkg -L qrtr-tools | grep -E 'qrtr-ns|service$'
systemctl list-unit-files '*qrtr*' --no-pager
pgrep -a qrtr
```

기존 chroot의 서비스 시작 제한 파일을 그대로 가져온 경우 내용을 확인한다. 기록에서는 이를 백업 경로로 옮긴 뒤 서비스를 시작했다.

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

실제 출력에서 `qrtr-ns.service`의 `active (running)`, `/usr/bin/qrtr-ns -f 1`, WLAN 펌웨어 서비스 lookup과 QMI WLFW 연결이 확인됐다. 다만 QRTR 준비만으로 `wlan0`가 생성되지는 않았다. 이미 CNSS가 타임아웃·복구 상태에 걸려 있던 시험에서는 서비스를 준비한 상태로 재부팅한 뒤 다시 확인했다.

### 16.4 CNSS의 Android daemon 대기 비트 변경

기록에서는 `drivers/net/wireless/cnss2/main.c`의 `cnss_init_control_params`에서 `ENABLE_DAEMON_SUPPORT` 비트만 해제했다. Android daemon을 포함해 클라이언트 두 개를 기다리는 조건을 바꾼 것이다. 아래는 사용자 diff에서 확인한 **참조용 발췌**다.

```diff
-               plat_priv->ctrl_params.quirks |= BIT(ENABLE_DAEMON_SUPPORT);
+               plat_priv->ctrl_params.quirks &= ~BIT(ENABLE_DAEMON_SUPPORT);
```

이 줄은 `of_property_read_bool(..., "cnss-daemon-support")` 조건 안에 있다. 다른 CNSS quirks를 모두 초기화하거나 probe 검사를 우회하는 변경은 아니다. 저장소의 [CNSS 변경 참고](../reference/cnss-daemon-support.ko.md)는 이 변경의 근거를 설명하는 참고 문서이며 Wi-Fi 완성 패치가 아니다.

이번 NCM 소스 묶음에는 CNSS 원본이 없어 이 변경을 적용 검사하지 않았다. 해당 고정 커널의 코드가 기록과 같은지 확인하고, 소스 차이를 보관한 뒤 앞의 빌드·커널 교체·복구 절차로 별도 시험한다. 기본 USB 부팅의 필수 패치로 포함하지 않는다.

### 16.5 직접 확인된 실패와 진단의 한계

이 커널의 WLAN 제어 장치는 `/dev/wlan`이었다. 제어 코드가 사용자 입력 세 바이트를 읽으므로, 기록처럼 줄바꿈을 포함한 `ON\n`을 전달했다.

```bash
printf 'ON\n' > /dev/wlan
echo "활성화 종료 코드: $?"
dmesg |
  grep -E 'R8Q-WIFI:|Failed to probe host driver|Number of clients'
ip -br link
```

사용자가 제공한 결과는 다음과 같다.

```text
printf: write error: Invalid argument
활성화 종료 코드: 1
cnss: Number of clients is 1
R8Q-WIFI: sync_create ret=0
R8Q-WIFI: qdf_ctx ret=-14
cnss: Failed to probe host driver, err = -14
```

`wlan0`는 나타나지 않았다. 추가된 `R8Q-WIFI:` 로그는 당시 진단용 소스 변경에서 나온 것으로, 수정하지 않은 기본 커널에서 그대로 출력된다고 기대하면 안 된다.

사용자가 제공한 `hdd_init_qdf_ctx` 본문은 QDF 컨텍스트가 없으면 `-EINVAL`, `cds_smmu_mem_map_setup(qdf_dev, ucfg_ipa_is_present())`가 성공하지 않으면 `-EFAULT`를 반환한다. 따라서 `qdf_ctx ret=-14`가 SMMU 초기화 실패 경로와 연결된다는 근거는 있다.

반면 구체적인 **WLAN과 IPA의 SMMU 상태 불일치**는 추가 진단 결과에 대한 기록상의 분석이다. 해당 진단 출력이 보존 자료에 포함되어 있지 않으므로 세부 불일치 조건을 독립적으로 재검증할 수 없다. firmware ready 도달에 대한 일부 설명도 실제 로그가 빠진 분석 기록에만 남아 있으므로, 직접 확인한 클라이언트 수 1과 host probe의 `-14`와 구분한다.

Wi-Fi 시험은 이 상태에서 중단됐다. 진단용 전체 소스 차이와 펌웨어가 빠져 있어 당시 `-dirty` 커널을 완전히 복원할 입력은 부족하다. 계속 시험한다면 펌웨어 요청 경로, QRTR 연결, CNSS 준비 상태, QDF 초기화, netdev 생성 순으로 확인한다. 펌웨어 파일 존재나 `/dev/wlan` 쓰기 종료코드만으로 성공을 판정하지 않는다.

<a id="port-17"></a>

## 17 패키지와 rootfs 무결성

기존 chroot를 재사용하면 rootfs의 불완전한 파일이 포팅 문제처럼 보일 수 있다. 기록에서는 `/usr/sbin/groupadd`가 실행 가능한 1바이트 파일이었다. 종료코드 0을 반환해도 그룹을 만들지 않아 `iperf3` 패키지 설정이 실패했다.

관련 명령의 위치, 패키지 파일 상태, 미완료 설정을 확인한다.

```bash
type -a groupadd addgroup getent
ls -lh /usr/sbin/groupadd
dpkg -V passwd
dpkg --audit
getent group iperf3
```

기록에서는 `passwd` 패키지를 재설치해 계정 관리 프로그램을 정상 크기로 복구하고 `dpkg --configure -a`를 수행했다. 이후 `dpkg --audit`에 미완료 패키지가 표시되지 않았고 `iperf3` 그룹과 계정이 생성됐다.

```bash
apt-get install --reinstall passwd
dpkg --configure -a
dpkg --audit
getent group iperf3
getent passwd iperf3
```

영향이 확인된 파일과 패키지를 복구한다. 기록만으로 1바이트 파일을 만든 과거 작업의 출처까지 확정할 수는 없다. 이 복구는 깨끗한 rootfs를 새로 만드는 경로의 필수 단계가 아니다. 앞서 확인한 `udev` 누락도 rootfs 구성 문제이므로, `systemd-udevd`가 없거나 USB가 `pending` 상태라면 11장의 패키지·장치 초기화 절차를 확인한다.

<a id="port-18"></a>

## 18 복구와 진단

### 18.1 boot가 정상 동작하지 않을 때

리커버리의 root ADB로 돌아가 외부 PC에 보관한 **정상 동작한 Debian RNDIS 또는 native rescue boot 이미지**를 복원한다. 파일 이름만으로 선택하지 말고, 지금 복구하려는 단계에서 사용할 수 있는 정상 이미지인지 확인한다. 2장에서 저장한 Android 원본 boot와 Debian RNDIS boot는 용도가 다르다.

**PC — 아래 경로는 선택한 정상 이미지로 바꾼다.**

```bash
adb root
sha256sum backup/boot-good-rndis.img
adb push backup/boot-good-rndis.img /tmp/boot-restore.img
adb shell 'readlink -f /dev/block/by-name/boot'
adb shell 'dd if=/tmp/boot-restore.img of=/dev/block/by-name/boot bs=1048576 && sync'
adb shell sha256sum /dev/block/by-name/boot
```

쓰기 전 대상 파티션과 이미지 크기를 6장의 절차로 확인하고, 기록 후 boot 파티션 해시가 선택한 이미지와 일치하는지 확인한다. 정상 boot를 복원해도 이미 포맷한 userdata의 Android 데이터는 되살아나지 않는다. Debian 설치 뒤에는 정상 `boot-native-rescue.img` 또는 RNDIS `boot-debian.img`를 사용해 접속을 복구한다.

기록에서는 `adb reboot` 뒤 리커버리로 돌아온 사례가 있었다. 이 경우 리커버리의 `Reboot system now`를 선택하고 실제 시스템 부팅을 확인한다. 연결 실패만 보고 userdata를 다시 포맷하지 않는다.

### 18.2 last_kmsg 확인

**PC — 리커버리 ADB 연결 상태**

```bash
mkdir -p ~/r8q-linux/debug-native
adb exec-out cat /proc/last_kmsg > ~/r8q-linux/debug-native/last_kmsg.txt
grep -aEn 'Linux version|Kernel command line|R8Q-NATIVE:|Failed to execute|No working init|not syncing|BUG:|Oops:|panic' \
  ~/r8q-linux/debug-native/last_kmsg.txt
```

`/init` 템플릿은 `/dev/kmsg`에 `R8Q-NATIVE:` 마커를 출력한다. 커널 빌드 식별값과 마커를 함께 보아 새 커널 실행, USB 초기화, Debian으로의 전환 중 어느 단계까지 진행했는지 구분한다. 기록의 `last_kmsg`에는 여러 부팅과 부트로더 로그가 섞여 있었으므로, 한 번의 부팅 구간을 지정한 뒤 원인을 분석한다. `last_kmsg`가 없는 구성은 사용 가능한 pstore 등 다른 로그 경로를 확인한다.

### 18.3 증상별 첫 확인

| 증상 | 먼저 확인할 내용 |
|---|---|
| 리커버리에서 오래된 uname이 나옴 | 리커버리 자체의 커널일 수 있다. 시스템 boot로 부팅한 뒤 판정한다. |
| USB 장치가 나타나지 않음 | `/init` 마커, 초기 `/dev/null`, UDC의 존재·bind 결과, raw Image와 DTB를 확인한다. |
| `ifname`이 unnamed로 나옴 | UDC bind 후 네트워크 인터페이스가 나타날 때까지 기다리는지 확인한다. |
| 호스트 NIC는 보이지만 ping 불가 | 재열거 후 호스트 IPv4가 사라졌는지, 양 끝의 MAC·IP가 맞는지 확인한다. |
| SSH는 안 되지만 rescue 접속 가능 | rootfs의 init, sshd 설정·키·계정, udev, networkd를 확인한다. |
| networkd에서 USB가 pending | udev 실행·trigger, `.network`의 MAC 일치, 먼저 매칭되는 다른 파일을 확인한다. |
| NCM으로 직접 부팅할 때만 연결 실패 | 정상 RNDIS ramdisk로 돌아간 뒤 Debian에서 지연 전환을 시험한다. |
| ext4를 마운트하지 못함 | userdata 식별, mke2fs 완료·종료코드, ext4 기능과 커널의 대응을 확인한다. |
| 부팅 로고가 남음 | DRM 커넥터와 모드를 조회하고 15장의 modetest 방법을 확인한다. |
| CNSS 초기화가 진행돼도 wlan0가 없음 | QDF probe의 `-14`와 SMMU 초기화 실패 경로를 확인한다. 구체적 IPA/WLAN 불일치는 이 기록에서 재검증되지 않았다. |

<a id="port-19"></a>

## 19 완료 확인과 보관할 자료

- [ ] 고정한 커널 커밋과 툴체인 버전을 기록했다.
- [ ] 원본 boot, 커널 설정, DTB를 외부 PC에 보관하고 해시를 확인했다.
- [ ] userdata 변경 전에 RNDIS rescue의 독립 부팅을 확인했다.
- [ ] userdata의 PARTNAME, 크기, 마운트 상태를 확인했다.
- [ ] ext4 기능과 포맷 완료를 확인하고 rootfs 전송 해시·tar 종료코드를 검증했다.
- [ ] PID 1이 systemd이고 루트가 ext4이며 SSH, udev, networkd가 동작하는지 확인했다.
- [ ] 재부팅 후에도 USB로 접속할 수 있다.
- [ ] NCM을 사용한다면 RNDIS에서의 지연 전환과 양방향 통신을 확인했다.
- [ ] Wi-Fi, GPU 가속, 영상 가속의 미완료·미검증 상태를 구분해 기록했다.

다음 자료를 함께 보관한다.

```text
커널 커밋 / 툴체인 커밋과 버전
running.config / 최종 out-native/.config
전체 git diff / 빌드 로그
원본 boot / rescue boot / Debian RNDIS boot
최종 kernel과 DTB / ramdisk cpio / init 원본
사용한 BusyBox·magiskboot의 버전과 해시
Debian rootfs 해시와 패키지 목록
파티션 표와 루트 UUID
최종 udev·네트워크·SSH·NCM unit 설정
```

**PC — 보관 예**

```bash
cd ~/r8q-linux/kernel
git rev-parse HEAD > ../backup/kernel-commit.txt
git diff --binary > ../backup/native-kernel-changes.patch
cp ../out-native/.config ../backup/native.config
cd ..
sha256sum boot-native-rescue.img boot-debian.img \
  busybox-arm64 magiskboot-arm64 > backup/final-artifacts.sha256
```

`git diff`에는 추적하지 않는 새 파일이 포함되지 않는다. 새 소스·설정 파일이 있다면 별도로 보관하고 목록을 남긴다. 툴체인, 펌웨어, 바이너리, rootfs도 해당 버전과 해시를 함께 기록해야 이후 재현할 수 있다.

**Debian — 패키지 목록**

```bash
dpkg-query -W -f='${binary:Package}\t${Version}\n' > /root/port-package-versions.tsv
```

개인 hostname, DNS, LAN 브리지, 셸 alias, 컨테이너 운영, 로그 보관 한도, 충전 상한 80% 설정은 기본 포팅 재현 조건에 포함하지 않는다.

<a id="port-20"></a>

## 20 참고 자료

주요 실기기 근거는 2026년 10월 7일부터 8일까지의 작업 기록에 보존된 명령 출력이다. 실제 결과와 새로 정리한 템플릿의 검증 범위는 [자료 출처와 검증 범위](../PROVENANCE.ko.md)에 구분했다. 결과나 재현 코드가 없는 시험 주장은 실측으로 취급하지 않는다.

- [LineageOS 커널 저장소](https://github.com/LineageOS/android_kernel_samsung_sm8250) — 커널 소스 확보에 사용한 저장소. 브랜치의 최신 상태 대신 문서에 기록한 고정 커밋을 사용한다.
- [Magisk Tools](https://topjohnwu.github.io/Magisk/tools.html) — boot unpack/repack 및 cpio 명령 형식.
- [Linux USB gadget configfs](https://www.kernel.org/doc/html/v5.10/usb/gadget_configfs.html) — USB gadget 구성과 UDC 연결.
- [Debian debootstrap](https://manpages.debian.org/trixie/debootstrap/debootstrap.8.en.html) — 새 Debian rootfs를 만드는 대안.

원본 코드의 해시와 적용 검사 결과는 [자료 출처와 검증 범위](../PROVENANCE.ko.md)에 기록했다. 전체 저장소 파일은 루트의 `SHA256SUMS`로 확인할 수 있다.
