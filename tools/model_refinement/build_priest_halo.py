"""Blender 4.5+: editable halo with original character reference; no external assets.
blender --background --python-exit-code 1 --python THIS -- --source source-idle.glb --rig inventory.json --out DIR
"""
import argparse,json,math,sys
from pathlib import Path
import bpy,bmesh
from mathutils import Matrix,Vector
p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--rig',required=True);p.add_argument('--out',required=True);a=p.parse_args(sys.argv[sys.argv.index('--')+1:]);out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=a.source)
refs=list(bpy.context.scene.objects)
for o in refs:o['role']='original_character_reference';o.hide_render=True
C=Matrix(((1,0,0,0),(0,0,-1,0),(0,1,0,0),(0,0,0,1)))
b=next(b for b in json.loads(Path(a.rig).read_text())['idle']['skeletons'][0]['bones'] if b['name']=='CC_Base_Head')['global_rest'];rest=Matrix(((*b['basis_x'],0),(*b['basis_y'],0),(*b['basis_z'],0),(*b['origin'],1))).transposed()
mat=bpy.data.materials.new('IvoryGold');mat.use_nodes=True;n=mat.node_tree.nodes;vc=n.new('ShaderNodeVertexColor');vc.layer_name='Color';bs=n.get('Principled BSDF');mat.node_tree.links.new(vc.outputs['Color'],bs.inputs['Base Color']);bs.inputs['Metallic'].default_value=.35;bs.inputs['Roughness'].default_value=.34
parts=[]
def mesh(name,verts,faces,color):
 m=bpy.data.meshes.new(name);m.from_pydata([tuple((C@Vector((*v,1))).xyz) for v in verts],[],faces);m.update();o=bpy.data.objects.new(name,m);bpy.context.collection.objects.link(o)
 bm=bmesh.new();bm.from_mesh(m);bmesh.ops.recalc_face_normals(bm,faces=bm.faces);bm.to_mesh(m);bm.free()
 for f in m.polygons:f.use_smooth=True
 at=m.color_attributes.new(name='Color',type='FLOAT_COLOR',domain='CORNER')
 for c in at.data:c.color=color
 m.materials.append(mat);parts.append(o);return o
# Rounded substantial outer rim and thin porcelain inner rim: two coherent bands.
for name,R,r,z,col in [('Gilded_outer_rim',.337,.025,-.34,(.65,.40,.12,1)),('Porcelain_inner_rim',.302,.013,-.324,(.86,.9,.94,1))]:
 vs=[];fs=[];N=64;M=8
 for i in range(N):
  t=2*math.pi*i/N
  for j in range(M):
   u=2*math.pi*j/M;rr=R+r*math.cos(u);vs.append((rr*math.cos(t),1.54+rr*math.sin(t),z+r*math.sin(u)))
 for i in range(N):
  for j in range(M):fs.append((i*M+j,((i+1)%N)*M+j,((i+1)%N)*M+(j+1)%M,i*M+(j+1)%M))
 mesh(name,vs,fs,col)
# Four restrained compass leaves, the crown leaf is the primary read.
for i,(dx,dy,size) in enumerate([(0,.347,.065),(.347,0,.045),(0,-.347,.035),(-.347,0,.045)]):
 c=Vector((dx,1.54+dy,-.308));v=[c+Vector((x,y,z)) for x,y,z in [(-size*.48,0,0),(0,size,0),(size*.48,0,0),(0,-size,0),(0,0,.028),(0,0,-.012)]]
 mesh('Compass_leaf_'+str(i),v,[(j,(j+1)%4,4) for j in range(4)]+[((j+1)%4,j,5) for j in range(4)],(.85,.62,.25,1))
# Save world-space editable components with reference, export a joined bone-local mesh.
for o in bpy.context.selected_objects:o.select_set(False)
for o in parts:o.select_set(True)
bpy.context.view_layer.objects.active=parts[0];bpy.ops.object.join();o=bpy.context.object;o.name='PriestHalo';o['bone_name']='CC_Base_Head';o['design']='Double rim compass halo; Y-up authored centre 1.54, radius .337'
bpy.ops.wm.save_as_mainfile(filepath=str(out/'priest_halo_editable.blend'))
for v in o.data.vertices:v.co=(C@rest.inverted()@C.inverted()@v.co.to_4d()).xyz
bpy.ops.export_scene.gltf(filepath=str(out/'priest_halo.glb'),export_format='GLB',use_selection=True,export_animations=False,export_vertex_color='ACTIVE',export_all_vertex_colors=True)
print('PRIEST_HALO_EXPORTED',len(o.data.vertices),len(o.data.polygons))
