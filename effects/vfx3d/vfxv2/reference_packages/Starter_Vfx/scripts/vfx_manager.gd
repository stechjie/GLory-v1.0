@tool
class_name VfxManager
extends Node

@export_subgroup("VFX Settings")

@export var vfx_scale: float = 1.0:
	set(value):
		vfx_scale = value
		_apply_scale()


@export var palette: VfxPalette:
	set(value):
		if palette and palette.changed.is_connected(_apply_palette):
			palette.changed.disconnect(_apply_palette)
		
		palette = value
		
		if palette and not palette.changed.is_connected(_apply_palette):
			palette.changed.connect(_apply_palette)
		
		_apply_palette()


@export_subgroup("Playback & Preview")
@export var is_looping: bool = false:
	set(value):
		is_looping = value
		_apply_loop()


@export var preview_interval: float = 2.0 

var _timer: float = 0.0
var _base_values: Dictionary = {}


func _ready() -> void:
	for child in get_children():
		if child is GPUParticles3D:
			var particle_mat: ParticleProcessMaterial = child.process_material as ParticleProcessMaterial
			if particle_mat != null:
				_base_values[child] = {
					"scale_min": particle_mat.scale_min,
					"scale_max": particle_mat.scale_max,
					"min_velocity": particle_mat.initial_velocity_min,
					"max_velocity": particle_mat.initial_velocity_max,
					"min_angular_velocity": particle_mat.angular_velocity_min,
					"max_angular_velocity": particle_mat.angular_velocity_max,
					"gravity": particle_mat.gravity,
					"radius": particle_mat.emission_sphere_radius
				}
	_apply_loop()
	
	if palette and not palette.changed.is_connected(_apply_palette):
		palette.changed.connect(_apply_palette)
		
		_apply_palette()



func _process(delta: float) -> void:
	if not is_looping:
		_timer += delta
		if _timer >= preview_interval:
			_timer = 0.0
			restart_vfx()


func restart_vfx() -> void:
	for child in get_children():
		if child is GPUParticles3D:
			child.restart()


func _apply_scale() -> void:
	if _base_values.is_empty(): return
	
	for child in get_children():
		if child is GPUParticles3D and _base_values.has(child):
			var particle_mat = child.process_material as ParticleProcessMaterial
			var base = _base_values[child]
			
			particle_mat.scale_min = base["scale_min"] * vfx_scale
			particle_mat.scale_max = base["scale_max"] * vfx_scale
			particle_mat.initial_velocity_min = base["min_velocity"] * vfx_scale
			particle_mat.initial_velocity_max = base["max_velocity"] * vfx_scale
			particle_mat.angular_velocity_min = base["min_angular_velocity"] * vfx_scale
			particle_mat.angular_velocity_max = base["max_angular_velocity"] * vfx_scale
			particle_mat.gravity = base["gravity"] * vfx_scale
			
			if particle_mat.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_SPHERE or \
				particle_mat.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE:
				
				particle_mat.emission_sphere_radius = base["radius"] * vfx_scale


func _apply_palette() -> void:
	if not palette: 
		return
		
	for child in get_children():
		if child is GPUParticles3D:
			var particle_mat = child.process_material as ParticleProcessMaterial
			if particle_mat:
				if child.is_in_group("use_main_color"):
					particle_mat.color = palette.main_color
				elif child.is_in_group("use_secondary_color"):
					particle_mat.color = palette.secondary_color
				elif child.is_in_group("use_tertiary_color"):
					particle_mat.color = palette.tertiary_color
				
				if child.is_in_group("use_main_gradient") and palette.color_ramp != null:
					particle_mat.color_ramp = palette.color_ramp
					if palette.color_initial_ramp != null:
						particle_mat.color_initial_ramp = palette.color_initial_ramp
				elif child.is_in_group("use_secondary_gradient") and palette.secondary_color_ramp != null:
					particle_mat.color_ramp = palette.secondary_color_ramp
					if palette.secondary_color_initial_ramp != null:
						particle_mat.color_initial_ramp = palette.secondary_color_initial_ramp
				elif child.is_in_group("use_tertiary_gradient") and palette.tertiary_color_ramp != null:
					particle_mat.color_ramp = palette.tertiary_color_ramp
					if palette.tertiary_color_initial_ramp != null:
						particle_mat.color_initial_ramp = palette.tertiary_color_initial_ramp


func _apply_loop() -> void:
	for child in get_children():
		if child is GPUParticles3D:
			child.one_shot = not is_looping
