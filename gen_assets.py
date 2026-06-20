#!/usr/bin/env python3
"""Generate Peel's app icon, iMessage icon set, and accent color — all vector (cairosvg)."""
import os, json, cairosvg

ROOT = os.path.dirname(os.path.abspath(__file__))
APP_ICONSET = os.path.join(ROOT, "Peel/Assets.xcassets/AppIcon.appiconset")
ACCENT = os.path.join(ROOT, "Peel/Assets.xcassets/AccentColor.colorset")
MSG_ICONSET = os.path.join(ROOT, "PeelStickers/Assets.xcassets/iMessage App Icon.stickersiconset")
for d in (APP_ICONSET, ACCENT, MSG_ICONSET,
          os.path.join(ROOT, "Peel/Assets.xcassets"),
          os.path.join(ROOT, "PeelStickers/Assets.xcassets")):
    os.makedirs(d, exist_ok=True)

PERI = "#7388FF"   # accent  rgb(0.45,0.55,1.0)
CANDY = "#FF4794"  # accent2 rgb(1.0,0.28,0.58)

def sparkle(cx, cy, R, fill, stroke=None, sw=0, op=1.0):
    s = (f'M {cx},{cy-R} Q {cx},{cy} {cx+R},{cy} Q {cx},{cy} {cx},{cy+R} '
         f'Q {cx},{cy} {cx-R},{cy} Q {cx},{cy} {cx},{cy-R} Z')
    st = f'stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="round"' if stroke else ''
    return f'<path d="{s}" fill="{fill}" {st} opacity="{op}"/>'

def icon_svg(W, H):
    """Square or landscape Peel icon: gradient bg, white sticker with a peeled corner + sparkles."""
    cx, cy = W / 2, H / 2
    s = min(W, H)
    # white sticker rect
    m = s * 0.17
    sx, sy = cx - (s/2 - m), cy - (s/2 - m)
    sw_ = s - 2 * m
    rx = sw_ * 0.16
    # peel geometry (bottom-right), fold along 45 deg diagonal
    cxr, cyb = sx + sw_, sy + sw_
    pin = sw_ * 0.26
    A = (cxr - pin, cyb)         # on bottom edge
    B = (cxr, cyb - pin)         # on right edge
    C = (cxr, cyb)               # original corner (peeled away -> show bg)
    Cf = (cxr - pin, cyb - pin)  # folded-back corner
    big = s * 0.165
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{PERI}"/><stop offset="1" stop-color="{CANDY}"/>
  </linearGradient>
  <linearGradient id="spark" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{PERI}"/><stop offset="1" stop-color="{CANDY}"/>
  </linearGradient>
  <linearGradient id="flap" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#e9ecff"/><stop offset="1" stop-color="#c7cdf2"/>
  </linearGradient>
  <filter id="sh" x="-30%" y="-30%" width="160%" height="160%">
    <feDropShadow dx="0" dy="{s*0.012}" stdDeviation="{s*0.02}" flood-color="#000" flood-opacity="0.22"/>
  </filter>
</defs>
<rect x="0" y="0" width="{W}" height="{H}" fill="url(#bg)"/>
<g filter="url(#sh)">
  <rect x="{sx}" y="{sy}" width="{sw_}" height="{sw_}" rx="{rx}" fill="#ffffff"/>
</g>
<!-- remove peeled corner: show background triangle -->
<path d="M {A[0]},{A[1]} L {C[0]},{C[1]} L {B[0]},{B[1]} Z" fill="url(#bg)"/>
<!-- subject sparkles on the sticker -->
{sparkle(cx, cy - s*0.02, big, "url(#spark)", "#ffffff", s*0.028)}
{sparkle(sx + sw_*0.80, sy + sw_*0.22, s*0.045, "url(#spark)")}
{sparkle(sx + sw_*0.22, sy + sw_*0.74, s*0.032, "{}".format(PERI), op=0.85)}
<!-- folded flap -->
<path d="M {A[0]},{A[1]} L {B[0]},{B[1]} L {Cf[0]},{Cf[1]} Z" fill="url(#flap)"
      stroke="#ffffff" stroke-width="{s*0.004}"/>
<path d="M {A[0]},{A[1]} L {B[0]},{B[1]}" stroke="#aab0d8" stroke-width="{s*0.006}" opacity="0.5"/>
</svg>'''

def render(svg, path, w, h):
    cairosvg.svg2png(bytestring=svg.encode(), write_to=path,
                     output_width=int(w), output_height=int(h), background_color="white")

# ---- App icon (single 1024) ----
render(icon_svg(1024, 1024), os.path.join(APP_ICONSET, "icon_1024.png"), 1024, 1024)
json.dump({"images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024",
                       "filename": "icon_1024.png"}],
           "info": {"author": "xcode", "version": 1}},
          open(os.path.join(APP_ICONSET, "Contents.json"), "w"), indent=2)

# ---- Accent color ----
json.dump({"colors": [{"idiom": "universal", "color": {"color-space": "srgb",
            "components": {"red": "0.451", "green": "0.549", "blue": "1.000", "alpha": "1.000"}}}],
           "info": {"author": "xcode", "version": 1}},
          open(os.path.join(ACCENT, "Contents.json"), "w"), indent=2)

# ---- iMessage App Icon (landscape-format set) ----
msg = [
    ("iphone", "2x", "60x45", 120, 90), ("iphone", "3x", "60x45", 180, 135),
    ("ipad", "2x", "67x50", 134, 100), ("ipad", "2x", "74x55", 148, 110),
    ("universal", "2x", "27x20", 54, 40, "ios"), ("universal", "3x", "27x20", 81, 60, "ios"),
    ("universal", "2x", "32x24", 64, 48, "ios"), ("universal", "3x", "32x24", 96, 72, "ios"),
    ("ios-marketing", "1x", "1024x1024", 1024, 1024, "ios"),
    ("universal", "1x", "1024x768", 1024, 768, "ios"),
    ("iphone", "2x", "29x29", 58, 58), ("iphone", "3x", "29x29", 87, 87),
    ("ipad", "2x", "29x29", 58, 58),
]
images = []
seen = {}
for entry in msg:
    idiom, scale, size = entry[0], entry[1], entry[2]
    w, h = entry[3], entry[4]
    platform = entry[5] if len(entry) > 5 else None
    fn = f"msg_{w}x{h}.png"
    if fn not in seen:
        render(icon_svg(w, h), os.path.join(MSG_ICONSET, fn), w, h)
        seen[fn] = True
    img = {"idiom": idiom, "scale": scale, "size": size, "filename": fn}
    if platform:
        img["platform"] = platform
    images.append(img)
json.dump({"images": images, "info": {"author": "xcode", "version": 1}},
          open(os.path.join(MSG_ICONSET, "Contents.json"), "w"), indent=2)

print("assets generated")
