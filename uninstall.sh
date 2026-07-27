#!/bin/bash
# Undo install.sh.
#
#   sudo ./uninstall.sh

set -euo pipefail

NAME=hdr-patched-edid.bin
FW_PATH=/usr/lib/firmware/edid/$NAME

[ "$EUID" -eq 0 ] || { echo "run with sudo: sudo ./uninstall.sh"; exit 1; }

echo "==> removing kernel parameter"
for f in /etc/default/limine /etc/default/grub /etc/kernel/cmdline; do
  [ -f "$f" ] || continue
  sed -i "s|drm\.edid_firmware=[^ \"]*$NAME ||g" "$f"
done

echo "==> removing from initramfs config"
[ -f /etc/mkinitcpio.conf ] && sed -i "s|$FW_PATH ||; s|($FW_PATH)|()|" /etc/mkinitcpio.conf
rm -f /etc/dracut.conf.d/90-hdr-edid.conf

echo "==> removing firmware"
rm -f "$FW_PATH"

echo "==> regenerating"
command -v mkinitcpio >/dev/null && mkinitcpio -P
command -v dracut-rebuild >/dev/null && dracut-rebuild
command -v limine-update >/dev/null && limine-update
command -v grub-mkconfig >/dev/null && [ -f /boot/grub/grub.cfg ] && grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "Done. Reboot."
echo "Backups, if install.sh made any: /etc/mkinitcpio.conf.hdr-backup,"
echo "/etc/default/limine.hdr-backup, /etc/default/grub.hdr-backup"
