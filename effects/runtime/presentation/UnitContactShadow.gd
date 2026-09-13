class_name UnitContactShadow
extends RefCounted

const SHADER := preload("res://shaders/unit_contact_shadow.gdshader")


static func create(node_name: String, footprint: Vector2) -> MeshInstance3D:
	var mesh := PlaneMesh.new()
	mesh.size = footprint
	var material := ShaderMaterial.new()
	material.shader = SHADER
	mesh.material = material
	var shadow := MeshInstance3D.new()
	shadow.name = node_name
	shadow.mesh = mesh
	shadow.position.y = 0.012
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return shadow
