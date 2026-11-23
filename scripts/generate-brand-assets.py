#!/usr/bin/env python3
"""
Generate every NForce app icon/splash asset from the master logo.

Usage:  python3 scripts/generate-brand-assets.py path/to/logo.(png|jpg)

The logo is a cube on a light background, and the white "N" touches the
cube's outline, so a background flood-fill would hollow out the letter.
Instead the cut-out uses the cube silhouette: the convex hull of the colored
(non-background) pixels, rasterized with 4x supersampling for smooth edges.
Inside the silhouette, near-white pixels become pure white so the N stays
solid and crisp on any background.

Requires Pillow and NumPy.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "apps" / "mobile" / "assets"


def convex_hull(points: np.ndarray) -> list[tuple[float, float]]:
    """Andrew's monotone chain on (x, y) points."""
    pts = sorted(set(map(tuple, points.tolist())))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def cut_out(path: Path) -> Image.Image:
    rgb = np.asarray(Image.open(path).convert("RGB")).astype(np.int16)
    h, w, _ = rgb.shape
    spread = rgb.max(axis=2) - rgb.min(axis=2)
    colored = (spread > 40) | (rgb.max(axis=2) < 170)  # teal/navy faces
    ys, xs = np.nonzero(colored)
    edge = np.stack([xs, ys], axis=1)
    hull = convex_hull(edge)

    ss = 4  # supersample the silhouette for anti-aliased edges
    mask = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(mask).polygon([(x * ss + ss / 2, y * ss + ss / 2) for x, y in hull], fill=255)
    alpha = mask.resize((w, h), Image.LANCZOS)

    out = rgb.copy()
    near_white = (rgb.min(axis=2) > 200) & (spread < 30)
    out[near_white] = 255  # solid white N
    img = Image.fromarray(out.astype(np.uint8), "RGB").convert("RGBA")
    img.putalpha(alpha)
    return img.crop(alpha.point(lambda v: 255 if v > 8 else 0).getbbox())


def place(logo: Image.Image, size: int, fraction: float, bg=(0, 0, 0, 0)) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), bg)
    scale = size * fraction / max(logo.size)
    art = logo.resize((round(logo.width * scale), round(logo.height * scale)), Image.LANCZOS)
    canvas.alpha_composite(art, ((size - art.width) // 2, (size - art.height) // 2))
    return canvas


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    logo = cut_out(Path(sys.argv[1]))
    (ASSETS / "brand").mkdir(parents=True, exist_ok=True)

    # iOS / store icon: opaque, logo on white with generous padding.
    place(logo, 1024, 0.72, (255, 255, 255, 255)).convert("RGB").save(ASSETS / "icon.png")
    # Android adaptive icon: keep the art inside the 66% safe zone.
    Image.new("RGB", (1024, 1024), (255, 255, 255)).save(ASSETS / "android-icon-background.png")
    fg = place(logo, 1024, 0.58)
    fg.save(ASSETS / "android-icon-foreground.png")
    # Monochrome (themed icons): cube silhouette with the N knocked out.
    a = np.asarray(fg)
    mono = np.zeros_like(a)
    solid = (a[..., 3] > 0) & ~((a[..., 0] > 230) & (a[..., 1] > 230) & (a[..., 2] > 230))
    mono[solid] = (0, 0, 0, 255)
    mono[..., 3] = np.where(solid, a[..., 3], 0)
    Image.fromarray(mono, "RGBA").save(ASSETS / "android-icon-monochrome.png")
    # Splash, in-app mark and favicon (transparent).
    place(logo, 1024, 0.82).save(ASSETS / "splash-icon.png")
    place(logo, 512, 0.96).save(ASSETS / "brand" / "logo.png")
    place(logo, 192, 0.94).resize((48, 48), Image.LANCZOS).save(ASSETS / "favicon.png")
    print("Generated brand assets in", ASSETS)


if __name__ == "__main__":
    main()
