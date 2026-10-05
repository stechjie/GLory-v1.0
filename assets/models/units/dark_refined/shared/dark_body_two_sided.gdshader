// Two-sided variant of dark_body.gdshader: same code (race_body.gdshaderinc), cull_disabled.
// Godot flips NORMAL on back faces, so inward-facing triangles light like their neighbours.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, ambient_light_disabled;

#include "res://assets/models/units/dark_refined/shared/race_body.gdshaderinc"
