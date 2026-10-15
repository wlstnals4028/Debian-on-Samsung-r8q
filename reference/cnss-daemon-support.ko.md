# CNSS daemon 지원 변경 실험

[English](cnss-daemon-support.md) · [한국어](cnss-daemon-support.ko.md) · [가이드](../docs/porting-guide.ko.md#port-16)

미완료 Wi-Fi 실험의 참고 자료입니다. 동작하는 Wi-Fi 패치나 Debian 기본 부팅의 필수 조건이 아닙니다.

기록에서 수정한 곳은 `drivers/net/wireless/cnss2/main.c`의 `cnss_init_control_params()` 안에 있는 `of_property_read_bool(..., "cnss-daemon-support")` 조건입니다.

변경 전:

```c
plat_priv->ctrl_params.quirks |= BIT(ENABLE_DAEMON_SUPPORT);
```

변경 후:

```c
plat_priv->ctrl_params.quirks &= ~BIT(ENABLE_DAEMON_SUPPORT);
```

다른 quirks는 유지하면서 이 비트만 해제합니다. Android 전용 daemon 클라이언트를 기다리는 조건을 피하려는 변경입니다. 이후 CNSS 클라이언트 수 1은 확인했지만, QDF 초기화가 `-14`로 실패해 정상 `wlan0`를 만들지는 못했습니다.

CNSS 원본과 진단 수정 전체는 제공된 세 파일에 포함되어 있지 않습니다. 따라서 자동 적용 패치가 아닌 참고 발췌이며 적용 검사를 수행하지 않았습니다. 전체 소스와 비교하고 추가 실험 전 정상 RNDIS boot 이미지를 보관합니다. 직접 실패 출력과 더 깊은 SMMU 진단의 차이는 [자료 출처와 검증 범위](../PROVENANCE.ko.md)에 설명했습니다.
