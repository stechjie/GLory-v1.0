#!/usr/bin/env python3
"""Smooth Crimson's split triangle normals without changing GLB topology or animation.

Only NORMAL accessor bytes are patched. Edge-connected, consistently wound faces
within 75 degrees share angle-weighted normals across UV seams. Opposite hair-card
faces, disconnected shells and different skin weights never get welded together.
Requires numpy. Use --output-dir for review before replacing shipping files.
"""
from __future__ import annotations
import argparse
import collections
import hashlib
import json
import math
from pathlib import Path
import struct
import numpy as np

UNITS = ('crimson', 'dancer', 'drumer', 'hunter', 'armbreaker', 'Icey', 'skypierce', 'lattern')
DTYPES = {5121: '<u1', 5123: '<u2', 5125: '<u4', 5126: '<f4'}
WIDTHS = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def read_glb(data):
    magic, version, length = struct.unpack_from('<III', data)
    assert magic == 0x46546C67 and version == 2 and length == len(data)
    size, kind = struct.unpack_from('<II', data, 12)
    assert kind == 0x4E4F534A
    doc = json.loads(data[20:20 + size])
    bin_size, kind = struct.unpack_from('<II', data, 20 + size)
    assert kind == 0x004E4942 and 28 + size + bin_size == len(data)
    return doc, 28 + size


def array(doc, data, base, index):
    acc = doc['accessors'][index]
    assert 'sparse' not in acc and not acc.get('normalized', False)
    view = doc['bufferViews'][acc['bufferView']]
    assert view.get('buffer', 0) == 0
    dtype = np.dtype(DTYPES[acc['componentType']])
    width = WIDTHS[acc['type']]
    offset = base + view.get('byteOffset', 0) + acc.get('byteOffset', 0)
    stride = view.get('byteStride', width * dtype.itemsize)
    return np.ndarray((acc['count'], width), dtype=dtype, buffer=data,
                      offset=offset, strides=(stride, dtype.itemsize))


def smooth_normals(positions, normals, faces, joints, weights, crease_degrees=75):
    v = positions.astype(np.float64)
    f = faces.astype(np.int64).reshape(-1, 3)
    assert np.isfinite(v).all() and np.isfinite(normals).all()
    # Equal positions at a UV seam may share a normal, but different skinning
    # must stay independent or animation can expose a new lighting seam.
    keys = []
    for i, pos in enumerate(v):
        skin = tuple(sorted((int(j), round(float(w), 6))
                            for j, w in zip(joints[i], weights[i]) if w > 1e-7))
        keys.append((tuple(np.round(pos, 7)), skin))
    key_ids = {}; vertex_ids = []
    for key in keys:
        vertex_ids.append(key_ids.setdefault(key, len(key_ids)))
    pos_ids = np.array(vertex_ids)[f]
    fn = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    lengths = np.linalg.norm(fn, axis=1)
    valid = lengths > 1e-15
    fn /= np.maximum(lengths[:, None], 1e-30)
    angles = np.zeros((len(f), 3))
    for k in range(3):
        a = v[f[:, (k + 1) % 3]] - v[f[:, k]]
        b = v[f[:, (k + 2) % 3]] - v[f[:, k]]
        den = np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1)
        angles[:, k] = np.where(valid, np.arccos(np.clip(
            np.sum(a * b, axis=1) / np.maximum(den, 1e-30), -1, 1)), 0)
    count = len(f) * 3
    parent = np.arange(count)

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i, j):
        parent[find(i)] = find(j)

    edges = collections.defaultdict(list)
    for fi, ids in enumerate(pos_ids):
        if not valid[fi]:
            continue
        for k in range(3):
            l = (k + 1) % 3
            x, y = int(ids[k]), int(ids[l])
            edges[tuple(sorted((x, y)))].append((fi, k, l, x, y))
    threshold = math.cos(math.radians(crease_degrees))
    joined_edges = 0
    for adjacent in edges.values():
        for i, edge in enumerate(adjacent):
            for other in adjacent[i + 1:]:
                if edge[3] != other[4] or edge[4] != other[3]:
                    continue
                if fn[edge[0]] @ fn[other[0]] < threshold:
                    continue
                union(edge[0] * 3 + edge[1], other[0] * 3 + other[2])
                union(edge[0] * 3 + edge[2], other[0] * 3 + other[1])
                joined_edges += 1
    roots = np.array([find(i) for i in range(count)])
    sums = np.zeros((count, 3))
    np.add.at(sums, roots, (normals[f].astype(np.float64) * angles[:, :, None]).reshape(-1, 3))
    sums /= np.maximum(np.linalg.norm(sums, axis=1)[:, None], 1e-30)
    result = np.zeros_like(v)
    np.add.at(result, f.reshape(-1), sums[roots] * angles.reshape(-1, 1))
    lengths = np.linalg.norm(result, axis=1)
    result = np.where((lengths > 1e-12)[:, None],
                      result / np.maximum(lengths[:, None], 1e-30), normals)
    result = result.astype('<f4')
    assert np.isfinite(result).all()
    assert np.allclose(np.linalg.norm(result, axis=1), 1, atol=1e-5)

    def flat_count(n):
        ns = n[f]
        return int(np.sum(np.all(np.sum(ns[:, :1] * ns, axis=2) > .99999, axis=1)))

    return result, dict(vertices=len(v), triangles=len(f), joined_edges=joined_edges,
                        flat_faces_before=flat_count(normals), flat_faces_after=flat_count(result),
                        changed_normals=int(np.sum(np.linalg.norm(result - normals, axis=1) > 1e-5)))


def repair(source, destination):
    original = source.read_bytes()
    doc, base = read_glb(original)
    fixed = bytearray(original)
    allowed = np.zeros(len(original), dtype=bool)
    reports = []
    for mesh in doc['meshes']:
        for primitive in mesh['primitives']:
            assert primitive.get('mode', 4) == 4
            attrs = primitive['attributes']
            assert 'TANGENT' not in attrs, 'Regenerate authored tangents before changing normals'
            get = lambda name: array(doc, original, base, attrs[name])
            new, stats = smooth_normals(get('POSITION'), get('NORMAL'),
                array(doc, original, base, primitive['indices']), get('JOINTS_0'), get('WEIGHTS_0'))
            target = array(doc, fixed, base, attrs['NORMAL'])
            target[:] = new
            acc = doc['accessors'][attrs['NORMAL']]
            assert acc['componentType'] == 5126 and acc['type'] == 'VEC3'
            view = doc['bufferViews'][acc['bufferView']]
            start = base + view.get('byteOffset', 0) + acc.get('byteOffset', 0)
            stride = view.get('byteStride', 12)
            for i in range(len(new)):
                allowed[start + i * stride:start + i * stride + 12] = True
            reports.append(stats)
    # Stronger than comparing animation names/counts: EVERY non-normal byte,
    # including positions, UVs, indices, joint weights and animation keys, is identical.
    different = np.frombuffer(original, np.uint8) != np.frombuffer(fixed, np.uint8)
    assert not np.any(different & ~allowed)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(fixed)
    return dict(source=str(source), output=str(destination),
                source_sha256=hashlib.sha256(original).hexdigest(),
                output_sha256=hashlib.sha256(fixed).hexdigest(),
                non_normal_bytes_identical=True, crease_degrees=75, meshes=reports)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    assert args.source_dir.resolve() != args.output_dir.resolve(), 'Use a separate output directory'
    results = [repair(args.source_dir / u / f'{u}_refined.glb',
                      args.output_dir / u / f'{u}_refined.glb') for u in UNITS]
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'units': len(results), 'non_normal_bytes_identical': True}))

if __name__ == '__main__':
    main()
