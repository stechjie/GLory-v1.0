"""Build cleaned dark-race albedo (and doom normal) sources for the refined scenes.

py -3 tools/model_refinement/dark_race_textures.py --refs <delivery>/source [--race dark|undead] [--units a,b] [--project <GLory root>]

Units belong to the race named by their id prefix and are written to <race>_refined/.

The original atlases stay untouched (the original wrappers keep using them).
Per unit, from the unit's real body mesh (reference_0.glb written by
export_unit_reference.gd, upright Godot space, +Z front):
  1. rasterise the body's UV islands;
  2. resample to 2048 with coverage weighting, so the opaque black gaps between
     the AI atlas islands never bleed into island edges;
  3. optional per-unit repairs, e.g. skin-coloured bake bleed on rear hair;
  4. pad island colours outward so 1024 runtime mips do not darken seams;
  5. save RGB at the 1024 runtime size (all sources are fully opaque, so VRAM
     compression also drops the unused alpha). Work happens at 2048; the
     originals stay the full-resolution source of truth for re-running this.
Requires numpy + Pillow only.
"""
import argparse
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
SIZE = 2048
OUT_SIZE = 1024
UNITS_DIR = "assets/models/units"

UNITS = {
    "dark_imp": {"albedo": "dark_imp_motong/dark_imp_motong_albedo.png"},
    "dark_mage": {"albedo": "dark_mage_violet_necromancer/dark_mage_albedo.png"},
    "dark_scythe": {"albedo": "dark_scythe_animated/dark_scythe_texture.png"},
    "dark_suc": {"albedo": "dark_suc_animated/dark_suc_albedo.png"},
    "dark_fear": {"albedo": "dark_fear_animated/dark_fear_texture.png"},
    "dark_queen": {"albedo": "dark_queen_animated/dark_queen_albedo.png"},
    "dark_doom": {"albedo": "dark_doom_animated/dark_doom_albedo.png",
                  "normal": "dark_doom_animated/dark_doom_idle_normal.png"},
    # Skin-coloured bake bleed on hair/cape showed as tan streaks once the purple
    # multiply was removed: rear-facing (iteration 01) and top-facing hair, seen by the
    # high battle camera (iteration 04). Side-facing skin (elf ears) and the face stay.
    "dark_dragon": {"albedo": "dark_dragon_animated/dark_dragon_texture.png",
                    "rear_skin_bleed": {"normal_z_below": -0.2, "normal_y_above": 0.45, "height_above": 0.75}},
    **{f"undead_{n}": {"albedo": f"undead_{n}_animated/undead_{n}_texture.png"}
       for n in ("small", "poison", "parasite", "spike", "fly", "bomb", "titan", "mother")},
}


def race_of(unit_id: str) -> str:
    return unit_id.split("_", 1)[0]


def read_glb(path: Path):
    data = path.read_bytes()
    length = struct.unpack_from("<I", data, 8)[0]
    offset, chunks = 12, {}
    while offset < length:
        size, kind = struct.unpack_from("<II", data, offset)
        chunks[kind] = data[offset + 8: offset + 8 + size]
        offset += 8 + size
    doc, blob = json.loads(chunks[0x4E4F534A]), chunks[0x004E4942]

    def accessor(index):
        acc = doc["accessors"][index]
        view = doc["bufferViews"][acc["bufferView"]]
        dtype = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[acc["componentType"]]
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[acc["type"]]
        start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        stride = view.get("byteStride", 0) or np.dtype(dtype).itemsize * width
        raw = np.frombuffer(blob, dtype=np.uint8, count=stride * (acc["count"] - 1) + np.dtype(dtype).itemsize * width, offset=start)
        rows = np.lib.stride_tricks.as_strided(raw, shape=(acc["count"], np.dtype(dtype).itemsize * width), strides=(stride, 1))
        return np.ascontiguousarray(rows).view(dtype).reshape(acc["count"], width)

    positions, normals, uvs, faces = [], [], [], []
    base = 0
    for mesh in doc["meshes"]:
        for prim in mesh["primitives"]:
            p = accessor(prim["attributes"]["POSITION"])
            positions.append(p)
            normals.append(accessor(prim["attributes"]["NORMAL"]))
            uvs.append(accessor(prim["attributes"]["TEXCOORD_0"]))
            faces.append(accessor(prim["indices"]).reshape(-1, 3).astype(np.int64) + base)
            base += len(p)
    return np.concatenate(positions), np.concatenate(normals), np.concatenate(uvs), np.concatenate(faces)


def rasterise(uv, faces, size):
    """Triangle id per texel (-1 = gap between islands), conservative by half a texel."""
    tri_id = np.full((size, size), -1, dtype=np.int32)
    pix = uv * size - 0.5
    for t, (a, b, c) in enumerate(faces):
        p0, p1, p2 = pix[a], pix[b], pix[c]
        x0, y0 = np.floor(np.minimum(np.minimum(p0, p1), p2) - 1).astype(int)
        x1, y1 = np.ceil(np.maximum(np.maximum(p0, p1), p2) + 1).astype(int)
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, size - 1), min(y1, size - 1)
        if x1 < x0 or y1 < y0:
            continue
        xs, ys = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        d = (p1[1] - p2[1]) * (p0[0] - p2[0]) + (p2[0] - p1[0]) * (p0[1] - p2[1])
        if abs(d) < 1e-12:
            continue
        w0 = ((p1[1] - p2[1]) * (xs - p2[0]) + (p2[0] - p1[0]) * (ys - p2[1])) / d
        w1 = ((p2[1] - p0[1]) * (xs - p2[0]) + (p0[0] - p2[0]) * (ys - p2[1])) / d
        w2 = 1 - w0 - w1
        # Half-texel slack in barycentric units along each edge.
        slack = 0.5 / max(np.linalg.norm(p1 - p0), np.linalg.norm(p2 - p1), np.linalg.norm(p0 - p2), 1.0)
        inside = (w0 >= -slack) & (w1 >= -slack) & (w2 >= -slack)
        tri_id[ys[inside], xs[inside]] = t
    return tri_id


def shift_sum(img, mask):
    acc = np.zeros_like(img)
    cnt = np.zeros(mask.shape, dtype=np.float32)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx == 0 and dy == 0:
                continue
            m = np.roll(np.roll(mask, dy, 0), dx, 1)
            acc += np.roll(np.roll(img * mask[..., None], dy, 0), dx, 1)
            cnt += m
    return acc, cnt


def diffuse_fill(img, known, todo, iterations):
    """Fill `todo` texels from `known` neighbours, ring by ring."""
    img, known = img.copy(), known.copy()
    for _ in range(iterations):
        acc, cnt = shift_sum(img, known.astype(np.float32))
        grow = todo & ~known & (cnt > 0)
        if not grow.any():
            break
        img[grow] = acc[grow] / cnt[grow][:, None]
        known |= grow
    return img


def coverage_resample(src: Image.Image, cover: np.ndarray) -> np.ndarray:
    """Resample to SIZE averaging only texels that belong to islands."""
    rgb = np.asarray(src.convert("RGB"), dtype=np.float32) / 255.0
    if rgb.shape[0] == SIZE:
        return rgb
    hi_cover = np.asarray(Image.fromarray((cover * 255).astype(np.uint8)).resize(rgb.shape[1::-1], Image.NEAREST), dtype=np.float32) / 255.0
    weighted = rgb * hi_cover[..., None]
    def down(a):
        return np.asarray(Image.fromarray(a.astype(np.float32), mode="F").resize((SIZE, SIZE), Image.BOX))
    num = np.stack([down(weighted[..., c]) for c in range(3)], -1)
    den = down(hi_cover)
    return np.where(den[..., None] > 1e-4, num / np.maximum(den[..., None], 1e-4), 0.0)


def save_rgb(rgb, path):
    image = Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    image.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS).save(path, optimize=True)


def hsv(rgb):
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = np.maximum(mx - mn, 1e-5)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    h = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) / 6.0
    return h * 360.0, (mx - mn) / np.maximum(mx, 1e-5), mx


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--refs", required=True, help="delivery source dir holding <unit>/reference_0.glb")
    parser.add_argument("--project", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--race", default="", help="only units of this race (dark, undead)")
    parser.add_argument("--units", default=",".join(UNITS))
    args = parser.parse_args()
    project, refs = Path(args.project), Path(args.refs)
    report = {}
    for unit_id in args.units.split(","):
        if args.race and race_of(unit_id) != args.race:
            continue
        spec = UNITS[unit_id]
        pos, nrm, uv, faces = read_glb(refs / unit_id / "reference_0.glb")
        tri_id = rasterise(uv, faces, SIZE)
        cover = tri_id >= 0
        rgb = coverage_resample(Image.open(project / UNITS_DIR / spec["albedo"]), cover)
        repaired = 0
        if "rear_skin_bleed" in spec:
            rule = spec["rear_skin_bleed"]
            tri_normal_z = nrm[faces].mean(1)[:, 2]
            tri_height = pos[faces].mean(1)[:, 1]
            rear = np.zeros(cover.shape, bool)
            sel = cover.copy()
            tri_normal_y = nrm[faces].mean(1)[:, 1]
            facing = (tri_normal_z < rule["normal_z_below"]) | (tri_normal_y > rule.get("normal_y_above", 2.0))
            rear[sel] = facing[tri_id[sel]] & (tri_height[tri_id[sel]] > rule["height_above"])
            h, s, v = hsv(rgb)
            skin = (h > 5) & (h < 45) & (s > 0.12) & (v > 0.3)
            bad = rear & skin
            # Grow the defect by one texel so the soft fringe goes too.
            grown = bad.copy()
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    grown |= np.roll(np.roll(bad, dy, 0), dx, 1)
            bad = grown & rear
            repaired = int(bad.sum())
            rgb = diffuse_fill(rgb, cover & ~bad, bad, 64)
        padded = diffuse_fill(rgb, cover, ~cover, 24)
        padded[~cover & (padded.sum(-1) == 0)] = rgb[cover].mean(0)
        out_dir = project / UNITS_DIR / f"{race_of(unit_id)}_refined" / unit_id
        out_dir.mkdir(parents=True, exist_ok=True)
        save_rgb(padded, out_dir / f"{unit_id}_albedo.png")
        row = {"source": spec["albedo"], "coverage": round(float(cover.mean()), 4), "repaired_texels": repaired}
        normal_source = project / UNITS_DIR / spec.get("normal", "")
        if "normal" in spec and not normal_source.is_file():
            # The 2048 source left the project in the 2026-10-04 cleanup (it is unused at
            # runtime); restore it from the asset bundle or the delivery removed-assets copy
            # to rebuild. The refined 1024 normal already in the project stays as is.
            print(f"{unit_id}: normal source {spec['normal']} not in project; kept existing refined normal")
            row["normal"] = spec["normal"] + " (source not present, not rebuilt)"
        elif "normal" in spec:
            n = np.asarray(Image.open(project / UNITS_DIR / spec["normal"]).convert("RGB").resize((SIZE, SIZE), Image.LANCZOS), dtype=np.float32) / 255.0
            n = diffuse_fill(n, cover, ~cover, 24)
            save_rgb(n, out_dir / f"{unit_id}_normal.png")
            row["normal"] = spec["normal"]
        report[unit_id] = row
        print(unit_id, json.dumps(row))
    # Merge, so rebuilding a subset of units keeps the other units' rows.
    for race in sorted({race_of(u) for u in report}):
        report_path = project / UNITS_DIR / f"{race}_refined" / "texture_build.json"
        merged = json.loads(report_path.read_text(encoding="utf-8"))["units"] if report_path.is_file() else {}
        merged.update({u: row for u, row in report.items() if race_of(u) == race})
        report_path.write_text(json.dumps({"tool": "tools/model_refinement/dark_race_textures.py", "work_size": SIZE, "output_size": OUT_SIZE,
                                           "units": {u: merged[u] for u in UNITS if u in merged}}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
