#!/bin/bash
# Walk the chain from EDID to what actually reaches the panel.
# Run after rebooting. For step 4 and 5, enable HDR first.
#
#   ./check.sh

CONNECTOR="${CONNECTOR:-}"
if [ -z "$CONNECTOR" ]; then
  for c in /sys/class/drm/card*-eDP-*; do
    [ -e "$c/status" ] && [ "$(cat "$c/status")" = "connected" ] || continue
    EDID_PATH="$c/edid"; CONNECTOR="${c##*/}"; CONNECTOR="${CONNECTOR#card*-}"; break
  done
else
  EDID_PATH=$(ls -1 /sys/class/drm/card*-"$CONNECTOR"/edid 2>/dev/null | head -1)
fi
[ -n "${EDID_PATH:-}" ] || { echo "no connected eDP panel found"; exit 1; }

echo "connector: $CONNECTOR"
echo
echo "1) is the kernel handing out the patched EDID?"
SIZE=$(wc -c < "$EDID_PATH")
if [ "$SIZE" -gt 384 ]; then
  echo "   yes, $SIZE bytes"
else
  echo "   no, $SIZE bytes (original). Check: cat /proc/cmdline | grep edid_firmware"
fi

echo
echo "2) does libdisplay-info see HDR metadata now?"
python3 - "$EDID_PATH" <<'EOF'
import ctypes, sys
try:
    lib = ctypes.CDLL("libdisplay-info.so.3")
except OSError:
    try:
        lib = ctypes.CDLL("libdisplay-info.so")
    except OSError:
        print("   libdisplay-info not found, skipping"); raise SystemExit
class H(ctypes.Structure):
    _fields_ = [("max", ctypes.c_float), ("fall", ctypes.c_float), ("min", ctypes.c_float),
                ("type1", ctypes.c_bool), ("sdr", ctypes.c_bool), ("thdr", ctypes.c_bool),
                ("pq", ctypes.c_bool), ("hlg", ctypes.c_bool)]
lib.di_info_parse_edid.restype = ctypes.c_void_p
lib.di_info_parse_edid.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.di_info_get_hdr_static_metadata.restype = ctypes.POINTER(H)
lib.di_info_get_hdr_static_metadata.argtypes = [ctypes.c_void_p]
d = open(sys.argv[1], "rb").read()
i = lib.di_info_parse_edid(d, len(d))
h = lib.di_info_get_hdr_static_metadata(i) if i else None
if h and h.contents.pq:
    m = h.contents
    print(f"   yes, PQ, peak {m.max:.0f} nit, frame-avg {m.fall:.0f} nit, min {m.min:.4f} nit")
else:
    print("   no")
EOF

echo
echo "3) does the compositor offer an HDR mode?"
if pgrep -x gnome-shell >/dev/null; then
  python3 - <<'EOF'
import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio
try:
    b = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    p = Gio.DBusProxy.new_sync(b, Gio.DBusProxyFlags.NONE, None,
        'org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
        'org.gnome.Mutter.DisplayConfig', None)
    m = p.call_sync('GetCurrentState', None, Gio.DBusCallFlags.NONE, -1, None).unpack()[1][0][2]
    s = m.get('supported-color-modes', [])
    print(f"   mutter: supported color modes {s}, current {m.get('color-mode')}")
    print("   bt2100 offered:", "yes" if 1 in s else "no")
except Exception as e:
    print("   could not query mutter:", e)
EOF
elif pgrep -x kwin_wayland >/dev/null; then
  echo "   kwin running; check System Settings > Display & Monitor for the HDR switch"
else
  echo "   no known compositor detected"
fi

echo
echo "4) what is actually being sent to the panel (only meaningful with HDR on)"
command -v modetest >/dev/null || { echo "   modetest not installed (package: libdrm)"; exit 0; }
modetest -c 2>/dev/null \
  | awk -v c="$CONNECTOR" '/^[0-9]+\t[0-9]+\t(connected|disconnected)/{p=($4==c)} p' \
  | awk '
      /[0-9]+ Colorspace:/     {s=1; next}
      s && /value:/            {print "   Colorspace = " $2 "   (0 = default, 9 = BT2020_RGB)"; s=0}
      /8 HDR_OUTPUT_METADATA:/ {h=1; next}
      h && /value:/            {getline
                                print "   HDR blob   = " ($1 ~ /^[0-9a-f]{32}$/ ? $1 : "(empty)")
                                h=0}'

echo
echo "5) decoded infoframe"
"$(dirname "$0")/infoframe.sh" 2>/dev/null | sed -n '/EOTF/,$p' | sed 's/^/   /'
