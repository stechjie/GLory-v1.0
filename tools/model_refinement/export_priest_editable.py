"""Archive a complete editable refined character from the Godot GLB export.
The GLB/.blend retains the skeleton, shape keys, UVs, body and new halo.
The custom runtime shader remains authoritative; Blender uses its material preview.
"""
import argparse,sys
import bpy
p=argparse.ArgumentParser();p.add_argument('--source',required=True);p.add_argument('--out',required=True);p.add_argument('--albedo',required=True)
a=p.parse_args(sys.argv[sys.argv.index('--')+1:])
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=a.source)
material=bpy.data.materials.new('Priest editable silk and embroidery');material.use_nodes=True
nodes=material.node_tree.nodes;image=nodes.new('ShaderNodeTexImage');image.image=bpy.data.images.load(a.albedo);material.node_tree.links.new(image.outputs['Color'],nodes.get('Principled BSDF').inputs['Base Color']);nodes.get('Principled BSDF').inputs['Roughness'].default_value=.75
for ob in bpy.context.scene.objects:
 if ob.type=='MESH' and ob.name=='Mesh_0':ob.data.materials.clear();ob.data.materials.append(material)
 if ob.type=='MESH':ob['editing_note']='Runtime body channels derived from original FBX; rebuild runtime via build_priest_body.gd. Halo authored via build_priest_halo.py.'
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=a.out)
print('EDITABLE_PRIEST',[(ob.name,ob.type) for ob in bpy.context.scene.objects if ob.type in ['MESH','ARMATURE']])
