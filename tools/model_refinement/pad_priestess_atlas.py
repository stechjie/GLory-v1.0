"""Deterministic UV-padding repair for the god_priestess albedo atlas.

Two modes, matching the two-step fix recorded in
docs/MODEL_REFINEMENT_GOD_PRIESTESS.md:

  default        Gutter padding. Fill large nearly pure black atlas background
                 regions (RGB max <= --gutter-threshold, >= --gutter-min-size
                 connected pixels) and a thin fringe, so no UV island samples an
                 unpainted gutter. Same algorithm as the priest precedent
                 (repair_priest_atlas.py), which is a no-op on the priestess
                 atlas because 99.46% of its pure black lies outside the UV
                 footprint.
  --keep-gutter  On-mesh dark fill. Only texels *inside* the mesh UV footprint
                 are candidates. Dark components are labelled *after*
                 intersecting with a dilated UV-coverage mask, so dark islands
                 that touch the atlas background stay separate components and
                 keep a high on-mesh ratio. Small ink components (eyes, ink
                 lines) survive because of --min-size.

Both modes propagate the boundary painted colour, Gaussian-blur only the newly
supplied texels, and never touch painted pixels or the alpha channel.

The UV coverage mask is rasterised from triangle UVs at pixel centres, using the
same convention as the runtime sampler (px = u * w, py = v * h; Godot's image
origin is top-left). Pass --tri-uv <json> (from priestess_uv_dump.gd) or an
explicit --coverage <png>.
"""
import argparse, json, hashlib
from collections import deque
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def dilate(m, it):
    for _ in range(it):
        a = np.zeros_like(m)
        a[1:] |= m[:-1]; a[:-1] |= m[1:]
        a[:, 1:] |= m[:, :-1]; a[:, :-1] |= m[:, 1:]
        m = m | a
    return m


def neighbors(k, w, h):
    x = k % w
    if x: yield k - 1
    if x < w - 1: yield k + 1
    if k >= w: yield k - w
    if k < w * (h - 1): yield k + w


def components(flat_dark, w, h):
    labels = np.zeros(w * h, np.int32)
    sizes = [0]
    for seed in np.flatnonzero(flat_dark):
        if labels[seed]: continue
        label = len(sizes); queue = deque([int(seed)]); labels[seed] = label; count = 0
        while queue:
            k = queue.popleft(); count += 1
            for n in neighbors(k, w, h):
                if flat_dark[n] and not labels[n]:
                    labels[n] = label; queue.append(n)
        sizes.append(count)
    return labels, sizes


def flood_fill(rgb, mask, w, h):
    """Nearest painted-boundary flood fill; raises if a void pixel is unreachable."""
    flat = mask.ravel()
    filled = rgb.reshape(-1, 3).copy()
    visited = ~flat.copy()
    queue = deque()
    for k in np.flatnonzero(flat):
        for n in neighbors(int(k), w, h):
            if not flat[n] and int(filled[n].max()) >= 100:
                filled[k] = filled[n]; visited[k] = True; queue.append(int(k)); break
    while queue:
        k = queue.popleft()
        for n in neighbors(k, w, h):
            if flat[n] and not visited[n]:
                filled[n] = filled[k]; visited[n] = True; queue.append(n)
    if not visited.all():
        raise RuntimeError('Unreachable void pixels; source atlas needs manual review')
    return filled


def rasterize(tris, w, h):
    """Rasterise the mesh UV footprint with PIL ImageDraw.polygon.

    Vertices are placed at (u*w, v*h); Godot's image origin is top-left, so no
    vertical flip. Pillow fills pixel centres *and* the polygon outline, which
    reproduces the handoff coverage mask bit for bit (verified: IoU 1.000 against
    the 0.56723-ratio reference mask).
    """
    img = Image.new("1", (w, h), 0)
    draw = ImageDraw.Draw(img)
    for t in tris:
        draw.polygon([(p[0] * w, p[1] * h) for p in t], fill=1)
    return np.array(img) > 0


def gutter_mask(rgb, threshold, min_size, fringe):
    labels, sizes = components((rgb.max(2) <= threshold).ravel(), rgb.shape[1], rgb.shape[0])
    chosen = [i for i, n in enumerate(sizes) if i and n >= min_size]
    mask = np.isin(labels, chosen).reshape(rgb.shape[:2])
    core = mask.copy()
    maximum = rgb.max(2)
    for _ in range(3):
        adj = np.zeros_like(mask)
        adj[1:] |= mask[:-1]; adj[:-1] |= mask[1:]
        adj[:, 1:] |= mask[:, :-1]; adj[:, :-1] |= mask[:, 1:]
        mask |= adj & (maximum < fringe)
    return mask, core, chosen, sizes


def onmesh_mask(rgb, cov, threshold, min_size):
    maximum = rgb.max(2)
    dark = (maximum <= threshold) & cov
    labels, sizes = components(dark.ravel(), rgb.shape[1], rgb.shape[0])
    chosen = [i for i, n in enumerate(sizes) if i and n >= min_size]
    mask = np.isin(labels, chosen).reshape(rgb.shape[:2])
    core = mask.copy()
    for _ in range(3):
        adj = np.zeros_like(mask)
        adj[1:] |= mask[:-1]; adj[:-1] |= mask[1:]
        adj[:, 1:] |= mask[:, :-1]; adj[:, :-1] |= mask[:, 1:]
        mask |= adj & (maximum < threshold + 20) & cov
    return mask, core, chosen, sizes


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--source', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--report', required=True)
    p.add_argument('--tri-uv', help='triangle UV json from priestess_uv_dump.gd')
    p.add_argument('--coverage', help='pre-rasterised coverage png (>0 = covered); overrides --tri-uv')
    p.add_argument('--keep-gutter', action='store_true', help='skip gutter padding; only fill dark texels inside the UV footprint')
    p.add_argument('--dark-threshold', type=int, default=96)
    p.add_argument('--min-size', type=int, default=800)
    p.add_argument('--coverage-dilate', type=int, default=3)
    p.add_argument('--gutter-threshold', type=int, default=12)
    p.add_argument('--gutter-min-size', type=int, default=256)
    p.add_argument('--gutter-fringe', type=int, default=80)
    a = p.parse_args()

    original = np.array(Image.open(a.source).convert('RGBA'))
    h, w = original.shape[:2]
    rgb = original[:, :, :3]

    if a.coverage:
        cov = np.array(Image.open(a.coverage).convert('L')) > 0
        triangles = None
    else:
        if not a.tri_uv:
            p.error('one of --tri-uv or --coverage is required')
        tris = json.loads(Path(a.tri_uv).read_text())['tris']
        triangles = len(tris)
        cov = rasterize(tris, w, h)
    coverage_ratio = float(cov.mean())

    if a.keep_gutter:
        mode = 'on_mesh'
        mask, core, chosen, sizes = onmesh_mask(rgb, dilate(cov, a.coverage_dilate), a.dark_threshold, a.min_size)
    else:
        mode = 'gutter'
        mask, core, chosen, sizes = gutter_mask(rgb, a.gutter_threshold, a.gutter_min_size, a.gutter_fringe)

    filled = flood_fill(rgb, mask, w, h)
    smooth = np.array(Image.fromarray(filled.reshape(h, w, 3)).filter(ImageFilter.GaussianBlur(1.5)))
    result = original.copy()
    result[:, :, :3][mask] = smooth[mask]
    Image.fromarray(result).save(a.out)

    record = {
        'mode': mode,
        'source_sha256': hashlib.sha256(Path(a.source).read_bytes()).hexdigest(),
        'output_sha256': hashlib.sha256(Path(a.out).read_bytes()).hexdigest(),
        'size': [w, h],
        'dark_threshold': a.dark_threshold,
        'min_size': a.min_size,
        'coverage_dilate': a.coverage_dilate,
        'gutter_threshold': a.gutter_threshold,
        'gutter_min_size': a.gutter_min_size,
        'gutter_fringe': a.gutter_fringe,
        'triangles': triangles,
        'coverage_ratio': coverage_ratio,
        'selected_components': len(chosen),
        'component_sizes': {str(i): sizes[i] for i in chosen},
        'core_void_pixels': int(core.sum()),
        'repaired_pixels_including_fringe': int(mask.sum()),
        'painted_pixels_unchanged': bool(np.array_equal(original[~mask], result[~mask])),
        'alpha_unchanged': bool(np.array_equal(original[:, :, 3], result[:, :, 3])),
        'remaining_nearly_black_pixels_in_repaired_regions': int((result[:, :, :3][core].max(1) <= a.gutter_threshold).sum()),
        'method': 'nearest painted boundary flood fill, soften new fill only; preserve small dark ink components',
    }
    Path(a.report).write_text(json.dumps(record, indent=2))
    print(json.dumps({k: record[k] for k in ('mode', 'coverage_ratio', 'selected_components', 'core_void_pixels', 'repaired_pixels_including_fringe', 'painted_pixels_unchanged', 'alpha_unchanged')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
