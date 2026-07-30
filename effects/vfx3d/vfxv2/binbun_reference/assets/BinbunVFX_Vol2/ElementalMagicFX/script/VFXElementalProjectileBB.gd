@tool
extends VFXEmitterBB
class_name VFXElementalProjectileBB

var audio_stream_player : AudioStreamPlayer3D:
	get():
		if audio_stream_player:
			return audio_stream_player
		
		var result = get_node_or_null("AudioStreamPlayer3D")
		
		if !Engine.is_editor_hint():
			audio_stream_player = result
		
		return result

var light : OmniLight3D:
	get():
		if light:
			return light
		
		var result = get_node_or_null("OmniLight3D")
		
		if !Engine.is_editor_hint():
			light = result
		
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

## The tertiary color of this effect. The color this effect fades into at edges
@export var tertiary_color : Color:
	set(v):
		tertiary_color = v
		_set_shader_param("tertiary_color", tertiary_color)


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

@export_group("Light")

## Color of the emitted light of this effect
@export var light_color : Color:
	set(v):
		light_color = v
		if light: light.light_color = light_color

## Energy of the emitted light of this effect
@export var light_energy : float = 5.0:
	set(v):
		light_energy = v
		if light: light.vfx_light_energy = light_energy

## Energy of the indirect light emitted by this effect
@export var light_indirect_energy : float = 1.0:
	set(v):
		light_indirect_energy = v
		if light: light.vfx_light_indirect_energy = light_indirect_energy

## Energy of the light in volumetric fog emitted by this effect
@export var light_volumetric_fog_energy : float = 1.0:
	set(v):
		light_volumetric_fog_energy = v
		if light: light.vfx_light_volumetric_fog_energy = light_volumetric_fog_energy

@export_group("Shape")

## The noise texture that's used for the shape of this effect.
@export var noise_texture : Texture2D:
	set(v):
		noise_texture = v
		_set_shader_param("noise_texture", noise_texture)

## Value used to scale the [code]noise_texture[/code]. Higher values make the noise more zoomed out.
## [br][br]
## Note that scales smaller than 1.0 can have hard edges
@export var noise_scale : Vector2 = Vector2(1.0,1.0):
	set(v):
		noise_scale = v
		_set_shader_param("noise_scale", noise_scale)

## The velocity at which the [code]noise_texture[/code] moves.
## [br][br]
## Controls essentially the speed of the flames.
@export var noise_scroll : Vector2 = Vector2(0.1,0.5):
	set(v):
		noise_scroll = v
		_set_shader_param("noise_scroll", noise_scroll)

## Controls the curve of the sampled noises gradient
@export_exp_easing("inout") var noise_curve : float = 1.0:
	set(v):
		noise_curve = v
		_set_shader_param("noise_curve", noise_curve)

## Scale of the waves coming off the tip of the effect.
@export var wave_scale : float = 2.0:
	set(v):
		wave_scale = v
		_set_shader_param("wave_scale", wave_scale)

## Speed at which the waves move.
@export var wave_speed : float = 1.0:
	set(v):
		wave_speed = v
		_set_shader_param("wave_speed", wave_speed)

## Extra detail offset for the wave.
@export var wave_detail : float = 3.0:
	set(v):
		wave_detail = v
		_set_shader_param("wave_detail", wave_detail)

## Twists the wave.
@export var wave_twist : float = 3.0:
	set(v):
		wave_twist = v
		_set_shader_param("wave_twist", wave_twist)

## Length of the tail. Does not affect physical size, just how far the fade reaches.
@export_range(0.0, 1.0, 0.01) var tail_length : float = 0.7:
	set(v):
		tail_length = v
		_set_shader_param("tail_length", tail_length)

## Width of the spiral streaks
@export_range(0.0, 1.0, 0.01) var streaks_width : float = 0.1:
	set(v):
		streaks_width = v
		_set_shader_param("streaks_width", streaks_width)

@export_group("Spiral")

## How strong the spiral is
@export_range(0.0, 1.0, 0.01, "or_greater") var spiral_amount : float = 0.4:
	set(v):
		spiral_amount = v
		_set_shader_param("spiral_amount", spiral_amount)

## Scale of the spiral wave
@export var spiral_scale : float = 20.0:
	set(v):
		spiral_scale = v
		_set_shader_param("spiral_scale", spiral_scale)

## Controls how many spirals the spiral effect has.
@export var spiral_count : int = 3:
	set(v):
		spiral_count = v
		_set_shader_param("spiral_count", spiral_count)

## How fast the spiral scrolls
@export var spiral_speed : float = 4.0:
	set(v):
		spiral_speed = v
		_set_shader_param("spiral_speed", spiral_speed)

## How strong the spiral is
@export_range(0.0, 1.0, 0.01) var spiral_noise : float = 0.0:
	set(v):
		spiral_noise = v
		_set_shader_param("spiral_noise", spiral_noise)

@export_group("Particles")

## Amount of particles used by this effect.
@export var particles_amount : int = 64:
	set(v):
		particles_amount = v
		_set_particle_param("amount", particles_amount)

## Lifetime of the flame particles.
## [br][br]
## Increasing this will make the flames go higher.
@export var lifetime : float = 1.0:
	set(v):
		lifetime = v
		_set_particle_param("lifetime", lifetime)

## Explosiveness of the flame particles.
@export_range(0.0, 1.0, 0.01) var explosiveness : float = 0.0:
	set(v):
		explosiveness = v
		_set_shader_param("explosiveness", explosiveness)

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

var volume_animation : float = 1.0

## When enabled, will fade audio based on VFXEmitterBB parameter [code]emitting[/code]
## Does not affect [code]audio_playing[/code]
@export var animate_volume : bool = true

@export_range(-80.0, 80.0, 0.01, "suffix:dB") var volume_db : float = 0.0:
	set(v):
		volume_db = v
		if audio_stream_player: audio_stream_player.volume_db = lerpf(-24.0, volume_db, volume_animation)

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

@export var autoplay : bool = false:
	set(v):
		autoplay = v
		if audio_stream_player: audio_stream_player.autoplay = autoplay

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
