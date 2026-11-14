"""高模减面（二次误差，fast_simplification）。用 Pixal3D 的 venv 跑：

D:/Pixal3D/.venv/Scripts/python.exe tools/ba_parts/simplify.py <raw.glb> <low.obj> --faces 4000

Blender 自带 Collapse 在生成器网格上会卡在约 4 万面降不下去（试过体素重建、删碎块、放大 100 倍都无效），
所以减面在这里做，Blender 只负责展 UV 和烘焙颜色（tools/ba_parts/lowpoly_bake.py --low-obj）。
"""
import sys
import fast_simplification
import numpy as np
import trimesh

src, dst = sys.argv[1], sys.argv[2]
faces = int(sys.argv[sys.argv.index("--faces") + 1]) if "--faces" in sys.argv else 4000
loaded = trimesh.load(src, force="mesh", process=False)
# 只要几何；带着贴图 split 会给每个碎块复制一份整张贴图，内存爆掉
mesh = trimesh.Trimesh(vertices=loaded.vertices, faces=loaded.faces, process=False)
mesh.merge_vertices()   # glTF 在 UV 接缝处拆开的顶点按位置合并
mesh.remove_unreferenced_vertices()
# 去掉很小的碎块（内部残渣）
parts = mesh.split(only_watertight=False)
big = max(len(p.faces) for p in parts)
keep = [p for p in parts if len(p.faces) >= big * 0.002]
# 完全落在最大块包围盒里的块是内部残壳（减面后会从外表面穿出来，成片的暗斑），去掉
main = max(keep, key=lambda p: len(p.faces))
lo, hi = main.bounds
inner = [p for p in keep if p is not main and (p.bounds[0] > lo).all() and (p.bounds[1] < hi).all()
         and main.contains(p.vertices[::max(1, len(p.vertices) // 50)]).mean() > 0.8] if main.is_watertight else []
keep = [p for p in keep if not any(p is q for q in inner)]
print("inner shells dropped", len(inner))
mesh = trimesh.util.concatenate(keep)
print("high", len(mesh.faces), "parts", len(parts), "kept", len(keep))
v, f = fast_simplification.simplify(mesh.vertices.astype(np.float32), mesh.faces.astype(np.int64),
                                    target_count=faces, agg=7)
out = trimesh.Trimesh(vertices=v, faces=f, process=True)
trimesh.repair.fix_normals(out)
out.export(dst)
print("low", len(out.faces), "->", dst)
