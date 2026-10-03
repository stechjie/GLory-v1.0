"""Author editable Guardian armour and export bone-local glTF parts.
Run with Blender --background --python THIS -- --source ... --rig-json ... --out ...
The original character rig/animations are a reference, never overwritten.
"""
import argparse, json, math, sys
from pathlib import Path
import bpy, bmesh
from mathutils import Vector, Matrix

args=sys.argv[sys.argv.index('--')+1:]
p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--rig-json',required=True);p.add_argument('--out',required=True)
a=p.parse_args(args); out=Path(a.out); out.mkdir(parents=True,exist_ok=True)
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=a.source)
refs=list(bpy.context.scene.objects)
for o in refs:o['role']='original_character_reference'
# Both Godot and glTF use Y-up. Blender import/export handles this fixed basis.
C=Matrix(((1,0,0,0),(0,0,-1,0),(0,1,0,0),(0,0,0,1)))
rig=json.loads(Path(a.rig_json).read_text()); bones={b['name']:b for b in rig['skeletons'][0]['bones']}
def rest(name):
 d=bones[name]['global_rest'];return Matrix(((*d['basis_x'],0),(*d['basis_y'],0),(*d['basis_z'],0),(*d['origin'],1))).transposed()
# Palette is stored per vertex; all armour shares ONE runtime material/surface per bone.
colors={'ivory':(.86,.9,.93,1),'gold':(.78,.54,.22,1),'pale_gold':(.92,.72,.36,1),'steel':(.065,.10,.17,1),'gem':(.24,.64,.78,1)}
mat=bpy.data.materials.new('GuardianArmourPalette');mat.use_nodes=True
nt=mat.node_tree; bs=nt.nodes.get('Principled BSDF');vc=nt.nodes.new('ShaderNodeVertexColor');vc.layer_name='Color';nt.links.new(vc.outputs['Color'],bs.inputs['Base Color']);bs.inputs['Metallic'].default_value=.45;bs.inputs['Roughness'].default_value=.33
parts={}; owned=[]
def finish(o,name,bone,col,bevel=0):
 o.name=name
 bm=bmesh.new();bm.from_mesh(o.data);bmesh.ops.recalc_face_normals(bm,faces=bm.faces);bm.to_mesh(o.data);bm.free()
 bpy.context.view_layer.objects.active=o;o.select_set(True)
 if bevel:
  mod=o.modifiers.new('Crafted edge bevel','BEVEL');mod.width=bevel;mod.segments=3
  bpy.ops.object.modifier_apply(modifier=mod.name)
 for poly in o.data.polygons:poly.use_smooth=True
 # Keep plate faces planar while bevels interpolate continuously.
 normal=o.modifiers.new('Area weighted craft normals','WEIGHTED_NORMAL');normal.keep_sharp=True;normal.weight=50
 bpy.ops.object.modifier_apply(modifier=normal.name)
 attr=o.data.color_attributes.new(name='Color',type='FLOAT_COLOR',domain='CORNER')
 for c in attr.data:c.color=colors[col]
 o.data.materials.clear();o.data.materials.append(mat)
 o['bone_name']=bone;o['design_part']=name;parts.setdefault(bone,[]).append(o);owned.append(o)
 o.select_set(False);return o

def prism(name,bone,points,center,u,v,w,depth,col,bevel=.006):
 c=Vector(center);u=Vector(u);v=Vector(v);w=Vector(w)
 # Author in Godot global rest coordinates, then convert to Blender world.
 verts=[C@(c+u*x+v*y+w*z).to_4d() for z in [-depth/2,depth/2] for x,y in points]
 n=len(points);faces=[tuple(reversed(range(n))),tuple(range(n,2*n))]
 faces += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
 mesh=bpy.data.meshes.new(name);mesh.from_pydata([tuple(x.xyz) for x in verts],[],faces);mesh.update()
 ob=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(ob)
 # The shield is gently bowed across its width. Tessellate only its large
 # faces before warping; bevels and crests share the same curved profile.
 if bone=='CC_Base_L_Forearm':
  bm=bmesh.new();bm.from_mesh(mesh)
  bmesh.ops.triangulate(bm,faces=list(bm.faces))
  if name in ['Aegis_gold_bevel','Aegis_ivory_face','Aegis_inner_plate']:
   bmesh.ops.subdivide_edges(bm,edges=list(bm.edges),cuts=3,use_grid_fill=True)
  for vertex in bm.verts:
   q=(C.inverted()@vertex.co.to_4d()).xyz
   across=q.y-.915
   q.z+=.065*max(0.0,1.0-(across/.245)**2)
   vertex.co=(C@q.to_4d()).xyz
  bm.to_mesh(mesh);bm.free();mesh.update()
 return finish(ob,name,bone,col,bevel)

def gem(name,bone,center,rx,ry,depth,col='gem',u=(1,0,0),v=(0,1,0),w=(0,0,1)):
 c=Vector(center);u=Vector(u);v=Vector(v);w=Vector(w)
 rim=[c-u*rx,c+v*ry,c+u*rx,c-v*ry]
 points=rim+[c+w*depth,c-w*depth*.3]
 if bone=='CC_Base_L_Forearm':
  for q in points:q.z+=.065*max(0.0,1.0-((q.y-.915)/.245)**2)
 verts=[C@q.to_4d() for q in points]
 faces=[(i,(i+1)%4,4) for i in range(4)]+[((i+1)%4,i,5) for i in range(4)]
 m=bpy.data.meshes.new(name);m.from_pydata([tuple(q.xyz) for q in verts],[],faces);m.update();o=bpy.data.objects.new(name,m);bpy.context.collection.objects.link(o)
 return finish(o,name,bone,col)

# The shield long axis follows the forearm in rest pose. It rotates upright
# with the existing idle/run poses, rather than being attached to world axes.
B='CC_Base_L_Forearm'; ctr=Vector((.65,.915,.19));U=Vector((0,1,0));V=Vector((-1,0,0));W=Vector((0,0,1))
outline=[(-.245,.27),(-.20,.38),(0,.445),(.20,.38),(.245,.27),(.225,-.17),(0,-.47),(-.225,-.17)]
prism('Aegis_gold_bevel',B,outline,ctr,U,V,W,.075,'gold',.012)
prism('Aegis_ivory_face',B,[(x*.87,y*.90) for x,y in outline],ctr+W*.055,U,V,W,.040,'ivory',.010)
# Finish the reverse as well: it is the dominant face for player units in battle.
prism('Aegis_inner_plate',B,[(x*.88,y*.91) for x,y in outline],ctr-W*.048,U,V,W,.026,'ivory',.006)
prism('Aegis_inner_rib',B,[(-.018,.31),(.018,.31),(.018,-.25),(0,-.34),(-.018,-.25)],ctr-W*.07,U,V,W,.018,'pale_gold',.003)
# Shift the whole tower outward in shoulder-down poses; this makes its
# silhouette survive a rear/overhead battle camera without enlarging it.

# Recessed dark separation and a raised central crest keep the shield readable at ~70px.
prism('Aegis_central_inlay',B,[(-.031,.33),(.031,.33),(.035,-.22),(0,-.35),(-.035,-.22)],ctr+W*.080,U,V,W,.012,'pale_gold',.004)
gem('Aegis_crystal_core',B,ctr+V*.12+W*.105,.057,.095,.035,u=U,v=V,w=W)
for sign in [-1,1]:
 pts=[(sign*x,y) for x,y in [(.052,.17),(.157,.25),(.125,.08),(.05,.035)]]
 if sign<0:pts.reverse()
 prism('Aegis_crest_wing',B,pts,ctr+W*.085,U,V,W,.022,'pale_gold',.004)
 for u,v in [(sign*.19,.25),(sign*.166,-.12)]:
  gem('Aegis_corner_pin',B,ctr+U*u+V*v+W*.070,.017,.017,.012,'pale_gold',U,V,W)
# Curved shoulder shells follow the humerus: an ivory dome and a thin
# gold rim replace the first trial's heavy extruded polygon blocks.
def shoulder_shell(name,bone,side,profile,col):
 verts=[];steps=24
 for along,radius in profile:
  for j in range(steps):
   theta=2*math.pi*j/steps
   q=Vector((side*(.29+along),1.012+radius*math.cos(theta),-.02+radius*1.06*math.sin(theta)))
   verts.append(tuple((C@q.to_4d()).xyz))
 faces=[]
 for row in range(len(profile)-1):
  for j in range(steps):
   faces.append((row*steps+j,row*steps+(j+1)%steps,(row+1)*steps+(j+1)%steps,(row+1)*steps+j))
 faces+=[tuple(reversed(range(steps))),tuple((len(profile)-1)*steps+j for j in range(steps))]
 mesh=bpy.data.meshes.new(name);mesh.from_pydata(verts,[],faces);mesh.update()
 ob=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(ob)
 return finish(ob,name,bone,col)
for side in [-1,1]:
 B='CC_Base_L_Upperarm' if side==1 else 'CC_Base_R_Upperarm'
 shoulder_shell('Pauldron_ivory_dome',B,side,[(-.09,.035),(-.055,.115),(0,.166),(.065,.182),(.13,.166),(.20,.132)],'ivory')
 shoulder_shell('Pauldron_forged_rim',B,side,[(.17,.151),(.184,.151),(.209,.139),(.224,.13),(.225,.118),(.210,.119)],'pale_gold')
 # Small crest on both anterior and posterior surfaces; broad original
 # shoulder decoration remains readable below the rim.
 for forward in [-1,1]:
  gem('Pauldron_lozenge',B,(side*.36,1.024,forward*.175-.02),.026,.049,.014,'pale_gold',w=(0,0,forward))
# A restrained forehead crest develops the existing split helmet silhouette.
B='CC_Base_Head'
prism('Crown_gilded_setting',B,[(-.045,0),(0,.085),(.045,0),(0,-.060)],(0,1.55,.303),(1,0,0),(0,.866,-.5),(0,.5,.866),.026,'pale_gold',.004)
gem('Crown_crystal_inset',B,(0,1.559,.33),.025,.051,.025,'gem',v=(0,.866,-.5),w=(0,.5,.866))

for obj in parts['CC_Base_L_Forearm']:
 for vertex in obj.data.vertices:vertex.co.z+=.075
# Create grouped bone-local runtime meshes; keep named parts and original rig
# separately editable in the blend file. Runtime parts are exported in rest pose.
collection=bpy.data.collections.new('AUTHORING — editable guardian armour');bpy.context.scene.collection.children.link(collection)
for o in owned:
 for co in list(o.users_collection):co.objects.unlink(o)
 collection.objects.link(o)
# Save source in its visible character rest coordinates before runtime transforms.
bpy.ops.wm.save_as_mainfile(filepath=str(out/'guardian_refinement.blend'))
exports=[]; summary=[]
for bone,objects in parts.items():
 bpy.ops.object.select_all(action='DESELECT')
 copies=[]
 for ob in objects:
  dup=ob.copy();dup.data=ob.data.copy();bpy.context.scene.collection.objects.link(dup);dup.select_set(True);copies.append(dup)
 bpy.context.view_layer.objects.active=copies[0];bpy.ops.object.join();obj=bpy.context.object
 obj.name=bone;matrix=C@rest(bone).inverted()@C.inverted()
 for vtx in obj.data.vertices:vtx.co=matrix@vtx.co
 # Bake triangulation now; output contains no modifiers or topology surprises.
 mod=obj.modifiers.new('Export triangulation','TRIANGULATE');bpy.ops.object.modifier_apply(modifier=mod.name)
 obj.data.materials.clear();obj.data.materials.append(mat)
 for poly in obj.data.polygons:poly.material_index=0
 exports.append(obj);summary.append({'bone':bone,'vertices':len(obj.data.vertices),'triangles':len(obj.data.polygons)})
bpy.ops.object.select_all(action='DESELECT')
for o in exports:o.select_set(True)
bpy.context.view_layer.objects.active=exports[0]
bpy.ops.export_scene.gltf(filepath=str(out/'guardian_armor.glb'),export_format='GLB',use_selection=True,export_animations=False,export_skins=False,export_yup=True,export_materials='EXPORT',export_vertex_color="MATERIAL",export_all_vertex_colors=True,export_attributes=False)
(out/'armor-manifest.json').write_text(json.dumps({'blender':bpy.app.version_string,'source_model':a.source,'parts':summary,'design':'Ivory and warm gold tank, broad layered pauldrons, crystal crest and forearm tower shield','coordinate_contract':'Each exported mesh uses its named original Godot bone rest-local coordinates; attach by bone name. Original body and animation resources remain unchanged.'},indent=2)+'\n')
print('GUARDIAN_ARMOR_COMPLETE',json.dumps(summary))
