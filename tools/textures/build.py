#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Draw Tavern Cards' board and card textures from code, so they are original and reproducible.

    python3 tools/textures/build.py            # writes Textures/*.tga and Data/Textures.lua
    python3 tools/textures/build.py --preview /tmp/sheet.png

Everything is procedural (numpy noise, PIL shapes, a bevel from a blurred mask): no image goes in, so
nothing here derives from Blizzard's or anyone else's art. The output is deterministic for a given
SEED. Shapes are drawn at SS x the size and scaled down, which antialiases their edges.

Data/Textures.lua records where things are inside each texture (portrait windows, gem centres, atlas
cells) as fractions, so the Lua layout always lines up with the art.
"""
import argparse
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, "Textures")
SEED = 1701
SS = 4

# Card art space: the widget is 100x148, so a 256-wide card is 379 tall; it sits at the top of a
# 256x512 texture (the rest is transparent and cut off by texture coordinates).
CW, CH, CTEX = 256, 379, 512

PALETTE = {
    "wood_dark": (59, 36, 20), "wood_light": (138, 90, 51),
    "stone_hi": (185, 162, 122), "stone_lo": (142, 122, 87),
    "gold": (201, 160, 74), "gold_hi": (242, 213, 138), "gold_lo": (120, 86, 30),
    "iron": (74, 78, 85), "iron_hi": (150, 156, 166),
    "parch": (236, 222, 186), "parch_lo": (196, 172, 128),
    "mana": (46, 123, 230), "attack": (224, 178, 58), "health": (200, 53, 43),
}
RARITY = {"common": (216, 216, 216), "rare": (63, 140, 255), "epic": (166, 77, 255), "legendary": (255, 154, 31)}


# ---- numeric helpers ----------------------------------------------------------------------------

def rng(salt):
    return np.random.default_rng(SEED * 1000 + salt)


def noise(w, h, salt, octaves=5, base=4):
    """Fractal value noise in [0, 1]."""
    r = rng(salt)
    out = np.zeros((h, w), np.float32)
    amp, total = 1.0, 0.0
    for o in range(octaves):
        cells = base * (2 ** o)
        grid = r.random((cells + 1, max(2, int(cells * w / h) + 1))).astype(np.float32)
        layer = np.asarray(Image.fromarray(grid).resize((w, h), Image.BICUBIC), np.float32)
        out += amp * layer
        total += amp
        amp *= 0.5
    out /= total
    return np.clip((out - out.min()) / max(1e-6, out.max() - out.min()), 0, 1)


def shape(w, h, draw_fn):
    """A float mask in [0, 1] from a PIL drawing function, antialiased by supersampling."""
    im = Image.new("L", (w * SS, h * SS), 0)
    draw_fn(ImageDraw.Draw(im), SS)
    return np.asarray(im.resize((w, h), Image.LANCZOS), np.float32) / 255.0


def blur(a, radius):
    im = Image.fromarray(np.clip(a * 255, 0, 255).astype(np.uint8))
    return np.asarray(im.filter(ImageFilter.GaussianBlur(radius)), np.float32) / 255.0


def bevel(mask, radius=4, strength=0.9):
    """Lighting from the top-left on the mask's edges: >1 lit, <1 shaded."""
    hgt = blur(mask, radius)
    gy, gx = np.gradient(hgt)
    light = -(gx * -0.7 + gy * -0.7) * radius * 2.2
    return 1 + np.clip(light, -1, 1) * strength


def tint(gray, lo, hi):
    lo, hi = np.array(lo, np.float32), np.array(hi, np.float32)
    return lo + (hi - lo) * gray[..., None]


class Layer:
    """An RGBA canvas (colour kept premultiplied by alpha) that shapes are composited onto."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.rgb = np.zeros((h, w, 3), np.float32)
        self.a = np.zeros((h, w), np.float32)

    def paint(self, mask, rgb, shade=None, alpha=1.0):
        a = np.clip(mask * alpha, 0, 1)
        col = rgb if rgb.ndim == 3 else np.broadcast_to(rgb, (self.h, self.w, 3))
        if shade is not None:
            col = col * shade[..., None]
        col = np.clip(col, 0, 255)
        self.rgb = col * a[..., None] + self.rgb * (1 - a[..., None])
        self.a = a + self.a * (1 - a)

    def erase(self, mask):
        keep = 1 - np.clip(mask, 0, 1)
        self.a *= keep
        self.rgb *= keep[..., None]

    def image(self, size=None):
        a = np.clip(self.a, 0, 1)
        rgb = self.rgb / np.maximum(a[..., None], 1e-4)   # paint() accumulates premultiplied colour
        out =np.dstack([np.clip(rgb, 0, 255), np.clip(a * 255, 0, 255)]).astype(np.uint8)
        im = Image.fromarray(out, "RGBA")
        if size and size != (self.w, self.h):
            canvas = Image.new("RGBA", size, (0, 0, 0, 0))
            canvas.paste(im, (0, 0))
            im = canvas
        return im


def solid(c):
    return np.array(c, np.float32)


# ---- materials ----------------------------------------------------------------------------------

def wood(w, h, salt):
    n = noise(w, h, salt, octaves=4, base=3)
    ys = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    # long grain: stretch noise along x so the streaks run with the planks, then a few soft growth rings
    streak = np.asarray(Image.fromarray((noise(max(8, w // 16), h, salt + 2, octaves=4, base=6) * 255).astype(np.uint8))
                        .resize((w, h), Image.BICUBIC), np.float32) / 255
    rings = 0.5 + 0.5 * np.sin((ys * (h / 9.0) + n * 6 + streak * 4) * math.pi)
    fine = noise(w, h, salt + 1, octaves=3, base=40)
    g = np.clip(0.18 + 0.4 * streak + 0.14 * rings + 0.18 * n + 0.1 * fine, 0, 1)
    return tint(g, PALETTE["wood_dark"], PALETTE["wood_light"])


def stone(w, h, salt, lo=None, hi=None):
    n = noise(w, h, salt, octaves=6, base=3)
    speck = noise(w, h, salt + 7, octaves=2, base=64)
    g = np.clip(0.2 + 0.7 * n + 0.15 * (speck - 0.5), 0, 1)
    return tint(g, lo or PALETTE["stone_lo"], hi or PALETTE["stone_hi"])


def metal(w, h, salt, lo, mid, hi):
    n = noise(w, h, salt, octaves=3, base=8)
    ys = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    band = 0.55 + 0.45 * np.cos(ys * math.pi * 1.4)
    g = np.clip(band * 0.8 + n * 0.25, 0, 1)
    lo, mid, hi = (np.array(x, np.float32) for x in (lo, mid, hi))
    g3 = g[..., None]
    return np.where(g3 < 0.5, lo + (mid - lo) * (g3 * 2), mid + (hi - mid) * ((g3 - 0.5) * 2))


def gold(w, h, salt):
    return metal(w, h, salt, PALETTE["gold_lo"], PALETTE["gold"], PALETTE["gold_hi"])


def iron(w, h, salt):
    return metal(w, h, salt, (40, 42, 46), PALETTE["iron"], PALETTE["iron_hi"])


def gray_stone(w, h, salt):
    """Greyscale stone for the tintable card bodies (vertex colour gives the class colour)."""
    n = noise(w, h, salt, octaves=6, base=3)
    veins = np.abs(noise(w, h, salt + 5, octaves=4, base=5) - 0.5) * 2   # 0 along the veins
    speck = noise(w, h, salt + 3, octaves=2, base=48)
    g = np.clip(0.42 + 0.5 * n + 0.18 * (speck - 0.5) - 0.22 * np.clip(0.12 - veins, 0, 1) / 0.12, 0, 1)
    return tint(g, (95, 95, 95), (245, 245, 245))


def parchment(w, h, salt):
    n = noise(w, h, salt, octaves=5, base=4)
    return tint(np.clip(0.35 + 0.65 * n, 0, 1), PALETTE["parch_lo"], PALETTE["parch"])


# ---- shapes ------------------------------------------------------------------------------------

def ellipse(cx, cy, rx, ry):
    return lambda d, s: d.ellipse([(cx - rx) * s, (cy - ry) * s, (cx + rx) * s, (cy + ry) * s], fill=255)


def rrect(x0, y0, x1, y1, r):
    return lambda d, s: d.rounded_rectangle([x0 * s, y0 * s, x1 * s, y1 * s], radius=r * s, fill=255)


def arch(x0, y0, x1, y1):
    """A rectangle with a semicircular top."""
    def fn(d, s):
        r = (x1 - x0) / 2
        d.ellipse([x0 * s, y0 * s, x1 * s, (y0 + 2 * r) * s], fill=255)
        d.rectangle([x0 * s, (y0 + r) * s, x1 * s, y1 * s], fill=255)
    return fn


def poly(points):
    return lambda d, s: d.polygon([(x * s, y * s) for x, y in points], fill=255)


def union(*fns):
    def fn(d, s):
        for f in fns:
            f(d, s)
    return fn


def ring(w, h, outer, inner):
    return np.clip(shape(w, h, outer) - shape(w, h, inner), 0, 1)


# ---- card frames -------------------------------------------------------------------------------

# Window and element geometry in card pixels (CW x CH). Exported to Data/Textures.lua as fractions.
FRAMES = {
    "minion": {"window": ("ellipse", 128, 122, 76, 100), "name": (22, 206, 234, 240), "text": (30, 248, 226, 340),
               "cost": (38, 40), "attack": (40, 340), "health": (216, 340), "rarity": (128, 238), "plate": (128, 352)},
    "spell": {"window": ("arch", 44, 28, 212, 200), "name": (22, 196, 234, 230), "text": (34, 240, 222, 344),
              "cost": (38, 40), "rarity": (128, 230), "plate": (128, 352)},
    "weapon": {"window": ("ellipse", 128, 118, 88, 88), "name": (22, 202, 234, 236), "text": (32, 246, 224, 340),
               "cost": (38, 40), "attack": (40, 340), "health": (216, 340), "rarity": (128, 236), "plate": (128, 352)},
    "hero": {"window": ("arch", 34, 24, 222, 214), "name": (22, 206, 234, 240), "text": (32, 248, 224, 340),
             "cost": (38, 40), "health": (216, 340), "rarity": (128, 240), "plate": (128, 352)},
}


def window_fn(spec, grow=0):
    kind = spec[0]
    if kind == "ellipse":
        _, cx, cy, rx, ry = spec
        return ellipse(cx, cy, rx + grow, ry + grow)
    _, x0, y0, x1, y1 = spec
    return arch(x0 - grow, y0 - grow, x1 + grow, y1 + grow)


def card_outline(grow=0):
    return rrect(6 - grow, 6 - grow, CW - 6 + grow, CH - 6 + grow, 18 + grow)


def frame_body(kind, salt):
    """The tintable stone body: card silhouette with the portrait window cut out."""
    f = FRAMES[kind]
    L = Layer(CW, CH)
    body = shape(CW, CH, card_outline())
    win = shape(CW, CH, window_fn(f["window"]))
    m = np.clip(body - win, 0, 1)
    shade = bevel(body, 5, 0.6) * bevel(1 - win, 3, 0.5)
    L.paint(m, gray_stone(CW, CH, salt), shade)
    # a carved groove inside the edge and a raised collar round the window
    groove = ring(CW, CH, card_outline(-12), card_outline(-15))
    L.paint(groove, solid((70, 70, 70)), bevel(1 - groove, 1.5, 0.8), 0.6)
    collar = np.clip(shape(CW, CH, window_fn(f["window"], 14)) - shape(CW, CH, window_fn(f["window"], 6)), 0, 1)
    L.paint(collar, gray_stone(CW, CH, salt + 1) * 1.08, bevel(collar, 3, 0.9), 0.9)
    return L


def banner(x0, y0, x1, y1, sag=6):
    """A ribbon with notched ends that sags a little in the middle."""
    mid = (x0 + x1) / 2
    top = [(x0 + 10, y0 + 4), (mid, y0 + sag), (x1 - 10, y0 + 4)]
    bot = [(x1 - 10, y1 - 2), (mid, y1 + sag - 2), (x0 + 10, y1 - 2)]
    notch_r = [(x1 + 4, y0 + 2), (x1 - 6, (y0 + y1) / 2 + 2), (x1 + 4, y1 + 2)]
    notch_l = [(x0 - 4, y1 + 2), (x0 + 6, (y0 + y1) / 2 + 2), (x0 - 4, y0 + 2)]
    return poly(top + notch_r + bot + notch_l)


def frame_trim(kind, salt):
    """Rims, name banner, text panel and plate: drawn over the tinted body, not tinted."""
    f = FRAMES[kind]
    L = Layer(CW, CH)
    # outer edge: a dark carved line and a thin gold bevel
    edge = ring(CW, CH, card_outline(), card_outline(-5))
    L.paint(edge, gold(CW, CH, salt), bevel(edge, 2, 0.9))
    # portrait rim
    rim = ring(CW, CH, window_fn(f["window"], 7), window_fn(f["window"]))
    rim_col = iron(CW, CH, salt + 1) if kind == "weapon" else gold(CW, CH, salt + 1)
    L.paint(rim, rim_col, bevel(rim, 2.5, 1.0))
    # text panel
    x0, y0, x1, y1 = f["text"]
    if kind == "spell":   # a scroll: a panel with rolled ends
        panel = shape(CW, CH, union(rrect(x0, y0, x1, y1, 6)))
        rolls = shape(CW, CH, union(rrect(x0 - 6, y0 - 4, x1 + 6, y0 + 8, 6), rrect(x0 - 6, y1 - 8, x1 + 6, y1 + 4, 6)))
        L.paint(panel, parchment(CW, CH, salt + 2), bevel(1 - panel, 3, 0.35))
        L.paint(rolls, parchment(CW, CH, salt + 3) * 0.92, bevel(rolls, 2, 0.8))
    else:
        panel = shape(CW, CH, rrect(x0, y0, x1, y1, 10))
        frame = ring(CW, CH, rrect(x0 - 4, y0 - 4, x1 + 4, y1 + 4, 13), rrect(x0, y0, x1, y1, 10))
        L.paint(panel, parchment(CW, CH, salt + 2), bevel(1 - panel, 4, 0.35))
        L.paint(frame, rim_col, bevel(frame, 2, 0.9))
    # name banner
    bx0, by0, bx1, by1 = f["name"]
    b = shape(CW, CH, banner(bx0, by0, bx1, by1))
    L.paint(b, wood(CW, CH, salt + 4) * 1.15, bevel(b, 3, 0.8))
    # race / school plate
    px, py = f["plate"]
    plate = shape(CW, CH, rrect(px - 62, py - 11, px + 62, py + 11, 8))
    L.paint(plate, wood(CW, CH, salt + 5), bevel(plate, 2, 0.9))
    plate_rim = ring(CW, CH, rrect(px - 64, py - 13, px + 64, py + 13, 9), rrect(px - 62, py - 11, px + 62, py + 11, 8))
    L.paint(plate_rim, gold(CW, CH, salt + 6), bevel(plate_rim, 1.5, 0.8))
    return L


def card_back_frame(salt):
    L = Layer(CW, CH)
    outer = shape(CW, CH, card_outline())
    inner = shape(CW, CH, rrect(22, 22, CW - 22, CH - 22, 12))
    body = np.clip(outer - inner, 0, 1)
    L.paint(body, wood(CW, CH, salt), bevel(body, 4, 0.8))
    edge = ring(CW, CH, card_outline(), card_outline(-4))
    L.paint(edge, gold(CW, CH, salt + 1), bevel(edge, 2, 0.9))
    inrim = ring(CW, CH, rrect(18, 18, CW - 18, CH - 18, 14), rrect(22, 22, CW - 22, CH - 22, 12))
    L.paint(inrim, gold(CW, CH, salt + 2), bevel(inrim, 2, 1.0))
    # corner studs and a crest at top and bottom centre
    for cx, cy in ((22, 22), (CW - 22, 22), (22, CH - 22), (CW - 22, CH - 22)):
        st = shape(CW, CH, ellipse(cx, cy, 11, 11))
        L.paint(st, gold(CW, CH, salt + 3), bevel(st, 3, 1.0))
    for cy in (14, CH - 14):
        crest = shape(CW, CH, poly([(128, cy - 12), (146, cy), (128, cy + 12), (110, cy)]))
        L.paint(crest, gold(CW, CH, salt + 4), bevel(crest, 2, 1.0))
    return L


LEG_TOP, LEG_BOTTOM = -48, 80   # card rows the legendary trim covers (it rises above the card)


def legendary_trim(salt):
    """Dragon wings rising from the portrait collar and spreading above the card's top corners.

    256x128, covering card rows LEG_TOP..LEG_BOTTOM; the portrait window stays clear."""
    w, h = 256, LEG_BOTTOM - LEG_TOP
    L = Layer(w, h)
    wing_r = [(176, 70), (188, 40), (214, 8), (232, -20), (250, -42), (242, -12), (255, -8), (238, 14), (253, 24),
              (228, 36), (242, 54), (206, 62), (196, 80)]
    wing_l = [(256 - x, y) for x, y in wing_r]
    crest = [(128, -40), (144, -8), (136, -2), (128, -16), (120, -2), (112, -8)]
    for pts, sv in ((wing_r, 1), (wing_l, 2), (crest, 3)):
        m = shape(w, h, poly([(x, y - LEG_TOP) for x, y in pts]))
        L.paint(m, gold(w, h, salt + sv), bevel(m, 3, 1.0))
    jewel = shape(w, h, ellipse(128, -22 - LEG_TOP, 6, 7))
    L.paint(jewel, solid(RARITY["legendary"]), bevel(jewel, 2, 1.0))
    return L


# ---- gems ---------------------------------------------------------------------------------------

def facet_gem(L, cx, cy, r, color, salt):
    m = shape(L.w, L.h, ellipse(cx, cy, r, r))
    yy, xx = np.mgrid[0:L.h, 0:L.w].astype(np.float32)
    d = np.sqrt((xx - cx + r * 0.3) ** 2 + (yy - cy + r * 0.35) ** 2) / (r * 1.6)
    g = np.clip(1.15 - d, 0, 1)[..., None]
    col = np.array(color, np.float32)
    shade = col * (0.35 + 0.9 * g)
    # facets: brighter and darker wedges
    ang = (np.arctan2(yy - cy, xx - cx) + math.pi) / (2 * math.pi)
    shade = shade * (0.9 + 0.12 * (np.floor(ang * 8) % 2))[..., None]
    L.paint(m, shade, bevel(m, r * 0.18, 0.7))
    hi = shape(L.w, L.h, ellipse(cx - r * 0.35, cy - r * 0.4, r * 0.28, r * 0.18))
    L.paint(hi, solid((255, 255, 255)), None, 0.55)


FLAT = {"mana": (40, 110, 230), "attack": (226, 172, 40), "health": (204, 40, 34),
        "durability": (120, 124, 132), "armor": (150, 156, 166)}


def hexagon(cx, cy, r):
    """A flat-topped... no: a pointy-topped hexagon (the mana crystal's face)."""
    return poly([(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in range(-90, 270, 60)])


def flat_gem(L, outline_fn, fill_fn, colour, face_fn=None):
    """Flat, two-tone: a dark outline, the colour, and a lighter inner face so it reads as a gem without the
    3D shading (which made the numbers harder to read)."""
    outline = shape(L.w, L.h, outline_fn)
    fill = shape(L.w, L.h, fill_fn)
    L.paint(outline, solid((20, 12, 6)))
    col = np.array(colour, np.float32)
    L.paint(fill, np.broadcast_to(col * 0.78, (L.h, L.w, 3)))
    if face_fn:
        face = shape(L.w, L.h, face_fn)
        L.paint(face, np.broadcast_to(np.minimum(col * 1.08 + 12, 255), (L.h, L.w, 3)))


def gems_atlas():
    """4x4 cells of 64: mana, attack, health, durability, armor, then rarity gems."""
    L = Layer(256, 256)
    cell = 64
    cells = {}

    def at(i):
        c, r = i % 4, i // 4
        cells_xy = (c * cell + cell / 2, r * cell + cell / 2)
        return cells_xy

    names = ["mana", "attack", "health", "durability", "armor", "common", "rare", "epic", "legendary"]
    for i, nm in enumerate(names):
        cx, cy = at(i)
        cells[nm] = (i % 4, i // 4)
        if nm in RARITY:
            ring_m = shape(256, 256, ellipse(cx, cy, 15, 19))
            L.paint(ring_m, gold(256, 256, 36), bevel(ring_m, 2, 1.0))
            facet_gem(L, cx, cy, 12, RARITY[nm], 37)
            continue
        # Stat gems are flat: a plain colour with a dark outline and a faint top-to-bottom shade, so the
        # number on them reads at a glance (the faceted look was harder to read).
        if nm == "health":   # a teardrop
            outline = union(ellipse(cx, cy + 6, 25, 25), poly([(cx, cy - 31), (cx + 22, cy - 3), (cx - 22, cy - 3)]))
            fill = union(ellipse(cx, cy + 6, 22, 22), poly([(cx, cy - 26), (cx + 19, cy - 2), (cx - 19, cy - 2)]))
            face = union(ellipse(cx, cy + 7, 17, 17), poly([(cx, cy - 18), (cx + 14, cy + 1), (cx - 14, cy + 1)]))
        elif nm == "armor":   # a shield
            outline = poly([(cx - 26, cy - 26), (cx + 26, cy - 26), (cx + 26, cy + 4), (cx, cy + 30), (cx - 26, cy + 4)])
            fill = poly([(cx - 23, cy - 23), (cx + 23, cy - 23), (cx + 23, cy + 3), (cx, cy + 26), (cx - 23, cy + 3)])
            face = poly([(cx - 18, cy - 18), (cx + 18, cy - 18), (cx + 18, cy + 1), (cx, cy + 19), (cx - 18, cy + 1)])
        elif nm == "mana":   # a hexagonal crystal
            outline, fill, face = hexagon(cx, cy, 31), hexagon(cx, cy, 27), hexagon(cx, cy, 20)
        else:   # attack, durability: a disc
            outline, fill, face = ellipse(cx, cy, 29, 29), ellipse(cx, cy, 26, 26), ellipse(cx, cy, 20, 20)
        flat_gem(L, outline, fill, FLAT[nm], face)
    return L, cells


# ---- the board ----------------------------------------------------------------------------------

BW, BH = 1000, 692
SURFACE = (186, 170, 814, 434)   # the stone play surface (x0, y0, x1, y1): the two minion rows


def board_table():
    L = Layer(BW, BH)
    L.paint(np.ones((BH, BW), np.float32), wood(BW, BH, 50))
    # planks: darker seams every ~110px
    seams = shape(BW, BH, lambda d, s: [d.line([(0, y * s), (BW * s, y * s)], fill=255, width=2 * s) for y in range(40, BH, 112)])
    L.paint(seams, solid(PALETTE["wood_dark"]) * 0.6, None, 0.8)
    x0, y0, x1, y1 = SURFACE
    shadow = blur(shape(BW, BH, rrect(x0 - 6, y0 - 2, x1 + 6, y1 + 12, 40)), 10)
    L.paint(shadow, solid((10, 6, 3)), None, 0.7)
    rim = shape(BW, BH, rrect(x0 - 5, y0 - 5, x1 + 5, y1 + 5, 30))   # a narrow brass line round the stone
    L.paint(rim, gold(BW, BH, 51) * 0.95, bevel(rim, 2, 0.9))
    surf = shape(BW, BH, rrect(x0, y0, x1, y1, 26))
    st = stone(BW, BH, 52)
    yy, xx = np.mgrid[0:BH, 0:BW].astype(np.float32)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    vign = 1 - 0.28 * np.clip(((xx - cx) / ((x1 - x0) / 2)) ** 2 + ((yy - cy) / ((y1 - y0) / 2)) ** 2 - 0.2, 0, 1)
    L.paint(surf, st, bevel(1 - surf, 6, 0.45) * vign)
    # cracks: a few thin dark lines across the stone
    r = rng(53)
    cracks = np.zeros((BH, BW), np.float32)
    for _ in range(7):
        px, py = r.uniform(x0 + 40, x1 - 40), r.uniform(y0 + 30, y1 - 30)
        pts = [(px, py)]
        ang = r.uniform(0, 2 * math.pi)
        for _ in range(int(r.integers(4, 9))):
            ang += r.normal(0, 0.6)
            px, py = px + math.cos(ang) * r.uniform(12, 30), py + math.sin(ang) * r.uniform(8, 20)
            pts.append((px, py))
        cracks = np.maximum(cracks, shape(BW, BH, lambda d, s, pts=pts: d.line([(a * s, b * s) for a, b in pts], fill=255, width=s)))
    L.paint(cracks * surf, solid((92, 74, 48)), None, 0.55)
    # The window's gold border (the client's) frames the table; inside it, a soft shadow so the wood
    # meets the border rather than ending flat. Square corners, like the border.
    shade = blur(1 - shape(BW, BH, rrect(18, 18, BW - 18, BH - 18, 2)), 10)
    L.paint(shade, solid((0, 0, 0)), None, 0.5)
    return L


def board_wood_mask():
    """White over the wood, clear over the stone surface and its rim: where a table painting may tint."""
    x0, y0, x1, y1 = SURFACE
    m = 1 - shape(BW, BH, rrect(x0 - 5, y0 - 5, x1 + 5, y1 + 5, 30))
    L = Layer(BW, BH)
    L.paint(m, solid((255, 255, 255)))
    return L


def board_seam():
    w, h = 512, 32
    L = Layer(w, h)
    m = shape(w, h, rrect(0, 12, w, 20, 4))
    L.paint(m, gold(w, h, 60), bevel(m, 2, 1.0))
    for x in range(16, w, 64):
        st = shape(w, h, ellipse(x, 16, 6, 6))
        L.paint(st, gold(w, h, 61), bevel(st, 2, 1.0))
    return L


class Squash:
    """Draw in widget units on a power-of-two texture that the client stretches back to the widget's shape.

    Shapes are given in widget pixels (e.g. the 84x108 minion token); thicknesses stay true after the stretch."""

    def __init__(self, tw, th, ww, wh):
        self.tw, self.th, self.sx, self.sy = tw, th, tw / ww, th / wh

    def ellipse(self, cx, cy, rx, ry):
        return ellipse(cx * self.sx, cy * self.sy, rx * self.sx, ry * self.sy)

    def poly(self, pts):
        return poly([(x * self.sx, y * self.sy) for x, y in pts])

    def arch(self, x0, y0, x1, y1):
        sx, sy = self.sx, self.sy

        def fn(d, s):
            r = (x1 - x0) / 2
            d.ellipse([x0 * sx * s, y0 * sy * s, x1 * sx * s, (y0 + 2 * r) * sy * s], fill=255)
            d.rectangle([x0 * sx * s, (y0 + r) * sy * s, x1 * sx * s, y1 * sy * s], fill=255)
        return fn


TOKEN_W, TOKEN_H = 84, 108   # the board's minion slot (UI/Board/Board.lua SLOT_W, SLOT_H)


TOKEN_RIM = 4   # widget pixels of frame round the minion's window (the 3D model fills the window exactly)


def token_frame(legendary=False):
    """The minion token: a narrow rounded-square frame round the 84x108 slot (128x256, stretched back).

    Square, not oval, because a 3D model can only be clipped to a rectangle: the window is the model's
    rectangle, so nothing spills past the frame."""
    q = Squash(128, 256, TOKEN_W, TOKEN_H)
    L = Layer(128, 256)
    r = TOKEN_RIM

    def rr(x0, y0, x1, y1, rad):
        return rrect(x0 * q.sx, y0 * q.sy, x1 * q.sx, y1 * q.sy, rad * q.sx)

    rim = ring(128, 256, rr(0, 0, TOKEN_W, TOKEN_H, 9), rr(r, r, TOKEN_W - r, TOKEN_H - r, 5))
    col = gold(128, 256, 72) if legendary else iron(128, 256, 70) * 0.5 + gold(128, 256, 72) * 0.5
    L.paint(rim, col, bevel(rim, 2, 1.0))
    edge = ring(128, 256, rr(0, 0, TOKEN_W, TOKEN_H, 9), rr(1, 1, TOKEN_W - 1, TOKEN_H - 1, 8))
    L.paint(edge, solid((30, 20, 10)), None, 0.8)
    return L


def token_wings():
    """Legendary minion wings above the token: 128x64 for an 84x42 strip whose bottom overlaps the oval top."""
    q = Squash(128, 64, TOKEN_W, 42)
    L = Layer(128, 64)
    for sgn in (-1, 1):
        cx = TOKEN_W / 2
        pts = [(cx + sgn * 14, 40), (cx + sgn * 26, 22), (cx + sgn * 40, 2), (cx + sgn * 36, 16), (cx + sgn * 42, 14),
               (cx + sgn * 34, 26), (cx + sgn * 40, 30), (cx + sgn * 26, 36)]
        m = shape(128, 64, q.poly(pts))
        L.paint(m, gold(128, 64, 73 + sgn), bevel(m, 2, 1.0))
    jewel = shape(128, 64, q.ellipse(TOKEN_W / 2, 34, 4, 5))
    L.paint(jewel, solid(RARITY["legendary"]), bevel(jewel, 1.5, 1.0))
    return L


HERO_PAD = 12   # widget pixels the hero frame reaches outside the 84x84 portrait


def hero_frame():
    """An arch-topped frame round the 84x84 hero portrait, reaching HERO_PAD outside it (256x256 for 108x108)."""
    side = 84 + 2 * HERO_PAD
    q = Squash(256, 256, side, side)
    L = Layer(256, 256)
    p0, p1 = HERO_PAD, HERO_PAD + 84
    outer = shape(256, 256, q.arch(1, 1, side - 1, side - 1))
    win = shape(256, 256, q.arch(p0, p0, p1, p1))
    body = np.clip(outer - win, 0, 1)
    L.paint(body, stone(256, 256, 80, (52, 56, 62), (128, 134, 144)), bevel(body, 4, 0.8))
    for o, i in (((1, 1, side - 1, side - 1), (3, 3, side - 3, side - 3)), ((p0 - 3, p0 - 3, p1 + 3, p1 + 3), (p0, p0, p1, p1))):
        rm = ring(256, 256, q.arch(*o), q.arch(*i))
        L.paint(rm, gold(256, 256, 81), bevel(rm, 2, 1.0))
    return L


def hero_power():
    """A thin ring round a round icon (hero power, weapon): most of the art shows."""
    w = h = 128
    L = Layer(w, h)
    rimm = ring(w, h, ellipse(64, 64, 62, 62), ellipse(64, 64, 55, 55))
    L.paint(rimm, iron(w, h, 90) * 0.4 + gold(w, h, 91) * 0.6, bevel(rimm, 2, 1.0))
    edge = ring(w, h, ellipse(64, 64, 63, 63), ellipse(64, 64, 61.5, 61.5))
    L.paint(edge, solid((30, 20, 10)), None, 0.8)
    return L


def mana_crystal():
    """Four 64x64 cells, the cost gem's hexagon: full, empty, locked (overload), locked next turn."""
    L = Layer(256, 64)
    looks = [FLAT["mana"], (52, 62, 84), (176, 48, 40), (130, 76, 70)]
    for i, col in enumerate(looks):
        cx = i * 64 + 32
        flat_gem(L, hexagon(cx, 32, 30), hexagon(cx, 32, 26), col, hexagon(cx, 32, 19) if i != 1 else None)
        if i == 2:   # a bar across the locked crystal
            bar = shape(256, 64, rrect(cx - 20, 28, cx + 20, 36, 3))
            L.paint(bar, solid((30, 16, 12)), None, 0.9)
    return L


def overlays_atlas():
    """4x4 cells of 128."""
    L = Layer(512, 512)
    cells = {}
    names = ["taunt", "divine", "frozen", "stealth", "silence", "enrage", "deathrattle", "trigger",
             "poisonous", "lifesteal", "windfury", "sleep"]
    yy, xx = np.mgrid[0:512, 0:512].astype(np.float32)
    for i, nm in enumerate(names):
        c, r = i % 4, i // 4
        cells[nm] = (c, r)
        ox, oy = c * 128, r * 128
        cx, cy = ox + 64, oy + 64
        if nm == "taunt":   # a stone shield behind the token
            pts = [(cx - 56, cy - 58), (cx, cy - 64), (cx + 56, cy - 58), (cx + 54, cy + 10), (cx, cy + 62), (cx - 54, cy + 10)]
            m = shape(512, 512, poly(pts))
            L.paint(m, stone(512, 512, 110, (90, 84, 76), (170, 160, 140)), bevel(m, 5, 0.9))
            rimm = np.clip(m - shape(512, 512, poly([(x + (cx - x) * 0.1, y + (cy - y) * 0.1) for x, y in pts])), 0, 1)
            L.paint(rimm, gold(512, 512, 111), bevel(rimm, 2, 1.0))
        elif nm == "divine":   # a golden bubble
            d = np.sqrt(((xx - cx) / 58) ** 2 + ((yy - cy) / 62) ** 2)
            a = np.clip((d - 0.55) * 2.4, 0, 1) * (d < 1)
            a = a * np.clip((1 - d) * 18, 0, 1)
            L.paint(a, solid((255, 220, 90)), None, 0.9)
        elif nm == "frozen":   # ice shards
            r_ = rng(112)
            m = np.zeros((512, 512), np.float32)
            for _ in range(14):
                a = r_.uniform(0, 2 * math.pi)
                l_ = r_.uniform(24, 58)
                wdt = r_.uniform(6, 12)
                tip = (cx + math.cos(a) * l_, cy + math.sin(a) * l_)
                left = (cx + math.cos(a + 1.57) * wdt, cy + math.sin(a + 1.57) * wdt)
                right = (cx + math.cos(a - 1.57) * wdt, cy + math.sin(a - 1.57) * wdt)
                m = np.maximum(m, shape(512, 512, poly([left, tip, right])))
            L.paint(m, solid((170, 220, 255)), bevel(m, 2, 0.8), 0.75)
        elif nm == "stealth":   # smoky haze
            n = noise(512, 512, 113, octaves=4, base=6)
            d = np.sqrt(((xx - cx) / 60) ** 2 + ((yy - cy) / 62) ** 2)
            a = np.clip(1 - d, 0, 1) * (0.4 + 0.6 * n)
            L.paint(a, solid((40, 30, 60)), None, 0.85)
        elif nm == "silence":   # a struck-through circle
            m = ring(512, 512, ellipse(cx, cy, 40, 40), ellipse(cx, cy, 31, 31))
            bar = shape(512, 512, poly([(cx - 30, cy + 24), (cx + 24, cy - 30), (cx + 30, cy - 24), (cx - 24, cy + 30)]))
            L.paint(np.maximum(m, bar), solid((210, 40, 40)), bevel(np.maximum(m, bar), 2, 0.8))
        elif nm == "enrage":   # a red radial glow
            d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / 62
            L.paint(np.clip(1 - d, 0, 1) ** 1.5 * (d < 1), solid((255, 60, 40)), None, 0.9)
        elif nm == "deathrattle":   # a skull
            sk = shape(512, 512, union(ellipse(cx, cy - 8, 30, 28), rrect(cx - 18, cy + 8, cx + 18, cy + 34, 6)))
            holes = shape(512, 512, union(ellipse(cx - 12, cy - 6, 8, 9), ellipse(cx + 12, cy - 6, 8, 9),
                                          poly([(cx, cy + 6), (cx - 5, cy + 16), (cx + 5, cy + 16)])))
            L.paint(sk, solid((226, 218, 196)), bevel(sk, 3, 0.9))
            L.paint(holes, solid((30, 20, 16)), None, 0.95)
        elif nm == "trigger":   # a lightning bolt
            pts = [(cx + 8, cy - 40), (cx - 20, cy + 6), (cx - 2, cy + 6), (cx - 10, cy + 40), (cx + 20, cy - 8), (cx + 2, cy - 8)]
            m = shape(512, 512, poly(pts))
            L.paint(m, gold(512, 512, 114) * 1.1, bevel(m, 2, 1.0))
        elif nm == "poisonous":   # a green drop
            m = shape(512, 512, union(ellipse(cx, cy + 8, 22, 22), poly([(cx, cy - 34), (cx + 19, cy), (cx - 19, cy)])))
            L.paint(m, solid((70, 190, 60)), bevel(m, 3, 1.0))
        elif nm == "lifesteal":   # a heart
            m = shape(512, 512, union(ellipse(cx - 13, cy - 8, 17, 17), ellipse(cx + 13, cy - 8, 17, 17),
                                      poly([(cx - 29, cy - 2), (cx + 29, cy - 2), (cx, cy + 32)])))
            L.paint(m, solid((200, 30, 60)), bevel(m, 3, 1.0))
        elif nm == "windfury":   # a swirl
            m = np.zeros((512, 512), np.float32)
            for k in range(3):
                rad = 14 + k * 12
                arc = shape(512, 512, lambda d, s, rad=rad, k=k: d.arc([(cx - rad) * s, (cy - rad) * s, (cx + rad) * s, (cy + rad) * s],
                                                                       start=k * 70, end=k * 70 + 230, fill=255, width=5 * s))
                m = np.maximum(m, arc)
            L.paint(m, solid((190, 230, 255)), bevel(m, 1.5, 0.8))
        elif nm == "sleep":   # Zzz
            m = np.zeros((512, 512), np.float32)
            for k, (zx, zy, sz) in enumerate(((cx - 18, cy + 12, 18), (cx + 6, cy - 6, 14), (cx + 22, cy - 22, 10))):
                pts = [(zx - sz, zy - sz), (zx + sz, zy - sz), (zx - sz, zy + sz), (zx + sz, zy + sz)]
                m = np.maximum(m, shape(512, 512, lambda d, s, pts=pts, sz=sz: d.line([(a * s, b * s) for a, b in pts], fill=255, width=max(2, sz // 4) * s)))
            L.paint(m, solid((240, 240, 255)), None, 0.95)
    return L, cells


def arrow_parts():
    """The targeting arrow: a chevron segment and the head, each 64x64 and pointing up. Separate files,
    not atlas cells, because the client rotates them (SetRotation can reset texture coordinates)."""
    seg = Layer(64, 64)
    m = shape(64, 64, poly([(8, 44), (32, 16), (56, 44), (56, 58), (32, 32), (8, 58)]))
    seg.paint(m, solid((255, 255, 255)), bevel(m, 2, 0.6))
    head = Layer(64, 64)
    m = shape(64, 64, poly([(6, 60), (32, 2), (58, 60), (32, 46)]))
    head.paint(m, solid((255, 255, 255)), bevel(m, 3, 0.7))
    return seg, head


def end_turn_button():
    """Four 256x64 rows: ready, hover, waiting (disabled), and the "your turn" glow."""
    L = Layer(256, 256)
    for i in range(4):
        oy = i * 64
        body = shape(256, 256, rrect(10, oy + 8, 246, oy + 56, 22))
        col = {0: (210, 170, 60), 1: (240, 200, 80), 2: (90, 86, 80), 3: (110, 200, 70)}[i]
        L.paint(body, stone(256, 256, 120 + i, tuple(int(c * 0.6) for c in col), col), bevel(body, 4, 0.9))
        rimm = ring(256, 256, rrect(6, oy + 4, 250, oy + 60, 26), rrect(10, oy + 8, 246, oy + 56, 22))
        L.paint(rimm, gold(256, 256, 125) if i != 2 else iron(256, 256, 126), bevel(rimm, 2, 1.0))
    return L


def rope_tex():
    """256x64: row 0 a tileable twisted fuse, row 1 the spark."""
    L = Layer(256, 64)
    yy, xx = np.mgrid[0:64, 0:256].astype(np.float32)
    twist = 0.5 + 0.5 * np.sin((xx / 256 * 16 + (yy - 16) / 10) * math.pi)
    m = shape(256, 64, rrect(0, 9, 256, 23, 6))
    L.paint(m, tint(twist, (90, 60, 30), (200, 160, 100)), bevel(m, 2, 0.8))
    d = np.sqrt((xx - 128) ** 2 + (yy - 48) ** 2) / 16
    L.paint(np.clip(1 - d, 0, 1) ** 1.2, solid((255, 200, 80)), None, 1.0)
    return L


GLOW_M = 24   # card pixels of halo around the card in card_glow (exported as a fraction)


def card_glow():
    """The playable / selected outline of a card: a bright line on the card's rounded edge and a soft
    halo outside it, nothing over the card face (it is drawn additive). Covers the card plus GLOW_M."""
    w, h = CW + 2 * GLOW_M, CH + 2 * GLOW_M
    L = Layer(w, h)
    outline = shape(w, h, rrect(GLOW_M + 6, GLOW_M + 6, w - GLOW_M - 6, h - GLOW_M - 6, 18))
    inside = shape(w, h, rrect(GLOW_M + 12, GLOW_M + 12, w - GLOW_M - 12, h - GLOW_M - 12, 14))
    halo = blur(shape(w, h, rrect(GLOW_M - 4, GLOW_M - 4, w - GLOW_M + 4, h - GLOW_M + 4, 26)), 9)
    line = np.clip(outline - inside, 0, 1)
    L.paint(np.clip(halo * 0.75 * (1 - inside) + line, 0, 1), solid((255, 255, 255)))
    L.rgb = np.asarray(Image.fromarray(np.clip(L.rgb, 0, 255).astype(np.uint8)).resize((256, 512), Image.LANCZOS), np.float32)
    L.a = np.asarray(Image.fromarray((L.a * 255).astype(np.uint8)).resize((256, 512), Image.LANCZOS), np.float32) / 255
    L.w, L.h = 256, 512
    return L


def token_glow():
    """A rounded-square glow round a minion token (128x256 for the slot plus a 20px halo), drawn additive."""
    M = 20
    q = Squash(128, 256, TOKEN_W + 2 * M, TOKEN_H + 2 * M)

    def rr(x0, y0, x1, y1, rad):
        return rrect(x0 * q.sx, y0 * q.sy, x1 * q.sx, y1 * q.sy, rad * q.sx)

    w, h = 128, 256
    L = Layer(w, h)
    band = ring(w, h, rr(M - 4, M - 4, M + TOKEN_W + 4, M + TOKEN_H + 4, 12), rr(M + 2, M + 2, M + TOKEN_W - 2, M + TOKEN_H - 2, 7))
    halo = blur(band, 5)
    L.paint(np.clip(halo * 1.7, 0, 1), solid((255, 255, 255)))
    return L


TOKEN_GLOW_M = 20


def glow_tex():
    w = h = 128
    L = Layer(w, h)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt((xx - 64) ** 2 + (yy - 64) ** 2) / 62
    L.paint(np.clip(1 - d, 0, 1) ** 2, solid((255, 255, 255)))
    return L


def mask(fn, w, h):
    m = shape(w, h, fn)
    L = Layer(w, h)
    L.paint(m, solid((255, 255, 255)))
    return L


# ---- preview ------------------------------------------------------------------------------------

def sample_cards():
    """Whole cards put together the way the client layers them: portrait, tinted body, trim, gems."""
    def tex(name):
        return Image.open(os.path.join(OUT, name + ".tga")).convert("RGBA")

    gems = tex("gems")

    def gem(name, size):
        c, r = [(k, v) for k, v in gems_cells.items() if k == name][0][1]
        return gems.crop((c * 64, r * 64, c * 64 + 64, r * 64 + 64)).resize((size, size), Image.LANCZOS)

    def portrait(salt):
        n = noise(CW, CH, 900 + salt, octaves=4, base=3)
        hue = np.array([(70, 110, 60), (60, 80, 140), (140, 70, 50), (90, 60, 120)][salt % 4], np.float32)
        rgb = np.clip(hue * (0.5 + n[..., None]), 0, 255).astype(np.uint8)
        return Image.fromarray(np.dstack([rgb, np.full((CH, CW), 255, np.uint8)]), "RGBA")

    _, gems_cells = gems_atlas()
    out = []
    samples = [("minion", (176, 150, 116), "common", False), ("spell", (105, 170, 240), "rare", False),
               ("weapon", (200, 130, 90), "epic", False), ("minion", (240, 210, 120), "legendary", True),
               ("hero", (160, 120, 220), "legendary", False)]
    for i, (kind, colour, rarity, legendary) in enumerate(samples):
        card = Image.new("RGBA", (CW, CH + 48), (0, 0, 0, 0))
        win = Image.fromarray((shape(CW, CH, window_fn(FRAMES[kind]["window"], 4)) * 255).astype(np.uint8), "L")
        pic = portrait(i)
        pic.putalpha(win)
        card.alpha_composite(pic, (0, 48))
        body = tex("frame_%s_body" % kind).crop((0, 0, CW, CH))
        arr = np.asarray(body, np.float32)
        arr[..., :3] *= np.array(colour, np.float32) / 255
        card.alpha_composite(Image.fromarray(arr.astype(np.uint8), "RGBA"), (0, 48))
        card.alpha_composite(tex("frame_%s" % kind).crop((0, 0, CW, CH)), (0, 48))
        if legendary:   # under the gems, as in the client
            card.alpha_composite(tex("frame_legendary"), (0, 48 + LEG_TOP))
        f = FRAMES[kind]
        for key, name in (("cost", "mana"), ("attack", "attack"), ("health", "health")):
            if key in f:
                gx, gy = f[key]
                card.alpha_composite(gem(name, 64), (int(gx - 32), int(gy - 32 + 48)))
        rx, ry = f["rarity"]
        card.alpha_composite(gem(rarity, 36), (int(rx - 18), int(ry - 18 + 48)))
        out.append(card)
    return out


# ---- output -------------------------------------------------------------------------------------

def save(L, name, size, stretch=False):
    """size: the power-of-two canvas. stretch: scale the art to fill it (used without texture coordinates,
    which matters for masks: the client ignores SetTexCoord on a MaskTexture)."""
    path = os.path.join(OUT, name + ".tga")
    im = L.image(None if stretch else size)
    if stretch:
        im = im.resize(size, Image.LANCZOS)
    im.save(path)   # 32-bit uncompressed TGA, which the client reads
    return path


def lua_num(x):
    return ("%.4f" % x).rstrip("0").rstrip(".")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="also write a contact sheet PNG here")
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    written = []

    for i, kind in enumerate(FRAMES):
        written.append((save(frame_body(kind, 10 + i * 10), "frame_%s_body" % kind, (256, 512)), (CW, CH)))
        written.append((save(frame_trim(kind, 15 + i * 10), "frame_%s" % kind, (256, 512)), (CW, CH)))
    written.append((save(card_back_frame(140), "card_back_frame", (256, 512)), (CW, CH)))
    written.append((save(legendary_trim(150), "frame_legendary", None), None))
    gems, gem_cells = gems_atlas()
    written.append((save(gems, "gems", None), None))
    board = board_table()
    written.append((save(board, "board_table", (1024, 1024), stretch=True), None))
    written.append((save(board_seam(), "board_seam", None), None))
    written.append((save(token_frame(), "token_frame", None), None))
    written.append((save(token_frame(True), "token_frame_legendary", None), None))
    written.append((save(token_wings(), "token_wings", None), None))
    written.append((save(board_wood_mask(), "board_wood_mask", (1024, 1024), stretch=True), None))
    written.append((save(hero_frame(), "hero_frame", None), None))
    written.append((save(hero_power(), "hero_power", None), None))
    written.append((save(mana_crystal(), "mana_crystal", None), None))
    ov, ov_cells = overlays_atlas()
    written.append((save(ov, "overlays", None), None))
    seg, head = arrow_parts()
    written.append((save(seg, "arrow_segment", None), None))
    written.append((save(head, "arrow_head", None), None))
    written.append((save(end_turn_button(), "button_end_turn", None), None))
    written.append((save(rope_tex(), "rope", None), None))
    written.append((save(glow_tex(), "glow", None), None))
    written.append((save(card_glow(), "card_glow", None), None))
    written.append((save(token_glow(), "token_glow", None), None))
    written.append((save(mask(arch(2, 2, 126, 254), 128, 256), "mask_arch", None), None))
    written.append((save(mask(ellipse(64, 64, 62, 62), 128, 128), "mask_round", None), None))

    # Data/Textures.lua: where things are, as fractions of the card / texture
    out = ["-- GENERATED by tools/textures/build.py. Do not edit.",
           "-- Card geometry is in fractions of the card (0..1 across, 0..1 down); atlas cells are {left, right, top, bottom}.",
           "local TC = TavernCards_NS", "TC.TexLayout = {",
           "    card = { texBottom = %s, legendary = { %s, %s }, glow = { %s, %s } }," % (
               lua_num(CH / CTEX), lua_num(LEG_TOP / CH), lua_num(LEG_BOTTOM / CH), lua_num(GLOW_M / CW), lua_num(GLOW_M / CH),
),
           "    surface = { %s, %s, %s, %s }," % tuple(lua_num(v / d) for v, d in zip(SURFACE, (BW, BH, BW, BH))),
           "    heroFrame = { pad = %d }," % HERO_PAD,
           "    plateWidth = %s," % lua_num(120 / CW)]
    for kind, f in FRAMES.items():
        parts = []
        spec = f["window"]
        if spec[0] == "ellipse":
            _, cx, cy, rx, ry = spec
            x0, y0, x1, y1 = cx - rx, cy - ry, cx + rx, cy + ry
        else:
            _, x0, y0, x1, y1 = spec
        parts.append("window = { %s, %s, %s, %s, shape = %r }" % (
            lua_num(x0 / CW), lua_num(y0 / CH), lua_num(x1 / CW), lua_num(y1 / CH), spec[0]))
        for key in ("name", "text"):
            a, b, c, d = f[key]
            parts.append("%s = { %s, %s, %s, %s }" % (key, lua_num(a / CW), lua_num(b / CH), lua_num(c / CW), lua_num(d / CH)))
        for key in ("cost", "attack", "health", "rarity", "plate"):
            if key in f:
                x, y = f[key]
                parts.append("%s = { %s, %s }" % (key, lua_num(x / CW), lua_num(y / CH)))
        out.append("    %s = { %s }," % (kind, ", ".join(parts).replace("'", '"')))

    def cells_lua(name, cells, n, size):
        items = []
        for k, (c, r) in sorted(cells.items()):
            items.append("%s = { %s, %s, %s, %s }" % (k, lua_num(c / n), lua_num((c + 1) / n), lua_num(r / n), lua_num((r + 1) / n)))
        out.append("    %s = { %s }," % (name, ", ".join(items)))

    cells_lua("gems", gem_cells, 4, 256)
    cells_lua("overlays", ov_cells, 4, 512)
    out.append("}")
    with open(os.path.join(REPO, "Data", "Textures.lua"), "w") as fh:
        fh.write("\n".join(out) + "\n")

    if args.preview:
        tiles = sample_cards() + [Image.open(p).convert("RGBA").crop((0, 0) + (crop or Image.open(p).size)) for p, crop in written]
        bg = (48, 40, 34, 255)
        x = y = row_h = 0
        width = 1600
        placed = []
        for t in tiles:
            scale = min(1.0, 400 / max(t.size))
            t = t.resize((max(1, int(t.width * scale)), max(1, int(t.height * scale))), Image.LANCZOS)
            if x + t.width > width:
                x, y, row_h = 0, y + row_h + 12, 0
            placed.append((t, x, y))
            x += t.width + 12
            row_h = max(row_h, t.height)
        sheet = Image.new("RGBA", (width, y + row_h + 12), bg)
        for t, px, py in placed:
            sheet.alpha_composite(t, (px, py))
        sheet.convert("RGB").save(args.preview)
    print("textures: %d written to %s" % (len(written), os.path.relpath(OUT, REPO)))


if __name__ == "__main__":
    main()
