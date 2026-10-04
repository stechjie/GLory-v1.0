"""Blender 4.5: editable, deterministic priestess mitre inlay and blessing clasp.
Coordinates are authored in Godot skeleton rest space (Y up) and flipped at
export (Y -> -Z) so the GLB lands in the engine's handedness, exactly like the
halo precedent. Body, skin and animations remain the original runtime FBX; no
gameplay edits.

blender --background --python-exit-code 1 --python THIS.py -- \\
  --source <inventory source-idle.glb> \\
  --texture <original god_priestess_texture.png> \\
  --out DIR
"""
import argparse, sys
from pathlib import Path
import bpy
from mathutils import Vector

p = argparse.ArgumentParser()
p.add_argument('--source', required=True, help='source-idle.glb exported by priestess_inventory.gd')
p.add_argument('--texture', required=True, help='original god_priestess_texture.png for the editable blend')
p.add_argument('--out', required=True, help='directory for the editable .blend sources and the exported .glb parts')
a = p.parse_args(sys.argv[sys.argv.index('--') + 1:])
OUT = Path(a.out); OUT.mkdir(parents=True, exist_ok=True)

bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
def mat(name,c,metal=0,rough=.6):
 m=bpy.data.materials.new(name);m.diffuse_color=(*c,1);m.use_nodes=True
 p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=(*c,1);p.inputs['Metallic'].default_value=metal;p.inputs['Roughness'].default_value=rough
 return m
gold=mat('Warm champagne gold',(.72,.48,.16),.55,.32)
ivory=mat('Ivory ceremonial enamel',(.88,.86,.75),0,.7)
blue=mat('Blessing sapphire',(.08,.32,.48),.25,.3)
def xyz(p):
 z=p[2]-.09*(p[1]-1.49) if p[1]>1.45 else p[2]
 if .7<p[1]<1.0:z-=.04 # Seat clasp back into robe; avoid a floating plate in attack.
 return Vector((p[0],-z,p[1]))
def mesh(name,verts,faces,material):
 data=bpy.data.meshes.new(name);data.from_pydata([xyz(p) for p in verts],[],faces);data.update()
 ob=bpy.data.objects.new(name,data);bpy.context.collection.objects.link(ob);data.materials.append(material);return ob
def rod(name,a,b,r,material):
 d=xyz(b)-xyz(a);bpy.ops.mesh.primitive_cylinder_add(vertices=8,radius=r,depth=d.length,location=(xyz(a)+xyz(b))/2)
 o=bpy.context.object;o.name=name;o.rotation_mode='QUATERNION';o.rotation_quaternion=d.to_track_quat('Z','Y');o.data.materials.append(material);return o
def plaque(name,poly,z,depth,material):
 n=len(poly);vs=[(x,y,z+dz) for dz in [0,-depth] for x,y in poly]
 faces=[tuple(range(n)),tuple(reversed(range(n,n*2)))]+[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
 return mesh(name,vs,faces,material)
def jewel(name,x,y,z,w,h):
 return mesh(name,[(x-w,y,z),(x,y+h,z),(x+w,y,z),(x,y-h,z),(x,y,z+.026),(x,y,z-.016)],[(1,0,4),(2,1,4),(3,2,4),(0,3,4),(0,1,5),(1,2,5),(2,3,5),(3,0,5)],blue)
def export(part):
 bpy.ops.object.select_all(action='SELECT')
 bpy.context.view_layer.objects.active=next(o for o in bpy.context.selected_objects if o.type=='MESH')
 bpy.ops.object.join()
 bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
 bpy.ops.export_scene.gltf(filepath=str(OUT/(part+'.glb')),export_format='GLB',use_selection=True,export_animations=False)
 bpy.ops.wm.save_as_mainfile(filepath=str(OUT/(part+'.blend')))
 bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
poly=[(-.145,1.49),(.145,1.49),(.172,1.745),(0,1.858),(-.172,1.745)]
plaque('Mitre ivory inset',poly,.275,.025,ivory)
for i in range(len(poly)):
 a=poly[i];b=poly[(i+1)%len(poly)];rod('Raised mitre border',(*a,.292),(*b,.292),.009,gold)
rod('Mitre spine',(0,1.5,.295),(0,1.83,.295),.008,gold)
plaque('Diamond gold setting',[(-.062,1.674),(0,1.783),(.062,1.674),(0,1.565)],.307,.013,gold)
jewel('Mitre sapphire',0,1.674,.324,.041,.079)
export('priestess_mitre')
plaque('Clasp gold mount',[(-.075,.853),(0,.936),(.075,.853),(0,.755)],.235,.021,gold)
jewel('Blessing clasp',0,.853,.257,.046,.064)
for s in [-1,1]:
 rod('Clasp collar link',(s*.05,.90,.222),(s*.125,.94,.192),.009,gold)
export('priestess_clasp')
# Full editable original character with packed texture; overlay pieces are separate
# collections/files to avoid modifying the imported action's rig or shape keys.
bpy.ops.import_scene.gltf(filepath=str(a.source))
m=mat('Original priestess atlas', (1,1,1))
n=m.node_tree.nodes.new('ShaderNodeTexImage');n.image=bpy.data.images.load(str(a.texture))
m.node_tree.links.new(n.outputs['Color'],m.node_tree.nodes.get('Principled BSDF').inputs['Base Color'])
for ob in bpy.context.scene.objects:
 if ob.type=='MESH':ob.data.materials.clear();ob.data.materials.append(m)
bpy.ops.file.pack_all();bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'priestess_body_editable.blend'))
print('PRIESTESS_BUILD_COMPLETE')
