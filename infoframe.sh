#!/bin/bash
# Decode the HDR_OUTPUT_METADATA infoframe the compositor is programming on the
# panel. Run with HDR enabled.
#
#   ./infoframe.sh
#
# All-zero mastering fields mean the compositor is telling the display to use
# the PQ curve without saying anything about the mastering display, which leaves
# the display's tone mapping guessing. See
# https://gitlab.gnome.org/GNOME/mutter/-/issues/4386

CONNECTOR="${CONNECTOR:-}"
if [ -z "$CONNECTOR" ]; then
  for c in /sys/class/drm/card*-eDP-*; do
    [ -e "$c/status" ] && [ "$(cat "$c/status")" = "connected" ] || continue
    CONNECTOR="${c##*/}"; CONNECTOR="${CONNECTOR#card*-}"; break
  done
fi
[ -n "$CONNECTOR" ] || { echo "no connected eDP panel found"; exit 1; }

command -v modetest >/dev/null || { echo "modetest not installed (package: libdrm)"; exit 1; }

# Pin modetest to the driver behind this connector; by default it opens the
# first DRM device, which need not be the one driving the panel.
CARD=$(basename "$(echo /sys/class/drm/card*-"$CONNECTOR" | cut -d" " -f1)" | cut -d- -f1)
DRIVER=$(basename "$(readlink -f "/sys/class/drm/$CARD/device/driver" 2>/dev/null)" 2>/dev/null)
[ -n "$DRIVER" ] && [ "$DRIVER" != "." ] && MT="modetest -M $DRIVER" || MT="modetest"

$MT -c 2>/dev/null \
  | awk -v c="$CONNECTOR" '/^[0-9]+\t[0-9]+\t(connected|disconnected)/{p=($4==c)} p' > /tmp/.edp.$$

python3 - "$CONNECTOR" "/tmp/.edp.$$" <<'EOF'
import re, struct, sys
connector, path = sys.argv[1], sys.argv[2]
s = open(path).read()

def enum(name):
    m = re.search(rf'\d+ {re.escape(name)}:.*?value:\s*(\d+)', s, re.S)
    return m.group(1) if m else '?'

m = re.search(r'8 HDR_OUTPUT_METADATA:.*?value:\s*\n(.*?)(?=\n\t\d+ )', s, re.S)
hexstr = ''.join(re.findall(r'[0-9a-f]{32}', m.group(1))) if m else ''

print(f"connector      {connector}")
print(f"Colorspace     {enum('Colorspace')}   (0 = default, 9 = BT2020_RGB, 11 = DCI-P3)")
print(f"Broadcast RGB  {enum('Broadcast RGB')}   (0 = auto, 1 = full, 2 = limited)")
print(f"max bpc        {enum('max bpc')}")

if not hexstr:
    print("HDR_OUTPUT_METADATA is empty (is HDR enabled?)")
    raise SystemExit

b = bytes.fromhex(hexstr)
print(f"\nblob ({len(b)} bytes) {hexstr}\n")
if len(b) < 30:
    raise SystemExit

mtype = struct.unpack('<I', b[0:4])[0]
eotf, smd = b[4], b[5]
rx, ry, gx, gy, bx, by, wx, wy, maxdml, mindml, maxcll, maxfall = struct.unpack('<12H', b[6:30])
names = {0: 'traditional SDR gamma', 1: 'traditional HDR gamma', 2: 'SMPTE ST2084 (PQ)', 3: 'HLG'}

print(f"metadata type  {mtype}")
print(f"EOTF           {eotf} ({names.get(eotf, '?')})")
print(f"descriptor     {smd}")
print(f"primaries  R   ({rx}, {ry})   G ({gx}, {gy})   B ({bx}, {by})")
print(f"white point    ({wx}, {wy})")
print(f"max mastering  {maxdml} nit")
print(f"min mastering  {mindml/10000:.4f} nit")
print(f"MaxCLL         {maxcll} nit")
print(f"MaxFALL        {maxfall} nit")

if not any((rx, ry, gx, gy, bx, by, wx, wy, maxdml, mindml, maxcll, maxfall)):
    print("\n>>> every mastering field is zero: the display is tone mapping blind")
    print(">>> see https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/5199")
else:
    print("\n>>> mastering metadata is populated")
    if rx:
        print(f">>> primaries in xy: ({rx*0.00002:.4f}, {ry*0.00002:.4f}) "
              f"({gx*0.00002:.4f}, {gy*0.00002:.4f}) ({bx*0.00002:.4f}, {by*0.00002:.4f})")
EOF

rm -f "/tmp/.edp.$$"
