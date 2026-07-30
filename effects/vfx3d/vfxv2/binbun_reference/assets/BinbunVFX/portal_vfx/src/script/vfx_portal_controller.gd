@tool
extends Node3D
class_name VFXPortalController

@onready var portal_mesh : MeshInstance3D = $PortalMesh
@onready var glow_mesh : MeshInstance3D = $GlowMesh
@onready var stencil_mesh : MeshInstance3D = $StencilMesh
@onready var particles : GPUParticles3D = $GPUParticles3D
@onready var light : OmniLight3D = $OmniLight3D
@onready var anim : AnimationPlayer = $AnimationPlayer

## Sets the size of the portal.
## [br][br]
## Prefer this over [code]scale[/code], because this scales textures and particles correctly.
@export var size : Vector2 = Vector2(2.0,2.0):
	set(v):
		size = v
		if _check_mesh():
			portal_mesh.mesh.size = size
			glow_mesh.mesh.size = size * 1.5
			stencil_mesh.mesh.size = size
			particles.process_material.emission_shape_scale = Vector3(size.x * 0.5, size.y * 0.5, 1.0)
			set_portal_param("size", size)

@export_group("Portal")

## Changes how the other side of the portal is rendered. 
## [br][br]
## [b]Opaque[/b]: Simply uses [code]secondary_color[/code] for what's in the portal.
## [br][br]
## [b]Warp[/b]: Distorts what's behind the portal. Unfortunately the same distortion can't be achieved with [b]Stencil[/b]
## [br][br]
## [b]Stencil[/b]: Allows you to use the stencil buffer in objects to only show them through this portal.
## [b]1.[/b] In the material of your object, set [code]stencil_mode[/code] to [b]Custom[/b] [br]
## [b]2.[/b] Set [code]stencil_flags[/code] to [b]Read[/b][br]
## [b]3.[/b] Set [code]stencil_compare[/code] to [b]Equal[/b][br]
## [b]4.[/b] Set [code]stencil_reference[/code] to [b]1[/b]
@export_enum("Opaque", "Warp", "Stencil") var portal_mode : int = 1:
	set(v):
		portal_mode = v
		if _check_mesh():
			set_portal_mode(portal_mode)

@export_group("Color")

@export var primary_color : Color:
	set(v):
		primary_color = v
		if _check_mesh():
			light.light_color = primary_color
			set_portal_param("primary_color", primary_color)
			particles.material_override.albedo_color = primary_color * emission_strength

@export var secondary_color : Color:
	set(v):
		secondary_color = v
		if _check_mesh():
			set_portal_param("secondary_color", secondary_color)

@export var emission_strength : float = 2.0:
	set(v):
		emission_strength = v
		if _check_mesh():
			set_portal_param("emission_strength", emission_strength)
			particles.material_override.albedo_color = primary_color * emission_strength

@export var dither : bool = false:
	set(v):
		dither = v
		if _check_mesh():
			set_portal_param("dither", dither)

@export_group("Shape")

## Used for the shape of the portal.
## [br][br]
## A radial gradient for example makes the portal round.
@export var shape_texture : Texture2D:
	set(v):
		shape_texture = v
		if _check_mesh():
			set_portal_param("shape_texture", shape_texture)

## Sets the noise used in the portal.
@export var noise_texture : Texture2D:
	set(v):
		noise_texture = v
		if _check_mesh():
			set_portal_param("noise_texture", noise_texture)

## Change how much the [code]noise_texture[/code] is warped.
## [br][br]
## Warping simply uses a scaled version of the [code]noise_texture[/code]
@export_range(0.0,1.0,0.01) var shape_warp : float = 0.1:
	set(v):
		shape_warp = v
		if _check_mesh():
			set_portal_param("shape_warp", shape_warp)

## General slider for controlling how open the portal is.
## [br][br]
## Note that it is animated by the open and close animations.
@export_range(0.0,1.0,0.01) var open_amount : float = 1.0:
	set(v):
		open_amount = v
		if _check_mesh():
			particles.scale = Vector3(open_amount, open_amount, 1.0)
			light.omni_range = pow(open_amount, 0.4) * 5.0
			if open_amount == 0.0: 
				particles.hide()
			else:
				particles.show()
			set_portal_param("open_amount", open_amount)

## Affects the thickness of the edges of the portal.
@export_range(0.0,1.0,0.01) var density : float = 0.4:
	set(v):
		density = v
		if _check_mesh():
			set_portal_param("density", density)

## Affects how much the edges of the portal shrink the deeper they are.
## [br][br]
## Note that it is animated by the open and close animations.
@export_range(0.0,1.0,0.01) var shrink_amount : float = 0.5:
	set(v):
		shrink_amount = v
		if _check_mesh():
			set_portal_param("shrink_amount", shrink_amount)

## Changes the softness of the edges.
## [br][br]
## When set to [code]0.0[/code], the portal effectively uses Alpha Cut for transparency instead of smooth alpha, which might improve performance.
@export_range(0.0,1.0,0.01) var edge_softness : float = 0.5:
	set(v):
		edge_softness = v
		if _check_mesh():
			set_portal_param("edge_softness", edge_softness)

@export_group("Depth")

## Changes how deep the parallax effect in the portal goes.
@export var depth : float = 1.0:
	set(v):
		depth = v
		if _check_mesh():
			set_portal_param("depth_amount", depth)

## Multiplier for [code]depth[/code].
## [br][br]
## Note that it is animated by the open and close animations.
@export var depth_mult : float = 1.0:
	set(v):
		depth_mult = v
		if _check_mesh():
			set_portal_param("depth_mult", depth_mult)

## Used to set the amount of parallax layers in the portal.
## [br][br]
## Higher values [i]might[/i] affect performance.
@export_range(0, 64, 1) var layers : int = 8:
	set(v):
		layers = v
		if _check_mesh():
			set_portal_param("layers", layers)

## Falloff curve of the parallax layers.
@export_exp_easing("attenuation") var fade : float = 1.0:
	set(v):
		fade = v
		if _check_mesh():
			set_portal_param("fade_amount", fade)

## Multiplier for [code]fade[/code].
## [br][br]
## Note that it is animated by the open and close animations.
@export var fade_mult : float = 1.0:
	set(v):
		fade_mult = v
		if _check_mesh():
			set_portal_param("fade_mult", fade_mult)

@export_group("Motion")

## General value to control speed scale of all parts of the effect.
## [br][br]
## Does not affect animation speed.
@export var speed_scale : float = 1.0:
	set(v):
		speed_scale = v
		if _check_mesh():
			set_portal_param("speed_scale", speed_scale)
			particles.speed_scale = speed_scale 

## The velocity at which the portals layers rotate.
## [br][br]
## Scales by depth.
@export var spin_motion : float = 0.1:
	set(v):
		spin_motion = v
		if _check_mesh():
			set_portal_param("spin_motion", spin_motion)

## The velocity at which the portals layers scroll inwards.
## [br][br]
## Scales by depth.
@export var inward_motion : float = 0.2:
	set(v):
		inward_motion = v
		if _check_mesh():
			set_portal_param("inward_motion", inward_motion)

## Baseline motion to which [code]spin_motion[/code] and [code]inward_motion[/code] is added on to.
@export var base_motion : float = 0.2:
	set(v):
		base_motion = v
		if _check_mesh():
			set_portal_param("base_motion", base_motion)

@export_group("Particles")

@export var emitting : bool = true:
	set(v):
		emitting = v
		if _check_mesh():
			particles.emitting = emitting

@export var amount : int = 32:
	set(v):
		amount = v
		if _check_mesh():
			particles.amount = amount

@export_group("Animation")

@export_tool_button("Play Open") var play_open = func(): open() 
@export_tool_button("Play Close") var play_close = func(): close() 

@export var animation_speed : float = 1.0:
	set(v):
		animation_speed = v
		if _check_mesh():
			anim.speed_scale = animation_speed

func _check_anim() -> void:
	if !anim:
		anim = $AnimationPlayer

func _check_mesh() -> bool:
	if portal_mesh and glow_mesh and stencil_mesh and particles and light:
		return true
	else:
		return false

func open() -> void:
	anim.play("open")
	anim.seek(0.0)

func close() -> void:
	anim.play("close")
	anim.seek(0.0)

func set_portal_param(param : String, value) -> void:
	if portal_mesh and glow_mesh and stencil_mesh:
		portal_mesh.material_override.set_shader_parameter(param, value)
		glow_mesh.material_override.set_shader_parameter(param, value)
		stencil_mesh.material_override.set_shader_parameter(param, value)

func set_portal_mode(mode : int) -> void:
	if portal_mesh and glow_mesh and stencil_mesh:
		_check_mesh()
		set_portal_param("portal_mode", mode)
		stencil_mesh.visible = mode == 2
