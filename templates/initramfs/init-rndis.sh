#!/bin/sh
# Adapted from the recorded working initialization sequence; not device-tested as a whole.
# Validate RAM-only USB rescue first, then change BOOT_STAGE to debian.
BOOT_STAGE=rescue
ROOT_DEVICE=/dev/sda36
UDC_NAME=a600000.dwc3

export PATH=/bin
export TERM=xterm
exec >/dev/kmsg 2>&1
set -x
echo 'R8Q-NATIVE: init entered'
/bin/busybox --install -s /bin

hold()
{
    echo "R8Q-NATIVE: hold: $*"
    while :; do sleep 60; done
}

mount -t proc proc /proc || hold 'proc mount failed'
mount -t sysfs sysfs /sys || hold 'sysfs mount failed'
mount -t devtmpfs devtmpfs /dev || hold 'devtmpfs mount failed'
mount -t tmpfs tmpfs /run || hold 'run mount failed'
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts -o mode=620,ptmxmode=666 || hold 'devpts failed'
ln -sfn pts/ptmx /dev/ptmx
mount -t configfs configfs /config || hold 'configfs mount failed'

n=0
while [ ! -e "/sys/class/udc/$UDC_NAME" ]; do
    n=$((n + 1))
    [ "$n" -lt 60 ] || hold 'USB controller did not appear'
    sleep 1
done

g=/config/usb_gadget/native
mkdir -p "$g" || hold 'gadget creation failed'
cd "$g" || hold 'gadget directory missing'
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0200 > bcdUSB
echo 0x0100 > bcdDevice
mkdir -p strings/0x409
echo r8q-native-test > strings/0x409/serialnumber
echo Linux > strings/0x409/manufacturer
echo 'r8q native boot test' > strings/0x409/product
mkdir -p configs/c.1/strings/0x409
echo RNDIS > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower
mkdir -p functions/rndis.usb0 || hold 'RNDIS function creation failed'
echo 02:77:00:00:00:01 > functions/rndis.usb0/dev_addr
echo 02:77:00:00:00:02 > functions/rndis.usb0/host_addr
ln -s "$g/functions/rndis.usb0" configs/c.1/rndis.usb0 || hold 'RNDIS linking failed'
echo "$UDC_NAME" > UDC || hold 'USB controller binding failed'

n=0
while :; do
    netif=$(cat functions/rndis.usb0/ifname)
    [ -e "/sys/class/net/$netif" ] && break
    n=$((n + 1))
    [ "$n" -lt 30 ] || hold "USB network interface missing: $netif"
    sleep 1
done
ip link set lo up
ip addr add 192.168.77.1/30 dev "$netif" || hold 'USB address failed'
ip link set "$netif" up || hold 'USB link failed'

rescue()
{
    echo "R8Q-NATIVE: rescue: $*"
    cd /
    telnetd -F -b 192.168.77.1 -p 23 -l /bin/sh &
    while :; do sleep 60; done
}

case "$BOOT_STAGE" in
    rescue) rescue 'RAM-only installation shell' ;;
    debian) ;;
    *) hold 'Invalid BOOT_STAGE' ;;
esac

cd /
mkdir -p /newroot
mount -t ext4 -o rw,noatime "$ROOT_DEVICE" /newroot || rescue 'Debian root mount failed'
[ -x /newroot/sbin/init ] || rescue 'Debian init missing'
mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/run /newroot/config
echo 'R8Q-NATIVE: switching to Debian'
mount -o move /dev /newroot/dev || rescue 'move dev failed'
mount -o move /proc /newroot/proc || rescue 'move proc failed'
mount -o move /sys /newroot/sys || rescue 'move sys failed'
mount -o move /run /newroot/run || rescue 'move run failed'
mount -o move /config /newroot/config || rescue 'move config failed'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec /bin/switch_root /newroot /sbin/init
