#!/usr/bin/env python3
"""Generate the Veil app icon as PNG directly using Pillow.

Produces 1024x1024 PNGs with three translucent elliptical shapes fanning
out from a shared base point, implying a V silhouette.
"""

import math
from PIL import Image, ImageDraw


SIZE = 8192  # render at 8x, then downsample with sips for anti-aliasing
FINAL_SIZE = 1024

# --- Variants (color intensity levels) ---
VARIANTS = {
    # Each step: R -10, G -13, B -4 per petal; opacity +0.05 per petal
    "icon-v1.png": {
        "bg": (232, 233, 237),
        "colors": [(184, 169, 212), (196, 177, 222), (209, 188, 230)],
        "opacities": [0.45, 0.40, 0.35],
    },
    "icon-v2.png": {
        "bg": (232, 233, 237),
        "colors": [(174, 156, 208), (186, 164, 218), (199, 175, 226)],
        "opacities": [0.50, 0.45, 0.40],
    },
    "icon-v3.png": {
        "bg": (232, 233, 237),
        "colors": [(164, 143, 204), (176, 151, 214), (189, 162, 222)],
        "opacities": [0.55, 0.50, 0.45],
    },
    "icon-v4.png": {
        "bg": (232, 233, 237),
        "colors": [(154, 130, 200), (166, 138, 210), (179, 149, 218)],
        "opacities": [0.60, 0.55, 0.50],
    },
    "icon-v5.png": {
        "bg": (232, 233, 237),
        "colors": [(144, 117, 196), (156, 125, 206), (169, 136, 214)],
        "opacities": [0.65, 0.60, 0.55],
    },
    "icon-v6.png": {
        "bg": (232, 233, 237),
        "colors": [(134, 104, 192), (146, 112, 202), (159, 123, 210)],
        "opacities": [0.70, 0.65, 0.60],
    },
    "icon-v7.png": {
        "bg": (232, 233, 237),
        "colors": [(124, 91, 188), (136, 99, 198), (149, 110, 206)],
        "opacities": [0.75, 0.70, 0.65],
    },
}

# --- Petal geometry ---
BASE_X_RATIO = 0.50
BASE_Y_RATIO = 0.78
PETAL_RX_RATIO = 0.09
PETAL_RY_RATIO = 0.38
PETAL_OFFSET_RATIO = 0.30
ANGLES_DEG = [-22, 0, 22]


def draw_ellipse_rotated(canvas, cx, cy, rx, ry, angle_deg, pivot_x, pivot_y, color_rgba):
    """Draw a filled rotated ellipse by compositing a rotated layer."""
    margin = int(max(rx, ry) * 2)
    tmp_size = margin * 2
    tmp = Image.new("RGBA", (tmp_size, tmp_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tmp)

    tcx, tcy = tmp_size // 2, tmp_size // 2
    draw.ellipse(
        [tcx - rx, tcy - ry, tcx + rx, tcy + ry],
        fill=color_rgba,
    )

    pivot_in_tmp_x = pivot_x - cx + tcx
    pivot_in_tmp_y = pivot_y - cy + tcy

    angle_rad = math.radians(-angle_deg)
    cos_a = math.cos(angle_rad)
    sin_a = math.sin(angle_rad)

    a = cos_a
    b = sin_a
    c = pivot_in_tmp_x - cos_a * pivot_in_tmp_x - sin_a * pivot_in_tmp_y
    d = -sin_a
    e = cos_a
    f = pivot_in_tmp_y + sin_a * pivot_in_tmp_x - cos_a * pivot_in_tmp_y

    tmp_rotated = tmp.transform(tmp.size, Image.AFFINE, (a, b, c, d, e, f), resample=Image.BICUBIC)

    paste_x = int(cx - tcx)
    paste_y = int(cy - tcy)
    canvas.alpha_composite(tmp_rotated, (paste_x, paste_y))


def generate_icon(filename, bg, colors, opacities):
    img = Image.new("RGBA", (SIZE, SIZE), (*bg, 255))

    base_x = SIZE * BASE_X_RATIO
    base_y = SIZE * BASE_Y_RATIO
    petal_rx = SIZE * PETAL_RX_RATIO
    petal_ry = SIZE * PETAL_RY_RATIO
    petal_offset = SIZE * PETAL_OFFSET_RATIO

    for angle, color, opacity in zip(ANGLES_DEG, colors, opacities):
        cx = base_x
        cy = base_y - petal_offset
        pivot_x = cx
        pivot_y = cy + petal_ry

        alpha = int(opacity * 255)
        color_rgba = (*color, alpha)

        draw_ellipse_rotated(img, cx, cy, petal_rx, petal_ry, angle,
                             pivot_x, pivot_y, color_rgba)

    # Save hi-res, then downsample with sips for clean anti-aliasing
    hires = filename.replace(".png", "-hires.png")
    img.save(hires, "PNG")

    import subprocess
    subprocess.run([
        "/usr/bin/sips",
        "-s", "format", "png",
        "-z", str(FINAL_SIZE), str(FINAL_SIZE),
        hires, "--out", filename,
    ], check=True, capture_output=True)

    import os
    os.remove(hires)

    print(f"Written {filename}")


if __name__ == "__main__":
    for filename, params in VARIANTS.items():
        generate_icon(filename, **params)
