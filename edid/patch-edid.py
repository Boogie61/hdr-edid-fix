#!/usr/bin/env python3
"""
Rewrite an EDID so that HDR metadata hidden inside a DisplayID extension block
is also exposed through a standard CTA-861 extension block.

Why this is needed
------------------
Some displays (notably Samsung ATNA-series laptop OLED panels) put their
Colorimetry Data Block and HDR Static Metadata Data Block inside a *CTA-861
DisplayID Data Block*, nested in a DisplayID 2.0 extension block (tag 0x70),
instead of in a standalone CTA-861 extension block (tag 0x02).

libdisplay-info does not reach those blocks, so di_info_get_hdr_static_metadata()
returns nothing. Every Wayland compositor that uses it (mutter, kwin, ...) then
decides the display has no HDR support and never offers an HDR mode.

See https://gitlab.freedesktop.org/emersion/libdisplay-info/-/issues/59

This script finds those two data blocks in the raw EDID, copies them verbatim
into a new CTA-861 extension block appended to the end, and fixes up the
extension count and checksums. Nothing else is touched: the original blocks,
timings, DSC and adaptive sync information are left exactly as they were.

Usage
-----
    ./patch-edid.py                        # read the built-in panel, write patched.bin
    ./patch-edid.py /sys/class/drm/card0-eDP-1/edid out.bin
    ./patch-edid.py --check                # only report, write nothing
"""

import sys
import glob
import argparse

CTA_EXT_TAG = 0x02
DISPLAYID_EXT_TAG = 0x70

# CTA-861 extended tag codes, wrapped in a "use extended tag" data block header
COLORIMETRY_EXT_TAG = 0x05
HDR_STATIC_METADATA_EXT_TAG = 0x06


def checksum(block):
    """CTA/EDID blocks must sum to 0 mod 256."""
    return (-sum(block[:127])) & 0xFF


def find_data_block(blocks, ext_tag):
    """
    Scan raw extension bytes for a CTA-861 data block that uses the extended
    tag `ext_tag`. Returns the block including its header byte, or None.

    A CTA data block header is: (tag_code << 5) | length, where tag code 7
    means "use extended tag" and the next byte is the extended tag.
    """
    i = 0
    n = len(blocks)
    while i < n - 1:
        header = blocks[i]
        tag_code = header >> 5
        length = header & 0x1F
        if tag_code == 7 and length >= 1 and i + 1 + length <= n:
            if blocks[i + 1] == ext_tag:
                return bytes(blocks[i:i + 1 + length])
        i += 1
    return None


def describe_hdr(block):
    """Human readable summary of an HDR Static Metadata Data Block."""
    if block is None or len(block) < 4:
        return "not found"
    eotf = block[2]
    names = []
    if eotf & 0x01:
        names.append("SDR gamma")
    if eotf & 0x02:
        names.append("HDR gamma")
    if eotf & 0x04:
        names.append("ST2084/PQ")
    if eotf & 0x08:
        names.append("HLG")
    out = "EOTF: " + (", ".join(names) or "none")
    # optional luminance bytes
    if len(block) >= 5:
        out += f", max code {block[4]}"
    if len(block) >= 6:
        out += f", frame-avg code {block[5]}"
    if len(block) >= 7:
        out += f", min code {block[6]}"
    return out


def build_cta_block(data_blocks):
    """Build a 128 byte CTA-861 revision 3 extension block holding data_blocks."""
    payload = b"".join(data_blocks)
    if 4 + len(payload) > 127:
        raise ValueError("data blocks do not fit in one CTA extension block")

    cta = bytearray(128)
    cta[0] = CTA_EXT_TAG
    cta[1] = 0x03                      # revision 3
    cta[2] = 4 + len(payload)          # offset of the (empty) DTD area
    cta[3] = 0x80                      # IT formats underscanned; no audio/YCbCr/native DTDs
    cta[4:4 + len(payload)] = payload
    cta[127] = checksum(cta)
    return bytes(cta)


def patch(edid):
    if len(edid) < 128:
        raise ValueError("EDID shorter than one block")

    base = bytearray(edid[:128])
    ext_count = base[126]
    if ext_count == 0:
        raise ValueError("EDID has no extension blocks, nothing to look into")

    extensions = bytearray(edid[128:128 + ext_count * 128])

    # Only look inside DisplayID extensions. A display that already has a
    # standalone CTA extension does not need this workaround.
    displayid = bytearray()
    for i in range(ext_count):
        block = extensions[i * 128:(i + 1) * 128]
        if not block:
            continue
        if block[0] == CTA_EXT_TAG:
            raise ValueError(
                "this EDID already has a standalone CTA-861 extension block; "
                "if HDR still is not detected the cause is elsewhere")
        if block[0] == DISPLAYID_EXT_TAG:
            displayid += block

    if not displayid:
        raise ValueError("no DisplayID extension block found")

    colorimetry = find_data_block(displayid, COLORIMETRY_EXT_TAG)
    hdr = find_data_block(displayid, HDR_STATIC_METADATA_EXT_TAG)

    print(f"  colorimetry data block : {'found' if colorimetry else 'not found'}")
    print(f"  hdr static metadata    : {describe_hdr(hdr)}")

    if hdr is None:
        raise ValueError(
            "no HDR Static Metadata Data Block inside the DisplayID extension; "
            "this panel probably really has no HDR support")

    blocks = [b for b in (colorimetry, hdr) if b is not None]
    cta = build_cta_block(blocks)

    base[126] = ext_count + 1
    base[127] = checksum(base)

    return bytes(base) + bytes(extensions) + cta


def default_edid_path():
    for path in sorted(glob.glob("/sys/class/drm/card*-eDP-*/edid")):
        try:
            with open(path, "rb") as f:
                if f.read(8) == b"\x00\xff\xff\xff\xff\xff\xff\x00":
                    return path
        except OSError:
            continue
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", nargs="?", help="EDID to read (default: built-in panel)")
    ap.add_argument("output", nargs="?", default="patched.bin", help="where to write")
    ap.add_argument("--check", action="store_true", help="report only, write nothing")
    args = ap.parse_args()

    source = args.source or default_edid_path()
    if not source:
        sys.exit("no built-in panel EDID found, pass one explicitly")

    with open(source, "rb") as f:
        edid = f.read()

    print(f"reading {source} ({len(edid)} bytes)")

    try:
        patched = patch(edid)
    except ValueError as e:
        sys.exit(f"error: {e}")

    print(f"  patched EDID           : {len(patched)} bytes")

    if args.check:
        print("--check given, nothing written")
        return

    with open(args.output, "wb") as f:
        f.write(patched)
    print(f"wrote {args.output}")
    print()
    print("Verify with:  edid-decode " + args.output)
    print("Compare with: di-edid-decode " + args.output)


if __name__ == "__main__":
    main()
