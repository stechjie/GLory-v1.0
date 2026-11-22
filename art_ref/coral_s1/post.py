# Cleans alpha edges of samples/*.png and exports them at the game's slot sizes into final/.
# Usage: python post.py
import os, glob
import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
# name prefix -> (width, height, mode). "fit" keeps aspect inside the canvas, "stretch" is for layers whose layout must line up.
SIZES = {
    "shop_button": (1536, 466, "fit"), "skin_shop_panel": (1550, 576, "stretch"),
    "skin_river": (1672, 941, "stretch"), "skin_bench": (1668, 943, "stretch"),
    "skin_carrot": (1214, 1295, "stretch"), "avatar_frame": (1100, 1100, "fit"),
    "pet_": (1254, 1254, "fit"), "emote_": (512, 512, "fit"),
    "bg_": (1672, 941, "stretch"), "key_art": (1672, 941, "stretch"),
}
OPAQUE = ("bg_", "key_art")

def clean_edges(im):
    """Remove colour fringe: drop near-invisible pixels, then give every soft-edge pixel the colour of the nearest solid pixel."""
    a = np.array(im.convert("RGBA")).astype(np.float32)
    alpha = a[..., 3]
    alpha[alpha < 24] = 0
    solid = alpha >= 250
    rgb = a[..., :3].copy()
    filled = solid.copy()
    for _ in range(6):  # push solid colours outward a few pixels
        if filled.all():
            break
        acc = np.zeros_like(rgb); cnt = np.zeros(alpha.shape, np.float32)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            m = np.roll(filled, (dy, dx), (0, 1)); c = np.roll(rgb, (dy, dx), (0, 1))
            acc += c * m[..., None]; cnt += m
        new = (~filled) & (cnt > 0)
        rgb[new] = acc[new] / cnt[new][:, None]
        filled |= new
    soft = (alpha > 0) & ~solid
    a[..., :3][soft] = rgb[soft]
    a[..., 3] = alpha
    return Image.fromarray(a.clip(0, 255).astype(np.uint8), "RGBA")

def export(path):
    name = os.path.basename(path)
    key = next((k for k in SIZES if name.startswith(k)), None)
    im = Image.open(path)
    opaque = name.startswith(OPAQUE)
    im = im.convert("RGB") if opaque else clean_edges(im)
    if key:
        w, h, mode = SIZES[key]
        if mode == "stretch":
            im = im.resize((w, h), Image.LANCZOS)
        else:
            if not opaque:
                box = im.getbbox()
                if box:
                    im = im.crop(box)
            margin = 0.015 if key == "shop_button" else 0.04
            s = min(w * (1 - margin) / im.width, h * (1 - margin) / im.height)
            im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
            canvas = Image.new(im.mode, (w, h), (0, 0, 0, 0) if im.mode == "RGBA" else (0, 0, 0))
            canvas.paste(im, ((w - im.width) // 2, (h - im.height) // 2))
            im = canvas
    out = os.path.join(HERE, "final", name.replace("_v1", ""))
    im.save(out)
    return name, im.size, im.mode

if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "final"), exist_ok=True)
    for p in sorted(glob.glob(os.path.join(HERE, "samples", "*.png"))):
        print(*export(p))
