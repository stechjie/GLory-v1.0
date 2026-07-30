@tool
extends VFXControllerBB

var audio_stream_player : AudioStreamPlayer3D:
	get():
		if audio_stream_player:
			return audio_stream_player
		
		var result = get_node_or_null("AudioStreamPlayer3D")
		
		if !Engine.is_editor_hint():
			audio_stream_player = result
		
		return result

@export_group("Color")

## The primary color of this effect.
@export var primary_color : Color:
	set(v):
		primary_color = v
		_set_shader_param("primary_color", primary_color)

## The secondary color of this effect.
@export var secondary_color : Color:
	set(v):
		secondary_color = v
		_set_shader_param("secondary_color", secondary_color)

## Emission of the effect. Higher values make it glowy.
@export var emission : float = 2.0:
	set(v):
		emission = v
		_set_shader_param("emission", emission)

## Controls the curve of the transition from [code]primary_color[/code] to [code]secondary_color[/code]
@export_exp_easing("inout") var color_curve : float = 1.0:
	set(v):
		color_curve = v
		_set_shader_param("color_curve", color_curve)

@export_group("Shape")

## The noise texture that's used for the shape of this effect.
@export var noise_texture : Texture2D:
	set(v):
		noise_texture = v
		_set_shader_param("noise_texture", noise_texture)

## Value used to scale the [code]noise_texture[/code]. Higher values make the noise more zoomed out.
## [br][br]
## Note that scales smaller than 1.0 can have hard edges
@export var noise_scale : Vector2 = Vector2(1.0,2.0):
	set(v):
		noise_scale = v
		_set_shader_param("noise_scale", noise_scale)

## The velocity at which the [code]noise_texture[/code] moves.
## [br][br]
## Controls essentially the speed of the flames.
@export var noise_scroll : Vector2 = Vector2(0.1,0.3):
	set(v):
		noise_scroll = v
		_set_shader_param("noise_scroll", noise_scroll)

## The exponent used on the noise shape
@export_exp_easing("inout") var shape_curve : float = 1.0:
	set(v):
		shape_curve = v
		_set_shader_param("shape_curve", shape_curve)

@export_group("Transparency")

## Hardness of the edges of each part of this effect
@export_range(0.0, 1.0, 0.01) var edge_hardness : float = 0.0:
	set(v):
		edge_hardness = v
		_set_shader_param("edge_hardness", edge_hardness)

## Cutoff of the hard edges
@export_range(0.0, 1.0, 0.01) var edge_position : float = 0.2:
	set(v):
		edge_position = v
		_set_shader_param("edge_position", edge_position)

@export_group("Audio")

## Audio stream used for the effect. Other audio related settings are the same as with AudioStreamPlayer3D
@export var audio_stream : AudioStream:
	set(v):
		audio_stream = v
		if audio_stream_player: audio_stream_player.stream = audio_stream

@export var attenuation_model : AudioStreamPlayer3D.AttenuationModel:
	set(v):
		attenuation_model = v
		if audio_stream_player: audio_stream_player.attenuation_model = attenuation_model

@export_range(-80.0, 80.0, 0.01, "suffix:dB") var volume_db : float = 0.0:
	set(v):
		volume_db = v
		if audio_stream_player: audio_stream_player.volume_db = volume_db

@export_range(0.1, 100.0, 0.01) var unit_size : float = 10.0:
	set(v):
		unit_size = v
		if audio_stream_player: audio_stream_player.unit_size = unit_size

@export_range(-24.0, 6.0, 0.01, "suffix:dB") var max_db : float = 3.0:
	set(v):
		max_db = v
		if audio_stream_player: audio_stream_player.max_db = max_db

@export_range(0.01, 4.0, 0.01) var pitch_scale : float = 1.0:
	set(v):
		pitch_scale = v
		if audio_stream_player: audio_stream_player.pitch_scale = pitch_scale

@export var audio_playing : bool = false:
	set(v):
		audio_playing = v
		if audio_stream_player: audio_stream_player.playing = audio_playing

@export var audio_autoplay : bool = false:
	set(v):
		audio_autoplay = v
		if audio_stream_player: audio_stream_player.autoplay = audio_autoplay

@export var stream_paused : bool = false:
	set(v):
		stream_paused = v
		if audio_stream_player: audio_stream_player.stream_paused = stream_paused

@export_range(0.0, 2000.0, 0.01, "suffix:m") var audio_max_distance : float = 3.0:
	set(v):
		audio_max_distance = v
		if audio_stream_player: audio_stream_player.max_distance = audio_max_distance

@export var max_polyphony : int = 1:
	set(v):
		max_polyphony = v
		if audio_stream_player: audio_stream_player.max_polyphony = max_polyphony

@export_range(0.0, 3.0, 0.01) var panning_strength : float = 1.0:
	set(v):
		panning_strength = v
		if audio_stream_player: audio_stream_player.panning_strength = panning_strength

@export var bus : StringName = &"Master":
	set(v):
		bus = v
		if audio_stream_player: audio_stream_player.bus = bus

@export_group("About")

@export_tool_button("Documentation", "ExternalLink") var docs_button : Callable:
	get():
		return func(): OS.shell_open("https://bun3d.com/assets/vfx/godot_elemetal_magic/")

@export_tool_button("Rate This Effect!", "Favorites") var rate_asset_button : Callable:
	get():
		return func(): OS.shell_open("https://binbun3d.itch.io/elemental-magic-fx/rate")
