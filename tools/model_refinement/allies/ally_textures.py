"""Formation-ally texture refinement (GLory, CODEX_MODEL_WORKFLOW §3.3).

For every atlas actually used at runtime:
  1. rasterize the real mesh UV triangles -> coverage mask (union of all actions
     that sample this atlas),
  2. keep covered pixels untouched except large unpainted near-black blobs;
     fill gutters and those holes by push-pull dilation from valid neighbours
     (removes opaque-black gutters that low mips bleed into small islands),
  3. derive an emission mask from the hot lava pixels inside coverage
     (bright + saturated warm hue), so the cracks keep glowing on the shadow side,
  4. per-unit identity recolour (RECOLOR): saturated "hot" texels (the lava /
     glow paint) are rotated to the unit's signature hue; the remaining
     saturated body paint is pulled toward a body hue and low-saturation darks
     get a faint tint, so each ally reads as its own colour at battle distance
     while values (light/dark structure) stay untouched,
  5. write RGB (no alpha) at <= 2048 to allies_refined/<id>/.

Also reports which texture fits a UV set (fraction of covered texels that are
near-black gutter), used to pick the right atlas for the re-rigged run FBX.

usage: python3 ally_textures.py <allies_src_dir> <uv_dir> <out_root> [--report-only] [--no-recolor]
"""
import sys, os, json, hashlib
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

NO_RECOLOR = "--no-recolor" in sys.argv
HOLE_MIN_AREA = 150  # texels at 1024: smaller dark blobs are treated as painted detail

UNITS = {
    1: ("ally_flame_claw", "formation_ally_1_animated", {"body": ("flame_claw_albedo.png", ["idle", "attack", "run"])}),
    2: ("ally_soul_chain", "formation_ally_2_animated", {"body": ("texture.png", ["idle", "attack", "run"])}),
    3: ("ally_abyss_beast", "formation_ally_3_animated", {"body": ("texture.png", ["idle", "attack", "run"])}),
    4: ("ally_hell_inferno", "formation_ally_4_animated", {"body": ("texture.png", ["idle", "attack", "run"])}),
    5: ("ally_eternal_night", "formation_ally_5_animated", {"body": ("texture.png", ["idle", "attack", "run"])}),
}
OUT_EDGE = 2048
# hot-lava emission thresholds per unit (value, saturation, hue window in degrees)
LAVA = {1: (0.55, 0.55, (0, 50)), 2: (0.55, 0.55, (0, 50)), 3: (0.55, 0.55, (0, 50)),
        4: (0.62, 0.6, (330, 360)), 5: (0.62, 0.6, (330, 360))}

# Signature colours (2026-10-12, user: "整个模型更有辨识度"):
#   1 flame_claw  amber flame   2 soul_chain cyan soul-fire   3 abyss_beast acid green
#   4 hell_inferno crimson hellfire   5 eternal_night violet night-fire
# hot_h: hue for glowing paint. body_h: hue the other saturated paint is pulled to
# (None = keep). body_pull: 0..1 strength. tint_s: min saturation given to dark
# low-sat paint (0 = keep neutral). body_s_mul: saturation scale for body paint.
RECOLOR = {
    1: dict(hot_h=34, body_h=None, body_pull=0.0, tint_s=0.0, body_s_mul=1.0),
    2: dict(hot_h=188, body_h=205, body_pull=1.0, tint_s=0.16, body_s_mul=0.8),
    3: dict(hot_h=92, body_h=105, body_pull=1.0, tint_s=0.14, body_s_mul=0.55),
    4: dict(hot_h=10, body_h=None, body_pull=0.0, tint_s=0.0, body_s_mul=1.0),
    5: dict(hot_h=282, body_h=272, body_pull=1.0, tint_s=0.14, body_s_mul=0.95),
}


def recolor(rgb, hot, cfg):
    """rgb float 0..255, hot bool mask -> recoloured rgb (values preserved)."""
    import cv2
    hsv_img = cv2.cvtColor((rgb / 255.0).astype(np.float32), cv2.COLOR_RGB2HSV)  # H 0..360
    h, s, v = hsv_img[..., 0], hsv_img[..., 1], hsv_img[..., 2]
    # soft "hot" weight: hot mask dilated + feathered so glow edges follow
    hot_w = np.asarray(Image.fromarray((hot * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5))
                       .filter(ImageFilter.GaussianBlur(1.5))).astype(np.float32) / 255.0
    # orange/yellow lava highlights that fell just outside the strict mask
    warm = ((h < 60) | (h > 330)) & (s > 0.35) & (v > 0.35)
    hot_w = np.maximum(hot_w, warm * np.clip((v - 0.35) / 0.3, 0, 1))
    out_h = h.copy()
    out_s = s.copy()
    if cfg["body_h"] is not None:
        body_w = np.clip((s - 0.12) / 0.25, 0, 1) * cfg["body_pull"]
        out_h = np.where(body_w > 0, cfg["body_h"], h)
        out_s = np.where(body_w > 0, s * (1 - body_w) + s * cfg["body_s_mul"] * body_w, s)
        # blend hue on the colour wheel: pick by weight (hue lerp would cross the wheel)
        out_h = np.where(body_w >= 0.5, cfg["body_h"], h)
        if cfg["tint_s"] > 0:
            low = s < cfg["tint_s"]
            out_h = np.where(low, cfg["body_h"], out_h)
            out_s = np.where(low, s + (cfg["tint_s"] - s) * np.clip(v * 3.0, 0, 1) * 0.8, out_s)
    out_h = np.where(hot_w > 0.5, cfg["hot_h"], out_h)
    # hot paint keeps its own saturation; sat-blend the feather so edges stay soft
    hsv_out = np.stack([out_h, out_s, v], -1).astype(np.float32)
    rgb_out = cv2.cvtColor(hsv_out, cv2.COLOR_HSV2RGB) * 255.0
    hot_rgb = cv2.cvtColor(np.stack([np.full_like(h, cfg["hot_h"]), s, v], -1).astype(np.float32), cv2.COLOR_HSV2RGB) * 255.0
    w = hot_w[..., None]
    return rgb_out * (1 - w) + hot_rgb * w


def load_uv(path):
    a = np.fromfile(path, dtype=np.float32)
    return a.reshape(-1, 3, 2)


def coverage(uv_sets, size):
    W, H = size
    # rasterize at 4x supersampled then reduce -> any coverage
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    for tris in uv_sets:
        u = np.mod(tris[..., 0], 1.0) * W
        v = np.mod(tris[..., 1], 1.0) * H
        for t in range(tris.shape[0]):
            d.polygon([(u[t, 0], v[t, 0]), (u[t, 1], v[t, 1]), (u[t, 2], v[t, 2])], fill=255)
    # conservative: grow 1px so triangle edges are counted as covered
    return np.asarray(m.filter(ImageFilter.MaxFilter(3))) > 0


def push_pull(rgb, mask):
    """Fill uncovered pixels from covered neighbours (mip pyramid push-pull)."""
    levels = []
    c = rgb.astype(np.float32) * mask[..., None]
    w = mask.astype(np.float32)
    while min(c.shape[0], c.shape[1]) > 1:
        levels.append((c, w))
        h2, w2 = c.shape[0] // 2, c.shape[1] // 2
        c = c[: h2 * 2, : w2 * 2].reshape(h2, 2, w2, 2, 3).sum((1, 3))
        w = w[: h2 * 2, : w2 * 2].reshape(h2, 2, w2, 2).sum((1, 3))
    levels.append((c, w))
    filled = np.where(w[..., None] > 0, c / np.maximum(w[..., None], 1e-6), 0)
    for c, w in reversed(levels[:-1]):
        up = np.repeat(np.repeat(filled, 2, 0), 2, 1)
        up = np.pad(up, ((0, c.shape[0] - up.shape[0]), (0, c.shape[1] - up.shape[1]), (0, 0)), mode="edge")
        own = np.where(w[..., None] > 0, c / np.maximum(w[..., None], 1e-6), 0)
        filled = np.where(w[..., None] > 0, own, up)
    return filled


def hsv(rgb):
    r, g, b = [rgb[..., i] / 255.0 for i in range(3)]
    mx = np.max(rgb / 255.0, -1); mn = np.min(rgb / 255.0, -1)
    d = mx - mn
    s = np.where(mx > 0, d / np.maximum(mx, 1e-6), 0)
    h = np.zeros_like(mx)
    nz = d > 1e-6
    rm = nz & (mx == r); gm = nz & (mx == g) & ~rm; bm = nz & ~rm & ~gm
    h[rm] = (60 * ((g - b)[rm] / d[rm])) % 360
    h[gm] = 60 * ((b - r)[gm] / d[gm]) + 120
    h[bm] = 60 * ((r - g)[bm] / d[bm]) + 240
    return h, s, mx


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]


def main():
    src_root, uv_dir, out_root = sys.argv[1:4]
    report_only = "--report-only" in sys.argv
    report = {}
    for u, (uid, folder, atlases) in UNITS.items():
        for key, (tex, actions) in atlases.items():
            src = os.path.join(src_root, folder, tex)
            im = Image.open(src).convert("RGB")
            # fit report: gutter fraction under every action's UVs for this atlas
            small = np.asarray(im.resize((512, 512), Image.BILINEAR)).astype(np.float32)
            lum_s = small @ np.array([0.2126, 0.7152, 0.0722])
            fit = {}
            for a in ["idle", "attack", "run"]:
                cov = coverage([load_uv(os.path.join(uv_dir, f"{u}_{a}.bin"))], (512, 512))
                fit[a] = round(float((lum_s[cov] < 6).mean()), 4)
            entry = {"src": f"{folder}/{tex}", "src_sha": sha(src), "src_size": im.size, "used_by": actions,
                     "black_under_uv": fit}
            if not report_only:
                edge = min(OUT_EDGE, im.size[0])
                im_r = im.resize((edge, edge), Image.LANCZOS) if im.size[0] != edge else im
                rgb = np.asarray(im_r).astype(np.float32)
                cov = coverage([load_uv(os.path.join(uv_dir, f"{u}_{a}.bin")) for a in actions], (edge, edge))
                # Unpainted holes INSIDE coverage: large connected near-black blobs
                # (AI bake left opaque black there). Small dark details (pupils,
                # ink lines, crevices) stay: only blobs >= HOLE_MIN_AREA texels at
                # 1024-equivalent are repainted from valid neighbours.
                lum0 = rgb @ np.array([0.2126, 0.7152, 0.0722])
                dark = cov & (lum0 < 6)
                lab, n_lab = ndimage.label(dark)
                areas = ndimage.sum(dark, lab, index=np.arange(1, n_lab + 1)) if n_lab else np.array([])
                min_area = HOLE_MIN_AREA * (edge / 1024.0) ** 2
                big = np.zeros(n_lab + 1, bool); big[1:] = areas >= min_area
                holes = big[lab]
                valid = cov & ~holes
                h, s, v = hsv(rgb)
                vt, st, (h0, h1) = LAVA[u]
                hot = cov & (v > vt) & (s > st) & (((h >= h0) & (h <= h1)) | ((h0 > h1) & ((h >= h0) | (h <= h1))))
                rgb_rc = recolor(rgb, hot, RECOLOR[u]) if not NO_RECOLOR else rgb
                filled = push_pull(rgb_rc, valid)
                out = np.where(valid[..., None], rgb_rc, filled)
                # soft mask: ramp on value, then dilate 1px & blur slightly
                ramp = np.clip((v - vt) / (1.0 - vt), 0, 1) * hot
                em = Image.fromarray((ramp * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.8))
                em_rgb = np.stack([np.asarray(em)] * 3, -1).astype(np.float32)
                em_fill = push_pull(em_rgb, cov)
                em_out = np.where(cov[..., None], em_rgb, em_fill)
                od = os.path.join(out_root, uid)
                os.makedirs(od, exist_ok=True)
                base = f"{uid}_{key}"
                pa = os.path.join(od, base + "_albedo.png")
                pe = os.path.join(od, base + "_emission.png")
                Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(pa, optimize=True)
                Image.fromarray(np.clip(em_out, 0, 255).astype(np.uint8)).save(pe, optimize=True)
                lum = out @ np.array([0.2126, 0.7152, 0.0722])
                entry.update({"out_albedo": os.path.relpath(pa, out_root), "out_emission": os.path.relpath(pe, out_root),
                              "out_size": [edge, edge], "uv_coverage": round(float(cov.mean()), 4),
                              "hot_fraction_of_coverage": round(float(hot.sum() / max(cov.sum(), 1)), 4),
                              "nearblack_before": round(float(((rgb @ np.array([0.2126, 0.7152, 0.0722])) < 8).mean()), 4),
                              "nearblack_after": round(float((lum < 8).mean()), 4),
                              "recolor": None if NO_RECOLOR else RECOLOR[u],
                              "covered_hole_pixels_repainted": int(holes.sum()), "hole_blobs": int(big.sum()),
                              "albedo_sha": sha(pa), "emission_sha": sha(pe)})
            report[f"{uid}:{key}"] = entry
            print(uid, key, json.dumps(entry, ensure_ascii=False))
    if not report_only:
        json.dump(report, open(os.path.join(out_root, "texture_report.json"), "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
