#!/bin/bash

REPORAW="https://raw.githubusercontent.com/janztec/empc-arpi4-linux-drivers/main"

ERR='\033[0;31m'
INFO='\033[0;32m'
NC='\033[0m' # No Color

KERNEL=$(uname -r)
VERSION=$(echo $KERNEL | cut -d. -f1)
PATCHLEVEL=$(echo $KERNEL | cut -d. -f2)
SUBLEVEL=$(echo $KERNEL | cut -d. -f3 | cut -d- -f1)
KERNELVER=$(($VERSION*100+$PATCHLEVEL))

YEAR=$[`date +'%Y'`]
DATE=$(date +"%Y%m%d_%H%M%S")


# Check if preconditions are met
if [ $EUID -ne 0 ]; then
    echo -e "$ERR ERROR: This script should be run as root. $NC" 1>&2
    exit 1
fi

if test -e /opt/janztec/empc-arpi4-linux-drivers/installdrivers.sh; then
    echo -e "$ERR ERROR: This script is not supported on images with pre-installed driver installation script. Use script /opt/janztec/empc-arpi4-linux-drivers/installdrivers.sh , or contact Janz Tec support for new image download. $NC" 1>&2
    exit 1
fi

wget -q --spider https://www.github.com
if [ $? -ne 0 ]; then
    echo -e "$ERR ERROR: Internet connection required! $NC" 1>&2
    exit 1
fi

lsb_release -a 2>1 | grep "Raspbian GNU/Linux" || (echo -e "$ERR ERROR: Raspbian GNU/Linux required! $NC" 1>&2; exit 1;)

if [ $KERNELVER -lt 601 ]; then 
    echo -e "$ERR ERROR: Kernel is outdated! Please update your kernel or install the latest Raspberry PI OS! Kernel versions below 6.1.0 are not supported! $NC" 1>&2
    exit 1
fi

if [ $YEAR -lt 2023 ] ; then
    echo -e "$ERR ERROR: invalid date. set current date and time! $NC" 1>&2
    exit 1
fi

FREE=`df $PWD | awk '/[0-9]%/{print $(NF-2)}'`
if [[ $FREE -lt 1048576 ]]; then
  echo -e "$ERR ERROR: 1GB free disk space required (run raspi-config, 'Expand Filesystem') $NC" > /dev/stderr
  exit 1
fi

UNATTENDED=0

if [ "$1" = "-y" ]
then
        UNATTENDED=1
fi

WELCOME="These drivers and tools will be installed:\n
- SPI driver
- CAN-FD driver (SocketCAN)
- Serial driver (RS232/RS485)
- TPM driver
- GPIO port expander driver
- RTC driver
- can-utils, device-tree-compiler, gpio tools, socat\n
continue installation?"

if [ $UNATTENDED -eq 0 ]
then
    if (whiptail --title "emPC-A/RPI4 Installation Script" --yesno "$WELCOME" 20 60) then
        echo ""
    else
        exit 0
    fi
fi

apt -y install device-tree-compiler can-utils gpiod libgpiod-dev libgpiod-doc socat


rm -rf /tmp/empc-arpi-linux-drivers
mkdir -p /tmp/empc-arpi-linux-drivers

cd /tmp/empc-arpi-linux-drivers

# Download device tree sources
wget -nv $REPORAW/src/spi6-3cs-overlay.dts -O spi6-3cs-overlay.dts
wget -nv $REPORAW/src/mcp251xfd-spi6-0-overlay.dts -O mcp251xfd-spi6-0-overlay.dts
wget -nv $REPORAW/src/sc16is760-spi6-overlay.dts -O sc16is760-spi6-overlay.dts
wget -nv $REPORAW/src/tpm-slb9670-spi6-overlay.dts -O tpm-slb9670-spi6-overlay.dts
wget -nv $REPORAW/src/mcp23018-overlay.dts -O mcp23018-overlay.dts

# Build device tree overlays and copy to /boot/overlays
dtc -@ -I dts -O dtb -o spi6-3cs.dtbo spi6-3cs-overlay.dts
dtc -@ -I dts -O dtb -o mcp251xfd-spi6-0.dtbo mcp251xfd-spi6-0-overlay.dts
dtc -@ -I dts -O dtb -o sc16is760-spi6.dtbo sc16is760-spi6-overlay.dts
dtc -@ -I dts -O dtb -o tpm-slb9670-spi6.dtbo tpm-slb9670-spi6-overlay.dts
dtc -@ -I dts -O dtb -o mcp23018.dtbo mcp23018-overlay.dts

cp *.dtbo /boot/overlays/


# Check on every boot if J301 is set. if it is not set, then set RS485 mode automatically in driver using ioctl

# Download and compile ttySC0 rs485 switch source
wget -nv $REPORAW/src/tty-auto-rs485.c -O tty-auto-rs485.c
gcc tty-auto-rs485.c -o /usr/sbin/tty-auto-rs485

if [ ! -f "/usr/sbin/tty-auto-rs485" ]; then
    echo -e "$ERR Error: Installation failed! (could not build tty-auto-rs485) $NC" 1>&2
    if [ $UNATTENDED -eq 0 ]
    then
        whiptail --title "Error" --msgbox "Installation failed! (could not build tty-auto-rs485)" 10 60
    fi
    exit 1
fi

WELCOME2="These configuration settings will automatically be made:\n
- Install emPC-A/RPI4 default config.txt
- Install RTC initialization in initramfs
- Increase USB max. current
- Enable previously installed drivers
- Install rpi4 lte and gps service
\ncontinue installation?\n"

if [ $UNATTENDED -eq 0 ]
then
    if (whiptail --title "emPC-A/RPI4 Installation Script" --yesno "$WELCOME2" 18 60) then
        echo ""
    else
        exit 0
    fi
fi

# Install emPC-A/RPI4 default config.txt
echo -e "$INFO INFO: creating backup copy of config: /boot/config-backup-$DATE.txt $NC" 1>&2
cp -rf /boot/config.txt /boot/config-backup-$DATE.txt

# Download Janz Tec default config.txt
echo -e "$INFO INFO: Using emPC-A/RPI4 default config.txt $NC" 1>&2
wget -nv $REPORAW/src/config.txt -O /boot/config.txt

# Download can0 and can1 network configuration files to /etc/network/interfaces.d/
wget -nv $REPORAW/src/can0.interface -O /etc/network/interfaces.d/can0.interface
wget -nv $REPORAW/src/can1.interface -O /etc/network/interfaces.d/can1.interface

# Disable fake-hwclock as we have a real hwclock
systemctl disable fake-hwclock
systemctl mask fake-hwclock
service fake-hwclock stop
rm -f /etc/cron.hourly/fake-hwclock
update-rc.d fake-hwclock disable
service hwclock.sh stop
update-rc.d hwclock.sh disable

# Read RTC time in initramfs (early as possible)
# Download hwclock initramfs files
wget -nv $REPORAW/src/hwclock.hooks -O /etc/initramfs-tools/hooks/hwclock
wget -nv $REPORAW/src/hwclock.init-bottom -O /etc/initramfs-tools/scripts/init-bottom/hwclock

chmod +x /etc/initramfs-tools/hooks/hwclock
chmod +x /etc/initramfs-tools/scripts/init-bottom/hwclock

# Generate new initramfs
echo -e "$INFO INFO: generating initramfs $NC"
mkinitramfs -o /boot/initramfs.gz

if test -e /boot/initramfs.gz; then
	echo -e "$INFO INFO: Installing initramfs $NC"
	echo "initramfs initramfs.gz followkernel" >>/boot/config.txt
fi

# Download i2c device initialization service
wget -nv $REPORAW/src/instantiate_i2c -O /etc/init.d/instantiate_i2c

# Download check rs485 service
wget -nv $REPORAW/src/check_rs485 -O /etc/init.d/check_rs485

# Download lte and gps service
wget -nv $REPORAW/src/arpi4_lte -O /etc/init.d/arpi4_lte

# Enable i2c device initialization service service
chmod +x /etc/init.d/instantiate_i2c
update-rc.d instantiate_i2c defaults

# Enable check rs485 service
chmod +x /etc/init.d/check_rs485
update-rc.d check_rs485 defaults

# Enable lte and gps service
chmod +x /etc/init.d/arpi4_lte
update-rc.d arpi4_lte defaults

# Setting emPC-A/RPI4 specific codesys settings if codesys is installed
if [ ! -f "/etc/CODESYSControl.cfg" ]; then
        echo ""
else
    echo -e "$INFO INFO: CODESYS installation found $NC"

    if [ $UNATTENDED -eq 0 ]
    then
        if (whiptail --title "CODESYS installation found" --yesno "CODESYS specific settings:\n- Set SYS_COMPORT1 to /dev/ttySC0\n- Install rts_set_baud.sh SocketCan script\n\ninstall?" 16 60) then
            wget -nv $REPORAW/src/codesys-settings.sh -O codesys-settings.sh
            bash codesys-settings.sh
        fi
    else
        wget -nv $REPORAW/src/codesys-settings.sh -O codesys-settings.sh
        bash codesys-settings.sh
    fi
fi

# Finish
if [ $UNATTENDED -eq 0 ]
then
    if (whiptail --title "emPC-A/RPI4 Installation Script" --yesno "Installation completed! reboot required\n\nreboot now?" 12 60) then
        reboot
    fi
else
    echo "Installation completed! reboot required!"
fi
