# HDR on Linux laptops whose EDID hides the HDR metadata in a DisplayID block

If your laptop has an HDR capable OLED panel, HDR works on Windows, and on Linux
the HDR switch simply is not there — in GNOME, in KDE, in anything — this is
probably why.

The underlying bug is fixed upstream in libdisplay-info 0.4.0. If your distro
already ships that, you need nothing from here. Distros that still ship 0.3.0 do
hit it, and the workaround below covers that gap.

Confirmed on a Samsung `ATNA60HU06-0` (ASUS ROG Zephyrus G16, 2560x1600 240 Hz
OLED, Intel Panther Lake, `xe` driver). Very likely applies to other Samsung
ATNA-series laptop panels, and to any panel with the same EDID layout.

## The two problems

They are independent and you may hit either or both.

**1. The compositor never sees that the panel supports HDR.**

Most displays advertise HDR through an HDR Static Metadata Data Block inside a
CTA-861 extension block (tag `0x02`). This panel puts it inside a *CTA-861
DisplayID Data Block*, nested in a DisplayID 2.0 extension block (tag `0x70`).
`libdisplay-info` only learned to read that location in **0.4.0**, released
2026-07-23. With 0.3.0, `di_info_get_hdr_static_metadata()` returns nothing and
every compositor built on it concludes the display is SDR only. No HDR switch
appears anywhere.

Check what you have before doing anything else:

```sh
pacman -Q libdisplay-info      # or your distro's equivalent
```

**If it is 0.4.0 or newer, this half of the problem does not apply to you.**
Arch and CachyOS still shipped 0.3.0 at the time of writing, which is why the
workaround below exists. Once the package is updated it becomes unnecessary, and
you should run `./uninstall.sh`.

Filed as [libdisplay-info#59](https://gitlab.freedesktop.org/emersion/libdisplay-info/-/issues/59)
and closed: the fix had already landed upstream in
[!202](https://gitlab.freedesktop.org/emersion/libdisplay-info/-/merge_requests/202)
before I reported it. My mistake, I tested the distro package instead of git.

**2. On GNOME, HDR turns on but everything looks washed out.**

Separate bug. `mutter` programs `HDR_OUTPUT_METADATA` with the EOTF set to PQ
and every other field left at zero: no mastering display primaries, no white
point, no luminance range, no MaxCLL or MaxFALL. Displays that tone map on their
own get no information to work with and fall back to a default curve. KWin fills
these fields in, which is why the same panel looks right under KDE.

Reported as [mutter#4386](https://gitlab.gnome.org/GNOME/mutter/-/issues/4386),
fix proposed in [mutter!5199](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/5199).

## Which fix do you need

| | problem 1 | problem 2 |
|---|---|---|
| KDE / KWin | yes | not affected |
| GNOME / mutter | yes | yes |

## Fixing problem 1

Only needed while your distro still ships libdisplay-info 0.3.0.

`patch-edid.py` reads your panel's EDID, finds the Colorimetry and HDR Static
Metadata data blocks inside the DisplayID extension, copies them verbatim into a
new standard CTA-861 extension block appended at the end, and fixes the
extension count and checksums. Nothing else is touched, so timings, DSC and
adaptive sync are unaffected.

Look before you install:

```sh
./edid/patch-edid.py --check
```

If it reports an HDR Static Metadata Data Block, install it:

```sh
sudo ./install.sh
```

That writes the patched EDID to `/usr/lib/firmware/edid/`, adds
`drm.edid_firmware=<connector>:edid/hdr-patched-edid.bin` to the kernel command
line, and makes sure the file lands in the initramfs (it has to, because the DRM
driver is usually loaded from there). It knows about mkinitcpio and dracut, and
about limine, GRUB and `/etc/kernel/cmdline`. If it cannot find your bootloader
it prints the parameter for you to add by hand.

Reboot, then:

```sh
./check.sh
```

To undo everything: `sudo ./uninstall.sh`. If the panel stays dark at boot, edit
the entry in your bootloader menu and drop the `drm.edid_firmware=` parameter for
that boot.

## Fixing problem 2 (GNOME only)

Until [!5199](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/5199) lands
you need a patched mutter. `mutter/hdr-mastering-metadata.patch` applies to
mutter 50.x. On Arch:

```sh
git clone https://gitlab.archlinux.org/archlinux/packaging/packages/mutter.git
cd mutter
cp ../mutter/hdr-mastering-metadata.patch .
# add the patch to source=(), add its b2sum to b2sums=(),
# and add this line to prepare():
#   patch -Np1 -i "$srcdir/hdr-mastering-metadata.patch"
makepkg -si
```

Log out and back in afterwards; mutter cannot be replaced while running. Note
that a patched mutter is overwritten by every update.

## Checking your work

```sh
./infoframe.sh
```

Decodes what the compositor is actually programming on the connector. With HDR
enabled you want to see the EOTF set to PQ *and* the mastering fields populated.
All zeros after the EOTF byte is problem 2.

For the luminance side, `test/hdr-test.mp4` is a PQ encoded pattern with flat
patches at 100, 203, 600 and 1000 cd/m², plus saturated BT.2020 primaries, on a
black background:

```sh
mpv --vo=gpu-next --gpu-api=vulkan --loop=inf --fullscreen test/hdr-test.mp4
```

The 600 and 1000 nit patches should be clearly different from each other. If they
are, the panel really is reproducing above SDR white. In SDR mode they collapse
into one, which makes a useful control. `test/make-pattern.py` regenerates the
file if you want to change the levels.

## A note on colours looking less vivid

On a wide gamut panel, an unmanaged SDR desktop stretches sRGB content across the
full native gamut, which looks punchy but is wrong. This panel is about 1.55x the
area of sRGB, and roughly 50% oversaturated in green. Any correctly colour
managed mode, HDR included, will look duller than that by comparison. That part
is not a bug, and GNOME's `sdr-native` colour mode exists precisely to render
sRGB correctly on such panels.

Problem 2 is a real defect on top of that, and worth fixing separately. Do not
confuse the two.

## Requirements

`python3`, `ffmpeg` with libx265 for regenerating the test pattern, `libdrm` for
`modetest`, and `edid-decode` from v4l-utils if you want to inspect EDIDs by
hand. `di-edid-decode` ships with libdisplay-info and is useful for showing the
difference on 0.3.0: it prints nothing for the DisplayID blocks that
`edid-decode` parses fine. On 0.4.0 both agree.

## Licence

Public domain / CC0. Do whatever you want with it.
