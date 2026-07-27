#!/usr/bin/env python3
"""
Generate hdr-test.mp4: a PQ encoded test pattern for checking whether a display
really reaches above SDR white.

Left to right: flat white patches at 100, 203, 600 and 1000 cd/m2, then
saturated BT.2020 red, green and blue at 203 cd/m2. The top and bottom 15% are
code value zero, so you can also judge the black level.

What to look for, played back in an HDR aware player with HDR enabled:

  - the 600 and 1000 nit patches should be clearly different from each other.
    If they look the same, the display is not reproducing above SDR white and
    HDR is not actually working. In SDR mode they collapse into one, which is
    the expected behaviour and a useful control.
  - the black bars should be black, not grey.
  - the primaries should look saturated.

Needs ffmpeg with libx265.

    ./make-pattern.py            # writes hdr-test.mp4
"""

import struct
import subprocess
import sys
import tempfile
import os

W, H = 1920, 1080
SECONDS = 15

PATCHES = [
    (100,  (1, 1, 1)),
    (203,  (1, 1, 1)),   # BT.2408 reference white
    (600,  (1, 1, 1)),
    (1000, (1, 1, 1)),
    (203,  (1, 0, 0)),
    (203,  (0, 1, 0)),
    (203,  (0, 0, 1)),
]


def pq(nits):
    """Absolute luminance in cd/m2 -> SMPTE ST 2084 code value in 0..1"""
    m1, m2 = 2610 / 16384, 2523 / 4096 * 128
    c1, c2, c3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    y = min(nits / 10000.0, 1.0)
    return ((c1 + c2 * y ** m1) / (1 + c3 * y ** m1)) ** m2


def u16(v):
    return max(0, min(65535, int(round(v * 65535))))


def frame():
    n = len(PATCHES)
    pw = W // n
    rows = []
    for y in range(H):
        dark = y < H * 0.15 or y > H * 0.85
        row = bytearray()
        for x in range(W):
            nits, rgb = PATCHES[min(x // pw, n - 1)]
            code = 0.0 if dark else pq(nits)
            row += struct.pack('<3H', *(u16(code * c) for c in rgb))
        rows.append(bytes(row))
    return b''.join(rows)


def main():
    print("building frame...")
    data = frame()

    with tempfile.NamedTemporaryFile(suffix='.raw', delete=False) as f:
        f.write(data)
        raw = f.name

    x265 = (
        "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:"
        "master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)"
        "L(11070000,7):max-cll=1107,497:repeat-headers=1:info=0"
    )

    hevc = raw + '.hevc'
    print("encoding...")
    subprocess.run([
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'rawvideo', '-pix_fmt', 'rgb48le', '-s', f'{W}x{H}',
        '-framerate', '1', '-stream_loop', str(SECONDS - 1), '-i', raw,
        '-vf', 'scale=out_color_matrix=bt2020nc,format=yuv420p10le',
        '-c:v', 'libx265', '-preset', 'ultrafast', '-x265-params', x265,
        hevc,
    ], check=True)

    # Mux, forcing the container level colour tags too.
    subprocess.run([
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
        '-r', '1', '-i', hevc, '-c', 'copy', '-video_track_timescale', '1000',
        '-color_primaries', 'bt2020', '-color_trc', 'smpte2084',
        '-colorspace', 'bt2020nc', '-color_range', 'tv',
        'hdr-test.mp4',
    ], check=True)

    os.unlink(raw)
    os.unlink(hevc)
    print("wrote hdr-test.mp4")
    print()
    print("play with:  mpv --vo=gpu-next --gpu-api=vulkan --loop=inf --fullscreen hdr-test.mp4")


if __name__ == '__main__':
    sys.exit(main())
