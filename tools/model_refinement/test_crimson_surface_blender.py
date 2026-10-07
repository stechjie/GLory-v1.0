"""Run with Blender --background --python this_file.py; no project files are written."""
import sys
from pathlib import Path
import bpy
sys.path.insert(0, str(Path(__file__).resolve().parent))
from crimson_decimate import prepare_surface


def fixture(different_weights=False):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    mesh = bpy.data.meshes.new('SplitQuad')
    mesh.from_pydata([(0,0,0), (1,0,0), (1,1,0), (0,0,0), (1,1,0), (0,1,0)], [], [(0,1,2), (3,4,5)])
    obj = bpy.data.objects.new('SkinnedUVSeam', mesh)
    bpy.context.collection.objects.link(obj)
    a, b = obj.vertex_groups.new(name='A'), obj.vertex_groups.new(name='B')
    a.add([0,1,2], 1.0, 'REPLACE')
    (b if different_weights else a).add([3,4,5], 1.0, 'REPLACE')
    uv = mesh.uv_layers.new()
    for i, loop in enumerate(uv.data):
        loop.uv = (i / 7, i / 13)
    expected = sorted(tuple(loop.uv) for loop in uv.data)
    prepare_surface(obj)
    assert len(mesh.polygons) == 2, 'Welding must not delete clothing faces'
    assert sorted(tuple(loop.uv) for loop in mesh.uv_layers.active.data) == expected, 'Corner UVs changed'
    assert len(mesh.vertices) == (6 if different_weights else 4), 'UV seam not welded or distinct skin weights merged'
    assert all(p.use_smooth for p in mesh.polygons)
    for vertex in mesh.vertices:
        assert len(vertex.groups) == 1 and abs(vertex.groups[0].weight - 1) < 1e-6


fixture(False)
fixture(True)
print('CRIMSON_SURFACE_TEST PASS: UV preservation, continuous topology, skin-weight separation')
