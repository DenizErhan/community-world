#!/usr/bin/env python3
"""Generate all world art (SVG) from design/tokens.json.

    python3 tools/gen_assets.py          # (re)write assets/
    python3 tools/gen_assets.py --check  # exit 1 if assets/ is out of date (used by CI)

Rules live in tokens.json, not here: palettes per age, face shading, building
shape parameters. Change a token, rerun, commit the regenerated SVGs.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOK = json.loads((ROOT / "design" / "tokens.json").read_text(encoding="utf-8"))
G = TOK["grid"]
L = TOK["light"]
TW, TH = G["tile_w"], G["tile_h"]
SW, SH = G["sprite_canvas"]
AX, AY = G["sprite_anchor"]
TCW, TCH = G["tile_canvas"]
TAX, TAY = G["tile_anchor"]


# ---- color math (matches Godot's Color.darkened / Color.lightened) ----------

def _rgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def _hex(c):
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(v))) for v in c)


def darken(h, a):
    return _hex([v * (1 - a) for v in _rgb(h)])


def lighten(h, a):
    return _hex([v + (255 - v) * a for v in _rgb(h)])


# ---- svg primitives ----------------------------------------------------------

def f1(v):
    s = "%.1f" % v
    return s[:-2] if s.endswith(".0") else s


def poly(pts, fill, opacity=None):
    p = " ".join("%s,%s" % (f1(x), f1(y)) for x, y in pts)
    extra = ' fill-opacity="%s"' % opacity if opacity is not None else ""
    return '<polygon points="%s" fill="%s"%s/>' % (p, fill, extra)


def add(p, d):
    return (p[0] + d[0], p[1] + d[1])


def lerp(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def svg(w, h, body):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">\n  %s\n</svg>\n'
        % (w, h, w, h, "\n  ".join(body))
    )


def diamond(c, scale=1.0):
    hw, hh = TW * 0.5 * scale, TH * 0.5 * scale
    return [(c[0], c[1] - hh), (c[0] + hw, c[1]), (c[0], c[1] + hh), (c[0] - hw, c[1])]


# ---- building blocks ---------------------------------------------------------

def box(c, f, h, col):
    hw, hh = TW * 0.5 * f, TH * 0.5 * f
    up = (0, -h)
    tp, rt = (c[0], c[1] - hh), (c[0] + hw, c[1])
    bt, lf = (c[0], c[1] + hh), (c[0] - hw, c[1])
    return [
        poly([lf, bt, add(bt, up), add(lf, up)], darken(col, L["left_face_darken"])),
        poly([bt, rt, add(rt, up), add(bt, up)], darken(col, L["right_face_darken"])),
        poly([add(tp, up), add(rt, up), add(bt, up), add(lf, up)], lighten(col, L["top_face_lighten"])),
    ]


def shadow(c, scale):
    if scale <= 0:
        return []
    return [poly(diamond(add(c, (6, 3)), scale), "#000000", L["contact_shadow_opacity"])]


# ---- buildings ---------------------------------------------------------------

def hut(pal, age):
    p = TOK["shapes"]["hut"]
    a = p["ages"][age]
    c = (AX, AY)
    f, h = a["f"], a["h"]
    out = shadow(c, p["shadow"])
    out += box(c, f, h, pal[p["role_wall"]])
    hw, hh = TW * 0.5 * f, TH * 0.5 * f
    up = (0, -h)
    # door on the right face, window on the left face
    bt, rt, lf = (c[0], c[1] + hh), (c[0] + hw, c[1]), (c[0] - hw, c[1])
    if a["door"]:
        p0, p1 = lerp(bt, rt, 0.30), lerp(bt, rt, 0.62)
        dh = h * 0.55
        out.append(poly([p0, p1, add(p1, (0, -dh)), add(p0, (0, -dh))], pal["door"]))
    if a["window"]:
        q0, q1 = lerp(lf, bt, 0.30), lerp(lf, bt, 0.62)
        out.append(poly([add(q0, (0, -h * 0.45)), add(q1, (0, -h * 0.45)),
                         add(q1, (0, -h * 0.78)), add(q0, (0, -h * 0.78))], pal["window"]))
    # hip roof
    o = a["overhang"]
    rhw, rhh = TW * 0.5 * o, TH * 0.5 * o
    apex = (c[0], c[1] - h - a["roof_h"])
    rl = add((c[0] - rhw, c[1]), up)
    rb = add((c[0], c[1] + rhh), up)
    rr = add((c[0] + rhw, c[1]), up)
    roof = pal[p["role_roof"]]
    out.append(poly([rl, rb, apex], darken(roof, L["roof_left_darken"])))
    out.append(poly([rb, rr, apex], darken(roof, L["roof_right_darken"])))
    if a["chimney"]:
        out += box((c[0] - 14, c[1] - h - 4), 0.16, 20, pal["rock"])
    return out


def farm(pal, age):
    p = TOK["shapes"]["farm"]
    c = (AX, AY)
    base = pal[p["role_base"]]
    out = shadow(c, p["shadow"])
    out += box(c, p["f"], p["h"], base)
    top = (c[0], c[1] - p["h"])
    hw, hh = TW * 0.5 * p["f"], TH * 0.5 * p["f"]
    tp, rt = (top[0], top[1] - hh), (top[0] + hw, top[1])
    bt, lf = (top[0], top[1] + hh), (top[0] - hw, top[1])
    col = darken(base, p["stripe_darken"])
    n = p["stripes"] + 1
    for i in range(1, n):
        t = i / n
        a, b = lerp(tp, lf, t), lerp(rt, bt, t)
        out.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-width="3"/>'
                   % (f1(a[0]), f1(a[1]), f1(b[0]), f1(b[1]), col))
    return out


def well(pal, age):
    p = TOK["shapes"]["well"]
    c = (AX, AY)
    out = shadow(c, p["shadow"])
    out += box(c, p["f"], p["h"], pal[p["role_base"]])
    out.append(poly(diamond((c[0], c[1] - p["h"]), p["water_inset"]), pal[p["role_water"]]))
    return out


def quarry(pal, age):
    p = TOK["shapes"]["quarry"]
    c = (AX, AY)
    out = shadow(c, p["shadow"])
    base = pal[p["role_base"]]
    for b in p["boulders"]:
        col = darken(base, b["darken"]) if b["darken"] else base
        if b["lighten"]:
            col = lighten(base, b["lighten"])
        out += box((c[0] + b["dx"], c[1] + b["dy"]), b["f"], b["h"], col)
    return out


BUILDERS = {"hut": hut, "farm": farm, "well": well, "quarry": quarry}


# ---- ground ------------------------------------------------------------------

def ground(pal, variant):
    spec = TOK["ground"]["variants"][variant]
    c = (TAX, TAY)
    scale = (TW * 0.5 + G["tile_bleed"]) / (TW * 0.5)  # slight bleed hides seams between tiles
    out = [poly(diamond(c, scale), pal["ground_a" if variant == "a" else "ground_b"])]
    for x, y in spec["tufts"]:
        px, py = c[0] + x, c[1] + y
        out.append(poly([(px - 4, py), (px - 2.5, py - 6), (px - 1, py)], pal["ground_decor"]))
        out.append(poly([(px, py), (px + 1.5, py - 8), (px + 3, py)], pal["ground_decor"]))
        out.append(poly([(px + 3, py), (px + 4.5, py - 5), (px + 6, py)], pal["ground_decor"]))
    for x, y in spec["pebbles"]:
        px, py = c[0] + x, c[1] + y
        out.append('<ellipse cx="%s" cy="%s" rx="3.2" ry="1.7" fill="%s"/>'
                   % (f1(px), f1(py), lighten(pal["rock"], 0.2)))
    return out


# ---- UI icons ----------------------------------------------------------------
# Stroked glyphs (round caps), one ink color from the UI tokens. The four arrows point
# along the grid's diagonals: the direction the neighbouring tile lies on screen.

ICON = TOK["ui"]["icon"]
IC = ICON["canvas"]
IP = IC / 96.0  # path coordinates below are authored on a 96 grid


def _pts(pts):
    return " ".join("%s,%s" % (f1(x * IP), f1(y * IP)) for x, y in pts)


def icon_svg(paths):
    ink = TOK["ui"]["colors"][ICON["color_role"]]
    body = ['<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" '
            'stroke-linecap="round" stroke-linejoin="round"/>' % (_pts(p), ink, f1(ICON["stroke"] * IP))
            for p in paths]
    return svg(IC, IC, body)


ICONS = {
    "confirm": [[(22, 50), (41, 69), (74, 29)]],
    "cancel": [[(26, 26), (70, 70)], [(70, 26), (26, 70)]],
    "arrow_nw": [[(66, 66), (30, 30)], [(30, 52), (30, 30), (52, 30)]],
    "arrow_ne": [[(30, 66), (66, 30)], [(44, 30), (66, 30), (66, 52)]],
    "arrow_sw": [[(66, 30), (30, 66)], [(30, 44), (30, 66), (52, 66)]],
    "arrow_se": [[(30, 30), (66, 66)], [(66, 44), (66, 66), (44, 66)]],
}

# Godot would otherwise ship a compiled texture instead of the raw SVG text, and the web
# build could not read it (assets.gd rasterizes the text at runtime). "keep" ships it as-is.
IMPORT_KEEP = '[remap]\n\nimporter="keep"\n'


# ---- driver ------------------------------------------------------------------

def build():
    files = {}
    for age, spec in TOK["ages"].items():
        pal = spec["palette"]
        for name, fn in BUILDERS.items():
            files["assets/buildings/%s_%s.svg" % (name, age)] = svg(SW, SH, fn(pal, age))
        for v in TOK["ground"]["variants"]:
            files["assets/ground/ground_%s_%s.svg" % (age, v)] = svg(TCW, TCH, ground(pal, v))
    for name, paths in ICONS.items():
        files["assets/ui/icon_%s.svg" % name] = icon_svg(paths)
    for p in [p for p in files if p.endswith(".svg")]:
        files[p + ".import"] = IMPORT_KEEP
    return files


def main():
    files = build()
    if "--check" in sys.argv:
        stale = [p for p, s in files.items()
                 if not (ROOT / p).exists() or (ROOT / p).read_text(encoding="utf-8") != s]
        if stale:
            print("Assets out of date (run tools/gen_assets.py):")
            for p in stale:
                print("  " + p)
            sys.exit(1)
        print("Assets up to date (%d files)." % len(files))
        return
    for p, s in files.items():
        out = ROOT / p
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(s, encoding="utf-8")
    print("Wrote %d files (SVG art and their .import files)." % len(files))


if __name__ == "__main__":
    main()
