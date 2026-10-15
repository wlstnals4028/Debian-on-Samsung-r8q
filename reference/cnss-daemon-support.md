# CNSS daemon-support experiment

[English](cnss-daemon-support.md) · [한국어](cnss-daemon-support.ko.md) · [Guide](../docs/porting-guide.en.md#port-16)

This is an incomplete Wi-Fi experiment, not a working Wi-Fi patch or a prerequisite for native Debian boot.

The recorded change was in `drivers/net/wireless/cnss2/main.c`, inside `cnss_init_control_params()`, under the `of_property_read_bool(..., "cnss-daemon-support")` condition.

Before:

```c
plat_priv->ctrl_params.quirks |= BIT(ENABLE_DAEMON_SUPPORT);
```

After:

```c
plat_priv->ctrl_params.quirks &= ~BIT(ENABLE_DAEMON_SUPPORT);
```

The change clears that bit while retaining other quirks. It was intended to avoid waiting for an Android-specific daemon client. The record then shows one CNSS client, but host QDF initialization still fails with `-14` and `wlan0` does not become usable.

The CNSS source file and full diagnostic changes are not included in the supplied three-file snapshot. This note is a reference excerpt, not an automatically applicable patch; no applicability check was performed for it. Compare your complete source tree first and retain the working RNDIS boot image before any further experiment. See [provenance](../PROVENANCE.md) for the distinction between direct failure output and the deeper SMMU diagnosis.
