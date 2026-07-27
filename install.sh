#!/bin/bash
# Install the patched EDID so the kernel hands it to userspace instead of the
# panel's own, which makes libdisplay-info (and therefore every Wayland
# compositor) see the HDR metadata that is otherwise unreachable.
#
#   sudo ./install.sh
#
# Undo with ./uninstall.sh

set -euo pipefail

FW_DIR=/usr/lib/firmware/edid
NAME=hdr-patched-edid.bin
FW_PATH="$FW_DIR/$NAME"

[ "$EUID" -eq 0 ] || { echo "run with sudo: sudo ./install.sh"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
cd "$(dirname "$0")"

# ---------------------------------------------------------------- connector
CONNECTOR="${CONNECTOR:-}"
if [ -z "$CONNECTOR" ]; then
  for c in /sys/class/drm/card*-eDP-*; do
    [ -e "$c/status" ] || continue
    [ "$(cat "$c/status")" = "connected" ] || continue
    CONNECTOR="${c##*/}"; CONNECTOR="${CONNECTOR#card*-}"
    break
  done
fi
[ -n "$CONNECTOR" ] || { echo "no connected eDP panel found; set CONNECTOR=eDP-1 and retry"; exit 1; }

PARAM="drm.edid_firmware=$CONNECTOR:edid/$NAME"
echo "==> connector: $CONNECTOR"

# ---------------------------------------------------------------- build EDID
echo "==> generating patched EDID"
EDID_PATH=$(ls -1 /sys/class/drm/card*-"$CONNECTOR"/edid 2>/dev/null | head -1)
[ -n "$EDID_PATH" ] || { echo "cannot find EDID for $CONNECTOR"; exit 1; }
python3 edid/patch-edid.py "$EDID_PATH" /tmp/$NAME
install -Dm644 /tmp/$NAME "$FW_PATH"
rm -f /tmp/$NAME
echo "    installed $FW_PATH"

# ---------------------------------------------------------------- initramfs
# The DRM driver is usually loaded from the initramfs, so the firmware has to
# be in there too or request_firmware() fails and the real EDID is used.
if [ -f /etc/mkinitcpio.conf ]; then
  echo "==> mkinitcpio"
  if grep -q "$NAME" /etc/mkinitcpio.conf; then
    echo "    already listed"
  else
    cp -n /etc/mkinitcpio.conf /etc/mkinitcpio.conf.hdr-backup
    if grep -q '^FILES=()' /etc/mkinitcpio.conf; then
      sed -i "s|^FILES=()|FILES=($FW_PATH)|" /etc/mkinitcpio.conf
    else
      sed -i "s|^FILES=(|FILES=($FW_PATH |" /etc/mkinitcpio.conf
    fi
    grep -q "$NAME" /etc/mkinitcpio.conf || { echo "    could not edit FILES=, add $FW_PATH by hand"; exit 1; }
    echo "    added to FILES="
  fi
elif [ -d /etc/dracut.conf.d ]; then
  echo "==> dracut"
  printf 'install_items+=" %s "\n' "$FW_PATH" > /etc/dracut.conf.d/90-hdr-edid.conf
  echo "    wrote /etc/dracut.conf.d/90-hdr-edid.conf"
else
  echo "==> unknown initramfs generator, make sure $FW_PATH ends up in the initramfs"
fi

# ---------------------------------------------------------------- cmdline
# Handles both quoting styles, and only claims success if the parameter is
# really there afterwards.
added_cmdline=0

add_param() {           # $1 = file, $2 = sed expression
  local file="$1" expr="$2"
  if grep -q edid_firmware "$file"; then
    echo "    already present"
    added_cmdline=1
    return
  fi
  cp -n "$file" "$file.hdr-backup" 2>/dev/null || true
  sed -i "$expr" "$file"
  if grep -q edid_firmware "$file"; then
    echo "    added"
    added_cmdline=1
  else
    echo "    could not edit $file automatically"
  fi
}

if [ -f /etc/default/limine ]; then
  echo "==> limine"
  add_param /etc/default/limine "s|^\\(KERNEL_CMDLINE\\[[^]]*\\]+\\?=[\"']\\)|\\1$PARAM |"
elif [ -f /etc/default/grub ]; then
  echo "==> grub"
  add_param /etc/default/grub "s|^\\(GRUB_CMDLINE_LINUX_DEFAULT=[\"']\\)|\\1$PARAM |"
elif [ -f /etc/kernel/cmdline ]; then
  echo "==> /etc/kernel/cmdline"
  add_param /etc/kernel/cmdline "1s|^|$PARAM |"
fi

# ---------------------------------------------------------------- regenerate
echo "==> regenerating"
command -v mkinitcpio >/dev/null && mkinitcpio -P
command -v dracut-rebuild >/dev/null && dracut-rebuild
command -v limine-update >/dev/null && limine-update
command -v grub-mkconfig >/dev/null && [ -f /boot/grub/grub.cfg ] && grub-mkconfig -o /boot/grub/grub.cfg
command -v bootctl >/dev/null && [ -d /efi/loader ] && kernel-install add-all 2>/dev/null || true

echo
if [ "$added_cmdline" -eq 0 ]; then
  echo "Could not detect your bootloader. Add this to the kernel command line yourself:"
  echo
  echo "    $PARAM"
  echo
fi
echo "Reboot, then run ./check.sh"
echo
echo "If the panel stays dark at boot, edit the entry in your bootloader menu and"
echo "remove '$PARAM' for that boot, then run ./uninstall.sh"
