class_name VfxPalette
extends Resource

@export_category("Plane Colors")
@export var main_color: Color = Color.WHITE:
	set(value):
		main_color = value
		emit_changed()
@export var secondary_color: Color = Color.WHITE:
	set(value):
		secondary_color = value
		emit_changed()
@export var tertiary_color: Color = Color.WHITE:
	set(value):
		tertiary_color = value
		emit_changed()

@export_category("Gradients")
@export_subgroup("Main Gradient")
@export var color_ramp: GradientTexture1D:
	set(value):
		color_ramp = value
		emit_changed()
@export var color_initial_ramp: GradientTexture1D:
	set(value):
		color_initial_ramp = value
		emit_changed()

@export_subgroup("Secondary Gradient")
@export var secondary_color_ramp: GradientTexture1D:
	set(value):
		secondary_color_ramp = value
		emit_changed()
@export var secondary_color_initial_ramp: GradientTexture1D:
	set(value):
		secondary_color_initial_ramp = value
		emit_changed()

@export_subgroup("Tertiary Gradient")
@export var tertiary_color_ramp: GradientTexture1D:
	set(value):
		tertiary_color_ramp = value
		emit_changed()
@export var tertiary_color_initial_ramp: GradientTexture1D:
	set(value):
		tertiary_color_initial_ramp = value
		emit_changed()
