"""Build the crimson (赤律族) refinements from the original Meshy GLBs.

py -3 tools/model_refinement/crimson_refine.py --unit <id> --dump <crimson_decimate.py npz> [--project <GLory root>]
py -3 tools/model_refinement/crimson_refine.py --audit [--unit <id> ...]

A refined GLB is a copy of the ORIGINAL (kept unchanged for rollback) with only:
- mesh primitives replaced by the Blender dump (decimated where the unit was over budget);
- positions/normals re-expressed so the mesh AABB Godot measures is the rest pose, with the
  inverse bind matrices compensating exactly (bind_fix) - several Meshy exports bind in
  world space under a rotated (dancer) or 0.01-scaled (Icey) armature, so BattleRenderer's
  AABB centering floated or shrank them;
- images/textures/samplers dropped and materials reduced to their names: the race body
  ShaderMaterials are attached at import (dark_race_materials.py --race crimson);
- Icey's unused zero-weight morph target dropped.
Nodes, skin joints and animations are copied value for value; --audit proves it.
Textures per material: base colour <= 1024 px and normal map <= 512 px, RGB. Icey's white hair is
recoloured to the race red (user decision 2026-10-05).
"""
import argparse
import copy
import io
import json
import struct
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from repair_crimson_normals import repair as repair_split_normals

UNITS = ["crimson", "dancer", "drumer", "hunter", "armbreaker", "Icey", "skypierce", "lattern"]
ORIGINAL = "assets/models/units/crimson_race/{unit}.glb"
REFINED_DIR = "assets/models/units/crimson_refined/{unit}"
MAX_TEXTURE = 1024
# Under toon shading the normal map only adds faint relief, invisible at battle distance
# (docs/MODEL_ASSET_BUDGET.md: battle textures normally 512).
MAX_NORMAL = 512
COMPONENT = {5121: np.uint8, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
# Hair recolour ramp (luminance -> race red), sampled from the other crimson units' hair.
HAIR_RAMP = [(0.0, (0.05, 0.0, 0.01)), (0.35, (0.28, 0.02, 0.04)), (0.7, (0.58, 0.05, 0.06)), (1.0, (0.86, 0.20, 0.18))]


# ---------------------------------------------------------------- glTF binary I/O
def read_glb(path: Path):
    data = path.read_bytes()
    json_len = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + json_len])
    bin_len = struct.unpack_from("<I", data, 20 + json_len)[0]
    return doc, data[28 + json_len:28 + json_len + bin_len]


def write_glb(path: Path, doc: dict, blob: bytes) -> None:
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    blob = bytes(blob) + b"\0" * (-len(blob) % 4)
    total = 12 + 8 + len(text) + 8 + len(blob)
    path.write_bytes(struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(text), 0x4E4F534A) + text
                     + struct.pack("<II", len(blob), 0x004E4942) + blob)


def accessor(doc: dict, blob: bytes, index: int) -> np.ndarray:
    acc = doc["accessors"][index]
    view = doc["bufferViews"][acc["bufferView"]]
    dtype, width = np.dtype(COMPONENT[acc["componentType"]]), WIDTH[acc["type"]]
    item = dtype.itemsize * width
    stride = view.get("byteStride", item)
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    raw = np.frombuffer(blob, np.uint8, stride * (acc["count"] - 1) + item, start)
    rows = np.lib.stride_tricks.as_strided(raw, (acc["count"], item), (stride, 1))
    return np.ascontiguousarray(rows).view(dtype).reshape(acc["count"], width)


class Packer:
    """Tightly packed buffer views/accessors for the refined GLB."""

    def __init__(self):
        self.blob, self.views, self.accessors = bytearray(), [], []

    def add(self, array: np.ndarray, kind: str, component: int, target: int | None = None, bounds: bool = False) -> int:
        array = np.ascontiguousarray(array, dtype=COMPONENT[component])
        self.blob += b"\0" * (-len(self.blob) % 4)
        view = {"buffer": 0, "byteOffset": len(self.blob), "byteLength": array.nbytes}
        if target is not None:
            view["target"] = target
        self.blob += array.tobytes()
        self.views.append(view)
        acc = {"bufferView": len(self.views) - 1, "componentType": component, "count": len(array), "type": kind}
        if bounds:
            flat = array.reshape(len(array), -1)
            acc["min"], acc["max"] = flat.min(0).tolist(), flat.max(0).tolist()
        self.accessors.append(acc)
        return len(self.accessors) - 1

    def copy(self, doc: dict, blob: bytes, index: int) -> int:
        old = doc["accessors"][index]
        new = self.add(accessor(doc, blob, index), old["type"], old["componentType"])
        for key in ("min", "max", "normalized"):
            if key in old:
                self.accessors[new][key] = old[key]
        return new


# ---------------------------------------------------------------- transforms
def local_matrix(node: dict) -> np.ndarray:
    if "matrix" in node:
        return np.array(node["matrix"], dtype=np.float64).reshape(4, 4).T
    x, y, z, w = node.get("rotation", [0, 0, 0, 1])
    rot = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                    [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                    [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
    m = np.eye(4)
    m[:3, :3] = rot * np.array(node.get("scale", [1, 1, 1]))
    m[:3, 3] = node.get("translation", [0, 0, 0])
    return m


def world_matrices(doc: dict) -> tuple[list, dict]:
    parent = {c: i for i, n in enumerate(doc["nodes"]) for c in n.get("children", [])}
    cache = {}

    def world(i):
        if i not in cache:
            cache[i] = (world(parent[i]) if i in parent else np.eye(4)) @ local_matrix(doc["nodes"][i])
        return cache[i]

    return [world(i) for i in range(len(doc["nodes"]))], parent


def bind_fix(doc: dict, blob: bytes, skin_index: int) -> tuple[np.ndarray, float]:
    """M with v' = M v so that (frame Godot puts the skinned mesh in) * v' = rest-pose world.

    B = world(joint) * IBM(joint) maps bind space to world and is the same for every joint
    of a skin bound in its rest pose. Godot parents the skinned MeshInstance3D to the
    Skeleton3D, which sits at the parent of the highest joint above it; non-joint nodes
    between joints become bones, so armbreaker's maul skin (Bone under Armature.001 under
    a hand joint) shares the body skeleton (G). Returns (M, spread of B).
    """
    world, parent = world_matrices(doc)
    skin = doc["skins"][skin_index]
    ibm = accessor(doc, blob, skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1).astype(np.float64)
    binds = np.array([world[j] @ ibm[k] for k, j in enumerate(skin["joints"])])
    spread = float(np.abs(binds - binds[0]).max())
    all_joints = {j for s in doc["skins"] for j in s["joints"]}
    tops = set()
    for joint in skin["joints"]:
        highest, node = joint, parent.get(joint)
        while node is not None:
            if node in all_joints:
                highest = node
            node = parent.get(node)
        tops.add(parent.get(highest))
    if len(tops) != 1:
        raise RuntimeError(f"skin {skin_index}: joints belong to {len(tops)} different skeletons")
    top = tops.pop()
    frame = world[top] if top is not None else np.eye(4)
    return np.linalg.inv(frame) @ binds[0], spread


# ---------------------------------------------------------------- refined GLB
def dump_to_gltf(doc: dict, blob: bytes, mesh_index: int, dump) -> tuple[np.ndarray, float]:
    """4x3 affine X with [p_dump, 1] @ X = p_glTF, fitted on the undecimated reference.

    Reference and original vertices are paired by UV (exact floats survive the import); the
    few UV-sharing pairs that are not the same point are dropped as outliers before refitting.
    Returns (X, max residual of the inliers).
    """
    prim = doc["meshes"][mesh_index]["primitives"][0]
    orig_pos = accessor(doc, blob, prim["attributes"]["POSITION"]).astype(np.float64)
    orig_uv = accessor(doc, blob, prim["attributes"]["TEXCOORD_0"])
    k = f"m{mesh_index}_"
    first = {}
    for i, key in enumerate(map(tuple, np.round(orig_uv.astype(np.float64), 6))):
        first.setdefault(key, i)
    pairs = [(j, first[key]) for j, key in enumerate(map(tuple, np.round(dump[k + "ref_uv"].astype(np.float64), 6))) if key in first]
    src = np.column_stack([dump[k + "ref_positions"][[j for j, _ in pairs]].astype(np.float64), np.ones(len(pairs))])
    dst = orig_pos[[i for _, i in pairs]]
    keep = np.ones(len(pairs), bool)
    size = np.ptp(orig_pos, axis=0).max()
    for _ in range(3):
        x = np.linalg.lstsq(src[keep], dst[keep], rcond=None)[0]
        residual = np.linalg.norm(src @ x - dst, axis=1)
        keep = residual < 1e-4 * size
    if keep.sum() < 0.9 * len(pairs):
        raise RuntimeError(f"mesh {mesh_index}: only {keep.sum()}/{len(pairs)} reference vertices fit one transform")
    return x, float(residual[keep].max())


def refined_glb(doc: dict, blob: bytes, dump: np.lib.npyio.NpzFile) -> tuple[dict, bytes, dict]:
    out = copy.deepcopy(doc)
    pack = Packer()
    copied = {}

    def keep(index):
        if index not in copied:
            copied[index] = pack.copy(doc, blob, index)
        return copied[index]

    report = {"meshes": [], "skins": []}
    fixes = {}
    for s, skin in enumerate(doc["skins"]):
        m, spread = bind_fix(doc, blob, s)
        identity = bool(np.allclose(m, np.eye(4), atol=1e-5))
        fixes[s] = m
        ibm = accessor(doc, blob, skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1).astype(np.float64)
        if not identity:
            ibm = ibm @ np.linalg.inv(m)
        out["skins"][s]["inverseBindMatrices"] = pack.add(ibm.transpose(0, 2, 1).reshape(-1, 16), "MAT4", 5126)
        report["skins"].append({"joints": len(skin["joints"]), "bind_spread": spread, "rebased": not identity,
                                "M": None if identity else np.round(m, 6).tolist()})
    skin_of_mesh = {n["mesh"]: n["skin"] for n in doc["nodes"] if "mesh" in n and "skin" in n}
    for mi, mesh in enumerate(doc["meshes"]):
        if len(mesh["primitives"]) != 1:
            raise RuntimeError(f"mesh {mi}: expected one primitive")
        k = f"m{mi}_"
        pos, nrm = dump[k + "positions"].astype(np.float64), dump[k + "normals"].astype(np.float64)
        names = [str(x) for x in dump[k + "joint_names"]]
        joints = [doc["nodes"][j].get("name") for j in doc["skins"][skin_of_mesh[mi]]["joints"]]
        if names != joints:
            raise RuntimeError(f"mesh {mi}: Blender vertex groups {names[:3]}... differ from skin joints {joints[:3]}...")
        # Dump frame -> original glTF mesh space (fitted) -> skeleton frame: v' = M v.
        x, residual = dump_to_gltf(doc, blob, mi, dump)
        pos = np.column_stack([pos, np.ones(len(pos))]) @ x
        nrm = nrm @ np.linalg.inv(x[:3].T)
        m = fixes[skin_of_mesh[mi]]
        pos = pos @ m[:3, :3].T + m[:3, 3]
        nrm = nrm @ np.linalg.inv(m[:3, :3])
        indices = dump[k + "indices"].reshape(-1, 3).astype(np.int64)
        length = np.linalg.norm(nrm, axis=1)
        if (length < 1e-8).any():
            # A few collapsed corners carry no normal: use the area-weighted face normals around them.
            corners = pos[indices]
            faces = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
            fallback = np.zeros_like(pos)
            for c in range(3):
                np.add.at(fallback, indices[:, c], faces)
            zero = length < 1e-8
            nrm[zero] = fallback[zero]
            nrm[np.linalg.norm(nrm, axis=1) < 1e-12] = (0.0, 1.0, 0.0)
        nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
        prim = mesh["primitives"][0]
        attributes = {
            "POSITION": pack.add(pos, "VEC3", 5126, 34962, bounds=True),
            "NORMAL": pack.add(nrm, "VEC3", 5126, 34962),
            "TEXCOORD_0": pack.add(dump[k + "uv"], "VEC2", 5126, 34962),
            "JOINTS_0": pack.add(dump[k + "joints"], "VEC4", 5121 if len(joints) < 256 else 5123, 34962),
            "WEIGHTS_0": pack.add(dump[k + "weights"], "VEC4", 5126, 34962),
        }
        out["meshes"][mi] = {"name": mesh.get("name", f"mesh{mi}"), "primitives": [{
            "attributes": attributes, "indices": pack.add(dump[k + "indices"], "SCALAR", 5125, 34963),
            "material": prim["material"], "mode": prim.get("mode", 4)}]}
        report["meshes"].append({"name": mesh.get("name"), "fit_residual": residual, "vertices_before": doc["accessors"][prim["attributes"]["POSITION"]]["count"],
                                 "vertices_after": len(pos), "triangles_before": doc["accessors"][prim["indices"]]["count"] // 3,
                                 "triangles_after": len(dump[k + "indices"]) // 3})
    for a, anim in enumerate(doc.get("animations", [])):
        for s, sampler in enumerate(anim["samplers"]):
            out["animations"][a]["samplers"][s]["input"] = keep(sampler["input"])
            out["animations"][a]["samplers"][s]["output"] = keep(sampler["output"])
    out["materials"] = [{"name": m.get("name", f"material{i}")} for i, m in enumerate(doc["materials"])]
    for key in ("images", "textures", "samplers"):
        out.pop(key, None)
    for key in ("extensionsUsed", "extensionsRequired"):
        out.pop(key, None)
    out["accessors"], out["bufferViews"] = pack.accessors, pack.views
    out["buffers"] = [{"byteLength": len(pack.blob)}]
    out["asset"] = dict(doc.get("asset", {}), generator="GLory crimson_refine.py (geometry/materials only)")
    return out, bytes(pack.blob), report


# ---------------------------------------------------------------- textures
def image_bytes(doc: dict, blob: bytes, texture: int) -> bytes:
    view = doc["bufferViews"][doc["images"][doc["textures"][texture]["source"]]["bufferView"]]
    start = view.get("byteOffset", 0)
    return blob[start:start + view["byteLength"]]


def fit(image: Image.Image, limit: int = MAX_TEXTURE) -> Image.Image:
    edge = max(image.size)
    return image if edge <= limit else image.resize((image.width * limit // edge, image.height * limit // edge), Image.LANCZOS)


def fit_normal(image: Image.Image) -> Image.Image:
    if max(image.size) <= MAX_NORMAL:
        return image
    small = np.asarray(fit(image, MAX_NORMAL), dtype=np.float64) / 127.5 - 1.0
    small /= np.maximum(np.linalg.norm(small, axis=2, keepdims=True), 1e-6)
    return Image.fromarray(np.clip((small + 1.0) * 127.5 + 0.5, 0, 255).astype(np.uint8))


def hair_mask(doc: dict, blob: bytes, mesh_index: int, image: np.ndarray) -> np.ndarray:
    """Texels of UV islands that are mostly pale, unsaturated paint (Icey's white hair).

    Islands are connected triangle sets of the ORIGINAL mesh (glTF vertices are split at UV
    seams). Face/skin islands are mostly warm skin and stay as they are, so eye whites are kept.
    """
    prim = doc["meshes"][mesh_index]["primitives"][0]
    uv = accessor(doc, blob, prim["attributes"]["TEXCOORD_0"])
    tris = accessor(doc, blob, prim["indices"]).reshape(-1, 3).astype(np.int64)
    parent = np.arange(len(uv))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a, b, c in tris:
        for x, y in ((a, b), (b, c)):
            rx, ry = find(x), find(y)
            if rx != ry:
                parent[rx] = ry
    _, island = np.unique([find(t[0]) for t in tris], return_inverse=True)
    h, w = image.shape[:2]
    canvas = Image.new("I", (w, h), 0)
    draw = ImageDraw.Draw(canvas)
    for t, label in zip(tris, island):
        draw.polygon([(float(u) * w, float(v) * h) for u, v in uv[t]], fill=int(label) + 1)
    labels = np.asarray(canvas, dtype=np.int64)
    hsv = np.array(Image.fromarray(image).convert("HSV"), dtype=np.float64) / 255.0
    pale = (hsv[..., 1] < 0.22) & (hsv[..., 2] > 0.5)
    area = np.bincount(labels.ravel(), minlength=island.max() + 2)
    pale_area = np.bincount(labels[pale], minlength=island.max() + 2)
    hair = pale_area > 0.25 * np.maximum(area, 1)
    hair[0] = False
    mask = hair[labels]
    covered = labels > 0
    # Gutter texels next to hair islands (not under any island) follow the hair.
    grown = mask.copy()
    for _ in range(4):
        g = grown.copy()
        g[1:] |= grown[:-1]; g[:-1] |= grown[1:]; g[:, 1:] |= grown[:, :-1]; g[:, :-1] |= grown[:, 1:]
        grown = g
    return mask | (grown & ~covered)


def recolour_hair(image: np.ndarray, mask: np.ndarray) -> np.ndarray:
    rgb = image.astype(np.float64) / 255.0
    lum = rgb @ np.array([0.299, 0.587, 0.114])
    # Stretch the hair's own luminance range so strand shading survives the recolour.
    lo, hi = np.percentile(lum[mask], [2, 98])
    # Gamma > 1 keeps most strands mid-dark so the bright ones read as highlights (iteration 03: flat sheet).
    t = np.clip((lum - lo) / max(hi - lo, 1e-3), 0, 1) ** 1.6
    keys = np.array([k for k, _ in HAIR_RAMP])
    cols = np.array([c for _, c in HAIR_RAMP])
    red = np.stack([np.interp(t, keys, cols[:, c]) for c in range(3)], axis=-1)
    out = rgb.copy()
    out[mask] = red[mask]
    return np.clip(out * 255.0 + 0.5, 0, 255).astype(np.uint8)


def textures(doc: dict, blob: bytes, unit: str, folder: Path) -> list:
    rows = []
    for mi, mat in enumerate(doc["materials"]):
        row = {"material": mat.get("name"), "index": mi}
        base = mat.get("pbrMetallicRoughness", {}).get("baseColorTexture")
        if base is None:
            raise RuntimeError(f"{unit}: material {mi} has no base colour texture")
        image = np.asarray(Image.open(io.BytesIO(image_bytes(doc, blob, base["index"]))).convert("RGB"))
        if unit == "Icey":
            meshes = [i for i, m in enumerate(doc["meshes"]) if m["primitives"][0].get("material") == mi]
            mask = np.zeros(image.shape[:2], bool)
            for m in meshes:
                mask |= hair_mask(doc, blob, m, image)
            image = recolour_hair(image, mask)
            row["hair_texels"] = int(mask.sum())
        albedo = fit(Image.fromarray(image))
        albedo.save(folder / f"{unit}_m{mi}_albedo.png")
        row["albedo"] = f"{unit}_m{mi}_albedo.png"
        row["albedo_size"] = albedo.size
        if "normalTexture" in mat:
            normal = fit_normal(Image.open(io.BytesIO(image_bytes(doc, blob, mat["normalTexture"]["index"]))).convert("RGB"))
            normal.save(folder / f"{unit}_m{mi}_normal.png")
            row["normal"] = f"{unit}_m{mi}_normal.png"
        rows.append(row)
    return rows


# ---------------------------------------------------------------- audit
def audit(project: Path, unit: str) -> list:
    """Problems found comparing the refined GLB with the original (empty list = pass)."""
    problems = []
    doc, blob = read_glb(project / ORIGINAL.format(unit=unit))
    ref_path = project / REFINED_DIR.format(unit=unit) / f"{unit}_refined.glb"
    if not ref_path.is_file():
        return [f"{unit}: {ref_path.name} missing"]
    ref, rblob = read_glb(ref_path)
    if ref["nodes"] != doc["nodes"] or ref.get("scenes") != doc.get("scenes"):
        problems.append("node hierarchy/transforms differ")
    if [s["joints"] for s in ref["skins"]] != [s["joints"] for s in doc["skins"]]:
        problems.append("skin joints differ")
    if len(ref.get("animations", [])) != len(doc.get("animations", [])):
        problems.append("animation count differs")
    for a, (old, new) in enumerate(zip(doc.get("animations", []), ref.get("animations", []))):
        if old.get("name") != new.get("name") or old["channels"] != new["channels"]:
            problems.append(f"animation {a} channels differ")
            continue
        for so, sn in zip(old["samplers"], new["samplers"]):
            if so.get("interpolation") != sn.get("interpolation"):
                problems.append(f"animation {a} interpolation differs")
            for key in ("input", "output"):
                if not np.array_equal(accessor(doc, blob, so[key]), accessor(ref, rblob, sn[key])):
                    problems.append(f"animation {a} sampler {key} values differ")
    fixes = {}
    for s, (old, new) in enumerate(zip(doc["skins"], ref["skins"])):
        m, _ = bind_fix(doc, blob, s)
        fixes[s] = m
        ibm_old = accessor(doc, blob, old["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
        ibm_new = accessor(ref, rblob, new["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
        # Same skinning: IBM' * M == IBM for every joint.
        if not np.allclose(ibm_new @ m, ibm_old, atol=1e-4):
            problems.append(f"skin {s}: inverse binds do not compensate the bind fix")
    for mi, mesh in enumerate(ref["meshes"]):
        prim = mesh["primitives"][0]
        joints = accessor(ref, rblob, prim["attributes"]["JOINTS_0"])
        weights = accessor(ref, rblob, prim["attributes"]["WEIGHTS_0"])
        skin = next(n["skin"] for n in ref["nodes"] if n.get("mesh") == mi)
        if joints.max() >= len(ref["skins"][skin]["joints"]):
            problems.append(f"mesh {mi}: joint index out of range")
        if not np.allclose(weights.sum(1), 1.0, atol=1e-4):
            problems.append(f"mesh {mi}: weights do not sum to 1")
        if prim.get("material") != doc["meshes"][mi]["primitives"][0].get("material"):
            problems.append(f"mesh {mi}: material slot changed")
        # Decimation keeps the silhouette, so the rebased bounds must match M * original bounds.
        old_pos = accessor(doc, blob, doc["meshes"][mi]["primitives"][0]["attributes"]["POSITION"]).astype(np.float64)
        m = fixes[skin]
        expect = old_pos @ m[:3, :3].T + m[:3, 3]
        got = accessor(ref, rblob, prim["attributes"]["POSITION"])
        size = np.ptp(expect, axis=0).max()
        if np.abs(got.min(0) - expect.min(0)).max() > 0.03 * size or np.abs(got.max(0) - expect.max(0)).max() > 0.03 * size:
            problems.append(f"mesh {mi}: bounds {got.min(0).round(3)}..{got.max(0).round(3)} expected "
                            f"{expect.min(0).round(3)}..{expect.max(0).round(3)}")
    if ref.get("images") or ref.get("textures"):
        problems.append("refined GLB still embeds images")
    return problems


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--unit", action="append", choices=UNITS)
    parser.add_argument("--dump", help="crimson_decimate.py output for the (single) --unit")
    parser.add_argument("--audit", action="store_true")
    args = parser.parse_args()
    project = Path(args.project)
    if args.audit:
        failed = False
        for unit in args.unit or UNITS:
            problems = audit(project, unit)
            failed |= bool(problems)
            print(f"CRIMSON_AUDIT {unit} {'PASS' if not problems else 'FAIL ' + '; '.join(problems)}")
        raise SystemExit(1 if failed else 0)
    if not args.unit or len(args.unit) != 1 or not args.dump:
        parser.error("build mode needs exactly one --unit and its --dump")
    unit = args.unit[0]
    doc, blob = read_glb(project / ORIGINAL.format(unit=unit))
    folder = project / REFINED_DIR.format(unit=unit)
    folder.mkdir(parents=True, exist_ok=True)
    dump = np.load(args.dump)
    out, out_blob, report = refined_glb(doc, blob, dump)
    report["surface_preparation"] = "weld_matching_skin_weights_then_recalculate" if "repacked_uv" in dump else "legacy"
    report["repacked_uv"] = bool(dump["repacked_uv"]) if "repacked_uv" in dump else False
    write_glb(folder / f"{unit}_refined.glb", out, out_blob)
    # Meshy exports split almost every painted triangle. Smooth continuous fans
    # after decimation without re-exporting skins, UVs or animation channels.
    model_path = folder / f"{unit}_refined.glb"
    normal_path = folder / f"{unit}_normals.tmp.glb"
    normal_report = repair_split_normals(model_path, normal_path)
    normal_path.replace(model_path)
    report["normal_repair"] = {k: normal_report[k] for k in
        ("source_sha256", "output_sha256", "non_normal_bytes_identical", "crease_degrees", "meshes")}
    report["textures"] = textures(doc, blob, unit, folder)
    if report["repacked_uv"]:
        for row in report["textures"]:
            baked = Path(str(Path(args.dump).with_suffix("")) + f"_m{row['index']}_albedo.png")
            with Image.open(baked) as image:
                if max(image.size) > MAX_TEXTURE or image.mode not in ("RGB", "RGBA"):
                    raise RuntimeError(f"Invalid runtime albedo bake: {baked}")
            shutil.copyfile(baked, folder / row["albedo"])
            # A tangent-space normal map belongs to its original UV chart basis.
            # Never use the old map with the repacked UVs.
            row["normal_map_enabled"] = False
    report["materials"] = [m.get("name") for m in doc["materials"]]
    (folder / "refine.json").write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"CRIMSON_REFINE {unit} " + json.dumps({"meshes": report["meshes"], "rebased": [s["rebased"] for s in report["skins"]]}))


if __name__ == "__main__":
    main()
