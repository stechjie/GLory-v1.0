#!/usr/bin/env python3
"""Repair only flat normal arrays in binary FBX; preserve every other property.

Normals are angle weighted at coincident control points, with a 60 degree
crease limit. UV splits are respected by the FBX unchanged; normal averaging
across them removes artificial lighting seams without merging vertices.
No external dependencies. Source files are never overwritten.
"""
from __future__ import annotations
import argparse, collections, hashlib, json, math, struct, zlib
from dataclasses import dataclass, field
from pathlib import Path

SCALARS = {b'Y':('h',2), b'C':('?',1), b'I':('i',4), b'F':('f',4), b'D':('d',8), b'L':('q',8)}
ARRAYS = {b'f':('f',4), b'd':('d',8), b'l':('q',8), b'i':('i',4), b'b':('B',1), b'c':('B',1)}
@dataclass
class Node:
    name: bytes
    props: list[bytes]
    children: list['Node'] = field(default_factory=list)
    terminator: bool = False
    def child(self, name):
        return next(c for c in self.children if c.name == name.encode())

def prop_end(data, offset):
    kind = data[offset:offset+1]
    if kind in SCALARS: return offset+1+SCALARS[kind][1]
    if kind in (b'S',b'R'): return offset+5+struct.unpack_from('<I', data, offset+1)[0]
    if kind in ARRAYS: return offset+13+struct.unpack_from('<I', data, offset+9)[0]
    raise ValueError(f'Unknown property {kind!r} at {offset}')

def decode(prop):
    kind=prop[:1]
    if kind in SCALARS:return struct.unpack_from('<'+SCALARS[kind][0],prop,1)[0]
    if kind in (b'S',b'R'):return prop[5:]
    count,encoding,length=struct.unpack_from('<III',prop,1)
    assert encoding in (0,1)
    raw=zlib.decompress(prop[13:]) if encoding else prop[13:]
    assert len(raw)==count*ARRAYS[kind][1]
    return struct.unpack('<'+str(count)+ARRAYS[kind][0],raw)

def encode_array(values, original):
    kind=original[:1];_,encoding,_=struct.unpack_from('<III',original,1)
    raw=struct.pack('<'+str(len(values))+ARRAYS[kind][0],*values)
    payload=zlib.compress(raw,9) if encoding else raw
    return kind+struct.pack('<III',len(values),encoding,len(payload))+payload

class BinaryFBX:
    def __init__(self,data):
        assert data[:23]==b'Kaydara FBX Binary  \x00\x1a\x00'
        self.data=data;self.version=struct.unpack_from('<I',data,23)[0]
        self.fmt='<QQQB' if self.version>=7500 else '<IIIB'
        self.header_size=struct.calcsize(self.fmt)
        self.roots=[];position=27
        while any(data[position:position+self.header_size]):
            node,position=self._parse_node(position);self.roots.append(node)
        self.tail=data[position:]
    def _parse_node(self,position):
        end,count,prop_length,name_length=struct.unpack_from(self.fmt,self.data,position)
        assert end>position
        position+=self.header_size
        node=Node(self.data[position:position+name_length],[]);position+=name_length
        prop_start=position
        for _ in range(count):
            next_pos=prop_end(self.data,position)
            node.props.append(self.data[position:next_pos]);position=next_pos
        assert position==prop_start+prop_length
        while position<end:
            if self.data[position:position+self.header_size]==bytes(self.header_size):
                node.terminator=True;position+=self.header_size;break
            child,position=self._parse_node(position);node.children.append(child)
        assert position==end
        return node,end
    def serialize(self):
        out=bytearray(self.data[:27])
        def append(node):
            start=len(out);out.extend(bytes(self.header_size));out.extend(node.name)
            for prop in node.props:out.extend(prop)
            for child in node.children:append(child)
            if node.terminator:out.extend(bytes(self.header_size))
            struct.pack_into(self.fmt,out,start,len(out),len(node.props),sum(map(len,node.props)),len(node.name))
        for node in self.roots:append(node)
        out.extend(self.tail)
        return bytes(out)
    def walk(self):
        def rec(nodes,path):
            for i,n in enumerate(nodes):
                new=path+f'/{n.name.decode(errors="replace")}[{i}]'
                yield new,n
                yield from rec(n.children,new)
        return rec(self.roots,'')

def sha(data):return hashlib.sha256(data).hexdigest()
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def sub(a,b):return tuple(x-y for x,y in zip(a,b))
def normalized(v):
    n=math.sqrt(dot(v,v));assert n>1e-12
    return tuple(x/n for x in v)
def triples(values):return [tuple(values[i:i+3]) for i in range(0,len(values),3)]

def smooth_geometry(geometry, crease_degrees=60):
    vertices=triples(decode(geometry.child('Vertices').props[0]))
    encoded_indices=decode(geometry.child('PolygonVertexIndex').props[0])
    indices=[i if i>=0 else -i-1 for i in encoded_indices]
    faces=[];corners=[]
    for corner,i in enumerate(encoded_indices):
        corners.append(corner)
        if i<0:faces.append(corners);corners=[]
    assert not corners and all(len(f)==3 for f in faces), 'Only audited triangulated geometry is accepted'
    result=[]
    for layer in (n for n in geometry.children if n.name==b'LayerElementNormal'):
        assert decode(layer.child('MappingInformationType').props[0])==b'ByPolygonVertex'
        assert decode(layer.child('ReferenceInformationType').props[0])==b'Direct'
        normals_node=layer.child('Normals');before=triples(decode(normals_node.props[0]))
        assert len(before)==len(indices)
        flat_faces=sum(all(dot(normalized(before[f[0]]),normalized(before[j]))>1-1e-8 for j in f) for f in faces)
        assert flat_faces==len(faces), 'Refuse to replace existing smooth/custom normals'
        face_normals=[normalized(before[f[0]]) for f in faces]
        # Positions coincide exactly in this FBX. Rounded keys merely make the
        # intended precision explicit and do not alter/control-point coordinates.
        keys=[tuple(round(c,7) for c in v) for v in vertices]
        by_position=collections.defaultdict(list);face_of={};weights={}
        for fi,f in enumerate(faces):
            for local,c in enumerate(f):
                point=vertices[indices[c]]
                u=normalized(sub(vertices[indices[f[(local+1)%3]]],point))
                v=normalized(sub(vertices[indices[f[(local+2)%3]]],point))
                weight=math.acos(max(-1,min(1,dot(u,v))))
                weights[c]=weight;face_of[c]=fi
                by_position[keys[indices[c]]].append(c)
        threshold=math.cos(math.radians(crease_degrees));after=[];hard_corners=0;changed=0
        for c,old in enumerate(before):
            reference=face_normals[face_of[c]];summed=[0.0]*3
            adjacent=by_position[keys[indices[c]]]
            accepted=[other for other in adjacent if dot(reference,face_normals[face_of[other]])>=threshold-1e-10]
            if len(accepted)<len(adjacent):hard_corners+=1
            for other in accepted:
                for axis in range(3):summed[axis]+=face_normals[face_of[other]][axis]*weights[other]
            new=normalized(summed);after.append(new)
            if dot(normalized(old),new)<1-1e-8:changed+=1
        normals_node.props[0]=encode_array([v for normal in after for v in normal],normals_node.props[0])
        smooth_flat_faces=sum(all(dot(after[f[0]],after[j])>1-1e-8 for j in f) for f in faces)
        # Equality across all ordinary smooth fans is stronger than merely
        # reducing face-flatness; sharp fans are allowed to retain a crease.
        smooth_fans=0;max_smooth_fan_delta=0.0
        for fan in by_position.values():
            if all(dot(face_normals[face_of[a]],face_normals[face_of[b]])>=threshold-1e-10 for a in fan for b in fan):
                smooth_fans+=1
                max_smooth_fan_delta=max(max_smooth_fan_delta,max(math.sqrt(sum((after[a][i]-after[fan[0]][i])**2 for i in range(3))) for a in fan))
        assert max_smooth_fan_delta<1e-9
        result.append({'vertices':len(vertices),'triangles':len(faces),'normal_vectors':len(after),'flat_faces_before':flat_faces,'flat_faces_after':smooth_flat_faces,'normal_vectors_changed':changed,'corners_with_preserved_crease':hard_corners,'smooth_fans':smooth_fans,'maximum_normal_difference_in_smooth_fan':max_smooth_fan_delta,'crease_degrees':crease_degrees})
    assert result
    return result

def repair(source,destination):
    original=source.read_bytes();fbx=BinaryFBX(original)
    assert fbx.serialize()==original, 'Original binary round trip must be byte identical'
    property_snapshot={p:list(n.props) for p,n in fbx.walk()}
    reports=[]
    for path,node in fbx.walk():
        if node.name==b'Geometry' and len(node.props)>=3 and decode(node.props[2])==b'Mesh':
            reports.extend(smooth_geometry(node))
    changed=[]
    for path,node in fbx.walk():
        if node.props!=property_snapshot[path]:
            assert node.name==b'Normals' and '/LayerElementNormal[' in path
            changed.append(path)
    assert changed and len(changed)==len(reports)
    fixed=fbx.serialize();again=BinaryFBX(fixed)
    assert again.serialize()==fixed
    fixed_snapshot={p:list(n.props) for p,n in again.walk()}
    assert fixed_snapshot.keys()==property_snapshot.keys()
    for path,props in property_snapshot.items():
        if path not in changed:assert props==fixed_snapshot[path],path
    destination.parent.mkdir(parents=True,exist_ok=True);destination.write_bytes(fixed)
    return {'source':str(source),'output':str(destination),'source_sha256':sha(original),'output_sha256':sha(fixed),'source_bytes':len(original),'output_bytes':len(fixed),'fbx_version':fbx.version,'changed_property_nodes':changed,'unchanged_other_property_nodes':len(property_snapshot)-len(changed),'meshes':reports}

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--model-prefix',default='dark_queen')
    parser.add_argument('--output-suffix',default='_smooth')
    args=parser.parse_args();reports=[]
    for action in ('attack','idle','run'):
        source=args.source_dir/(args.model_prefix+'_'+action+'.fbx')
        output=args.output_dir/(source.stem+args.output_suffix+source.suffix)
        assert output.resolve()!=source.resolve()
        reports.append(repair(source,output))
    assert len(reports)==3
    args.report.write_text(json.dumps(reports,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(reports,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
