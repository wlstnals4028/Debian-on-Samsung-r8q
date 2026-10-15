#!/bin/sh
# Adapted from the recorded USB mode switch; no LAN bridge configuration.
set -eu
g=/config/usb_gadget/native
mode="${1:?usage: r8q-usb-mode ncm or rndis}"
case "$mode" in
    ncm|rndis) ;;
    *) echo 'mode must be ncm or rndis' >&2; exit 1 ;;
esac

if [ "$mode" = ncm ]; then
    mkdir -p "$g/functions/ncm.usb0"
    cat "$g/functions/rndis.usb0/dev_addr" > "$g/functions/ncm.usb0/dev_addr"
    cat "$g/functions/rndis.usb0/host_addr" > "$g/functions/ncm.usb0/host_addr"
fi

echo '' > "$g/UDC"
rm -f "$g/configs/c.1/rndis.usb0" "$g/configs/c.1/ncm.usb0"
ln -s "$g/functions/$mode.usb0" "$g/configs/c.1/$mode.usb0"
echo a600000.dwc3 > "$g/UDC"
udevadm trigger --action=add --subsystem-match=net
networkctl reload
