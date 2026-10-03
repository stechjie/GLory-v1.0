extends "res://assets/models/units/god_guard_crystalbound/GodGuardCrystalboundAnimationTest.gd"
## Refines this character while retaining its original rig and animation data.
const BODY := preload("res://assets/models/units/god_guard_refined/guardian_body.tres")
const ARMOR := preload("res://assets/models/units/god_guard_refined/guardian_armor.glb")
const PALETTE := preload("res://assets/models/units/god_guard_refined/guardian_armor.tres")

func _ready() -> void:
	super._ready()
	var body := get_node("Skeleton3D/Mesh1_0") as MeshInstance3D
	body.material_override = BODY
	var skeleton := get_node("Skeleton3D") as Skeleton3D
	var source := ARMOR.instantiate()
	for part in source.find_children("*", "MeshInstance3D", true, false):
		var bone := skeleton.find_bone(str(part.name))
		if bone < 0:
			push_error("Guardian refinement part has unknown bone: " + str(part.name))
			continue
		var attachment := BoneAttachment3D.new()
		attachment.name = "Crafted_" + str(part.name)
		attachment.bone_name = skeleton.get_bone_name(bone)
		attachment.bone_idx = bone
		skeleton.add_child(attachment)
		var mesh := MeshInstance3D.new()
		mesh.name = "CraftedArmor"
		mesh.mesh = part.mesh
		mesh.material_override = PALETTE
		attachment.add_child(mesh)
	source.free()
