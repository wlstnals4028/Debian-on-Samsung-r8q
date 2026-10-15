# NCM source snapshot

This directory contains two original C files and one header used to check the supplied NCM patch:

```text
drivers/usb/gadget/function/f_ncm.c
drivers/usb/gadget/function/u_ether.c
drivers/usb/gadget/function/u_ether.h
```

It is a source excerpt, not a standalone module or a complete kernel tree. The patch changes only `f_ncm.c`; the common Ethernet files provide context for multi-frame support and timeout flushing.

From this directory, applicability checks are:

```sh
patch --dry-run -p1 -i ../patches/r8q-ncm-tx-aggregation.patch
```

Run the Git check from the repository root:

```sh
git apply --check --directory=sources patches/r8q-ncm-tx-aggregation.patch
```

Preserve the original SPDX and copyright notices. Hashes are in [PROVENANCE.md](../PROVENANCE.md); license information is in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## 한국어

C 파일 두 개와 헤더 한 개의 원본입니다. 전체 커널이나 단독 빌드 모듈이 아닙니다. 패치는 `f_ncm.c`만 수정하며 두 `u_ether` 파일은 기존 다중 프레임 지원과 flush 동작을 확인하는 참고 소스입니다. 위 명령은 적용 가능성만 검사합니다.
