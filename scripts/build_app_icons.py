#!/usr/bin/env python3
"""Turn the hand-drawn logo into every icon size Android and the app need.

    python3 scripts/build_app_icons.py

Two source files, for two different jobs — they are not interchangeable:

  * `applogo/japanodict_logo.png` — the original 1024x1024 **RGB** export,
    no alpha at all, so the rounded corners of the yellow tile are painted
    white rather than left transparent, with an 8px white margin around the
    whole thing. Used for the places the mark has to float on a coloured
    surface it doesn't control (the drawer header, the launch splash) — those
    need real transparent rounded corners, not a hard-edged square. The first
    thing this script does is *recover* the alpha channel this file never had:
    flood-fill inward from the four corners over everything lighter than the
    tile's yellow (the yellow ring is a closed barrier — the disc is darker,
    `{jd}` is black — so the fill can't leak into the artwork), read each
    filled pixel's whiteness back out as alpha coverage so the anti-aliased
    corner arcs stay smooth, and repaint those pixels the tile's own yellow
    underneath the new alpha so downscaling can't bleed a white fringe in.
  * `applogo/japanodict_android_icon.png` — a second, **already full-bleed**
    square: flat yellow edge to edge, no white halo, no alpha needed. This is
    the source for the Android launcher icon specifically (see below for why
    that has to be a flat square rather than the rounded tile).

Icon output, three families, all from the *second* file:

  * `ic_launcher` — the flat square as-is, for pre-Android-8 launchers that
    draw the bitmap with no masking. It already fills its canvas edge to edge.
  * `ic_launcher_foreground` — **not** the whole square. Adaptive icons pair a
    foreground with a flat-colour background
    (`mipmap-anydpi-v26/ic_launcher.xml`), and this background is the tile's
    own yellow, sampled exactly. That makes the square's yellow field
    redundant with it: compositing the *whole* resized square onto that
    background can never show a seam no matter the scale, but scaling the
    whole square down to keep the disc inside the safe zone shrinks that
    yellow field right along with it, for no visual benefit — an earlier
    version of this script did exactly that and produced an icon that looked
    shrunken next to its home-screen neighbours (the disc landed at 57% of the
    canvas, under even the conservative 66/108 safe circle). So the foreground
    here is the disc **content alone** — auto-detected as the pixels that
    aren't the tile's yellow — scaled up to DISC_SCALE and centred; the
    background layer supplies all the yellow around it, seamlessly, at
    whatever size is left over.
  * `ic_launcher_monochrome` — the Android 13 themed-icon layer, which is an
    alpha mask the system tints itself. Colour is therefore thrown away and
    only the red disc's silhouette is kept, with the `{jd}` knocked back out of
    it, so the themed icon still reads as this logo and not as a plain circle.
    Scaled the same way as the foreground, for the same reason.

`recover_alpha` runs on *both* files, not just the rounded one — on the
flat square it is a safe no-op (nothing lighter than the tile colour exists to
flood), so one code path handles both without a special case.

It also writes `drawable-*/splash_logo.png`, from the **rounded** file, for the
Android launch window — a plain `<bitmap>` in a layer-list, drawn before any
Flutter code runs, so it cannot come from the Flutter asset bundle and needs
its own copies at each density.

`assets/images/japanodict_logo.png`, also from the rounded file, is the in-app
copy (drawer header, first-run screen); 512px because nothing in the UI draws
it larger than ~96dp.
"""

import os
import sys
from collections import deque

from PIL import Image

# Android's density buckets, as a multiple of the 48dp baseline icon.
DENSITIES = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
}

# Edge of the launch-window logo, in dp. Sized like a splash mark rather than
# like an icon — the launch window is a full screen, not a 48dp home-screen
# cell.
SPLASH_DP = 128

# Fraction of the 108dp adaptive canvas that a launcher's mask actually shows.
# The guaranteed-visible "safe zone" is the inner 66dp circle, but the shape
# nearly every launcher really draws is the 72dp one, so that is what the
# artwork is composed against.
MASK_FRACTION = 72 / 108

# The whole designed square from `applogo/japanodict_android_icon.png` is
# scaled to exactly MASK_FRACTION and centred — i.e. the icon as drawn is
# placed *inside the mask*, which is what the source art is already composed
# for (a red disc at ~75% of a yellow field).
#
# Do not raise this to make the icon "bigger". It does not work, and the
# failure is invisible until you look at a real device:
#
#   * The icon's rendered size is NOT set by this number. It is set by the
#     `<background>` layer, a solid colour that covers the entire canvas and so
#     always fills the mask edge to edge — exactly how Gmail's white circle and
#     Chrome's coloured one fill theirs. Measured on-device, this app's icon and
#     every sibling in the dock render at an identical 158px.
#   * All this number controls is how much of that circle is *red disc* versus
#     *yellow field*. Pushing it past MASK_FRACTION doesn't enlarge anything;
#     it just slides the disc's edge outside the mask so the yellow is clipped
#     away entirely, and the brand's second colour silently disappears. An
#     earlier revision shipped at 0.72 against a 0.667 mask and did exactly
#     that — the launcher icon became a plain red squircle.
SQUARE_SCALE = MASK_FRACTION

# Sanity bound on how much of the canvas the corner flood may claim. The white
# surround is ~4% of the source; anything approaching this means the flood
# found a path into the artwork and the whole tile is about to go translucent.
MAX_FLOOD = 0.15


def recover_alpha(src):
    """Flood the white surround out of an alpha-less logo. Returns RGBA."""
    im = src.convert('RGB')
    w, h = im.size
    px = im.load()

    # The tile's own yellow, sampled from a point that is unambiguously inside
    # the flat border rather than hard-coded, so a re-drawn logo still works.
    yellow = px[w // 2, int(h * 0.04)]
    if min(yellow) > 200:
        raise SystemExit(
            f'expected the flat tile colour near the top edge, found {yellow} '
            '— that sample point is in the white surround, so the logo layout '
            'changed and this script needs re-pointing'
        )

    # Flood anything even one step lighter than the tile, rather than picking a
    # threshold partway to white: a pixel left just under the cut keeps its
    # whitened colour at full alpha and draws a pale 1px halo around the whole
    # tile. The tile is a closed ring at this value (the red disc is darker
    # still), so tightening it here cannot leak.
    cutoff = yellow[2]

    outside = bytearray(w * h)
    queue = deque()
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        queue.append(seed)
    while queue:
        x, y = queue.popleft()
        if not (0 <= x < w and 0 <= y < h):
            continue
        i = y * w + x
        if outside[i] or px[x, y][2] <= cutoff:
            continue
        outside[i] = 1
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

    filled = sum(outside)
    if filled > MAX_FLOOD * w * h:
        raise SystemExit(
            f'corner flood claimed {100 * filled / (w * h):.0f}% of the canvas '
            '— it escaped into the artwork instead of stopping at the tile'
        )

    span = 255 - yellow[2]
    out = Image.new('RGBA', (w, h))
    op = out.load()
    for y in range(h):
        row = y * w
        for x in range(w):
            if outside[row + x]:
                # How much of this pixel was tile rather than white.
                a = round((255 - px[x, y][2]) * 255 / span)
                op[x, y] = yellow + (max(0, min(255, a)),)
            else:
                op[x, y] = px[x, y] + (255,)

    # Drop the blank margin so the tile fills the canvas edge to edge; a
    # launcher icon that is 98% of its own bitmap looks shrunken next to its
    # neighbours on the home screen.
    return out.crop(out.getbbox()), yellow


def content_bbox(logo, yellow):
    """Bounding box of pixels that are opaque and not the tile's yellow.

    Auto-detected rather than hard-coded so a redrawn logo (different disc
    size, off-centre artwork) still produces a sane crop instead of a stale
    fraction baked in from this file.
    """
    w, h = logo.size
    px = logo.load()
    xs = []
    ys = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a < 128:
                continue
            if abs(r - yellow[0]) < 10 and abs(g - yellow[1]) < 10 and abs(b - yellow[2]) < 10:
                continue
            xs.append(x)
            ys.append(y)
    if not xs:
        raise SystemExit('found no non-background content — is the source blank?')
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def square_crop(logo, bbox):
    """`bbox` padded to a centred square, so a non-square content region (the
    disc is round, but nothing guarantees the detected bbox is) does not get
    stretched when it is later resized onto a square canvas."""
    x0, y0, x1, y1 = bbox
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    half = max(x1 - x0, y1 - y0) / 2
    return logo.crop((round(cx - half), round(cy - half), round(cx + half), round(cy + half)))


def monochrome(logo):
    """The themed-icon layer: the red disc's silhouette, `{jd}` knocked out."""
    w, h = logo.size
    px = logo.convert('RGB').load()
    src_a = logo.split()[3].load()
    out = Image.new('RGBA', (w, h))
    op = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y]
            # Red disc only: strongly red, and not the yellow tile behind it.
            is_disc = src_a[x, y] > 127 and r > 180 and g < 160 and b < 160
            op[x, y] = (0, 0, 0, 255 if is_disc else 0)
    return out


def inset(logo, size, scale, background=None):
    """`logo` centred at `scale` of a `size` canvas, over `background`."""
    canvas = Image.new('RGBA', (size, size), background or (0, 0, 0, 0))
    inner = round(size * scale)
    canvas.alpha_composite(
        logo.resize((inner, inner), Image.LANCZOS),
        ((size - inner) // 2, (size - inner) // 2),
    )
    return canvas


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res = os.path.join(root, 'android/app/src/main/res')

    logo_source, android_source = (
        sys.argv[1:3]
        if len(sys.argv) > 2
        else (
            'applogo/japanodict_logo.png',
            'applogo/japanodict_android_icon.png',
        )
    )

    # The rounded tile: in-app logo + splash, both floating on a surface this
    # script doesn't control, so both need real transparent corners.
    logo, _ = recover_alpha(Image.open(logo_source))
    print(f'logo (rounded):   {logo.size[0]}x{logo.size[1]}')

    asset = os.path.join(root, 'assets/images/japanodict_logo.png')
    logo.resize((512, 512), Image.LANCZOS).save(asset, optimize=True)
    print(f'  {os.path.relpath(asset, root)}  512x512')

    # The flat square: the launcher icon. recover_alpha is a no-op on this one
    # (nothing lighter than the tile colour to flood) but reusing it means one
    # code path validates both files and samples `yellow` the same way.
    android, yellow = recover_alpha(Image.open(android_source))
    print(f'android (flat):   {android.size[0]}x{android.size[1]}, tile {yellow}')

    # How much of the source square the disc occupies. Only needed to scale the
    # monochrome layer to match the colour one — the colour foreground is the
    # whole square and needs no such correction.
    bbox = content_bbox(android, yellow)
    disc_in_square = (bbox[2] - bbox[0]) / android.size[0]
    print(f'disc is {disc_in_square:.1%} of the source square '
          f'-> {SQUARE_SCALE * disc_in_square:.1%} of the adaptive canvas, '
          f'{disc_in_square:.1%} of the visible mask')

    mono = square_crop(monochrome(android), bbox)
    for bucket, size in DENSITIES.items():
        out = os.path.join(res, f'mipmap-{bucket}')
        os.makedirs(out, exist_ok=True)
        # Adaptive layers are 108dp against the icon's 48dp baseline.
        adaptive = round(size * 108 / 48)
        for name, image in (
            ('ic_launcher', android.resize((size, size), Image.LANCZOS)),
            ('ic_launcher_foreground', inset(android, adaptive, SQUARE_SCALE)),
            ('ic_launcher_monochrome',
             inset(mono, adaptive, SQUARE_SCALE * disc_in_square)),
        ):
            image.save(os.path.join(out, f'{name}.png'), optimize=True)
        splash = os.path.join(res, f'drawable-{bucket}')
        os.makedirs(splash, exist_ok=True)
        splash_px = round(SPLASH_DP * size / 48)
        logo.resize((splash_px, splash_px), Image.LANCZOS).save(
            os.path.join(splash, 'splash_logo.png'), optimize=True
        )
        print(f'  mipmap-{bucket}  {size}px legacy, {adaptive}px adaptive; '
              f'drawable-{bucket}  {splash_px}px splash')

    print(f'\nadaptive background colour should be #{yellow[0]:02X}'
          f'{yellow[1]:02X}{yellow[2]:02X} (values/colors.xml)')


if __name__ == '__main__':
    main()
